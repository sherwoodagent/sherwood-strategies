// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title  Vendored Sushi Launchpad V2 interface
/// @notice PROVENANCE: transcribed from the verified `ISushiLaunchpadV2_2`
///         source (`contracts/v2/versions/2.2/interfaces/ISushiLaunchpadV2_2.sol`)
///         behind the ERC-1967 proxy `0xF1716eBf85836ffE2985db9A50dd29e5814caBe9`
///         on Robinhood Chain 4663. Implementation at transcription:
///         `SushiLaunchpadV2_2` at `0x230065BdF7D8d639dc921539f16ed2FFB0521E75`
///         (`implementationVersion() == 2`, `implementationRevision() == 2`,
///         compiler `v0.8.36`), fetched from Sourcify (exact match). Every
///         selector, enum order, struct field order and field width below is
///         byte-identical to that source.
///
///         THE PROXY IS UUPS AND THE VENUE OWNER CAN UPGRADE IT. The adapter
///         therefore reads every economic input live and asserts the shape of
///         what it depends on at runtime rather than trusting this file to stay
///         current. `implementationVersion` / `implementationRevision` are
///         vendored so the deploy ceremony can record which implementation it
///         certified against.
///
///         REDUCED SURFACE, vendoring only what `SushiLaunchAdapter` and its
///         deploy ceremony call. Deliberately NOT vendored:
///           - `launch(...)`, the no-dev-buy variant. Unusable here: the venue
///             deposits the whole fixed supply as one-sided liquidity and the
///             creator receives ZERO tokens, so a launch without an initial buy
///             leaves the fund with no reserve.
///           - `launchAndBuyNative(...)`. The adapter pairs against an ERC-20
///             quote chosen per proposal and funds the launch fee from WETH, so
///             it never needs the venue to wrap for it.
///           - `setFeeDisposition`, `lockFeeReceiver`, `transferCreator`: the
///             creator-only levers. The adapter's clone holds the creator role
///             and deliberately exposes no path to any of them (see the
///             adapter's header).
///           - the owner/admin setters (`setFeeReceiver`, `setSushiFeeBps`,
///             `setLaunchFee`, `setQuoteTokenPriceFeed(s)`, upgrades), which are
///             venue governance. Their effects are read live.
///           - events, errors, `distributeFeesWithDeviation` (owner-only),
///             `initializeV2_2`, and the position enumeration views.
///
///         PRAGMA: upstream compiles under `v0.8.36`; this file declares
///         `0.8.28` to match the repo. An `interface` emits no bytecode, and the
///         ABI encoding of these signatures is identical across both versions.
///
///         VENUE ECONOMICS the adapter depends on (read from the verified
///         source, and the reason each member below is here):
///           - Fixed supply `1e9 * 1e18`, deposited in full as one-sided Sushi
///             V3 liquidity (1% fee tier) held by a non-upgradeable custodian.
///             The creator receives NOTHING, so `launchAndBuy`'s initial buy IS
///             the fund's reserve.
///           - `feeReceiver` IS SET TO THE LAUNCHER (`msg.sender`) AND ONLY THE
///             VENUE OWNER CAN CHANGE IT (`setFeeReceiver` is `onlyOwner`).
///             This is the fact that separates V2 from V1: V1 paid fees to the
///             transferable CREATOR role, so a singleton adapter could hand the
///             role to the vault in the launch transaction. V2 pays the
///             `feeReceiver`, which no creator action can move, so whoever calls
///             `launchAndBuy` receives the fee stream for the life of the launch.
///           - `launchFee()` is native ETH taken from `msg.value` (`>=`, and any
///             excess is kept by the venue, not refunded). Owner-repriceable.
///           - `distributeFees(token)` is PERMISSIONLESS and pays the
///             `feeReceiver`, never the caller. The Sushi share is 30% by
///             default (20% for the canonical SUSHI quote), overridable per
///             token by the owner. What the non-Sushi share does depends on the
///             launch's `FeeDisposition`.
///           - Reverts the adapter relies on rather than duplicating:
///             `ZeroInitialBuyAmount`, `PartialInitialBuy` (the buy was not fully
///             consumed, so `quoteSpent == quoteIn` always),
///             `InsufficientInitialBuyOutput` (below `amountOutMinimum`),
///             `UnsupportedQuoteToken` (`quoteTokenPriceFeed[quote] == 0`),
///             `StalePriceFeedRound` (quote feed older than the venue's bound),
///             `InvalidInitialBuyRecipient`, `UnknownToken` (`launchInfo` on a
///             token this venue never issued, which is why the adapter reads it
///             by raw staticcall).
///           - Every state-changing entry point is `nonReentrant` upstream
///             (`ReentrancyGuardTransient`).
interface ISushiLaunchpadV2 {
    /// @notice Initial liquidity layout. STANDARD: one position from a $5,000
    ///         starting FDV to the maximum usable tick. MOON: a $10,000 start
    ///         across seven contiguous positions.
    enum LiquidityMode {
        STANDARD,
        MOON
    }

