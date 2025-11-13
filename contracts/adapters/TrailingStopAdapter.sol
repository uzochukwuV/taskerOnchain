// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title TrailingStopAdapter
 * @notice Dynamic stop loss that trails price movements upward
 * @dev Tracks peak price and triggers when price drops X% from peak
 */
contract TrailingStopAdapter is Ownable {

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
     * @notice Trailing stop tracking data per task
     * @param peakPrice Highest price reached since task creation
     * @param lastUpdateTime Last time peak was updated
     * @param trailingPercent Percentage drop from peak to trigger (basis points)
     * @param isActive Whether trailing stop is active
     */
    struct TrailingStopData {
        uint256 peakPrice;
        uint256 lastUpdateTime;
        uint256 trailingPercent;
        bool isActive;
    }

    // ============ State Variables ============

    /// @notice Action router that can call this adapter
    address public actionRouter;

    /// @notice Supported DEX routers
    mapping(address => bool) public supportedRouters;

    /// @notice Trailing stop data per task
    mapping(uint256 => TrailingStopData) public trailingStops;

    /// @notice Default deadline extension (5 minutes)
    uint256 public constant DEADLINE_EXTENSION = 5 minutes;

    /// @notice Default slippage tolerance
    uint256 public maxSlippageBps = 500;

    // ============ Events ============

    event TrailingStopInitialized(
        uint256 indexed taskId,
        uint256 initialPrice,
        uint256 trailingPercent
    );

    event PeakPriceUpdated(
        uint256 indexed taskId,
        uint256 oldPeak,
        uint256 newPeak
    );

    event TrailingStopTriggered(
        uint256 indexed taskId,
        address indexed token,
        uint256 peakPrice,
        uint256 triggerPrice,
        uint256 dropPercent,
        uint256 amountSold,
        uint256 amountReceived
    );

    event RouterAdded(address indexed router);

    // ============ Constructor ============

    constructor() Ownable(msg.sender) {}

    // ============ Core Functions ============

    /**
     * @notice Execute trailing stop order
     * @param _taskId Task identifier
     * @param _protocol DEX router address
     * @param _selector Function selector (not used)
     * @param _params Encoded parameters
     * @param _value ETH value (not used)
     * @return success Whether trailing stop executed
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
            address tokenToSell,
            address tokenToReceive,
            uint256 amountToSell,
            uint256 trailingPercent,  // Drop percentage from peak (e.g., 1000 = 10%)
            address recipient,
            address creator
        ) = abi.decode(_params, (address, address, uint256, uint256, address, address));

        // Validate parameters
        require(tokenToSell != address(0), "Invalid token to sell");
        require(tokenToReceive != address(0), "Invalid token to receive");
        require(amountToSell > 0, "Invalid amount");
        require(trailingPercent > 0 && trailingPercent <= 5000, "Invalid trailing %"); // Max 50%
        require(recipient != address(0), "Invalid recipient");
        require(creator != address(0), "Invalid creator");

        // Get current price
        uint256 currentPrice = _getCurrentPrice(tokenToSell, tokenToReceive, _protocol);
        require(currentPrice > 0, "Invalid price");

        TrailingStopData storage tsData = trailingStops[_taskId];

        // Initialize if first execution
        if (!tsData.isActive) {
            tsData.peakPrice = currentPrice;
            tsData.trailingPercent = trailingPercent;
            tsData.isActive = true;
            tsData.lastUpdateTime = block.timestamp;

            emit TrailingStopInitialized(_taskId, currentPrice, trailingPercent);
            return false; // Don't execute on initialization
        }

        // Update peak if price increased
        if (currentPrice > tsData.peakPrice) {
            uint256 oldPeak = tsData.peakPrice;
            tsData.peakPrice = currentPrice;
            tsData.lastUpdateTime = block.timestamp;

            emit PeakPriceUpdated(_taskId, oldPeak, currentPrice);
            return false; // Don't execute, price is rising
        }

        // Calculate trigger price (peak - trailing %)
        uint256 triggerPrice = (tsData.peakPrice * (10000 - tsData.trailingPercent)) / 10000;

        // Check if price dropped enough to trigger
        if (currentPrice > triggerPrice) {
            return false; // Price hasn't dropped enough
        }

        // Trailing stop triggered - execute sell
        bool transferSuccess = IERC20(tokenToSell).transferFrom(
            creator,
            address(this),
            amountToSell
        );
        require(transferSuccess, "Token transfer failed");

        // Calculate minimum output with slippage
        uint256 minAmountOut = (amountToSell * currentPrice * (10000 - maxSlippageBps)) / 10000 / 1e18;

        // Approve router
        IERC20(tokenToSell).approve(_protocol, amountToSell);

        // Build path
        address[] memory path = new address[](2);
        path[0] = tokenToSell;
        path[1] = tokenToReceive;

        // Execute swap
        try IUniswapV2Router(_protocol).swapExactTokensForTokens(
            amountToSell,
            minAmountOut,
            path,
            recipient,
            block.timestamp + DEADLINE_EXTENSION
        ) returns (uint256[] memory amounts) {

            // Calculate actual drop percentage
            uint256 dropPercent = ((tsData.peakPrice - currentPrice) * 10000) / tsData.peakPrice;

            emit TrailingStopTriggered(
                _taskId,
                tokenToSell,
                tsData.peakPrice,
                currentPrice,
                dropPercent,
                amounts[0],
                amounts[1]
            );

            // Deactivate trailing stop after execution
            tsData.isActive = false;

            return true;
        } catch {
            // Swap failed - return tokens
            IERC20(tokenToSell).transfer(creator, amountToSell);
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
            revert("Price fetch failed");
        }
    }

    /**
     * @notice Check if trailing stop should trigger
     * @param _taskId Task identifier
     * @param _router DEX router
     * @param _tokenIn Token to sell
     * @param _tokenOut Token to receive
     * @return shouldTrigger Whether stop should execute
     * @return currentPrice Current price
     * @return peakPrice Peak price
     * @return dropPercent Current drop from peak (basis points)
     */
    function checkTrailingStop(
        uint256 _taskId,
        address _router,
        address _tokenIn,
        address _tokenOut
    ) external view returns (
        bool shouldTrigger,
        uint256 currentPrice,
        uint256 peakPrice,
        uint256 dropPercent
    ) {
        if (!supportedRouters[_router]) {
            return (false, 0, 0, 0);
        }

        TrailingStopData storage tsData = trailingStops[_taskId];

        if (!tsData.isActive) {
            return (false, 0, 0, 0);
        }

        try this._getCurrentPrice(_tokenIn, _tokenOut, _router) returns (uint256 price) {
            currentPrice = price;
            peakPrice = tsData.peakPrice;

            if (currentPrice >= peakPrice) {
                dropPercent = 0;
                shouldTrigger = false;
            } else {
                dropPercent = ((peakPrice - currentPrice) * 10000) / peakPrice;
                uint256 triggerPrice = (peakPrice * (10000 - tsData.trailingPercent)) / 10000;
                shouldTrigger = currentPrice <= triggerPrice;
            }
        } catch {
            return (false, 0, 0, 0);
        }
    }

    /**
     * @notice Get trailing stop data for a task
     * @param _taskId Task identifier
     * @return data Trailing stop data
     */
    function getTrailingStopData(uint256 _taskId) external view returns (TrailingStopData memory data) {
        return trailingStops[_taskId];
    }

    /**
     * @notice Reset trailing stop for a task (admin only)
     * @param _taskId Task identifier
     */
    function resetTrailingStop(uint256 _taskId) external onlyOwner {
        delete trailingStops[_taskId];
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
     * @notice Set maximum slippage tolerance
     * @param _slippageBps Slippage in basis points
     */
    function setMaxSlippage(uint256 _slippageBps) external onlyOwner {
        require(_slippageBps <= 1000, "Slippage too high"); // Max 10%
        maxSlippageBps = _slippageBps;
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
