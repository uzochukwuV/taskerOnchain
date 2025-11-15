// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IConditionOracle
 * @notice Interface for ConditionOracle contract that verifies execution conditions
 */
interface IConditionOracle {

    // ============ Enums ============

    enum ConditionType {
        ALWAYS,              // No condition (always true)
        TIME_AFTER,          // block.timestamp >= target
        PRICE_ABOVE,         // Chainlink price >= target
        PRICE_BELOW,         // Chainlink price <= target
        BALANCE_ABOVE,       // Account balance >= target
        BALANCE_BELOW,       // Account balance <= target
        CUSTOM_ORACLE,       // External oracle with standard interface
        MULTI_AND,           // All sub-conditions true
        MULTI_OR             // Any sub-condition true
    }

    // ============ Structs ============

    struct Condition {
        ConditionType conditionType;
        bytes params; // ABI-encoded condition-specific params
    }

    struct ConditionResult {
        bool isMet;
        string reason;
    }

    // ============ Events ============

    event PriceFeedSet(address indexed token, address indexed feed);
    event OracleApproved(address indexed oracle);
    event OracleRevoked(address indexed oracle);

    // ============ Errors ============

    error InvalidConditionType();
    error NoPriceFeed();
    error StalePrice();
    error OracleNotApproved();
    error OracleCallFailed();

    // ============ Functions ============

    /// @notice Check if condition is met
    function checkCondition(Condition calldata condition)
        external
        view
        returns (ConditionResult memory);

    /// @notice Verify condition with proof (for commit-reveal)
    function verifyConditionWithProof(bytes32 conditionHash, bytes calldata proof)
        external
        view
        returns (bool);

    /// @notice Set Chainlink price feed for token
    function setPriceFeed(address token, address feed) external;

    /// @notice Batch set price feeds
    function batchSetPriceFeeds(address[] calldata tokens, address[] calldata feeds) external;

    /// @notice Get latest price from Chainlink
    function getLatestPrice(address token) external view returns (uint256 price, uint8 decimals);

    /// @notice Register custom oracle
    function registerOracle(address oracle) external;

    /// @notice Revoke oracle approval
    function revokeOracle(address oracle) external;

    /// @notice Check if oracle is approved
    function isOracleApproved(address oracle) external view returns (bool);

    /// @notice Get price feed for token
    function getPriceFeed(address token) external view returns (address);
}