    /// @notice What happens to the non-Sushi fee share. Transitions are one-way
    ///         toward paying the receiver less, and only the creator can make
    ///         them. `DISTRIBUTE_TO_HOLDERS` is new in V2.2 and is not in the
    ///         public docs as of 2026-09-22.
    enum FeeDisposition {
        DIRECT_PAYOUT,
        BURN_LAUNCH_TOKEN_FEES,
        BUYBACK_AND_BURN,
        DISTRIBUTE_TO_HOLDERS
    }

    /// @notice Name (max 64 bytes) and symbol (max 16 bytes). The venue fixes
    ///         supply and price, so there is nothing else to state.
    struct TokenConfig {
        string name;
        string symbol;
    }

    /// @notice The same-transaction dev buy, the only way to obtain launch
    ///         tokens at creation.
    /// @param amountIn          Exact quote pulled from the caller and spent.
    /// @param amountOutMinimum  Venue-enforced slippage floor.
    /// @param recipient         Who receives the bought tokens. Cannot be zero,
    ///                          the launchpad, its custodian, its fee executor
    ///                          or the new pool.
    struct InitialBuy {
        uint256 amountIn;
        uint256 amountOutMinimum;
        address recipient;
    }

    /// @notice Per-launch venue state, V2.2 layout (eleven static words). V2.0
    ///         and V2.1 returned the first nine; the adapter's raw read needs only
    ///         words 0..3, so it accepts either length.
    struct LaunchInfoV2 {
        address creator;
        address feeReceiver;
        address quoteToken;
        address pool;
        address custodian;
        LiquidityMode liquidityMode;
        FeeDisposition feeDisposition;
        uint16 sushiFeeBps;
        uint64 poolInitializedAt;
        bool supportsHolderRewards;
        address rewardDistributor;
    }

    /// @notice What one `distributeFees` call did. Vendored for the selector
    ///         and the ceremony; the adapter trusts only balance deltas.
    struct DistributionResult {
        uint256 quoteToSushi;
        uint256 launchTokenToSushi;
        uint256 quoteToReceiver;
        uint256 launchTokenToReceiver;
        uint256 launchTokenFeesBurned;
        uint256 quoteUsedForBuyback;
        uint256 launchTokenBoughtAndBurned;
        int24 priorMeanTick;
        int24 recentMeanTick;
        int24 spotTick;
    }

    /// @notice Deploy the token, create and seed its 1% V3 pool, and execute the
    ///         initial buy, all in this one transaction.
    /// @dev The native launch fee comes from `msg.value`; the quote comes from an
    ///      ERC-20 allowance on `msg.sender`. The caller becomes the launch
    ///      creator, current creator AND fee receiver.
    function launchAndBuy(
        TokenConfig calldata tokenConfig,
        address quoteToken,
        LiquidityMode liquidityMode,
        FeeDisposition feeDisposition,
        InitialBuy calldata initialBuy
    ) external payable returns (address token, address pool, uint256[] memory positionIds, uint256 amountOut);

    /// @notice Permissionless: collect the positions' fees and distribute them
    ///         per the launch's current split and disposition. Pays the
    ///         `feeReceiver`, never the caller. REVERTS `UnknownToken` on a token
    ///         this venue never issued, and can revert on a `BUYBACK_AND_BURN`
    ///         launch whose pool oracle is not ready or whose price moved.
    function distributeFees(address token) external returns (DistributionResult memory result);

    /// @notice Per-launch state. REVERTS `UnknownToken` for a token this venue
    ///         never issued; never call it typed from a must-not-revert view.
    function launchInfo(address token) external view returns (LaunchInfoV2 memory info);

    /// @notice The registered USD aggregator for a quote; `address(0)` means the
    ///         venue will not pair against it. Owner-managed.
    function quoteTokenPriceFeed(address quoteToken) external view returns (address);

    /// @notice Native launch fee, in wei. Owner-repriceable.
    function launchFee() external view returns (uint256);

    /// @notice The venue's wrapped native token, read from its position manager
    ///         at initialization. The adapter's fee source.
    function WETH() external view returns (address);

    /// @notice The Sushi V3 factory launch pools are created through. Vendored
    ///         for the deploy ceremony's identity round trip.
    function v3Factory() external view returns (address);

    /// @notice The Sushi V3 position manager. Vendored for the same round trip.
    function positionManager() external view returns (address);

    /// @notice The non-upgradeable custodian that holds every launch position.
    function custodian() external view returns (address);

    /// @notice The fee executor that performs distributions.
    function feeExecutor() external view returns (address);

    /// @notice Major version; `2` for every V2 implementation.
    function implementationVersion() external pure returns (uint64);

    /// @notice Minor revision; `2` for V2.2.
    function implementationRevision() external pure returns (uint64);
}

/// @notice Minimal wrapped-native surface: the two members the adapter needs to
///         turn a WETH allowance into the venue's native launch fee.
interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}
