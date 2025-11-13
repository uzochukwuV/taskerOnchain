// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title TokenRegistry
 * @notice Manages approved tokens for the task automation platform
 * @dev Provides token metadata, pricing, and allowlist functionality
 */
contract TokenRegistry is Ownable {

    // ============ Structures ============

    /**
     * @notice Token metadata
     * @param tokenAddress Token contract address
     * @param symbol Token symbol (e.g., "USDC")
     * @param name Token name (e.g., "USD Coin")
     * @param decimals Token decimals
     * @param isStablecoin Whether token is a stablecoin
     * @param isActive Whether token is currently approved
     * @param priceFeed Chainlink price feed address (if available)
     * @param category Token category (0=Stable, 1=Native, 2=Wrapped, 3=DeFi, 4=Other)
     */
    struct TokenInfo {
        address tokenAddress;
        string symbol;
        string name;
        uint8 decimals;
        bool isStablecoin;
        bool isActive;
        address priceFeed;
        uint8 category;
    }

    /**
     * @notice Token categories
     */
    enum TokenCategory {
        STABLECOIN,   // USDC, USDT, DAI, etc.
        NATIVE,       // GLMR, DOT, etc.
        WRAPPED,      // WGLMR, WETH, WBTC, etc.
        DEFI,         // Protocol tokens (AAVE, COMP, etc.)
        OTHER         // Other tokens
    }

    // ============ State Variables ============

    /// @notice Mapping from token address to token info
    mapping(address => TokenInfo) public tokens;

    /// @notice List of all registered token addresses
    address[] public tokenList;

    /// @notice Mapping from symbol to token address
    mapping(string => address) public symbolToAddress;

    /// @notice Total number of active tokens
    uint256 public activeTokenCount;

    // ============ Events ============

    event TokenAdded(
        address indexed tokenAddress,
        string symbol,
        string name,
        uint8 category
    );

    event TokenUpdated(
        address indexed tokenAddress,
        bool isActive
    );

    event TokenRemoved(address indexed tokenAddress);

    event PriceFeedSet(
        address indexed tokenAddress,
        address indexed priceFeed
    );

    // ============ Constructor ============

    constructor() Ownable(msg.sender) {}

    // ============ Core Functions ============

    /**
     * @notice Add a new token to the registry
     * @param _tokenAddress Token contract address
     * @param _symbol Token symbol
     * @param _name Token name
     * @param _isStablecoin Whether token is a stablecoin
     * @param _priceFeed Chainlink price feed (optional)
     * @param _category Token category
     */
    function addToken(
        address _tokenAddress,
        string calldata _symbol,
        string calldata _name,
        bool _isStablecoin,
        address _priceFeed,
        uint8 _category
    ) external onlyOwner {
        require(_tokenAddress != address(0), "Invalid token address");
        require(tokens[_tokenAddress].tokenAddress == address(0), "Token already exists");
        require(_category <= uint8(TokenCategory.OTHER), "Invalid category");

        // Get decimals from token contract
        uint8 decimals = IERC20Metadata(_tokenAddress).decimals();

        tokens[_tokenAddress] = TokenInfo({
            tokenAddress: _tokenAddress,
            symbol: _symbol,
            name: _name,
            decimals: decimals,
            isStablecoin: _isStablecoin,
            isActive: true,
            priceFeed: _priceFeed,
            category: _category
        });

        tokenList.push(_tokenAddress);
        symbolToAddress[_symbol] = _tokenAddress;
        activeTokenCount++;

        emit TokenAdded(_tokenAddress, _symbol, _name, _category);
    }

    /**
     * @notice Batch add multiple tokens
     * @param _tokenAddresses Array of token addresses
     * @param _symbols Array of symbols
     * @param _names Array of names
     * @param _isStablecoins Array of stablecoin flags
     * @param _priceFeeds Array of price feeds
     * @param _categories Array of categories
     */
    function batchAddTokens(
        address[] calldata _tokenAddresses,
        string[] calldata _symbols,
        string[] calldata _names,
        bool[] calldata _isStablecoins,
        address[] calldata _priceFeeds,
        uint8[] calldata _categories
    ) external onlyOwner {
        require(
            _tokenAddresses.length == _symbols.length &&
            _tokenAddresses.length == _names.length &&
            _tokenAddresses.length == _isStablecoins.length &&
            _tokenAddresses.length == _priceFeeds.length &&
            _tokenAddresses.length == _categories.length,
            "Array length mismatch"
        );

        for (uint256 i = 0; i < _tokenAddresses.length; i++) {
            if (tokens[_tokenAddresses[i]].tokenAddress == address(0)) {
                uint8 decimals = IERC20Metadata(_tokenAddresses[i]).decimals();

                tokens[_tokenAddresses[i]] = TokenInfo({
                    tokenAddress: _tokenAddresses[i],
                    symbol: _symbols[i],
                    name: _names[i],
                    decimals: decimals,
                    isStablecoin: _isStablecoins[i],
                    isActive: true,
                    priceFeed: _priceFeeds[i],
                    category: _categories[i]
                });

                tokenList.push(_tokenAddresses[i]);
                symbolToAddress[_symbols[i]] = _tokenAddresses[i];
                activeTokenCount++;

                emit TokenAdded(_tokenAddresses[i], _symbols[i], _names[i], _categories[i]);
            }
        }
    }

    /**
     * @notice Update token status (active/inactive)
     * @param _tokenAddress Token address
     * @param _isActive New status
     */
    function setTokenStatus(address _tokenAddress, bool _isActive) external onlyOwner {
        require(tokens[_tokenAddress].tokenAddress != address(0), "Token not found");

        bool wasActive = tokens[_tokenAddress].isActive;
        tokens[_tokenAddress].isActive = _isActive;

        if (wasActive && !_isActive) {
            activeTokenCount--;
        } else if (!wasActive && _isActive) {
            activeTokenCount++;
        }

        emit TokenUpdated(_tokenAddress, _isActive);
    }

    /**
     * @notice Set price feed for a token
     * @param _tokenAddress Token address
     * @param _priceFeed Chainlink price feed address
     */
    function setPriceFeed(address _tokenAddress, address _priceFeed) external onlyOwner {
        require(tokens[_tokenAddress].tokenAddress != address(0), "Token not found");
        tokens[_tokenAddress].priceFeed = _priceFeed;
        emit PriceFeedSet(_tokenAddress, _priceFeed);
    }

    // ============ View Functions ============

    /**
     * @notice Get token info
     * @param _tokenAddress Token address
     * @return info Token information
     */
    function getToken(address _tokenAddress) external view returns (TokenInfo memory info) {
        return tokens[_tokenAddress];
    }

    /**
     * @notice Get token address by symbol
     * @param _symbol Token symbol
     * @return address Token address
     */
    function getTokenBySymbol(string calldata _symbol) external view returns (address) {
        return symbolToAddress[_symbol];
    }

    /**
     * @notice Check if token is approved
     * @param _tokenAddress Token address
     * @return bool Whether token is active
     */
    function isTokenApproved(address _tokenAddress) external view returns (bool) {
        return tokens[_tokenAddress].isActive;
    }

    /**
     * @notice Get all active tokens
     * @return activeTokens Array of active token addresses
     */
    function getActiveTokens() external view returns (address[] memory activeTokens) {
        activeTokens = new address[](activeTokenCount);
        uint256 index = 0;

        for (uint256 i = 0; i < tokenList.length; i++) {
            if (tokens[tokenList[i]].isActive) {
                activeTokens[index] = tokenList[i];
                index++;
            }
        }
    }

    /**
     * @notice Get tokens by category
     * @param _category Token category
     * @return categoryTokens Array of token addresses in category
     */
    function getTokensByCategory(uint8 _category) external view returns (address[] memory categoryTokens) {
        uint256 count = 0;

        // Count tokens in category
        for (uint256 i = 0; i < tokenList.length; i++) {
            if (tokens[tokenList[i]].category == _category && tokens[tokenList[i]].isActive) {
                count++;
            }
        }

        // Fill array
        categoryTokens = new address[](count);
        uint256 index = 0;

        for (uint256 i = 0; i < tokenList.length; i++) {
            if (tokens[tokenList[i]].category == _category && tokens[tokenList[i]].isActive) {
                categoryTokens[index] = tokenList[i];
                index++;
            }
        }
    }

    /**
     * @notice Get all stablecoins
     * @return stablecoins Array of stablecoin addresses
     */
    function getStablecoins() external view returns (address[] memory stablecoins) {
        uint256 count = 0;

        for (uint256 i = 0; i < tokenList.length; i++) {
            if (tokens[tokenList[i]].isStablecoin && tokens[tokenList[i]].isActive) {
                count++;
            }
        }

        stablecoins = new address[](count);
        uint256 index = 0;

        for (uint256 i = 0; i < tokenList.length; i++) {
            if (tokens[tokenList[i]].isStablecoin && tokens[tokenList[i]].isActive) {
                stablecoins[index] = tokenList[i];
                index++;
            }
        }
    }

    /**
     * @notice Get total number of registered tokens
     * @return uint256 Total token count
     */
    function getTotalTokens() external view returns (uint256) {
        return tokenList.length;
    }

    /**
     * @notice Get paginated token list
     * @param _offset Starting index
     * @param _limit Number of tokens to return
     * @return tokens Array of token addresses
     * @return hasMore Whether there are more tokens
     */
    function getTokensPaginated(
        uint256 _offset,
        uint256 _limit
    ) external view returns (address[] memory tokens, bool hasMore) {
        uint256 total = tokenList.length;

        if (_offset >= total) {
            return (new address[](0), false);
        }

        uint256 end = _offset + _limit;
        if (end > total) {
            end = total;
        }

        uint256 resultLength = end - _offset;
        tokens = new address[](resultLength);

        for (uint256 i = 0; i < resultLength; i++) {
            tokens[i] = tokenList[_offset + i];
        }

        hasMore = end < total;
    }
}

/**
 * @notice ERC20 Metadata interface
 */
interface IERC20Metadata {
    function decimals() external view returns (uint8);
}
