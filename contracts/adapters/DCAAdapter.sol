// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title DCAAdapter
 * @notice Dollar Cost Averaging adapter for recurring token purchases
 * @dev Executes regular buys regardless of price (DCA strategy)
 */
contract DCAAdapter is Ownable {

    // ============ Interfaces ============

    interface IUniswapV2Router {
        function swapExactTokensForTokens(
            uint256 amountIn,
            uint256 amountOutMin,
            address[] calldata path,
            address to,
            uint256 deadline
        ) external returns (uint256[] memory amounts);

        function getAmountsOut(
            uint256 amountIn,
            address[] calldata path
        ) external view returns (uint256[] memory amounts);
    }

    // ============ Structures ============

    /**
     * @notice DCA execution tracking
     * @param totalExecutions Total number of DCA executions
     * @param totalAmountIn Total amount spent
     * @param totalAmountOut Total amount received
     * @param averagePrice Average price paid
     */
    struct DCAStats {
        uint256 totalExecutions;
        uint256 totalAmountIn;
        uint256 totalAmountOut;
        uint256 averagePrice;
    }

    // ============ State Variables ============

    /// @notice Action router that can call this adapter
    address public actionRouter;

    /// @notice Supported DEX routers
    mapping(address => bool) public supportedRouters;

    /// @notice DCA statistics per task
    mapping(uint256 => DCAStats) public dcaStats;

    /// @notice Default deadline extension (5 minutes)
    uint256 public constant DEADLINE_EXTENSION = 5 minutes;

    /// @notice Default slippage tolerance for DCA (10% - higher for any price acceptance)
    uint256 public defaultSlippageBps = 1000;

    // ============ Events ============

    event DCAExecuted(
        uint256 indexed taskId,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 currentPrice,
        uint256 executionNumber
    );

    event RouterAdded(address indexed router);

    // ============ Constructor ============

    constructor() Ownable(msg.sender) {}

    // ============ Core Functions ============

    /**
     * @notice Execute DCA purchase
     * @param _taskId Task identifier
     * @param _protocol DEX router address
     * @param _selector Function selector (not used)
     * @param _params Encoded parameters
     * @param _value ETH value (not used)
     * @return success Whether DCA executed
     */
    function execute(
        uint256 _taskId,
        address _protocol,
        bytes4 _selector,
        bytes calldata _params,
        uint256 _value
    ) external returns (bool success) {
        require(msg.sender == actionRouter, "Only action router");
        require(supportedRouters[_protocol], "Router not supported");

        // Decode parameters
        (
            address tokenToBuy,      // Token to purchase (e.g., ETH, BTC)
            address paymentToken,    // Token to pay with (e.g., USDC)
            uint256 amountToSpend,   // Fixed amount to spend each time
            uint256 minAmountOut,    // Minimum acceptable output (slippage protection)
            address recipient,       // Where to send purchased tokens
            address creator          // Task creator who owns payment tokens
        ) = abi.decode(_params, (address, address, uint256, uint256, address, address));

        // Validate parameters
        require(tokenToBuy != address(0), "Invalid token to buy");
        require(paymentToken != address(0), "Invalid payment token");
        require(amountToSpend > 0, "Invalid amount");
        require(recipient != address(0), "Invalid recipient");
        require(creator != address(0), "Invalid creator");

        // Transfer payment tokens from creator to adapter
        bool transferSuccess = IERC20(paymentToken).transferFrom(
            creator,
            address(this),
            amountToSpend
        );

        if (!transferSuccess) {
            return false; // Insufficient balance or approval
        }

        // Get current price for stats
        uint256 currentPrice = _getCurrentPrice(paymentToken, tokenToBuy, _protocol);

        // Approve router
        IERC20(paymentToken).approve(_protocol, amountToSpend);

        // Build path
        address[] memory path = new address[](2);
        path[0] = paymentToken;
        path[1] = tokenToBuy;

        // Execute swap
        try IUniswapV2Router(_protocol).swapExactTokensForTokens(
            amountToSpend,
            minAmountOut > 0 ? minAmountOut : 0, // Use provided slippage or accept any amount
            path,
            recipient,
            block.timestamp + DEADLINE_EXTENSION
        ) returns (uint256[] memory amounts) {

            // Update DCA statistics
            DCAStats storage stats = dcaStats[_taskId];
            stats.totalExecutions++;
            stats.totalAmountIn += amounts[0];
            stats.totalAmountOut += amounts[1];

            // Calculate average price (weighted)
            if (stats.totalAmountOut > 0) {
                stats.averagePrice = (stats.totalAmountIn * 1e18) / stats.totalAmountOut;
            }

            emit DCAExecuted(
                _taskId,
                paymentToken,
                tokenToBuy,
                amounts[0],
                amounts[1],
                currentPrice,
                stats.totalExecutions
            );

            return true;
        } catch {
            // Swap failed - return tokens
            IERC20(paymentToken).transfer(creator, amountToSpend);
            return false;
        }
    }

    /**
     * @notice Get current price from DEX
     * @param _tokenIn Input token
     * @param _tokenOut Output token
     * @param _router DEX router
     * @return price Current price (in 1e18 format)
     */
    function _getCurrentPrice(
        address _tokenIn,
        address _tokenOut,
        address _router
    ) internal view returns (uint256 price) {
        address[] memory path = new address[](2);
        path[0] = _tokenIn;
        path[1] = _tokenOut;

        try IUniswapV2Router(_router).getAmountsOut(1e18, path) returns (uint256[] memory amounts) {
            return amounts[1];
        } catch {
            return 0; // Return 0 if price fetch fails
        }
    }

    /**
     * @notice Preview DCA execution
     * @param _router DEX router
     * @param _paymentToken Token to spend
     * @param _tokenToBuy Token to buy
     * @param _amountToSpend Amount to spend
     * @return amountOut Expected output amount
     * @return currentPrice Current price
     */
    function previewDCA(
        address _router,
        address _paymentToken,
        address _tokenToBuy,
        uint256 _amountToSpend
    ) external view returns (uint256 amountOut, uint256 currentPrice) {
        require(supportedRouters[_router], "Router not supported");

        address[] memory path = new address[](2);
        path[0] = _paymentToken;
        path[1] = _tokenToBuy;

        uint256[] memory amounts = IUniswapV2Router(_router).getAmountsOut(_amountToSpend, path);
        amountOut = amounts[1];
        currentPrice = _getCurrentPrice(_paymentToken, _tokenToBuy, _router);
    }

    /**
     * @notice Get DCA statistics for a task
     * @param _taskId Task identifier
     * @return stats DCA statistics
     */
    function getDCAStats(uint256 _taskId) external view returns (DCAStats memory stats) {
        return dcaStats[_taskId];
    }

    /**
     * @notice Calculate profit/loss for a DCA task
     * @param _taskId Task identifier
     * @param _currentPrice Current price of the asset
     * @return profitLoss Profit or loss in basis points (10000 = 100%)
     * @return isProfit True if in profit, false if in loss
     */
    function calculateProfitLoss(
        uint256 _taskId,
        uint256 _currentPrice
    ) external view returns (uint256 profitLoss, bool isProfit) {
        DCAStats storage stats = dcaStats[_taskId];

        if (stats.averagePrice == 0 || stats.totalAmountOut == 0) {
            return (0, false);
        }

        // Current value = totalAmountOut * currentPrice / 1e18
        uint256 currentValue = (stats.totalAmountOut * _currentPrice) / 1e18;

        if (currentValue >= stats.totalAmountIn) {
            // In profit
            profitLoss = ((currentValue - stats.totalAmountIn) * 10000) / stats.totalAmountIn;
            isProfit = true;
        } else {
            // In loss
            profitLoss = ((stats.totalAmountIn - currentValue) * 10000) / stats.totalAmountIn;
            isProfit = false;
        }
    }

    // ============ Admin Functions ============

    /**
     * @notice Set action router address
     * @param _actionRouter Action router contract
     */
    function setActionRouter(address _actionRouter) external onlyOwner {
        require(_actionRouter != address(0), "Invalid router");
        actionRouter = _actionRouter;
    }

    /**
     * @notice Add supported DEX router
     * @param _router Router address
     */
    function addRouter(address _router) external onlyOwner {
        require(_router != address(0), "Invalid router");
        supportedRouters[_router] = true;
        emit RouterAdded(_router);
    }

    /**
     * @notice Set default slippage tolerance
     * @param _slippageBps Slippage in basis points
     */
    function setDefaultSlippage(uint256 _slippageBps) external onlyOwner {
        require(_slippageBps <= 2000, "Slippage too high"); // Max 20%
        defaultSlippageBps = _slippageBps;
    }

    /**
     * @notice Batch add multiple routers
     * @param _routers Array of router addresses
     */
    function batchAddRouters(address[] calldata _routers) external onlyOwner {
        for (uint256 i = 0; i < _routers.length; i++) {
            supportedRouters[_routers[i]] = true;
            emit RouterAdded(_routers[i]);
        }
    }

    /**
     * @notice Emergency withdraw stuck tokens
     * @param _token Token address
     * @param _to Recipient
     * @param _amount Amount
     */
    function emergencyWithdraw(
        address _token,
        address _to,
        uint256 _amount
    ) external onlyOwner {
        require(_to != address(0), "Invalid recipient");
        IERC20(_token).transfer(_to, _amount);
    }
}
