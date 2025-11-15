// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IActionAdapter.sol";

/**
 * @title GenericAdapter
 * @notice Generic adapter for arbitrary protocol calls
 * @dev Allows execution of any approved function on approved protocols
 * @custom:security Only whitelisted protocols and function selectors allowed
 */
contract GenericAdapter is IActionAdapter, Ownable {
    using SafeERC20 for IERC20;

    // ============ Structs ============

    struct GenericParams {
        address protocol;       // Protocol to call
        bytes4 selector;        // Function selector
        bytes callData;         // ABI-encoded call data (without selector)
        uint256 value;          // ETH value to send
        address[] tokensIn;     // Tokens to pull from vault
        uint256[] amountsIn;    // Amounts to pull
        address[] tokensOut;    // Expected output tokens to return to vault
    }

    // ============ State Variables ============

    mapping(address => bool) public approvedProtocols;
    mapping(address => mapping(bytes4 => bool)) public approvedFunctions; // protocol => selector => approved

    uint256 public constant MAX_TOKENS = 5; // Max tokens per call

    // ============ Events ============

    event FunctionApproved(address indexed protocol, bytes4 indexed selector);
    event FunctionRevoked(address indexed protocol, bytes4 indexed selector);

    // ============ Constructor ============

    constructor(address _owner) Ownable(_owner) {}

    // ============ Core Functions ============

    /// @inheritdoc IActionAdapter
    function execute(address vault, bytes calldata params)
        external
        override
        returns (bool success, bytes memory result)
    {
        require(msg.sender == vault, "Only vault");

        GenericParams memory genericParams = abi.decode(params, (GenericParams));

        // Validate
        require(approvedProtocols[genericParams.protocol], "Protocol not approved");
        require(
            approvedFunctions[genericParams.protocol][genericParams.selector],
            "Function not approved"
        );
        require(genericParams.tokensIn.length <= MAX_TOKENS, "Too many input tokens");
        require(genericParams.tokensOut.length <= MAX_TOKENS, "Too many output tokens");
        require(
            genericParams.tokensIn.length == genericParams.amountsIn.length,
            "Length mismatch"
        );

        // Pull input tokens from vault
        for (uint256 i = 0; i < genericParams.tokensIn.length; i++) {
            if (genericParams.amountsIn[i] > 0) {
                IERC20(genericParams.tokensIn[i]).safeTransferFrom(
                    vault,
                    address(this),
                    genericParams.amountsIn[i]
                );

                // Approve protocol to spend
                IERC20(genericParams.tokensIn[i]).safeApprove(
                    genericParams.protocol,
                    genericParams.amountsIn[i]
                );
            }
        }

        // Construct full calldata
        bytes memory fullCallData = abi.encodePacked(
            genericParams.selector,
            genericParams.callData
        );

        // Execute call
        (bool callSuccess, bytes memory callResult) = genericParams.protocol.call{
            value: genericParams.value
        }(fullCallData);

        // Clear approvals
        for (uint256 i = 0; i < genericParams.tokensIn.length; i++) {
            if (genericParams.amountsIn[i] > 0) {
                IERC20(genericParams.tokensIn[i]).safeApprove(genericParams.protocol, 0);
            }
        }

        if (!callSuccess) {
            // Return input tokens to vault
            for (uint256 i = 0; i < genericParams.tokensIn.length; i++) {
                if (genericParams.amountsIn[i] > 0) {
                    uint256 balance = IERC20(genericParams.tokensIn[i]).balanceOf(address(this));
                    if (balance > 0) {
                        IERC20(genericParams.tokensIn[i]).safeTransfer(vault, balance);
                    }
                }
            }

            return (false, callResult);
        }

        // Return output tokens to vault
        for (uint256 i = 0; i < genericParams.tokensOut.length; i++) {
            uint256 balance = IERC20(genericParams.tokensOut[i]).balanceOf(address(this));
            if (balance > 0) {
                IERC20(genericParams.tokensOut[i]).safeTransfer(vault, balance);
            }
        }

        // Return any remaining input tokens
        for (uint256 i = 0; i < genericParams.tokensIn.length; i++) {
            uint256 balance = IERC20(genericParams.tokensIn[i]).balanceOf(address(this));
            if (balance > 0) {
                IERC20(genericParams.tokensIn[i]).safeTransfer(vault, balance);
            }
        }

        emit ActionExecuted(vault, genericParams.protocol, true, callResult);
        return (true, callResult);
    }

    // ============ View Functions ============

    /// @inheritdoc IActionAdapter
    function isProtocolSupported(address protocol) external view override returns (bool) {
        return approvedProtocols[protocol];
    }

    /// @inheritdoc IActionAdapter
    function name() external pure override returns (string memory) {
        return "GenericAdapter_v1.0";
    }

    function isFunctionApproved(address protocol, bytes4 selector) external view returns (bool) {
        return approvedFunctions[protocol][selector];
    }

    // ============ Admin Functions ============

    function approveProtocol(address protocol) external onlyOwner {
        require(protocol != address(0), "Invalid protocol");
        approvedProtocols[protocol] = true;
    }

    function revokeProtocol(address protocol) external onlyOwner {
        approvedProtocols[protocol] = false;
    }

    function approveFunction(address protocol, bytes4 selector) external onlyOwner {
        require(approvedProtocols[protocol], "Protocol not approved");
        approvedFunctions[protocol][selector] = true;
        emit FunctionApproved(protocol, selector);
    }

    function revokeFunction(address protocol, bytes4 selector) external onlyOwner {
        approvedFunctions[protocol][selector] = false;
        emit FunctionRevoked(protocol, selector);
    }

    function batchApproveFunction(
        address protocol,
        bytes4[] calldata selectors
    ) external onlyOwner {
        require(approvedProtocols[protocol], "Protocol not approved");

        for (uint256 i = 0; i < selectors.length; i++) {
            approvedFunctions[protocol][selectors[i]] = true;
            emit FunctionApproved(protocol, selectors[i]);
        }
    }

    function emergencyWithdraw(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Invalid recipient");

        if (token == address(0)) {
            (bool success, ) = to.call{value: amount}("");
            require(success, "Transfer failed");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    receive() external payable {}
}
