// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/IConditionOracle.sol";

// Chainlink AggregatorV3Interface
interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );

    function decimals() external view returns (uint8);
}

/**
 * @title ConditionOracle
 * @notice Verifies execution conditions using Chainlink and custom oracles
 * @dev All condition checks are view functions for gas efficiency
 */
contract ConditionOracle is IConditionOracle, Ownable {

    // ============ State Variables ============

    mapping(address => AggregatorV3Interface) public priceFeeds;
    mapping(address => bool) public approvedOracles;

    uint256 public maxPriceStaleness = 1 hours;

    // ============ Constructor ============

    constructor(address _owner) Ownable(_owner) {}

    // ============ Core Functions ============

    /// @inheritdoc IConditionOracle
    function checkCondition(Condition calldata condition)
        external
        view
        returns (ConditionResult memory result)
    {
        if (condition.conditionType == ConditionType.ALWAYS) {
            return ConditionResult({isMet: true, reason: "Always true"});
        }

        if (condition.conditionType == ConditionType.TIME_AFTER) {
            return _checkTimeAfter(condition.params);
        }

        if (condition.conditionType == ConditionType.PRICE_ABOVE) {
            return _checkPriceAbove(condition.params);
        }

        if (condition.conditionType == ConditionType.PRICE_BELOW) {
            return _checkPriceBelow(condition.params);
        }

        if (condition.conditionType == ConditionType.BALANCE_ABOVE) {
            return _checkBalanceAbove(condition.params);
        }

        if (condition.conditionType == ConditionType.BALANCE_BELOW) {
            return _checkBalanceBelow(condition.params);
        }

        if (condition.conditionType == ConditionType.CUSTOM_ORACLE) {
            return _checkCustomOracle(condition.params);
        }

        if (condition.conditionType == ConditionType.MULTI_AND) {
            return _checkMultiAnd(condition.params);
        }

        if (condition.conditionType == ConditionType.MULTI_OR) {
            return _checkMultiOr(condition.params);
        }

        revert InvalidConditionType();
    }

    /// @inheritdoc IConditionOracle
    function verifyConditionWithProof(bytes32 conditionHash, bytes calldata proof)
        external
        view
        returns (bool)
    {
        // Verify proof matches hash
        bytes32 computedHash = keccak256(proof);
        return computedHash == conditionHash;
    }

    // ============ Condition Implementations ============

    function _checkTimeAfter(bytes memory params)
        internal
        view
        returns (ConditionResult memory)
    {
        uint256 targetTime = abi.decode(params, (uint256));

        if (block.timestamp >= targetTime) {
            return ConditionResult({isMet: true, reason: "Time reached"});
        } else {
            return ConditionResult({isMet: false, reason: "Time not reached"});
        }
    }

    function _checkPriceAbove(bytes memory params)
        internal
        view
        returns (ConditionResult memory)
    {
        (address token, uint256 targetPrice) = abi.decode(params, (address, uint256));

        (uint256 currentPrice, ) = _getLatestPrice(token);

        if (currentPrice >= targetPrice) {
            return ConditionResult({isMet: true, reason: "Price above target"});
        } else {
            return ConditionResult({isMet: false, reason: "Price below target"});
        }
    }

    function _checkPriceBelow(bytes memory params)
        internal
        view
        returns (ConditionResult memory)
    {
        (address token, uint256 targetPrice) = abi.decode(params, (address, uint256));

        (uint256 currentPrice, ) = _getLatestPrice(token);

        if (currentPrice <= targetPrice) {
            return ConditionResult({isMet: true, reason: "Price below target"});
        } else {
            return ConditionResult({isMet: false, reason: "Price above target"});
        }
    }

    function _checkBalanceAbove(bytes memory params)
        internal
        view
        returns (ConditionResult memory)
    {
        (address account, address token, uint256 threshold) =
            abi.decode(params, (address, address, uint256));

        uint256 balance = _getBalance(account, token);

        if (balance >= threshold) {
            return ConditionResult({isMet: true, reason: "Balance above threshold"});
        } else {
            return ConditionResult({isMet: false, reason: "Balance below threshold"});
        }
    }

    function _checkBalanceBelow(bytes memory params)
        internal
        view
        returns (ConditionResult memory)
    {
        (address account, address token, uint256 threshold) =
            abi.decode(params, (address, address, uint256));

        uint256 balance = _getBalance(account, token);

        if (balance <= threshold) {
            return ConditionResult({isMet: true, reason: "Balance below threshold"});
        } else {
            return ConditionResult({isMet: false, reason: "Balance above threshold"});
        }
    }

    function _checkCustomOracle(bytes memory params)
        internal
        view
        returns (ConditionResult memory)
    {
        (address oracle, bytes memory oracleCall) = abi.decode(params, (address, bytes));

        if (!approvedOracles[oracle]) revert OracleNotApproved();

        (bool success, bytes memory result) = oracle.staticcall(oracleCall);
        if (!success) revert OracleCallFailed();

        bool isMet = abi.decode(result, (bool));

        if (isMet) {
            return ConditionResult({isMet: true, reason: "Oracle check passed"});
        } else {
            return ConditionResult({isMet: false, reason: "Oracle check failed"});
        }
    }

    function _checkMultiAnd(bytes memory params)
        internal
        view
        returns (ConditionResult memory)
    {
        Condition[] memory conditions = abi.decode(params, (Condition[]));

        for (uint256 i = 0; i < conditions.length; i++) {
            ConditionResult memory result = this.checkCondition(conditions[i]);
            if (!result.isMet) {
                return ConditionResult({
                    isMet: false,
                    reason: string(abi.encodePacked("Condition ", i, " failed: ", result.reason))
                });
            }
        }

        return ConditionResult({isMet: true, reason: "All conditions met"});
    }

    function _checkMultiOr(bytes memory params)
        internal
        view
        returns (ConditionResult memory)
    {
        Condition[] memory conditions = abi.decode(params, (Condition[]));

        for (uint256 i = 0; i < conditions.length; i++) {
            ConditionResult memory result = this.checkCondition(conditions[i]);
            if (result.isMet) {
                return ConditionResult({
                    isMet: true,
                    reason: string(abi.encodePacked("Condition ", i, " passed"))
                });
            }
        }

        return ConditionResult({isMet: false, reason: "No conditions met"});
    }

    // ============ Helper Functions ============

    function _getLatestPrice(address token)
        internal
        view
        returns (uint256 price, uint8 decimals)
    {
        AggregatorV3Interface priceFeed = priceFeeds[token];
        if (address(priceFeed) == address(0)) revert NoPriceFeed();

        (
            uint80 roundId,
            int256 answer,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();

        require(answer > 0, "Invalid price");
        require(answeredInRound >= roundId, "Stale data");
        require(block.timestamp - updatedAt <= maxPriceStaleness, "Price too old");

        return (uint256(answer), priceFeed.decimals());
    }

    function _getBalance(address account, address token) internal view returns (uint256) {
        if (token == address(0)) {
            // Native token
            return account.balance;
        } else {
            // ERC20 token
            (bool success, bytes memory data) = token.staticcall(
                abi.encodeWithSignature("balanceOf(address)", account)
            );
            require(success, "Balance check failed");
            return abi.decode(data, (uint256));
        }
    }

    // ============ Admin Functions ============

    /// @inheritdoc IConditionOracle
    function setPriceFeed(address token, address feed) external onlyOwner {
        require(token != address(0), "Invalid token");
        require(feed != address(0), "Invalid feed");

        priceFeeds[token] = AggregatorV3Interface(feed);
        emit PriceFeedSet(token, feed);
    }

    /// @inheritdoc IConditionOracle
    function batchSetPriceFeeds(address[] calldata tokens, address[] calldata feeds)
        external
        onlyOwner
    {
        require(tokens.length == feeds.length, "Length mismatch");

        for (uint256 i = 0; i < tokens.length; i++) {
            priceFeeds[tokens[i]] = AggregatorV3Interface(feeds[i]);
            emit PriceFeedSet(tokens[i], feeds[i]);
        }
    }

    /// @inheritdoc IConditionOracle
    function registerOracle(address oracle) external onlyOwner {
        require(oracle != address(0), "Invalid oracle");
        approvedOracles[oracle] = true;
        emit OracleApproved(oracle);
    }

    /// @inheritdoc IConditionOracle
    function revokeOracle(address oracle) external onlyOwner {
        approvedOracles[oracle] = false;
        emit OracleRevoked(oracle);
    }

    function setMaxPriceStaleness(uint256 _maxStaleness) external onlyOwner {
        require(_maxStaleness > 0, "Invalid staleness");
        maxPriceStaleness = _maxStaleness;
    }

    // ============ View Functions ============

    /// @inheritdoc IConditionOracle
    function getLatestPrice(address token) external view returns (uint256 price, uint8 decimals) {
        return _getLatestPrice(token);
    }

    /// @inheritdoc IConditionOracle
    function isOracleApproved(address oracle) external view returns (bool) {
        return approvedOracles[oracle];
    }

    /// @inheritdoc IConditionOracle
    function getPriceFeed(address token) external view returns (address) {
        return address(priceFeeds[token]);
    }
}
