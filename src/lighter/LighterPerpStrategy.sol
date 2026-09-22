// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseStrategy, IAgentSet} from "@sherwood/strategies/BaseStrategy.sol";
import {IStrategy} from "@sherwood/interfaces/IStrategy.sol";
import {IZkLighter} from "./IZkLighter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ISyndicateGovernor} from "@sherwood/interfaces/ISyndicateGovernor.sol";
import {ISyndicateVault} from "@sherwood/interfaces/ISyndicateVault.sol";

/// @notice The hops walked to resolve the governance-owned counterparty
///         allowlist from this strategy: `vault() -> governor() -> tierRegistry()
///         -> isCounterpartyAllowed(ZK_LIGHTER)`. The SAME registry, reached the
///         same way, that `PortfolioStrategy` binds its swap adapter and feeds
///         through on v1.
/// @dev    Declared locally rather than imported, matching
///         `PortfolioStrategy.ITierBindingPath`: every hop is a length-checked
///         raw staticcall, so the strategy takes on no type dependency on the
///         governor or the registry. This exists to generate selectors, not to
///         type the responses.
interface ITierBindingPath {
    function governor() external view returns (address);
    function tierRegistry() external view returns (address);
    function isCounterpartyAllowed(address counterparty) external view returns (bool);
}

/**
 * @title LighterPerpStrategy
 * @notice Contract-owned Lighter (zkLighter) perp account. USDG is pulled from
 *         the vault and deposited into a strategy-owned margin account; an agent
 *         L2 trading key registered by the proposer drives trades off-chain via
 *         Lighter's API. The contract keeps the on-chain kill switch: cancel /
 *         market-close / withdraw all go through the venue authed by msg.sender.
 *
 *   Custody boundary (D1): the account is owned by THIS contract — only it can
 *   move funds. The agent key can trade but can never withdraw (changePubKey
 *   registers a trade-only L2 key; withdrawals are venue-authed to the account
 *   owner = this contract).
 *
 *   Settlement is THREE-STEP (G-H1 + C1/C2): withdrawals on Lighter are async
 *   priority requests that mature MUCH later (minutes to days), and the closing
 *   trades' PnL is not known until they fill.
 *     1. `initiateReturn()`        — cancel + both-side market-close every market.
 *     2. `queueWithdraw(ticks)`    — queue the drain, read off-chain AFTER the
 *                                    closes settle. Repeatable, and callable
 *                                    post-settle so an under-withdraw is never
 *                                    permanently stranded.
 *     3. `_settle()`               — claim the matured pending balance and push
 *                                    USDG to the vault, once everything queued
 *                                    has actually arrived.
 *
 *   Lane-B only: the venue exposes no on-chain mark anything here could trust —
 *   positions and margin are off-chain sequencer state and `IZkLighter` has no
 *   accessor for either. On protocol v1 that is simply how every template is
 *   treated: the vault's NAV is its idle asset balance, deposits and redemptions
 *   are shut while a proposal is open, and queued redemptions settle at the
 *   per-proposal price `onProposalSettled` stamps after this clone's `settle()`.
 *
 *   WHAT THIS TEMPLATE NO LONGER DECLARES. On `post-audit` it answered
 *   `IStrategyDelivery` (`hasUndeliveredValue` / `undeliveredValue` /
 *   `hasUnvaluedResidue`), which is how it told the vault about L2 margin it
 *   could not value, and it exposed an `onlyVault` `sweep()` door for the
 *   vault's `collectResidue`. v1 deleted that machinery and nothing on-chain
 *   reads either answer any more. Whether margin is still sitting at Lighter
 *   after settlement is now OFF-CHAIN KNOWLEDGE ONLY — the CLI / agent read it
 *   from the Lighter API — and the protocol makes no decision on it. The
 *   on-chain recovery path for anything that arrives late is `queueWithdraw`
 *   (still callable when `Settled`) → `recoverResiduals()` (claim onto this
 *   clone) → `BaseStrategy.rescueTo(USDG)` from a vault batch.
 */
