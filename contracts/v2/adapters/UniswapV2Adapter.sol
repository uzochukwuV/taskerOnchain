// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IActionAdapter.sol";

// Uniswap V2 Router Interface
interface IUniswapV2Router {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);
}

/**
 * @title UniswapV2Adapter
 * @notice Adapter for executing token swaps on Uniswap V2-compatible DEXes
 * @dev Handles limit orders by checking price conditions before executing
 */
contract UniswapV2Adapter is IActionAdapter, Ownable {
    using SafeERC20 for IERC20;

    // ============ Structs ============

    struct SwapParams {
        address router;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 minAmountOut;
        address recipient;
    }

    // ============ State Variables ============

    mapping(address => bool) public supportedRouters;
    uint256 public constant DEADLINE_EXTENSION = 5 minutes;

    // ============ Constructor ============

    constructor(address _owner) Ownable(_owner) {}

    // ============ Core Functions ============

    /// @inheritdoc IActionAdapter
    function execute(address vault, bytes calldata params)
        external
        override
        returns (bool success, bytes memory result)
    {
        // Only vault can call this
        require(msg.sender == vault, "Only vault");

        // Decode params
        SwapParams memory swapParams = abi.decode(params, (SwapParams));

        // Validate
        require(supportedRouters[swapParams.router], "Router not supported");
        require(swapParams.tokenIn != address(0), "Invalid tokenIn");
        require(swapParams.tokenOut != address(0), "Invalid tokenOut");
        require(swapParams.amountIn > 0, "Invalid amountIn");
        require(swapParams.minAmountOut > 0, "Invalid minAmountOut");
        require(swapParams.recipient != address(0), "Invalid recipient");

        // Check if price condition is met
        address[] memory path = new address[](2);
        path[0] = swapParams.tokenIn;
        path[1] = swapParams.tokenOut;

        uint256[] memory amountsOut = IUniswapV2Router(swapParams.router).getAmountsOut(
            swapParams.amountIn,
            path
        );

        // Check slippage
        if (amountsOut[1] < swapParams.minAmountOut) {
            return (false, bytes("Price condition not met"));
        }

        // Pull tokens from vault (vault has already approved this adapter)
        IERC20 tokenIn = IERC20(swapParams.tokenIn);
        uint256 balanceBefore = tokenIn.balanceOf(address(this));

        tokenIn.safeTransferFrom(vault, address(this), swapParams.amountIn);

        uint256 balanceAfter = tokenIn.balanceOf(address(this));
        require(balanceAfter >= balanceBefore + swapParams.amountIn, "Transfer failed");

        // Approve router
        tokenIn.safeApprove(swapParams.router, swapParams.amountIn);

        // Execute swap
        try IUniswapV2Router(swapParams.router).swapExactTokensForTokens(
            swapParams.amountIn,
            swapParams.minAmountOut,
            path,
            swapParams.recipient,
            block.timestamp + DEADLINE_EXTENSION
        ) returns (uint256[] memory amounts) {
            // Clear approval
            tokenIn.safeApprove(swapParams.router, 0);

            emit ActionExecuted(vault, swapParams.router, true, abi.encode(amounts));

            return (true, abi.encode(amounts));
        } catch Error(string memory reason) {
            // Swap failed - return tokens to vault
            tokenIn.safeApprove(swapParams.router, 0);
            tokenIn.safeTransfer(vault, swapParams.amountIn);

            return (false, bytes(reason));
        } catch {
            // Swap failed - return tokens to vault
            tokenIn.safeApprove(swapParams.router, 0);
            tokenIn.safeTransfer(vault, swapParams.amountIn);

            return (false, bytes("Swap failed"));
        }
    }

    // ============ View Functions ============

    /// @inheritdoc IActionAdapter
    function isProtocolSupported(address protocol) external view override returns (bool) {
        return supportedRouters[protocol];
    }

    /// @inheritdoc IActionAdapter
    function name() external pure override returns (string memory) {
        return "UniswapV2Adapter_v1.0";
    }

    /// @notice Preview swap output
    function previewSwap(
        address router,
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (uint256 amountOut) {
        require(supportedRouters[router], "Router not supported");

        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        uint256[] memory amounts = IUniswapV2Router(router).getAmountsOut(amountIn, path);

        return amounts[1];
    }

    /// @notice Check if limit order condition is met
    function checkLimitOrder(
        address router,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    ) external view returns (bool isMet) {
        if (!supportedRouters[router]) return false;

        try this.previewSwap(router, tokenIn, tokenOut, amountIn) returns (uint256 amountOut) {
            return amountOut >= minAmountOut;
        } catch {
            return false;
        }
    }

    // ============ Admin Functions ============

    function addRouter(address router) external onlyOwner {
        require(router != address(0), "Invalid router");
        supportedRouters[router] = true;
    }

    function removeRouter(address router) external onlyOwner {
        supportedRouters[router] = false;
    }

    function batchAddRouters(address[] calldata routers) external onlyOwner {
        for (uint256 i = 0; i < routers.length; i++) {
            supportedRouters[routers[i]] = true;
        }
    }

    /// @notice Emergency withdraw tokens
    function emergencyWithdraw(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Invalid recipient");
        IERC20(token).safeTransfer(to, amount);
    }
}
