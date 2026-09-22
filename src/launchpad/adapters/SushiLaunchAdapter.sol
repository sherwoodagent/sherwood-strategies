// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILaunchAdapter} from "../ILaunchAdapter.sol";
import {ISushiLaunchpadV2, IWETH} from "../vendor/sushi/ISushiLaunchpadV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/**
 * @title SushiLaunchAdapter
 * @notice `ILaunchAdapter` over Sushi Launchpad V2: an IMPLEMENTATION plus one
 *         ERC-1167 CLONE PER LAUNCH, in one contract.
 *
 *   WHY A CLONE, WHERE THE V1 ADAPTER WAS A SINGLETON. V1 paid LP fees to the
 *   CREATOR, a role the creator could transfer, so a stateless singleton could
 *   launch, hand the role to the fund's vault in the same transaction, and end
 *   every call holding nothing. V2 pays a separate `feeReceiver` that the venue
 *   sets to the LAUNCHER (`msg.sender`) and that only the VENUE OWNER can
 *   change. No creator action moves it. A singleton here would therefore be the
 *   permanent fee receiver of every fund's launch: one contract accumulating
 *   every fund's fee stream, which is the shared-custody shape the
 *   `ILaunchAdapter` custody invariant exists to forbid. So each launch gets its
 *   own clone, the clone is the launcher, and a compromise or mis-accounting of
 *   one clone reaches exactly one fund.
 *
 *   ONE CONTRACT, TWO ROLES, exactly as `StonkLaunchAdapter`:
 *     - IMPLEMENTATION ROLE (the address the TierRegistry counterparty
 *       allowlist names): `launch`, `phase`, `finalize`, `collectFees`,
 *       `quoteSupported`, `nativeFeeSource`, `launchTarget`, `isClone`. Its
 *       constructor locks its own initializer, so the allowlisted address can
 *       never be initialized into somebody's clone.
 *     - CLONE ROLE (owned by one strategy): `initialize`, `executeLaunch`,
 *       `clonePhase`, `cloneCollectFees`. `initialize` and `executeLaunch` are
 *       callable only by the implementation, so a clone of this code minted by
 *       anyone else stays uninitialized and every verb on it fails closed.
 *
 *   WHERE VALUE GOES:
 *     - the RESERVE (the initial buy) is delivered by the venue straight to the
 *       OWNING STRATEGY (`recipient = owner`). It is never a clone balance.
 *     - the FEE STREAM lands on the clone, because the clone is the venue's
 *       `feeReceiver`, and every fee verb forwards the clone's whole balance to
 *       `feeRecipient`, the fund's VAULT, pinned once at `initialize`. The
 *       destination is unconditional: not the caller, not the owner, and not a
 *       function of whether the owner has settled. Creator fees never enter
 *       strategy custody.
 *     - the CREATOR ROLE stays on the clone, and the clone exposes no path to
 *       any creator lever (`transferCreator`, `setFeeDisposition`,
 *       `lockFeeReceiver`). The fee mode chosen at launch is the fee mode for
 *       the life of the launch, as far as anything in this stack can affect.
 *
 *   TRUST IN THE VENUE OWNER, stated plainly. The Sushi owner can re-point any
 *   launch's `feeReceiver` (`setFeeReceiver`) and take the creator role
 *   (`transferCreator` admits the owner), and the proxy is UUPS-upgradeable.
 *   A fund launching here trusts Sushi's owner with its FEE STREAM. It does not
 *   trust it with its RESERVE, which reaches the strategy inside the launch
 *   transaction, or with the vault's capital, which the venue never holds.
 *   `executeLaunch` asserts at launch that the venue recorded this clone as both
 *   creator and fee receiver, so an upgrade that changed who receives fees fails
 *   the launch instead of silently paying somebody else.
 *
 *   REENTRANCY. No guard. The implementation holds no balance and no role
 *   between calls, and its only state is immutable. A clone holds value only
 *   inside `executeLaunch`, which runs once and only for the implementation.
 *   Every later clone verb sends to a FIXED destination, and every
 *   state-changing venue entry point is `nonReentrant` upstream.
 *
 *   The caller approves the IMPLEMENTATION for `p.quoteIn` of the quote plus
 *   `nativeFeeSource().amount` of WETH before calling `launch`; the
 *   implementation forwards both to the fresh clone, whose address does not
 *   exist until then.
 */