contract LighterPerpStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    // ── Venue (shared by 4663 mainnet + 9994663 fork — mainnet replay) ──
    IZkLighter internal constant ZK_LIGHTER = IZkLighter(0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d);
    IERC20 internal constant USDG = IERC20(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168);
    uint16 internal constant USDG_ASSET_INDEX = 3;
    uint8 internal constant ROUTE_PERPS = 0;
    uint8 internal constant ORDER_MARKET = 1;
    uint8 internal constant SIDE_BID = 0; // long / buy
    uint8 internal constant SIDE_ASK = 1; // short / sell
    /// @dev Unwind closes use the widest legal price bound (SELL at 1, BUY at
    ///      2^32-1) so the close is GUARANTEED to fill — an unwind that silently
    ///      no-fills is strictly worse than a bad fill, because the margin then
    ///      never leaves the venue. The cost is that the unwind carries NO
    ///      slippage protection and is an MEV / adverse-fill surface: a
    ///      searcher who can see the pending priority request may fill it at a
    ///      punitive price. Accepted deliberately; see docs/lighter/LighterPerpStrategy.md.
    uint32 internal constant MARKET_SELL_PRICE = 1;
    uint32 internal constant MARKET_BUY_PRICE = type(uint32).max;

    // ── Init bounds ──
    uint256 internal constant PUBKEY_LEN = 40;
    uint8 internal constant MIN_API_KEY_INDEX = 2;
    uint8 internal constant MAX_API_KEY_INDEX = 254;
    uint16 internal constant MAX_MARKET_INDEX = 254;
    /// @dev M2: `initiateReturn` makes 2 venue calls per market in ONE tx. An
    ///      unbounded list could push it past the block gas limit, which would
    ///      make `returnsInitiatedAt` unreachable and therefore `_settle`
    ///      permanently unreachable — locking vault redemptions.
    uint256 internal constant MAX_MARKETS = 16;
    uint256 internal constant MIN_DEPOSIT = 1e6; // 1 USDG (6dp)
    /// @dev `IZkLighter.withdraw` takes `uint64` ticks and 1 tick == 1 USDG base
    ///      unit, so a deposit above this could never be drained in one request.
    uint256 internal constant MAX_DEPOSIT = type(uint64).max;

    // ── Chain guard (venue addresses above are hardcoded constants) ──
    uint256 internal constant CHAIN_ROBINHOOD = 4663;
    uint256 internal constant CHAIN_ROBINHOOD_FORK = 9994663;

    // ── Guardrail actions ──
    // NOTE: 4 (WITHDRAW) is RETIRED — superseded by the top-level `queueWithdraw`,
    // which must also work in the `Settled` state and therefore cannot route
    // through `BaseStrategy.updateParams` (Executed-only). The number is left as
    // a hole so existing encodings for 1/2/3/5 keep their meaning; 4 now reverts
    // `InvalidAction`.
    uint8 internal constant ACTION_CANCEL_ALL = 1; // ()
    uint8 internal constant ACTION_CLOSE_MARKET = 2; // (uint16 market, uint32 price, uint8 isAsk)
    uint8 internal constant ACTION_ROTATE_KEY = 3; // (bytes newPubKey40)
    uint8 internal constant ACTION_REGISTER_KEY = 5; // ()

    // ── Storage (per-clone) ──
    bytes public apiKeyPubKey; // 40-byte Goldilocks L2 trading key
    uint8 public apiKeyIndex; // 2..254
    uint16[] public markets; // perp markets this clone may trade
    uint256 public depositAmount; // exact USDG pulled at execute; [MIN_DEPOSIT, MAX_DEPOSIT]
    uint256 public returnsInitiatedAt; // block.number of the FIRST initiateReturn(); 0 = not initiated
    bool public settled;
    /// @notice Cumulative ticks requested via `queueWithdraw`. The settle guard's
    ///         denominator: nothing settles until this much has come back.
    uint256 public queuedTicks;
    /// @notice Cumulative USDG this contract has pushed to the vault itself —
    ///         which on v1 means the `_settle` push, and nothing else. Monotone,
    ///         so the settle guard's `accounted` figure only ever grows through
    ///         this term.
    /// @dev    DOES NOT COUNT `BaseStrategy.rescueTo`. That door is inherited,
    ///         `onlyVault`, not `virtual`, and moves the balance without a hook
    ///         this template could observe. A vault batch that rescues USDG off
    ///         this clone BEFORE `settle()` therefore shrinks `accounted` by what
    ///         it moved; the settle guard then reads that as a shortfall and
    ///         `acknowledgeShortfall()` is the way through — but ONLY when the
    ///         rescue and the settle run in separate transactions.
    ///
    ///         NEVER PUT `rescueTo(USDG)` AHEAD OF `settle()` IN ONE BATCH. Inside
    ///         that batch `accounted` reads the rescued amount as missing, so
    ///         settle reverts `WithdrawalInFlight`; outside it everything has
    ///         arrived, so `acknowledgeShortfall()` reverts `NoShortfall`; and
    ///         `unstick` replays the same calls. Only the owner's emergency settle
    ///         gets out. A pre-settle rescue is never needed: `_settle` claims the
    ///         matured pending balance itself and pushes the whole USDG balance.
    ///         `[recoverResiduals(), rescueTo(USDG)]` is for AFTER settle.
    uint256 public returnedAssets;
    /// @notice Proposer/vault-owner assertion that settling below `queuedTicks`
    ///         is intended (venue under-fill / write-off). Settle's escape hatch.
    bool public shortfallAcknowledged;
    /// @notice USDG actually pulled and deposited at `execute()`. Equal to
    ///         `depositAmount` on a fully covered proposal, and the
    ///         coverage-scaled figure otherwise — see `_execute`. Zero before
    ///         execution. THIS, not `depositAmount`, is what the unwind is
    ///         accounted against: `queueWithdraw` should drain this, and every
    ///         off-chain sizing (the CLI's `queue-withdraw --all`, the bench's
    ///         vault-delta assertion) must read it rather than the declaration.
    uint256 public deployedAmount;

    // ── Events ──
    event Deposited(uint256 amount, uint48 accountIndex);
    event AgentKeyRegistered(uint48 accountIndex, uint8 apiKeyIndex);
    event OrdersCancelled(uint48 accountIndex);
    event MarketClosed(uint16 market, uint8 isAsk);
    event WithdrawQueued(uint64 ticks, uint256 cumulativeTicks);
    event ReturnsInitiated(address indexed caller);
    event ShortfallAcknowledged(address indexed caller, uint256 queuedTicks, uint256 accounted);
    event Settled();
    event FundsSwept(uint256 amount);

    // ── Errors ──
    error InvalidPubKey();
    error InvalidApiKeyIndex();
    error NoMarkets();
    error InvalidMarket();
    error DuplicateMarket();
    error TooManyMarkets();
    error DepositTooSmall();
    error DepositTooLarge();
    error AccountNotRegistered();
    error InvalidAction();
    error NotAuthorized();
    error ReturnsNotInitiated();
    error AlreadyInitiated();
    error SettleTooSoon();
    error ZeroTicks();
    error NothingQueued();
    error WithdrawalInFlight(uint256 queued, uint256 accounted);
    error NoShortfall(uint256 queued, uint256 accounted);
    /// @notice The venue still reports a claimable balance after `_settle`
    ///         claimed it; settling would leave deliverable value on the clone.
    error SettleIncomplete(uint128 stillPending);
    error UnsupportedChain();
    /// @notice The vault's ERC-4626 asset is not the `USDG` this template pins.
    error AssetMismatch();
    /// @notice `ZK_LIGHTER` does not carry counterparty standing in the registry
    ///         reached from this vault's governor.
    error CounterpartyNotAllowed(address counterparty, address registry);
    /// @notice `vault() -> governor() -> tierRegistry()` yielded nothing at init.
    error TierRegistryUnresolved();

    /// @dev Template-only guard (ERC-1167 clones skip constructors). The venue and
    ///      asset addresses above are `constant`, so a template deployed on any
    ///      other chain would point at whatever code happens to live there.
    constructor() {
        if (block.chainid != CHAIN_ROBINHOOD && block.chainid != CHAIN_ROBINHOOD_FORK) revert UnsupportedChain();
    }

    /// @inheritdoc IStrategy
    function name() external pure returns (string memory) {
        return "LighterPerp";
    }

    /// @notice Decode: (bytes apiKeyPubKey, uint8 apiKeyIndex, uint16[] markets, uint256 depositAmount)
    /// @dev `depositAmount` IS MANDATORY AND EXPLICIT. It used to accept 0 as
    ///      "dynamic-all" — pull whatever USDG the vault happens to hold at
    ///      execute. That mode cannot survive the v1 governor: the batch
    ///      that executes this proposal is checked against a per-call cap, and
    ///      `SyndicateVault` refuses a pull that would breach `QueueReserveBreached`
    ///      or `BufferBreached`. All three are decided against a SIZE, and a size
    ///      only knowable at execute time is a size nobody could vote on — a
    ///      deposit arriving between the vote and the execute silently enlarged
    ///      the pull. So the amount is pinned here, bounded on both ends, and
    ///      `_execute` never re-reads the vault's balance.
    ///
    ///      ALSO BINDS THE VAULT ASSET. The venue asset is a `constant` in this
    ///      template, so a vault whose ERC-4626 asset is anything else would have
    ///      every pull and every push denominated in a token that vault does not
    ///      account for — `_pushToVault` would credit it nothing the governor's
    ///      asset-delta P&L can see, and every tick-to-asset comparison in the
    ///      settle guard would be in the wrong unit. Same bind, same reason, as
    ///      `MorphoSupplyStrategy`'s `LoanAssetMismatch`.
    function _initialize(bytes calldata data) internal override {
        (bytes memory pubKey, uint8 keyIndex, uint16[] memory mkts, uint256 depositAmount_) =
            abi.decode(data, (bytes, uint8, uint16[], uint256));

        if (pubKey.length != PUBKEY_LEN) revert InvalidPubKey();
        if (keyIndex < MIN_API_KEY_INDEX || keyIndex > MAX_API_KEY_INDEX) revert InvalidApiKeyIndex();
        uint256 n = mkts.length;
        if (n == 0) revert NoMarkets();
        if (n > MAX_MARKETS) revert TooManyMarkets();
        // M2: dedupe with a 255-bit set (indices are bounded to 254, so `1 << m`
        // always fits a uint256). A padded/duplicated list would otherwise make
        // `initiateReturn` emit redundant venue calls for no benefit.
        uint256 seen;
        for (uint256 i; i < n; i++) {
            uint16 m = mkts[i];
            if (m > MAX_MARKET_INDEX) revert InvalidMarket();
            // forge-lint: disable-next-line(incorrect-shift)
            uint256 bit = 1 << m; // a bit at position `m`, not `m` shifted by one
            if (seen & bit != 0) revert DuplicateMarket();
            seen |= bit;
        }
        if (depositAmount_ < MIN_DEPOSIT) revert DepositTooSmall();
        if (depositAmount_ > MAX_DEPOSIT) revert DepositTooLarge();

        if (address(USDG) != IERC4626(vault()).asset()) revert AssetMismatch();

        // INIT IS FAIL-CLOSED ON THE REGISTRY, AND ONLY INIT — the shape
        // `PortfolioStrategy._initialize` and `MorphoSupplyStrategy._initialize`
        // share on v1: a walk that yields NO registry is fatal here and a skip
        // everywhere else. A governor whose `tierRegistry` is unwired resolves to
        // nothing, and for that population an early-return bind would be a silent
        // no-op: the venue switch would read as armed while doing nothing.
        // Refusing at bind time costs a re-proposal; nothing has moved yet.
        if (_resolveTierRegistry() == address(0)) revert TierRegistryUnresolved();
        _requireAllowedVenue();

        apiKeyPubKey = pubKey;
        apiKeyIndex = keyIndex;
        markets = mkts;
        depositAmount = depositAmount_;
    }

    /// @notice Pull USDG from the vault and deposit into a strategy-owned Lighter
    ///         margin account (registers the account synchronously in this tx).
    function _execute() internal override {
        // NEVER RE-READ FROM THE VAULT, BUT SCALED BY THE PROPOSAL'S OWN
        // COVERAGE. `_initialize` pinned `depositAmount` and bounded it to
        // [MIN_DEPOSIT, MAX_DEPOSIT]; that declaration is still the CEILING and
        // the vault's live balance still never enters the sizing. What has
        // changed is that the ceiling is not always reachable: when the approve
        // quorum comes in short, `SyndicateGovernor._deriveAndStoreEffectiveCapital`
        // scales the whole proposal down by `raised / required` — the batch cap
        // AND every per-call cap. Pulling the pinned declaration into a scaled
        // batch reverts `CallCapExceeded` at the execute leg, a governance cycle
        // after the sizing decision was made and with the vault untouched.
        // Deploying less is the strictly better outcome, and the proposal was
        // already voted on as a ceiling.
        uint256 amountIn = _coverageScaledDeposit();

        // FAIL CLOSED RATHER THAN DEPLOY DUST. The bounds `_initialize`
        // enforced were on the DECLARATION; this is the first point at which
        // the amount that will actually move is known, so `MIN_DEPOSIT` is
        // re-asserted against it. A deeply under-covered proposal is not a
        // smaller strategy — it is a Lighter account whose unwind costs more in
        // venue round-trips than it holds, and the recoverable failure (the
        // proposal expires, the vault is untouched) beats the unrecoverable one.
        if (amountIn < MIN_DEPOSIT) revert DepositTooSmall();

        // RE-CERTIFY THE VENUE, and here only. Blocking `execute()` strands
        // nothing — the proposal expires at `executeBy` with the vault untouched
        // — while blocking `settle()` or `recoverResiduals()` would strand
        // capital already at Lighter. An unresolved registry skips, as in
        // `PortfolioStrategy._execute`; `_initialize` already refused that case
        // at bind time, and on a real v1 vault it cannot reach here anyway — the
        // vault resolves its strategy registry THROUGH `tierRegistry()`, so an
        // unwired registry refuses the whole batch (`NotARegisteredStrategy`)
        // before this clone is ever called.
        _requireAllowedVenue();

        _pullFromVault(address(USDG), amountIn);
        USDG.forceApprove(address(ZK_LIGHTER), amountIn);
        ZK_LIGHTER.deposit(address(this), USDG_ASSET_INDEX, ROUTE_PERPS, amountIn);

        // RECORDED, because from here on `depositAmount` is only a declaration.
        // The unwind and the CLI's drain sizing both reason about what actually
        // left the vault.
        deployedAmount = amountIn;

        // `_acct()` reverts if the venue did not register the account in this tx.
        // Every kill-switch path needs a nonzero index, so failing the whole
        // execute (funds stay in the vault) beats custodying capital in an
        // account this contract cannot address.
        emit Deposited(amountIn, _acct());
    }

    /// @notice Register / re-assert the agent L2 trading key. Idempotent, and
    ///         reusable for rotation via the stored key.
    /// @dev    PROPOSER OR VAULT OWNER, not proposer alone. See
    ///         `guardrailAction` for why the owner needs a door here: after
    ///         `removeAgent` the proposer is no longer live, and a key that
    ///         cannot be re-registered is an account nobody can trade out of.
    function registerAgentKey() external {
        _requireProposerOrOwner();
        uint48 acct = _acct();
        ZK_LIGHTER.changePubKey(acct, apiKeyIndex, apiKeyPubKey);
        emit AgentKeyRegistered(acct, apiKeyIndex);
    }

    /// @notice Proposer-only guardrails via `(uint8 action, bytes args)`:
    ///           1 CANCEL_ALL()
    ///           2 CLOSE_MARKET(uint16 market, uint32 price, uint8 isAsk)  — single-side, side chosen off-chain
    ///           3 ROTATE_KEY(bytes newPubKey40)                          — updates stored key + changePubKey
    ///           5 REGISTER_KEY()                                          — (re)register the stored key
    ///         (4 WITHDRAW is retired — see `queueWithdraw`.)
    function _updateParams(bytes calldata data) internal override {
        (uint8 action, bytes memory args) = abi.decode(data, (uint8, bytes));
        uint48 acct = _acct();

        if (action == ACTION_CANCEL_ALL) {
            ZK_LIGHTER.cancelAllOrders(acct);
            emit OrdersCancelled(acct);
        } else if (action == ACTION_CLOSE_MARKET) {
            // H1/M3: `market` is DELIBERATELY not checked against `markets`. The
            // registered L2 key can trade ANY Lighter market — the venue enforces
            // no whitelist — so `markets` is only the automatic unwind list, not
            // the agent's reach. If the agent opens a position outside that list,
            // this is the operator's only way to close it. Impact is bounded:
            // `baseAmount = 0` can only CLOSE a position, never open one.
            (uint16 market, uint32 price, uint8 isAsk) = abi.decode(args, (uint16, uint32, uint8));
            ZK_LIGHTER.createOrder(acct, market, 0, price, isAsk, ORDER_MARKET);
            emit MarketClosed(market, isAsk);
        } else if (action == ACTION_ROTATE_KEY) {
            bytes memory newPubKey = abi.decode(args, (bytes));
            if (newPubKey.length != PUBKEY_LEN) revert InvalidPubKey();
            apiKeyPubKey = newPubKey;
            ZK_LIGHTER.changePubKey(acct, apiKeyIndex, newPubKey);
            emit AgentKeyRegistered(acct, apiKeyIndex);
        } else if (action == ACTION_REGISTER_KEY) {
            ZK_LIGHTER.changePubKey(acct, apiKeyIndex, apiKeyPubKey);
            emit AgentKeyRegistered(acct, apiKeyIndex);
        } else {
            revert InvalidAction();
        }
    }

    /// @notice The same guardrail actions `updateParams` dispatches, reachable by
    ///         the VAULT OWNER as well as the proposer.
    /// @dev    CLOSES A LIVENESS HOLE, not a permission gap. Every guardrail —
    ///         `CANCEL_ALL`, `CLOSE_MARKET`, `ROTATE_KEY`, `REGISTER_KEY` — was
    ///         reachable only through `BaseStrategy.updateParams`, which is
    ///         `onlyProposer`, which since the pashov finding-#9 fix re-reads the
    ///         vault's LIVE agent set. So the owner's own revocation lever,
    ///         `SyndicateVault.removeAgent`, KILLED THE KILL SWITCH: the moment
    ///         a misbehaving agent was de-registered, nobody could cancel its
    ///         resting orders or close its positions, the L2 key stayed
    ///         registered and tradeable, and the account sat exposed until
    ///         `strategyDuration` elapsed and the permissionless `initiateReturn`
    ///         opened. Revoking the agent made the position LESS controllable,
    ///         which is precisely backwards.
    ///
    ///         The owner is the right second holder: `SyndicateVault.owner()` is
    ///         the party that could remove the agent in the first place, and the
    ///         actions here cannot move funds anywhere — `CLOSE_MARKET` passes
    ///         `baseAmount = 0`, which the venue can only use to CLOSE a
    ///         position, and every withdrawal is venue-authed to this contract,
    ///         which only ever pushes to `vault()`.
    ///
    ///         `updateParams` is left exactly as it was: it is the `IStrategy`
    ///         surface the governor and the CLI already speak, and widening a
    ///         base-contract modifier for one template would change the auth of
    ///         every other one.
    function guardrailAction(bytes calldata data) external {
        _requireProposerOrOwner();
        if (_state != State.Executed) revert NotExecuted();
        _updateParams(data);
    }

    /// @notice Unwind step 1: cancel every resting order and both-side
    ///         market-close every configured market. Queues NOTHING — the drain
    ///         amount is only knowable after these closes fill (C1).
    /// @dev    Auth: LIVE proposer or vault owner anytime post-execute; anyone
    ///         once `strategyDuration` has elapsed on the live proposal.
    ///         Re-callable by the privileged callers (closes are idempotent in
    ///         effect); a permissionless caller may only KICK OFF the unwind, so
    ///         a griefer cannot spam venue priority requests block after block.
    ///
    ///         THE OWNER BRANCH IS THE LIVENESS FIX (see `guardrailAction`).
    ///         Without it, `removeAgent` pinned settlement shut until
    ///         `strategyDuration` expired: the de-registered proposer failed the
    ///         live-agent check, and nobody else could start the unwind.
    ///
    ///         `_isLiveProposer` RATHER THAN A BARE `msg.sender != proposer()`.
    ///         The hand-rolled comparison bypassed the live-agent re-check that
    ///         `onlyProposer` performs, so a de-registered agent kept the
    ///         PRIVILEGED branch — unbounded re-calls with no timing gate —
    ///         which is the standing the revocation was supposed to remove. It
    ///         now falls through to the permissionless branch, where it has
    ///         exactly as much authority as anyone else and no more.
    function initiateReturn() external {
        if (_state != State.Executed) revert NotExecuted();

        if (!_isLiveProposer(msg.sender) && !_isVaultOwner(msg.sender)) {
            // M1: `getProposal(0)` returns a ZEROED struct rather than reverting,
            // so `block.timestamp < 0 + 0` is false and the timing gate alone is
            // fail-OPEN for everyone once `_activeProposal` has been cleared —
            // which is exactly what the emergency-settle paths do while this
            // strategy is still `Executed`.
            ISyndicateGovernor gov = ISyndicateGovernor(ISyndicateVault(vault()).governor());
            uint256 pid = gov.getActiveProposal();
            if (pid == 0) revert NotAuthorized();
            ISyndicateGovernor.StrategyProposal memory p = gov.getProposal(pid);
            if (p.strategy != address(this)) revert NotAuthorized();
            // Validator skew is seconds; `strategyDuration` is days.
            // forge-lint: disable-next-line(block-timestamp)
            if (block.timestamp < p.executedAt + p.strategyDuration) revert NotAuthorized();
            if (returnsInitiatedAt != 0) revert AlreadyInitiated();
        }

        uint48 acct = _acct();
        ZK_LIGHTER.cancelAllOrders(acct);
        // Trustless close: the contract can't read a position's sign, so it emits
        // both a SELL-close and a BUY-close per market — the one opposing the open
        // position fills, the other no-ops against a flat/absent position.
        // PROVEN on 4663, BOTH DIRECTIONS (H2 canary, account 623; see
        // test/lighter/harness/LighterH2Canary.md). 2026-08-23, long side: the SELL
        // closed a real long, the follow-on BUY no-opped against the flat book
        // (37 samples / 2 min). 2026-08-26, short mirror: the FIRST-fired SELL
        // left a real open short exactly unchanged, the BUY closed it, and a
        // final SELL against the flat book no-opped (37 samples / 2 min). Every
        // cell this ordering can produce is covered — BUY-vs-long cannot occur,
        // since the SELL always fires first and flattens a long.
        uint256 n = markets.length;
        for (uint256 i; i < n; i++) {
            uint16 m = markets[i];
            ZK_LIGHTER.createOrder(acct, m, 0, MARKET_SELL_PRICE, SIDE_ASK, ORDER_MARKET);
            ZK_LIGHTER.createOrder(acct, m, 0, MARKET_BUY_PRICE, SIDE_BID, ORDER_MARKET);
        }

        // Latch on the FIRST call only. Re-latching would reset the async-maturity
        // clock and let a repeat caller hold `_settle` in `SettleTooSoon` forever.
        if (returnsInitiatedAt == 0) returnsInitiatedAt = block.number;
        emit ReturnsInitiated(msg.sender);
    }

    /// @notice Unwind step 2: queue an async USDG withdrawal of `ticks`
    ///         (1 USDG = 1e6 ticks) from the margin account to THIS contract.
    /// @dev    C1: deliberately separate from `initiateReturn` and callable in
    ///         BOTH `Executed` and `Settled`. The closing trades' PnL is not known
    ///         until they fill, so any amount read off-chain before them is
    ///         structurally stale; under-stating must therefore stay correctable
    ///         AFTER settle, which rules out routing this through
    ///         `BaseStrategy.updateParams` (Executed-only).
    ///
    ///         STILL OPEN AFTER SETTLE ON v1, DECIDED RATHER THAN INHERITED. On
    ///         `post-audit` the post-settle drain fed a vault consumer
    ///         (`hasUnvaluedResidue` and `collectResidue`). v1 has neither — once
    ///         `Settled`, nothing on-chain reads `queuedTicks` again, and the
    ///         settle guard that does read it has already run. The reason to keep
    ///         the door is custody, not accounting: the Lighter account is
    ///         venue-authed to THIS contract, so this function is the only way
    ///         anyone will ever be able to request a withdrawal of margin left
    ///         behind by an under-stated drain, a late-closing position or an
    ///         acknowledged shortfall that later matures. Closing it at settle
    ///         would make that margin unrecoverable by construction. Keeping it
    ///         costs nothing: a post-settle call only moves value from the venue
    ///         TOWARD this clone, where `recoverResiduals()` claims it and a vault
    ///         batch's `rescueTo(USDG)` takes it home.
    ///
    ///         C2: proposer/vault-owner-gated. The permissionless unwind path
    ///         must never be able to choose the drain amount — a wrong amount
    ///         cannot be un-queued and, pre-fix, poisoned the whole settlement.
    ///
    ///         Destination is structurally this contract (the venue pays the
    ///         account owner) and this contract only ever pushes to `vault()`,
    ///         so widening auth adds no exfiltration surface.
    function queueWithdraw(uint64 ticks) external {
        if (_state == State.Pending) revert NotExecuted();
        _requireProposerOrOwner();
        if (ticks == 0) revert ZeroTicks();

        queuedTicks += ticks;
        ZK_LIGHTER.withdraw(_acct(), USDG_ASSET_INDEX, ROUTE_PERPS, ticks);
        emit WithdrawQueued(ticks, queuedTicks);
    }

    /// @notice Waive the settle guard's "everything queued has come back" check.
    /// @dev    The contract cannot read its own L2 balance, so it can only verify
    ///         that what it ASKED for has arrived. When the venue under-fills
    ///         (partial fill, forced liquidation, a write-off), that check would
    ///         otherwise hold `_settle` shut. Proposer or vault owner asserts the
    ///         shortfall is real and settlement should book it. It only relaxes a
    ///         timing gate — it cannot redirect funds, and anything that matures
    ///         later is still recoverable post-settle via `queueWithdraw` →
    ///         `recoverResiduals` → a vault batch's `rescueTo(USDG)`.
    ///
    ///         R3: the waiver is gated on an ACTUAL, currently-observable
    ///         shortfall. Ungated it was a one-call bypass of BOTH settle guards
    ///         from the moment the strategy went `Executed` — arm it before the
    ///         closes and before any drain, and `settle()` booked the entire
    ///         principal as a 100% loss with the funds still at the venue. The
    ///         stranding is recoverable (C1), but the damage is the Lane-B price
    ///         stamp: `onProposalSettled` freezes the per-proposal redeem price
    ///         at the deflated NAV, so a later top-up lands AFTER the stamp and
    ///         the haircut falls on the exiting LPs.
    ///         Preconditions, all three necessary:
    ///           - `ReturnsNotInitiated` — you cannot acknowledge a shortfall on
    ///             positions that were never closed.
    ///           - `NothingQueued`       — nor on a drain that was never asked
    ///             for; there is no denominator to fall short of.
    ///           - `NoShortfall`         — nor when everything asked for is
    ///             already accounted. Absent a vault-batch `rescueTo` (see
    ///             `returnedAssets`) `accounted` only grows: if it ever reaches
    ///             `queuedTicks`, `_settle` passes unaided and the waiver is not
    ///             needed. Arming while
    ///             `accounted == 0` (nothing matured yet) stays legal — that is
    ///             the normal venue-under-fill case.
    ///
    ///         THE WAIVER DOES NOT WAIVE THE GOVERNOR. v1's `settleProposal`
    ///         refuses to finish below a price-per-share floor derived from the
    ///         proposal's `maxDrawdownBps` (capped at `MAX_STAMP_DRAWDOWN_BPS`,
    ///         90%): an acknowledged shortfall deeper than the declared drawdown
    ///         makes the whole settlement revert `SettlePriceBelowFloor`, and the
    ///         proposal then needs `unstick` (floor at the 90% cap) or the
    ///         owner's guardian-reviewed emergency settle. Declare the drawdown
    ///         envelope for a perp venue with that in mind.
    function acknowledgeShortfall() external {
        _requireProposerOrOwner();
        if (returnsInitiatedAt == 0) revert ReturnsNotInitiated();
        if (queuedTicks == 0) revert NothingQueued();

        uint256 accounted = returnedAssets + ZK_LIGHTER.getPendingBalance(address(this), USDG_ASSET_INDEX)
            + USDG.balanceOf(address(this));
        if (accounted >= queuedTicks) revert NoShortfall(queuedTicks, accounted);

        shortfallAcknowledged = true;
        emit ShortfallAcknowledged(msg.sender, queuedTicks, accounted);
    }

    /// @notice Unwind step 3 (governor-called). Claims the matured pending USDG
    ///         and pushes this contract's entire USDG balance to the vault.
    /// @dev    ALL-OR-REVERT. A successful `settle()` leaves this clone holding
    ///         nothing it could have delivered: the venue's matured pending
    ///         balance is claimed and re-read (`SettleIncomplete` if anything is
    ///         still claimable), and then the whole USDG balance — claim, prior
    ///         third-party claims and donations alike — goes to `vault()`. USDG is
    ///         the only token this template ever takes custody of; anything else
    ///         sent here was sent by someone outside the template and is the
    ///         vault's to take with `rescueTo(token)`. What settlement CANNOT
    ///         deliver is value that is not yet this contract's to claim — ticks
    ///         queued but not matured, and L2 margin never queued — and the guards
    ///         below exist so that it is not booked as a loss by accident.
    ///
    ///         Guards, in order:
    ///           - `ReturnsNotInitiated` — positions were never closed.
    ///           - `SettleTooSoon`       — same block as the close (async maturity).
    ///           - `NothingQueued`       — no drain was ever requested, so a
    ///             permissionless settle would book the whole principal as a loss.
    ///           - `WithdrawalInFlight`  — a drain was requested but has not fully
    ///             arrived; settling now books a phantom loss a depositor could
    ///             sandwich. Replaces the old `pending == 0 && bal == 0` check,
    ///             which anyone could satisfy by donating 1 wei of USDG.
    ///         `acknowledgeShortfall()` waives the last two.
    ///
    ///         SCOPE (be precise about what this does NOT do): the denominator is
    ///         `queuedTicks`, which the proposer chooses. This is a LIVENESS /
    ///         anti-phantom-loss check — "everything I ASKED for came back" — and
    ///         NOT a completeness check. `queueWithdraw(1)` plus one tick maturing
    ///         satisfies it with the rest of the account still at the venue. It
    ///         cannot be made complete on-chain: the contract has no way to read
    ///         its own L2 balance (positions and margin are off-chain sequencer
    ///         state, and IZkLighter exposes no accessor). Completeness is an
    ///         OFF-CHAIN guarantee — the CLI's `queue-withdraw --all` reads the
    ///         true L2 balance from the Lighter API and hard-aborts on any nonzero
    ///         position — and it sits in the same trust bucket as the agent key.
    ///         See the trust model in docs/lighter/LighterPerpStrategy.md.
    function _settle() internal override {
        if (returnsInitiatedAt == 0) revert ReturnsNotInitiated();
        if (block.number <= returnsInitiatedAt) revert SettleTooSoon();

        uint128 pending = ZK_LIGHTER.getPendingBalance(address(this), USDG_ASSET_INDEX);
        uint256 bal = USDG.balanceOf(address(this));

        if (!shortfallAcknowledged) {
            if (queuedTicks == 0) revert NothingQueued();
            // 1 tick == 1 USDG base unit (both 6dp), so ticks and assets compare
            // directly.
            uint256 accounted = returnedAssets + pending + bal;
            if (accounted < queuedTicks) revert WithdrawalInFlight(queuedTicks, accounted);
        }

        if (pending > 0) {
            ZK_LIGHTER.withdrawPendingBalance(address(this), USDG_ASSET_INDEX, pending);
            // The venue is third-party code behind a proxy. If a claim ever pays
            // out less than it was asked for, settling anyway would leave a
            // claimable balance behind that the governor's P&L has already
            // booked as lost; refusing keeps settlement all-or-revert, and the
            // proposal's emergency paths remain for a venue that stays broken.
            uint128 left = ZK_LIGHTER.getPendingBalance(address(this), USDG_ASSET_INDEX);
            if (left != 0) revert SettleIncomplete(left);
        }
        _deliver();

        settled = true;
        emit Settled();
    }

    /// @notice Claim any matured pending balance from the venue INTO THIS
    ///         CONTRACT. Permissionless, repeatable, any lifecycle state.
    /// @dev    CLAIM-ONLY, AND DELIBERATELY NOT A PUSH. The permissionless half
    ///         is the H-4 property: a proposal resolved through
    ///         `finalizeEmergencySettle` never calls `strategy.settle()`, so
    ///         nobody privileged need be around to move matured funds off the
    ///         venue, and `withdrawPendingBalance` is itself permissionless at
    ///         Lighter anyway — this is a convenience wrapper, not a new power.
    ///
    ///         Why it stops at this clone instead of pushing on to the vault: on
    ///         v1 the only thing that turns USDG in the vault into share value is
    ///         the vault's idle balance, and the vault is open to deposits
    ///         whenever no proposal is open. A permissionless push would let
    ///         anyone choose the block a late tranche lands in NAV, i.e. deposit
    ///         in front of it and take a slice of recovered principal that
    ///         belonged to the LPs who carried the loss. `BaseStrategy.rescueTo`
    ///         is `onlyVault`, so the push happens inside a governor batch, and
    ///         batches only run while a proposal is open — when deposits are
    ///         shut. That protects the PUSH, not the whole window: between this
    ///         clone's settle and the next proposal's Draft, deposits are open
    ///         while the unrecovered margin is visible on-chain
    ///         (`getPendingBalance`, the clone's USDG balance), and v1's deposit
    ///         lock reads only `openProposalCount()`. Anyone depositing in that
    ///         window shares the late tranche when it lands. The template cannot
    ///         close that on v1; operators must propose the recovery promptly (or
    ///         use the owner's emergency path) and should queue the true balance
    ///         before settling so there is nothing to recover. The removed `onlyVault` `sweep()` did the claim and the push
    ///         in one call for `post-audit`'s `collectResidue`; v1 has no such
    ///         dispatcher, and a batch can carry `[recoverResiduals(),
    ///         rescueTo(USDG)]` against this clone to get the same effect. The
    ///         price of routing through a batch: the vault's governor measures
    ///         P&L as the vault's asset delta across the proposal, so a late
    ///         tranche rescued inside a LATER proposal's batch is booked as that
    ///         proposal's profit and pays its performance fee. Accepted — the
    ///         alternative is a front-runnable NAV jump.
    function recoverResiduals() external {
        uint128 pending = ZK_LIGHTER.getPendingBalance(address(this), USDG_ASSET_INDEX);
        if (pending > 0) ZK_LIGHTER.withdrawPendingBalance(address(this), USDG_ASSET_INDEX, pending);
    }

    // ── Views ──

    /// @notice This contract's Lighter account index (0 until the first deposit).
    function accountIndex() external view returns (uint48) {
        return ZK_LIGHTER.addressToAccountIndex(address(this));
    }

    /// @notice USDG ticks matured on Lighter and awaiting claim.
    function pendingBalance() external view returns (uint128) {
        return ZK_LIGHTER.getPendingBalance(address(this), USDG_ASSET_INDEX);
    }

    // ── Internal ──

    /// @dev Shared account-index read. Every venue-calling path goes through this
    ///      so none of them can address account 0 (which is a DIFFERENT account,
    ///      not "no account") if registration ever stops being synchronous.
    function _acct() internal view returns (uint48 acct) {
        acct = ZK_LIGHTER.addressToAccountIndex(address(this));
        if (acct == 0) revert AccountNotRegistered();
    }

    // ── Auth ──

    /// @dev `BaseStrategy.onlyProposer`'s predicate, as an expression rather than
    ///      a modifier, so the paths that also admit the vault owner can consult
    ///      it instead of hand-rolling `msg.sender == proposer()`.
    ///
    ///      THAT HAND-ROLLED COMPARISON WAS THE BUG. `queueWithdraw`,
    ///      `acknowledgeShortfall` and `initiateReturn` each wrote it out, which
    ///      skipped the LIVE agent-set re-check `onlyProposer` performs — so
    ///      `SyndicateVault.removeAgent` did not actually revoke anything on an
    ///      already-deployed clone, and the whole point of the pashov finding-#9
    ///      fix (`BaseStrategy.onlyProposer`) was that revocation must bite.
    ///
    ///      Byte-for-byte the same read as the modifier, including the raw
    ///      staticcall and the explicit length check: a typed call into a vault
    ///      that cannot answer `isAgent` would revert in THIS frame with no data,
    ///      turning a missing selector into an undecodable failure of every
    ///      proposer-gated path rather than a stated one. Unanswerable resolves
    ///      to FALSE here, which for a caller who is also not the owner means
    ///      `NotAuthorized` — closed, matching the modifier.
    function _isLiveProposer(address who) internal view returns (bool) {
        if (who != proposer()) return false;
        (bool ok, bytes memory ret) = vault().staticcall(abi.encodeCall(IAgentSet.isAgent, (who)));
        return ok && ret.length == 32 && abi.decode(ret, (bool));
    }

    /// @dev The vault owner — the party that can seat and remove agents, and
    ///      therefore the right holder of the second key on every guardrail.
    function _isVaultOwner(address who) internal view returns (bool) {
        return who == ISyndicateVault(vault()).owner();
    }

    function _requireProposerOrOwner() internal view {
        if (!_isLiveProposer(msg.sender) && !_isVaultOwner(msg.sender)) revert NotAuthorized();
    }

    // ── Governance-allowlist binding ──

    /// @dev BINDS THE VENUE ON THE COUNTERPARTY AXIS, the way
    ///      `PortfolioStrategy` binds its swap adapter. `ZK_LIGHTER`
    ///      is a `constant` here rather than proposer input, so this is not
    ///      protection against a hostile address — it is the governance switch
    ///      that lets an owner make this template INERT without touching the
    ///      `StrategyFactory` allowlist or waiting on a redeploy. Lighter is a
    ///      third-party rollup whose sequencer this protocol does not control;
    ///      "stop opening new positions there, now" needs to be one owner call.
    ///
    ///      On v1 `isCounterpartyAllowed` is the ONLY address axis the
    ///      `TierRegistry` keeps, and it confers nothing on a governor batch —
    ///      the vault admits batch targets structurally (a registered strategy
    ///      or the vault asset under `AssetCallRules`). So the grant means
    ///      exactly "a reviewed template may hand this address funds from inside
    ///      its own code path", which is what `_execute`'s `forceApprove` +
    ///      `deposit` does and nothing more.
    ///
    ///      CODEHASH CAVEAT. The registry snapshots the counterparty's codehash
    ///      at grant time and stops vouching if it changes. `ZK_LIGHTER` is a
    ///      proxy, whose runtime code does not change across an implementation
    ///      upgrade, so a Lighter upgrade does NOT drop the grant. Re-review on
    ///      every venue upgrade is an operator duty; the switch below is how to
    ///      act on it.
    ///
    ///      Called from `_initialize` (fail-CLOSED, including on an unresolved
    ///      registry) and from `_execute` (re-certified, degrading OPEN on an
    ///      unresolved registry). Deliberately NOT from `initiateReturn`,
    ///      `queueWithdraw`, `_settle`, `recoverResiduals` or the guardrails:
    ///      those are the exit path and the kill switch, and gating them would
    ///      hand a demotion — or an unreachable registry — the power to freeze
    ///      capital already at the venue. `MorphoSupplyStrategy._requireAllowedMorpho`
    ///      spells the same asymmetry out.
    ///
    ///      Skips on an unresolved registry, like `PortfolioStrategy`'s
    ///      `_requireAllowedAdapter`; `_initialize` is fail-closed on that case
    ///      separately.
    function _requireAllowedVenue() private view {
        address registry = _resolveTierRegistry();
        if (registry == address(0)) return;
        if (!_isCounterpartyAllowed(registry, address(ZK_LIGHTER))) {
            revert CounterpartyNotAllowed(address(ZK_LIGHTER), registry);
        }
    }

    /// @dev The `vault() -> governor() -> tierRegistry()` walk. `address(0)` when
    ///      any hop is unreadable (no `governor()` surface, a governor without
    ///      the getter, or `tierRegistry() == 0`).
    function _resolveTierRegistry() private view returns (address registry) {
        address governor_ = _readAddress(vault(), abi.encodeCall(ITierBindingPath.governor, ()));
        if (governor_ == address(0)) return address(0);
        registry = _readAddress(governor_, abi.encodeCall(ITierBindingPath.tierRegistry, ()));
    }

    /// @dev `PortfolioStrategy._isCounterpartyAllowed`, byte for byte. A codeless
    ///      registry, a revert, or a return that is not exactly one word all
    ///      read as "not allowed" and surface as the named
    ///      `CounterpartyNotAllowed`.
    ///
    ///      DECODES THE WORD, where post-audit's copy read `word != 0`. The
    ///      difference is a returned word outside `{0, 1}`: `word != 0` read it
    ///      as a GRANT, while `abi.decode(ret, (bool))` reverts in this frame.
    ///      Both refusal shapes are closed — `_initialize` and `_execute` are
    ///      the only callers, and neither moves funds before this check — so the
    ///      stricter one is taken, with its cost stated: a malformed registry
    ///      answer fails init / execute with empty revert data instead of a
    ///      named error.
    function _isCounterpartyAllowed(address registry, address venue) private view returns (bool) {
        if (registry.code.length == 0) return false;
        (bool ok, bytes memory ret) =
            registry.staticcall(abi.encodeCall(ITierBindingPath.isCounterpartyAllowed, (venue)));
        if (!ok || ret.length != 32) return false;
        return abi.decode(ret, (bool));
    }

    // ── Coverage scaling ──

    /// @dev The USDG `_execute` will actually pull: `depositAmount` scaled by
    ///      the SAME `raised / required` ratio the governor applied to the
    ///      proposal at execute time, expressed as `effectiveMaxCapital /
    ///      maxCapital` because those are the two figures a strategy can read.
    ///
    ///      WHY THE RATIO AND NOT `min(depositAmount, effectiveMaxCapital)`.
    ///      There are TWO caps in play and the smaller one is not the one that
    ///      names the batch. `effectiveMaxCapital` is the batch-level net-outflow
    ///      meter; `BatchExecutorLib` additionally meters THIS call's gross
    ///      outflow against `_scaleCaps`'s `floor(cap_i * raised / required)`.
    ///      A proposal normally declares `maxCapital` as the vault's whole TVL
    ///      and `cap_i` as just the deploy size (the fork bench does exactly
    ///      that), so `min(depositAmount, effectiveMaxCapital)` resolves to the
    ///      unscaled `depositAmount` and still breaks the per-call cap. The
    ///      ratio form cannot: `floor(dep * floor(max*r/q) / max) <=
    ///      floor(dep * r / q) = scaledCap_i` for any `dep <= cap_i`, because the
    ///      inner floor only ever moves the numerator DOWN. The rounding gap is
    ///      at most a couple of base units, always on the safe side.
    ///
    ///      RE-VERIFIED AGAINST v1 (`SyndicateGovernor.executeProposal` →
    ///      `_deriveAndStoreEffectiveCapital`). The governor writes
    ///      `effectiveMaxCapital` BEFORE it hands the batch to the vault, so the
    ///      read below sees this execution's figure, and `getRiskEnvelope` still
    ///      returns the declared `maxCapital`. v1's `_scaleCaps` adds one step
    ///      post-audit did not have — it trims the largest scaled cap when the
    ///      scaled caps sum past `effectiveMaxCapital` — but that trim cannot
    ///      fire on the execute leg: `propose` rejects `sum(executeCallCaps) >
    ///      maxCapital` (`CallCapsExceedMaxCapital`), and a sum of floors is at
    ///      most the floor of the sum, so the scaled caps never exceed
    ///      `floor(maxCapital * r / q)`.
    ///
    ///      DEGRADES TO THE PINNED AMOUNT, and only there. An unresolvable
    ///      governor, one that does not answer either getter, a zero declared
    ///      envelope, or an effective capital at or above the declared one all
    ///      mean "nothing scaled this proposal" — and a governor that does not
    ///      scale the envelope does not scale the caps either, so the pinned
    ///      pull is exactly what such a batch expects. Every v1 governor answers
    ///      both getters; the fallback is kept because it costs nothing and the
    ///      alternative is an undecodable `execute()` revert.
    ///      Every read is a length-checked raw staticcall for the reason the
    ///      rest of this file gives: a typed call into a governor that cannot
    ///      answer would revert in THIS frame with no data, turning a missing
    ///      selector into an undecodable `execute()` failure.
    function _coverageScaledDeposit() private view returns (uint256) {
        uint256 pinned = depositAmount;

        address governor_ = _readAddress(vault(), abi.encodeCall(ITierBindingPath.governor, ()));
        if (governor_ == address(0)) return pinned;
        (bool okPid, uint256 pid) = _readUint(governor_, abi.encodeCall(ISyndicateGovernor.getActiveProposal, ()));
        if (!okPid || pid == 0) return pinned;

        (bool okMax, uint256 declared) = _readUint(governor_, abi.encodeCall(ISyndicateGovernor.getRiskEnvelope, (pid)));
        if (!okMax || declared == 0) return pinned;
        (bool okEff, uint256 effective) =
            _readUint(governor_, abi.encodeCall(ISyndicateGovernor.getEffectiveMaxCapital, (pid)));
        if (!okEff || effective >= declared) return pinned;

        // `mulDiv` rather than `*` then `/`: the product is bounded in practice
        // (`pinned <= type(uint64).max`) but `declared` is proposer input, and a
        // revert here would brick `execute()` on an arithmetic edge instead of
        // sizing it. Floors, matching `_scaleCaps` and `effectiveMaxCapital`.
        return Math.mulDiv(pinned, effective, declared);
    }

    /// @dev Staticcall-safe leading-word read. Codeless target, revert, or short
    ///      return all resolve to `(false, 0)` — distinguishable from a genuine
    ///      zero answer, which the callers above need.
    function _readUint(address target, bytes memory data) private view returns (bool, uint256) {
        if (target.code.length == 0) return (false, 0);
        (bool ok, bytes memory ret) = target.staticcall(data);
        if (!ok || ret.length < 32) return (false, 0);
        uint256 word;
        // Leading word of the payload; `getRiskEnvelope` returns two and only
        // the first (`maxCapital`) is wanted, which `abi.decode` cannot express.
        assembly ("memory-safe") {
            word := mload(add(ret, 0x20))
        }
        return (true, word);
    }

    /// @dev Staticcall-safe address read: codeless target, revert, short return,
    ///      or dirty upper bits all resolve to `address(0)`.
    function _readAddress(address target, bytes memory data) private view returns (address) {
        if (target.code.length == 0) return address(0);
        (bool ok, bytes memory ret) = target.staticcall(data);
        if (!ok || ret.length < 32) return address(0);
        uint256 word;
        // Reads the first return word directly: `abi.decode` cannot express
        // "leading word of a longer payload".
        assembly ("memory-safe") {
            word := mload(add(ret, 0x20))
        }
        if (word >> 160 != 0) return address(0);
        // forge-lint: disable-next-line(unsafe-typecast)
        return address(uint160(word)); // upper 96 bits checked zero on the line above
    }

    function _deliver() internal returns (uint256 bal) {
        bal = USDG.balanceOf(address(this));
        if (bal == 0) return 0;
        returnedAssets += bal;
        _pushToVault(address(USDG), bal);
        emit FundsSwept(bal);
    }
}
