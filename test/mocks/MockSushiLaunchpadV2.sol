// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISushiLaunchpadV2} from "../../src/launchpad/vendor/sushi/ISushiLaunchpadV2.sol";
import {ERC20Mock} from "./ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title  MockSushiLaunchpadV2
/// @notice Double for Sushi Launchpad V2.2 (`0xF1716eBf…caBe9` on Robinhood 4663)
///         that reproduces what `SushiLaunchAdapter` depends on and nothing else:
///           - fixed supply minted to the LAUNCHPAD, so the initial buy is the
///             only source of launch tokens;
///           - the launcher (`msg.sender`) recorded as creator AND fee receiver,
///             with `setFeeReceiver` owner-only and `transferCreator` open to the
///             creator or the owner, as upstream;
///           - a native launch fee taken from `msg.value` with any excess KEPT;
///           - a PERMISSIONLESS `distributeFees` that pays the FEE RECEIVER in
///             both legs, never the caller or the creator;
///           - `launchInfo` REVERTING `UnknownToken` for an unissued token.
///         Knobs (`setRate`, `setLaunchFee`, `setFeesOwed`, `setDistributeReverts`,
///         `setDistributeBurnsGas`, `setSkipOutputFloor`, `setRecordReceiverAs`)
///         drive the adapter's edges. The real venue prices the buy off its V3
///         pool and splits fees with Sushi; the adapter reads only deltas, so
///         neither is modelled.
contract MockSushiLaunchpadV2 {
    uint256 public constant SUPPLY = 1e9 * 1e18;

    address public immutable WETH;
    address public owner;

    uint256 public launchFee;
    uint256 public rate = 1e18;
    bool public distributeReverts;
    bool public distributeBurnsGas;
    bool public skipOutputFloor;
    /// @notice When nonzero, launches record THIS as the fee receiver instead of
    ///         the launcher: the shape of a venue upgrade that changed who is paid.
    address public recordReceiverAs;

    mapping(address => address) public quoteTokenPriceFeed;
    mapping(address => bool) public isLaunch;
    mapping(address => ISushiLaunchpadV2.LaunchInfoV2) internal _launches;
    mapping(address => uint256) public quoteFeeOwed;
    mapping(address => uint256) public tokenFeeOwed;
    uint256 public collectedNative;

    error ZeroInitialBuyAmount();
    error InsufficientInitialBuyOutput();
    error UnsupportedQuoteToken(address quoteToken);
    error InvalidInitialBuyRecipient(address recipient);
    error InsufficientLaunchFee(uint256 required, uint256 supplied);
    error UnknownToken(address token);
    error UnauthorizedCreator(address caller);
    error NotOwner();
    error DistributeFailed();

    constructor(address weth_) {
        WETH = weth_;
        owner = msg.sender;
    }

    // ── venue-owner knobs ──

    function setQuoteTokenPriceFeed(address quoteToken, address feed) external {
        quoteTokenPriceFeed[quoteToken] = feed;
    }

    function setLaunchFee(uint256 fee) external {
        launchFee = fee;
    }

    function setRate(uint256 rate_) external {
        rate = rate_;
    }

    function setFeesOwed(address token, uint256 quoteAmount, uint256 tokenAmount) external {
        quoteFeeOwed[token] = quoteAmount;
        tokenFeeOwed[token] = tokenAmount;
    }

    function setDistributeReverts(bool value) external {
        distributeReverts = value;
    }

    function setDistributeBurnsGas(bool value) external {
        distributeBurnsGas = value;
    }

    function setSkipOutputFloor(bool value) external {
        skipOutputFloor = value;
    }

    function setRecordReceiverAs(address who) external {
        recordReceiverAs = who;
    }

    /// @dev Upstream: `onlyOwner`, the only way a launch's fee receiver changes.
    function setFeeReceiver(address token, address newFeeReceiver) external {
        if (msg.sender != owner) revert NotOwner();
        if (!isLaunch[token]) revert UnknownToken(token);
        _launches[token].feeReceiver = newFeeReceiver;
    }

    // ── venue surface ──

    function launchAndBuy(
        ISushiLaunchpadV2.TokenConfig calldata tokenConfig,
        address quoteToken,
        ISushiLaunchpadV2.LiquidityMode liquidityMode,
        ISushiLaunchpadV2.FeeDisposition feeDisposition,
        ISushiLaunchpadV2.InitialBuy calldata initialBuy
    ) external payable returns (address token, address pool, uint256[] memory positionIds, uint256 amountOut) {
        if (initialBuy.amountIn == 0) revert ZeroInitialBuyAmount();
        if (initialBuy.recipient == address(0) || initialBuy.recipient == address(this)) {
            revert InvalidInitialBuyRecipient(initialBuy.recipient);
        }
        if (msg.value < launchFee) revert InsufficientLaunchFee(launchFee, msg.value);
        if (quoteTokenPriceFeed[quoteToken] == address(0)) revert UnsupportedQuoteToken(quoteToken);
        collectedNative += msg.value;

        ERC20Mock launched = new ERC20Mock(tokenConfig.name, tokenConfig.symbol, 18);
        launched.mint(address(this), SUPPLY);
        token = address(launched);
        pool = address(uint160(uint256(keccak256(abi.encode(token, quoteToken)))));

        IERC20(quoteToken).transferFrom(msg.sender, address(this), initialBuy.amountIn);
        amountOut = (initialBuy.amountIn * rate) / 1e18;
        if (!skipOutputFloor && amountOut < initialBuy.amountOutMinimum) revert InsufficientInitialBuyOutput();
        launched.transfer(initialBuy.recipient, amountOut);

        positionIds = new uint256[](liquidityMode == ISushiLaunchpadV2.LiquidityMode.MOON ? 7 : 1);

        isLaunch[token] = true;
        address receiver = recordReceiverAs == address(0) ? msg.sender : recordReceiverAs;
        _launches[token] = ISushiLaunchpadV2.LaunchInfoV2({
            creator: msg.sender,
            feeReceiver: receiver,
            quoteToken: quoteToken,
            pool: pool,
            custodian: address(this),
            liquidityMode: liquidityMode,
            feeDisposition: feeDisposition,
            sushiFeeBps: 3000,
            poolInitializedAt: uint64(block.timestamp),
            supportsHolderRewards: true,
            rewardDistributor: address(0)
        });
    }

    /// @dev Permissionless; pays the FEE RECEIVER, never the caller or creator.
    function distributeFees(address token) external returns (ISushiLaunchpadV2.DistributionResult memory result) {
        if (distributeBurnsGas) {
            assembly ("memory-safe") {
                invalid()
            }
        }
        if (!isLaunch[token]) revert UnknownToken(token);
        if (distributeReverts) revert DistributeFailed();

        ISushiLaunchpadV2.LaunchInfoV2 storage info = _launches[token];
        uint256 q = quoteFeeOwed[token];
        uint256 t = tokenFeeOwed[token];
        quoteFeeOwed[token] = 0;
        tokenFeeOwed[token] = 0;
        if (q != 0) IERC20(info.quoteToken).transfer(info.feeReceiver, q);
        if (t != 0) IERC20(token).transfer(info.feeReceiver, t);
        result.quoteToReceiver = q;
        result.launchTokenToReceiver = t;
    }

    /// @dev Upstream admits the current creator OR the owner.
    function transferCreator(address token, address newCreator) external {
        if (!isLaunch[token]) revert UnknownToken(token);
        if (msg.sender != _launches[token].creator && msg.sender != owner) revert UnauthorizedCreator(msg.sender);
        _launches[token].creator = newCreator;
    }

    function launchInfo(address token) external view returns (ISushiLaunchpadV2.LaunchInfoV2 memory) {
        if (!isLaunch[token]) revert UnknownToken(token);
        return _launches[token];
    }

    function v3Factory() external pure returns (address) {
        return address(0xFAC7);
    }

    function positionManager() external pure returns (address) {
        return address(0x9A4A);
    }

    function custodian() external view returns (address) {
        return address(this);
    }

    function feeExecutor() external view returns (address) {
        return address(this);
    }

    function implementationVersion() external pure returns (uint64) {
        return 2;
    }

    function implementationRevision() external pure returns (uint64) {
        return 2;
    }
}
