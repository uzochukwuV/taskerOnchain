// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title StopLossAdapter
 * @notice Automatically sells tokens when price drops below a threshold
 * @dev Works with Uniswap V2-compatible DEXes
 */
contract StopLossAdapter is Ownable {

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

    interface IPriceFeed {
        function latestRoundData() external view returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
        function decimals() external view returns (uint8);
    }

    // ============ State Variables ============

    /// @notice Action router that can call this adapter
    address public actionRouter;

    /// @notice Supported DEX routers
    mapping(address => bool) public supportedRouters;

    /// @notice Price feeds for tokens (Chainlink)
    mapping(address => address) public priceFeeds;

    /// @notice Default deadline extension (5 minutes)
    uint256 public constant DEADLINE_EXTENSION = 5 minutes;

    /// @notice Maximum slippage tolerance in basis points (500 = 5%)
    uint256 public maxSlippageBps = 500;

    // ============ Events ============

    event StopLossTriggered(
        uint256 indexed taskId,
        address indexed token,
        uint256 triggerPrice,
        uint256 amountSold,
        uint256 amountReceived
    );

    event RouterAdded(address indexed router);
    event PriceFeedSet(address indexed token, address indexed feed);

    // ============ Constructor ============

    constructor() Ownable(msg.sender) {}

    // ============ Core Functions ============

    /**
     * @notice Execute stop loss order
     * @param _taskId Task identifier
     * @param _protocol DEX router address
     * @param _selector Function selector (not used)
     * @param _params Encoded parameters
     * @param _value ETH value (not used)
     * @return success Whether stop loss executed
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
            uint256 stopLossPrice,  // Minimum acceptable price
            address recipient,
            address creator
        ) = abi.decode(_params, (address, address, uint256, uint256, address, address));

        // Validate parameters
        require(tokenToSell != address(0), "Invalid token to sell");
        require(tokenToReceive != address(0), "Invalid token to receive");
        require(amountToSell > 0, "Invalid amount");
        require(recipient != address(0), "Invalid recipient");
        require(creator != address(0), "Invalid creator");

        // Check if stop loss price is hit
        uint256 currentPrice = _getCurrentPrice(tokenToSell, tokenToReceive, _protocol);
        if (currentPrice > stopLossPrice) {
            return false; // Price still above stop loss threshold
        }

        // Transfer tokens from creator to adapter
        bool transferSuccess = IERC20(tokenToSell).transferFrom(
            creator,
            address(this),
            amountToSell
        );
        require(transferSuccess, "Token transfer failed");

        // Calculate minimum output with slippage
        uint256 minAmountOut = (amountToSell * stopLossPrice * (10000 - maxSlippageBps)) / 10000 / 1e18;

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
            emit StopLossTriggered(
                _taskId,
                tokenToSell,
                currentPrice,
                amounts[0],
                amounts[1]
            );
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
     * @notice Check if stop loss should trigger
     * @param _router DEX router
     * @param _tokenIn Token to sell
     * @param _tokenOut Token to receive
     * @param _stopLossPrice Stop loss threshold
     * @return bool Whether stop loss should trigger
     */
    function shouldTrigger(
        address _router,
        address _tokenIn,
        address _tokenOut,
        uint256 _stopLossPrice
    ) external view returns (bool) {
        if (!supportedRouters[_router]) {
            return false;
        }

        try this._getCurrentPrice(_tokenIn, _tokenOut, _router) returns (uint256 currentPrice) {
            return currentPrice <= _stopLossPrice;
        } catch {
            return false;
        }
    }

    /**
     * @notice Preview stop loss execution
     * @param _router DEX router
     * @param _tokenIn Token to sell
     * @param _tokenOut Token to receive
     * @param _amountIn Amount to sell
     * @return amountOut Expected output amount
     * @return currentPrice Current price
     */
    function previewStopLoss(
        address _router,
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn
    ) external view returns (uint256 amountOut, uint256 currentPrice) {
        require(supportedRouters[_router], "Router not supported");

        address[] memory path = new address[](2);
        path[0] = _tokenIn;
        path[1] = _tokenOut;

        uint256[] memory amounts = IUniswapV2Router(_router).getAmountsOut(_amountIn, path);
        amountOut = amounts[1];
        currentPrice = _getCurrentPrice(_tokenIn, _tokenOut, _router);
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
     * @notice Set price feed for token
     * @param _token Token address
     * @param _priceFeed Chainlink price feed address
     */
    function setPriceFeed(address _token, address _priceFeed) external onlyOwner {
        priceFeeds[_token] = _priceFeed;
        emit PriceFeedSet(_token, _priceFeed);
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