contract SushiLaunchAdapter is ILaunchAdapter {
    using SafeERC20 for IERC20;

    /// @notice What `ILaunchAdapter.LaunchParams.venueData` carries on this
    ///         venue: `abi.encode(VenueData)`, or EMPTY for the defaults
    ///         (`STANDARD`, `DIRECT_PAYOUT`).
    /// @dev Both are proposal parameters that voters see. Price and supply are
    ///      not: the venue fixes them (1e9 tokens, $5k or $10k starting FDV off
    ///      the quote's registered USD feed).
    /// @param liquidityMode  `STANDARD` or `MOON`, passed through.
    /// @param feeDisposition `DIRECT_PAYOUT`, `BURN_LAUNCH_TOKEN_FEES` or
    ///                       `BUYBACK_AND_BURN`. `DISTRIBUTE_TO_HOLDERS` is
    ///                       refused; see `DispositionUnsupported`.
    struct VenueData {
        ISushiLaunchpadV2.LiquidityMode liquidityMode;
        ISushiLaunchpadV2.FeeDisposition feeDisposition;
    }

    // ── ERC-1167 introspection constants ──

    /// @dev The 45-byte ERC-1167 runtime is
    ///      `363d3d373d3d3d363d73 <20-byte implementation> 5af43d82803e903d91602b57fd5bf3`.
    uint256 private constant _CLONE_RUNTIME_LENGTH = 45;
    bytes10 private constant _CLONE_PREFIX = 0x363d3d373d3d3d363d73;
    uint120 private constant _CLONE_SUFFIX = 0x5af43d82803e903d91602b57fd5bf3;

    /// @dev `launchInfo` returns eleven static words on V2.2 and nine on V2.0 /
    ///      V2.1. The adapter reads words 0..3 only, so it accepts either.
    uint256 private constant _MIN_LAUNCH_INFO_LENGTH = 9 * 32;

    // ── shared immutables (live in code, so a clone reads them identically) ──

    /// @notice This code's implementation address: the one the counterparty
    ///         allowlist names, the one embedded in every clone's runtime, and
    ///         the one `launch` clones.
    address public immutable implementation;

    /// @notice The Sushi Launchpad V2 proxy this adapter fronts.
    ISushiLaunchpadV2 public immutable launchpad;

    /// @notice The venue's wrapped native token, read from the venue at
    ///         construction so the fee source cannot be mis-wired relative to the
    ///         launchpad it funds.
    address public immutable weth;

    // ── clone-role storage (zero on the implementation, and stays that way) ──

    /// @notice The strategy that owns this clone and receives its reserve.
    address public owner;

    /// @dev One-shot init flag. `true` on the implementation from its
    ///      constructor; `false` on a fresh clone.
    bool private _initialized;

    /// @notice Where this clone forwards fees: the FUND'S VAULT, named by the
    ///         launch and pinned here for the life of the clone. No setter.
    address public feeRecipient;

    /// @notice The launched ERC-20. Nonzero IFF this clone has launched.
    address public launchToken;

    /// @notice The launch's quote asset, pinned at `executeLaunch`. The venue
    ///         does not let a launch change its quote, so caching it saves a
    ///         venue read on every fee sweep without any chance of disagreeing.
    address public quoteToken;

    // ── events ──

    /// @notice A launch was opened by a fresh clone.
    event LaunchCloned(
        address indexed clone,
        address indexed strategy,
        address indexed token,
        ISushiLaunchpadV2.LiquidityMode liquidityMode,
        ISushiLaunchpadV2.FeeDisposition feeDisposition
    );

    /// @notice A TOLERATED VENUE CALL DID NOT GO THROUGH.
    /// @dev    Same signature as `StonkLaunchAdapter`'s event, so one keeper
    ///         subscription covers both venues. `collectFees` returns `(0, 0)`
    ///         on a failed venue leg, which is also what an honest "nothing
    ///         accrued" looks like; this event is what tells them apart. On V1
    ///         the silent case was observed on 4663 under an estimated gas
    ///         limit: EIP-150 forwards 63/64 of the gas, so the child can run
    ///         out while the parent succeeds. On V2 a `BUYBACK_AND_BURN` launch
    ///         also refuses by design while its pool oracle is younger than 120
    ///         seconds or its price has moved past the deviation bound.
    /// @param  leg        Which venue call failed.
    /// @param  reason     The revert selector, or `0x00000000` for a revert
    ///                    with no returndata (what a starved child returns).
    /// @param  launchRef  The ref this adapter answers for: the clone.
    /// @param  gasStarved The child consumed essentially all the gas it was
    ///                    forwarded. A heuristic.
    event VenueCallFailed(bytes32 indexed leg, bytes4 indexed reason, bytes32 launchRef, bool gasStarved);

    /// @notice Fees swept out of the clone to its `feeRecipient`.
    event FeesCollected(address indexed recipient, uint256 quoteOut, uint256 tokenOut);

    // ── errors ──

    /// @notice The constructor's launchpad is not a contract, or exposes no
    ///         readable `WETH()`. Fail at deploy, not at the first launch.
    error InvalidLaunchpad();
    /// @notice `launchpad.WETH()` answered zero or a codeless address.
    error InvalidWeth();
    /// @notice A clone-role verb was reached on the implementation, or an
    ///         implementation-role verb on a clone.
    error WrongRole(address self, address expected);
    /// @notice `initialize` / `executeLaunch` was not called by the
    ///         implementation that minted this clone.
    error NotImplementation(address caller);
    /// @notice `initialize` ran twice, or on the implementation.
    error AlreadyInitialized();
    /// @notice A clone verb was reached before `initialize`.
    error NotInitialized();
    /// @notice `executeLaunch` ran twice on one clone.
    error AlreadyLaunched(address token);
    /// @notice Native value was attached to `launch`. The fee is funded from
    ///         WETH precisely so a governor batch never carries value; attached
    ///         value could only sit on a shared contract.
    error NativeValueRejected(uint256 value);
    /// @notice The venue has no registered price feed for this quote, so
    ///         `launchAndBuy` would revert `UnsupportedQuoteToken`. Checked before
    ///         any transfer, so a WOOD-quoted proposal submitted ahead of the
    ///         venue owner's feed registration fails without moving capital.
    error UnsupportedQuote(address quoteToken);
    /// @notice `p.feeRecipient == address(0)`: it is the clone's permanent fee
    ///         destination, so a zero would burn every later sweep.
    error ZeroFeeRecipient();
    /// @notice `p.quoteIn == 0`. The venue mints the launcher nothing, so the
    ///         dev buy IS the reserve.
    error ZeroQuoteIn();
    /// @notice `p.minTokensOut < p.reserveAmount`. The venue's slippage floor is
    ///         the only thing that makes the reserve enforceable at the venue;
    ///         a lower floor would let a sandwiched buy return fewer tokens than
    ///         the fund promised its holders and still succeed.
    error ReserveFloorBelowReserve(uint256 minTokensOut, uint256 reserveAmount);
    /// @notice `block.timestamp > p.deadline`. V2's `launchAndBuy` takes no
    ///         deadline of its own (V1's did), so the adapter enforces the
    ///         caller's locally rather than dropping it: a proposal executed
    ///         weeks late would otherwise launch at a starting price read off a
    ///         quote feed nobody re-checked.
    error DeadlineExpired(uint64 deadline, uint256 nowTimestamp);
    /// @notice `p.venueData` is neither empty nor exactly one `VenueData`.
    error InvalidVenueData(uint256 length);
    /// @notice `DISTRIBUTE_TO_HOLDERS` was requested. Under it the non-Sushi
    ///         quote share goes to a per-token `HolderRewards` contract that pays
    ///         out through `claim(holder)`. Nothing in this stack drives that
    ///         claim for the vault, and `collectFees` could neither trigger nor
    ///         report it, so the fund's fee income would accrue somewhere no
    ///         verb here reaches. Admitting it is a product change with its own
    ///         collection path, not a flag.
    error DispositionUnsupported(ISushiLaunchpadV2.FeeDisposition feeDisposition);
    /// @notice The buy delivered less than `p.reserveAmount` to the owner.
    ///         Redundant with the venue's own floor given the check above; kept so
    ///         the custody invariant is asserted by this contract and not merely
    ///         inherited from a venue upgrade's continued good behaviour.
    error ReserveNotDelivered(uint256 delivered, uint256 required);
    /// @notice After the launch the venue does not record this clone as both
    ///         creator and fee receiver. Every fee verb here assumes it is, so a
    ///         launch that disagrees would pay its fees somewhere this adapter
    ///         cannot forward from. Fires on a venue upgrade that changed who
    ///         receives fees.
    error FeeReceiverNotClone(address creator, address feeReceiver);
    /// @notice The clone finished a launch still holding launch tokens or
    ///         quote. Fires on a fee-on-transfer or rebasing quote rather than
    ///         letting a balance sit on the clone.
    error DustRemains(address token, uint256 amount);
    /// @notice Native value arrived from something other than `weth`. The only
    ///         legitimate inbound payment is the unwrap that funds the launch fee.
    error UnexpectedNativePayment(address sender);

    /// @param launchpad_ Sushi Launchpad V2 proxy (`0xF1716eBf…caBe9` on 4663).
    /// @dev The last two statements are the template lock: `_initialized = true`
    ///      means `initialize` can never run on the implementation.
    constructor(address launchpad_) {
        if (launchpad_ == address(0) || launchpad_.code.length == 0) revert InvalidLaunchpad();
        address weth_ = ISushiLaunchpadV2(launchpad_).WETH();
        if (weth_ == address(0) || weth_.code.length == 0) revert InvalidWeth();
        launchpad = ISushiLaunchpadV2(launchpad_);
        weth = weth_;
        implementation = address(this);
        _initialized = true;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // implementation role — ILaunchAdapter
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc ILaunchAdapter
    ///
    /// @dev HOW THE CUSTODY INVARIANT IS MET, in order:
    ///        1. a FRESH CLONE is minted and initialized with `owner = msg.sender`
    ///           and `feeRecipient = p.feeRecipient` before it touches the venue,
    ///           so the fee receiver the venue pins is an instance the calling
    ///           strategy exclusively owns, never this shared implementation;
    ///        2. the quote and the WETH fee move from the caller to the clone in
    ///           one statement each, so the implementation never holds a balance;
    ///        3. the clone launches with `recipient = owner`, so the reserve
    ///           reaches the strategy directly, and it ends `executeLaunch`
    ///           holding zero quote and zero launch token (asserted).
    ///
    ///      Every rejection happens before any transfer.
    function launch(LaunchParams calldata p) external payable override returns (LaunchResult memory) {
        if (address(this) != implementation) revert WrongRole(address(this), implementation);
        if (msg.value != 0) revert NativeValueRejected(msg.value);
        if (p.feeRecipient == address(0)) revert ZeroFeeRecipient();
        if (!quoteSupported(p.quoteToken)) revert UnsupportedQuote(p.quoteToken);
        if (p.quoteIn == 0) revert ZeroQuoteIn();
        if (p.minTokensOut < p.reserveAmount) revert ReserveFloorBelowReserve(p.minTokensOut, p.reserveAmount);
        if (p.deadline != 0 && block.timestamp > p.deadline) revert DeadlineExpired(p.deadline, block.timestamp);
        VenueData memory v = _decodeVenueData(p.venueData);

        // Read the fee LIVE and pull exactly it: the venue owner can reprice
        // between propose and execute, and the venue keeps any excess rather
        // than refunding it.
        uint256 fee = launchpad.launchFee();

        address clone = Clones.clone(implementation);
        SushiLaunchAdapter(payable(clone)).initialize(msg.sender, p.feeRecipient);

        IERC20(p.quoteToken).safeTransferFrom(msg.sender, clone, p.quoteIn);
        if (fee != 0) IERC20(weth).safeTransferFrom(msg.sender, clone, fee);

        (address token, uint256 reserveHeld) = SushiLaunchAdapter(payable(clone)).executeLaunch(p, v, fee);

        emit LaunchCloned(clone, msg.sender, token, v.liquidityMode, v.feeDisposition);

        return LaunchResult({
            token: token,
            // The ref IS the clone, resolved later by ERC-1167 introspection
            // rather than a map an attacker could seed. Lossless widening.
            // forge-lint: disable-next-line(unsafe-typecast)
            launchRef: bytes32(uint256(uint160(clone))),
            reserveHeld: reserveHeld,
            // The venue consumes the buy in full or reverts `PartialInitialBuy`.
            quoteSpent: p.quoteIn
        });
    }

    /// @inheritdoc ILaunchAdapter
    /// @dev Two phases only. The venue deploys the token, seeds the pool and
    ///      trades inside `launch`, so an issued launch is `Live` from its first
    ///      block. MUST NOT REVERT: a forged ref never becomes a call, and the
    ///      clone is read by length-checked raw staticcall with the answer
    ///      bounded before it is cast.
    function phase(bytes32 launchRef) external view override returns (LaunchPhase) {
        address clone = _refToClone(launchRef);
        if (clone == address(0)) return LaunchPhase.None;
        (bool ok, bytes memory ret) = clone.staticcall(abi.encodeCall(this.clonePhase, ()));
        if (!ok || ret.length < 32) return LaunchPhase.None;
        uint256 word = abi.decode(ret, (uint256));
        if (word > uint256(type(LaunchPhase).max)) return LaunchPhase.None;
        return LaunchPhase(word);
    }

    /// @inheritdoc ILaunchAdapter
    /// @dev No-op, and deliberately not a revert: the venue completes the launch
    ///      in one transaction, and a settlement path that calls `finalize`
    ///      unconditionally must not have to branch on the venue.
    function finalize(bytes32) external override {}

    /// @inheritdoc ILaunchAdapter
    /// @dev Pure routing to the clone, which pays its pinned `feeRecipient` and
    ///      nothing else. A forged ref answers `(0, 0)` without calling the
    ///      supplied address. Typed rather than raw: the callee is this code,
    ///      written not to revert, so a revert would be a bug worth surfacing.
    function collectFees(bytes32 launchRef) external override returns (uint256 quoteOut, uint256 tokenOut) {
        address clone = _refToClone(launchRef);
        if (clone == address(0)) return (0, 0);
        return SushiLaunchAdapter(payable(clone)).cloneCollectFees();
    }

    /// @inheritdoc ILaunchAdapter
    /// @dev Mirrors the venue's own gate, `quoteTokenPriceFeed(q) != 0`, rather
    ///      than an allowlist of ours. WOOD answers FALSE today and TRUE the
    ///      moment the venue owner registers a WOOD/USD aggregator, with no
    ///      change here. The venue can still refuse a supported quote at launch
    ///      if that feed's latest round is stale; that surfaces as the venue's
    ///      own `StalePriceFeedRound`.
    ///
    ///      MUST NOT REVERT: a length-checked raw staticcall, failing closed on
    ///      an unreadable or dirty answer. `launchpad` is immutable, so a clone
    ///      answers identically.
    function quoteSupported(address quoteToken_) public view override returns (bool) {
        if (quoteToken_ == address(0)) return false;
        address target = address(launchpad);
        (bool ok, bytes memory ret) =
            target.staticcall(abi.encodeCall(ISushiLaunchpadV2.quoteTokenPriceFeed, (quoteToken_)));
        if (!ok || ret.length < 32) return false;
        uint256 word;
        assembly ("memory-safe") {
            word := mload(add(ret, 0x20))
        }
        if (word >> 160 != 0) return false;
        return word != 0;
    }

    /// @inheritdoc ILaunchAdapter
    /// @dev WETH, always. The venue charges its fee in native ETH and the pair is
    ///      the agent's choice, so the fee cannot be assumed to come from the
    ///      quote; naming WETH lets the strategy acquire it through its own
    ///      allowlisted swap adapter. Read live; an unreadable fee answers
    ///      `(weth, 0)` because this is a planning read and `launch` re-reads
    ///      the fee typed.
    function nativeFeeSource() external view override returns (address token, uint256 amount) {
        return (weth, _safeLaunchFee());
    }

    /// @inheritdoc ILaunchAdapter
    /// @dev Names the venue for the deploy ceremony's counterparty standing.
    ///      Not a handoff address: the clone keeps the creator role and exposes
    ///      no path to transfer it.
    function launchTarget() external view override returns (address) {
        return address(launchpad);
    }

    /// @notice Whether `target` is an ERC-1167 clone of THIS implementation.
    function isClone(address target) external view returns (bool) {
        return _isOurClone(target);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // clone role
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Bind a fresh clone to its owning strategy and its permanent fee
    ///         destination.
    /// @dev ONE-SHOT and IMPLEMENTATION-ONLY: one-shot stops a fee-destination
    ///      change, and implementation-only means a clone minted by anyone else
    ///      can never be initialized. `feeRecipient_` is re-checked here because
    ///      this is the write that makes it permanent.
    function initialize(address owner_, address feeRecipient_) external {
        if (msg.sender != implementation) revert NotImplementation(msg.sender);
        if (_initialized) revert AlreadyInitialized();
        if (feeRecipient_ == address(0)) revert ZeroFeeRecipient();
        _initialized = true;
        owner = owner_;
        feeRecipient = feeRecipient_;
    }

    /// @notice Launch on the venue as the launcher of record, delivering the
    ///         reserve to the owner.
    /// @dev `p.quoteIn` of the quote and `fee` of WETH were forwarded here by the
    ///      implementation before this call. The clone unwraps exactly the fee,
    ///      so the venue receives `msg.value == launchFee()` and keeps nothing
    ///      extra.
    ///
    ///      The reserve is measured on the OWNER, not taken from the venue's
    ///      return value: the token did not exist before this call, so the
    ///      owner's balance is exactly what the launch delivered.
    function executeLaunch(LaunchParams calldata p, VenueData calldata v, uint256 fee)
        external
        returns (address token, uint256 reserveHeld)
    {
        if (msg.sender != implementation) revert NotImplementation(msg.sender);
        address owner_ = owner;
        if (owner_ == address(0)) revert NotInitialized();
        if (launchToken != address(0)) revert AlreadyLaunched(launchToken);

        if (fee != 0) IWETH(weth).withdraw(fee);

        ISushiLaunchpadV2 venue = launchpad;
        IERC20(p.quoteToken).forceApprove(address(venue), p.quoteIn);
        (token,,,) = venue.launchAndBuy{value: fee}(
            ISushiLaunchpadV2.TokenConfig({name: p.name, symbol: p.symbol}),
            p.quoteToken,
            v.liquidityMode,
            v.feeDisposition,
            ISushiLaunchpadV2.InitialBuy({amountIn: p.quoteIn, amountOutMinimum: p.minTokensOut, recipient: owner_})
        );
        IERC20(p.quoteToken).forceApprove(address(venue), 0);

        launchToken = token;
        quoteToken = p.quoteToken;

        reserveHeld = IERC20(token).balanceOf(owner_);
        if (reserveHeld < p.reserveAmount) revert ReserveNotDelivered(reserveHeld, p.reserveAmount);

        (bool known, address creator, address receiver,) = _readLaunch(token);
        if (!known || creator != address(this) || receiver != address(this)) {
            revert FeeReceiverNotClone(creator, receiver);
        }

        // The clone keeps the roles and nothing else. The venue consumes the
        // buy in full or reverts, and the fee was unwrapped exactly, so both
        // sweeps are expected to move nothing; they are here so residue from a
        // lossy quote reaches the owner it was pulled from or fails the launch.
        _sweepTo(token, owner_);
        if (p.quoteToken != token) _sweepTo(p.quoteToken, owner_);
    }

    /// @notice This clone's lifecycle position: `Live` once the venue knows its
    ///         token, `None` otherwise. MUST NOT REVERT.
    function clonePhase() public view returns (LaunchPhase) {
        address token = launchToken;
        if (token == address(0)) return LaunchPhase.None;
        (bool known,,, address pool) = _readLaunch(token);
        if (!known || pool == address(0)) return LaunchPhase.None;
        return LaunchPhase.Live;
    }

    /// @notice Drive the venue's fee distribution and send everything this clone
    ///         holds to its `feeRecipient`, the fund's vault.
    ///
    /// @dev PERMISSIONLESS, and it never pays the caller: the destination is one
    ///      slot written once at `initialize`. A keeper flushing a fund's fees is
    ///      a service the fund wants.
    ///
    ///      WHY A FORWARD IS NECESSARY. The venue pays its `feeReceiver`, which is
    ///      this clone and cannot be changed by anything here, so fee value
    ///      physically lands on the clone and has to be moved on. The venue's
    ///      `distributeFees` is also permissionless, so anyone may have pushed
    ///      fees here since the last sweep: this verb moves the clone's WHOLE
    ///      balance of both assets, not just what this call distributed. Nothing
    ///      can be stranded on a clone, because those are the only two assets any
    ///      path here can leave on it and this verb is callable forever.
    ///
    ///      Deltas are measured on the RECIPIENT: what actually arrived where it
    ///      was sent. `(0, 0)` rather than a revert when nothing accrued or the
    ///      venue refused; a refusal also emits `VenueCallFailed`.
    function cloneCollectFees() external returns (uint256 quoteOut, uint256 tokenOut) {
        address token = launchToken;
        address recipient = feeRecipient;
        if (token == address(0) || recipient == address(0)) return (0, 0);
        address quote_ = quoteToken;

        uint256 quoteBefore = _balanceOf(quote_, recipient);
        uint256 tokenBefore = _balanceOf(token, recipient);

        uint256 gasBefore = gasleft();
        // Raw call: a venue refusal must not propagate, and the return tuple is
        // unused because only the deltas are trusted. Binding no returndata
        // skips RETURNDATACOPY, so a verbose venue cannot bomb this path.
        // solhint-disable-next-line avoid-low-level-calls
        (bool distributed,) = address(launchpad).call(abi.encodeCall(ISushiLaunchpadV2.distributeFees, (token)));
        if (!distributed) {
            emit VenueCallFailed("distributeFees", _revertSelector(), _selfRef(), gasleft() <= gasBefore / 63);
        }

        _forward(quote_, recipient);
        if (token != quote_) _forward(token, recipient);

        uint256 quoteAfter = _balanceOf(quote_, recipient);
        uint256 tokenAfter = _balanceOf(token, recipient);
        quoteOut = quoteAfter > quoteBefore ? quoteAfter - quoteBefore : 0;
        tokenOut = tokenAfter > tokenBefore ? tokenAfter - tokenBefore : 0;
        emit FeesCollected(recipient, quoteOut, tokenOut);
    }

    /// @notice Accept native ONLY from `weth`: the unwrap inside `executeLaunch`
    ///         is the single legitimate inbound payment. A `selfdestruct`
    ///         force-send cannot be refused, and needs no handling: nothing reads
    ///         a native balance here, and a stranded wei belongs to no fund.
    receive() external payable {
        if (msg.sender != weth) revert UnexpectedNativePayment(msg.sender);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // internals
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Empty data selects the defaults. Otherwise the payload must be
    ///      exactly two words; `abi.decode` into the enums then reverts on an
    ///      out-of-range value, which is the right outcome at launch time.
    function _decodeVenueData(bytes calldata data) private pure returns (VenueData memory v) {
        if (data.length == 0) {
            return VenueData({
                liquidityMode: ISushiLaunchpadV2.LiquidityMode.STANDARD,
                feeDisposition: ISushiLaunchpadV2.FeeDisposition.DIRECT_PAYOUT
            });
        }
        if (data.length != 64) revert InvalidVenueData(data.length);
        v = abi.decode(data, (VenueData));
        if (v.feeDisposition == ISushiLaunchpadV2.FeeDisposition.DISTRIBUTE_TO_HOLDERS) {
            revert DispositionUnsupported(v.feeDisposition);
        }
    }

    /// @dev Resolve a ref to a clone THIS implementation minted, or to zero,
    ///      without ever calling the supplied address.
    function _refToClone(bytes32 launchRef) private view returns (address) {
        uint256 word = uint256(launchRef);
        if (word >> 160 != 0) return address(0);
        // Safe: the guard above rejects any word with bits above 160.
        // forge-lint: disable-next-line(unsafe-typecast)
        address target = address(uint160(word));
        return _isOurClone(target) ? target : address(0);
    }

    /// @dev ERC-1167 target introspection: prefix, embedded implementation and
    ///      suffix all checked, so the target runs this exact code. Same routine
    ///      as `StonkLaunchAdapter._isOurClone`.
    function _isOurClone(address target) private view returns (bool) {
        if (target == address(0) || target.code.length != _CLONE_RUNTIME_LENGTH) return false;
        bytes memory runtime = target.code;

        bytes32 head;
        bytes32 tail;
        address embedded;
        assembly ("memory-safe") {
            head := mload(add(runtime, 0x20))
            tail := mload(add(runtime, 0x2d))
            embedded := shr(96, mload(add(runtime, 0x2a)))
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        if (bytes10(head) != _CLONE_PREFIX) return false;
        // forge-lint: disable-next-line(unsafe-typecast)
        if (uint120(uint256(tail)) != _CLONE_SUFFIX) return false;
        return embedded == implementation;
    }

    /// @dev Length-checked raw read of `launchInfo(token)`, returning the first
    ///      four static words: creator, fee receiver, quote, pool. A revert
    ///      (`UnknownToken`), a short payload or dirty high bits answer
    ///      `known = false`.
    function _readLaunch(address token)
        private
        view
        returns (bool known, address creator, address receiver, address pool)
    {
        (bool ok, bytes memory ret) =
            address(launchpad).staticcall(abi.encodeCall(ISushiLaunchpadV2.launchInfo, (token)));
        if (!ok || ret.length < _MIN_LAUNCH_INFO_LENGTH) return (false, address(0), address(0), address(0));
        uint256 w0;
        uint256 w1;
        uint256 w3;
        assembly ("memory-safe") {
            w0 := mload(add(ret, 0x20))
            w1 := mload(add(ret, 0x40))
            w3 := mload(add(ret, 0x80))
        }
        if (w0 >> 160 != 0 || w1 >> 160 != 0 || w3 >> 160 != 0) {
            return (false, address(0), address(0), address(0));
        }
        // Safe: each word was checked for bits above 160.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (true, address(uint160(w0)), address(uint160(w1)), address(uint160(w3)));
    }

    /// @dev Safe read of the fee for `nativeFeeSource`; unreadable answers 0.
    function _safeLaunchFee() private view returns (uint256) {
        (bool ok, bytes memory ret) = address(launchpad).staticcall(abi.encodeCall(ISushiLaunchpadV2.launchFee, ()));
        if (!ok || ret.length < 32) return 0;
        return abi.decode(ret, (uint256));
    }

    /// @dev The revert selector of the call that just returned, four bytes into
    ///      scratch, or zero when the callee returned less. Never copies the
    ///      whole returndata.
    function _revertSelector() private pure returns (bytes4 sel) {
        assembly ("memory-safe") {
            if gt(returndatasize(), 3) {
                returndatacopy(0, 0, 4)
                sel := and(mload(0), 0xffffffff00000000000000000000000000000000000000000000000000000000)
            }
        }
    }

    /// @dev This clone's own `launchRef`, which is its address.
    function _selfRef() private view returns (bytes32) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return bytes32(uint256(uint160(address(this))));
    }

    /// @dev Non-reverting balance read, so `cloneCollectFees` cannot be turned
    ///      into a revert by a token that has since become unreadable.
    function _balanceOf(address token, address who) private view returns (uint256) {
        if (token == address(0) || token.code.length == 0) return 0;
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeCall(IERC20.balanceOf, (who)));
        if (!ok || ret.length < 32) return 0;
        return abi.decode(ret, (uint256));
    }

    /// @dev Move this clone's whole balance of `token` to `to`, or do nothing.
    ///      The zero-balance short-circuit keeps the nothing-accrued path from
    ///      touching any token.
    function _forward(address token, address to) private {
        if (token == address(0) || token.code.length == 0) return;
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal != 0) IERC20(token).safeTransfer(to, bal);
    }

    /// @dev Send any balance of `token` to `to`, then assert none is left.
    function _sweepTo(address token, address to) private {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal != 0) IERC20(token).safeTransfer(to, bal);
        uint256 remaining = IERC20(token).balanceOf(address(this));
        if (remaining != 0) revert DustRemains(token, remaining);
    }
}
