// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/v0.8/functions/v1_0_0/FunctionsClient.sol";
import "@chainlink/contracts/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";

// HyperlaneMessage struct defined in RemoteChainlinkCaller (source side).
// Both contracts must encode/decode the same struct for cross-chain compatibility.
import {HyperlaneMessage} from "./RemoteChainlinkCaller.sol";
import {IMailbox} from "./interfaces.sol";

interface IMessageRecipient {
    function handle(
        uint32 origin,
        bytes32 sender,
        bytes calldata body
    ) external;
}

/**
 * @title RemoteChainlinkCallerDestination
 * @dev Deployed on Polygon to handle Chainlink Functions requests on behalf of
 * RemoteChainlinkCaller on Autonity (or any chain without native Chainlink support).
 *
 * Receives oracle requests from RemoteChainlinkCaller via Hyperlane,
 * submits them to the Chainlink Functions Router on Polygon,
 * and sends results back to RemoteChainlinkCaller via Hyperlane.
 *
 * This contract is completely unchanged in logic from polygonChainlinkCaller.
 * Changes are renames only:
 *   - Contract:              polygonChainlinkCaller → RemoteChainlinkCallerDestination
 *   - autChainlinkCaller     → remoteChainlinkCaller
 *   - autChainlinkCallerLocked → remoteCallerLocked
 *   - autonityDomainId       → originDomainId
 *   - HyperlaneMessage       imported from RemoteChainlinkCaller.sol (was interfaces.sol)
 *   - All "autonity" / "polygon" / "aut" naming cleaned up throughout
 */
contract RemoteChainlinkCallerDestination is FunctionsClient, Ownable, IMessageRecipient {
    using FunctionsRequest for FunctionsRequest.Request;

    // =========================================================================
    // STRUCTS
    // =========================================================================

    /**
     * @dev State for a pending Chainlink Functions request, indexed by expiry address.
     */
    struct DestinationRequest {
        bytes32 chainlinkRequestId;
        uint256 timestamp;
        address expiry;
        address market;
        bool    isCompleted;
    }

    // =========================================================================
    // STATE VARIABLES
    // =========================================================================

    /// @dev RemoteChainlinkCaller address on the origin chain (e.g. Autonity)
    /// Set once, locked permanently after first set.
    address public remoteChainlinkCaller;

    /// @dev Lock: once set, remoteChainlinkCaller cannot be changed
    bool public remoteCallerLocked;

    /// @dev Hyperlane mailbox address on Polygon
    address public hyperlaneMailbox;

    /// @dev Trusted Relayer ISM address for Hyperlane message verification
    address public trustedRelayerISM;

    /// @dev Origin chain domain ID for Hyperlane (e.g. Autonity domain ID)
    uint32 public originDomainId;

    /// @dev Lock: once set, Hyperlane config cannot be changed
    bool public hyperlaneConfigLocked;

    /// @dev Pending requests indexed by expiry address
    mapping(address => DestinationRequest) public requests;

    /// @dev Reverse lookup: Chainlink requestId → expiry address
    mapping(bytes32 => address) public requestIdToExpiry;

    /// @dev Gas limit for Chainlink Functions calls
    uint32 public gasLimit;

    /// @dev Default DON ID (used if HyperlaneMessage.donId is zero)
    bytes32 public defaultDonId;

    /// @dev Default Subscription ID (used if HyperlaneMessage.subscriptionId is zero)
    uint64 public defaultSubscriptionId;

    // =========================================================================
    // EVENTS
    // =========================================================================

    event ChainlinkRequestSent(
        bytes32 indexed requestId,
        address indexed expiry,
        address indexed market
    );
    event ChainlinkResponseReceived(
        bytes32 indexed requestId,
        address indexed expiry,
        int256  value,
        uint256 timestamp
    );
    event ChainlinkRequestFailed(
        address indexed expiry,
        address indexed market,
        string  reason
    );
    event HyperlaneConfigUpdated(address indexed mailbox, uint32 originDomainId);
    event HyperlaneConfigLocked(address indexed mailbox, uint32 originDomainId);
    event RemoteCallerUpdated(address indexed oldCaller, address indexed newCaller);
    event RemoteCallerLocked(address indexed caller);
    event ChainlinkConfigUpdated(uint32 gasLimit, bytes32 defaultDonId, uint64 defaultSubscriptionId);
    event HyperlaneResponseSent(
        bytes32 indexed messageId,
        address indexed expiry,
        int256  value,
        uint256 timestamp
    );
    event HyperlaneErrorResponseSent(
        bytes32 indexed messageId,
        address indexed expiry,
        string  error
    );
    event ETHReceived(address indexed sender, uint256 amount, string reason);
    event ETHWithdrawn(address indexed recipient, uint256 amount);

    // =========================================================================
    // CONSTRUCTOR
    // =========================================================================

    /**
     * @dev Deploys RemoteChainlinkCallerDestination on Polygon.
     * @param _functionsRouter       Chainlink Functions Router address on Polygon
     * @param _gasLimit              Gas limit for Chainlink Functions executions
     * @param _defaultDonId          Default DON ID (used when message provides bytes32(0))
     * @param _defaultSubscriptionId Default subscription ID (used when message provides 0)
     */
    constructor(
        address _functionsRouter,
        uint32  _gasLimit,
        bytes32 _defaultDonId,
        uint64  _defaultSubscriptionId
    ) FunctionsClient(_functionsRouter) Ownable() {
        gasLimit              = _gasLimit;
        defaultDonId          = _defaultDonId;
        defaultSubscriptionId = _defaultSubscriptionId;
    }

    // =========================================================================
    // POST-DEPLOYMENT CONFIGURATION
    // =========================================================================

    /**
     * @dev Sets Hyperlane configuration. Locked after first call - cannot be changed.
     * @param _hyperlaneMailbox Address of the Hyperlane mailbox on Polygon
     * @param _originDomainId   Hyperlane domain ID of the origin chain (e.g. Autonity)
     */
    function setHyperlaneConfig(address _hyperlaneMailbox, uint32 _originDomainId)
        external onlyOwner
    {
        require(!hyperlaneConfigLocked, "Hyperlane config already locked");
        require(_hyperlaneMailbox != address(0), "Invalid hyperlane mailbox address");

        hyperlaneMailbox  = _hyperlaneMailbox;
        originDomainId    = _originDomainId;

        emit HyperlaneConfigUpdated(_hyperlaneMailbox, _originDomainId);
    }

    /**
     * @dev Sets the trusted relayer ISM address.
     */
    function setTrustedRelayerISM(address _trustedRelayerISM) external onlyOwner {
        require(_trustedRelayerISM != address(0), "Invalid ISM address");
        trustedRelayerISM = _trustedRelayerISM;
    }

    /**
     * @dev Locks the Hyperlane configuration permanently.
     */
    function lockHyperlaneConfig() external onlyOwner {
        require(hyperlaneMailbox != address(0), "Hyperlane config not set");
        require(!hyperlaneConfigLocked, "Hyperlane config already locked");
        hyperlaneConfigLocked = true;
        emit HyperlaneConfigLocked(hyperlaneMailbox, originDomainId);
    }

    /**
     * @dev Sets the RemoteChainlinkCaller address on the origin chain. Locked after first call.
     * @param _remoteChainlinkCaller Address of RemoteChainlinkCaller on origin chain
     */
    function setRemoteChainlinkCaller(address _remoteChainlinkCaller) external onlyOwner {
        require(!remoteCallerLocked, "RemoteChainlinkCaller already locked");
        require(_remoteChainlinkCaller != address(0), "Invalid caller address");

        address old = remoteChainlinkCaller;
        remoteChainlinkCaller = _remoteChainlinkCaller;
        remoteCallerLocked    = true;

        emit RemoteCallerUpdated(old, _remoteChainlinkCaller);
        emit RemoteCallerLocked(_remoteChainlinkCaller);
    }

    /**
     * @dev Updates Chainlink Functions configuration.
     */
    function setChainlinkConfig(
        uint32  _gasLimit,
        bytes32 _defaultDonId,
        uint64  _defaultSubscriptionId
    ) external onlyOwner {
        require(_gasLimit > 0,              "Gas limit must be greater than 0");
        require(_defaultDonId != bytes32(0),"Invalid DON ID");
        require(_defaultSubscriptionId > 0, "Invalid subscription ID");

        gasLimit              = _gasLimit;
        defaultDonId          = _defaultDonId;
        defaultSubscriptionId = _defaultSubscriptionId;

        emit ChainlinkConfigUpdated(_gasLimit, _defaultDonId, _defaultSubscriptionId);
    }

    /**
     * @dev Returns the ISM used to verify incoming Hyperlane messages.
     */
    function interchainSecurityModule() external view returns (address) {
        return trustedRelayerISM;
    }

    // =========================================================================
    // HYPERLANE - INCOMING REQUEST HANDLER
    // =========================================================================

    /**
     * @dev Handles oracle request messages from RemoteChainlinkCaller via Hyperlane.
     * Decodes the HyperlaneMessage, builds a Chainlink Functions request, and submits it.
     * Uses return-rather-than-revert pattern to avoid blocking Hyperlane gas estimation.
     */
    function handle(
        uint32 _origin,
        bytes32 _sender,
        bytes calldata _messageBody
    ) external override {
        // Safe early returns - don't revert during gas estimation
        if (hyperlaneMailbox == address(0) || originDomainId == 0) return;
        if (msg.sender != hyperlaneMailbox) return;
        if (_origin != originDomainId)      return;
        if (bytes32ToAddress(_sender) != remoteChainlinkCaller) return;

        // Decode the HyperlaneMessage
        HyperlaneMessage memory msg_ = abi.decode(_messageBody, (HyperlaneMessage));

        // Basic validation - return rather than revert
        if (msg_.market == address(0) || msg_.expiry == address(0) ||
            bytes(msg_.sourceCode).length == 0)
        {
            return;
        }

        // Apply defaults for zero-valued fields
        bytes32 useDonId          = msg_.donId          == bytes32(0) ? defaultDonId          : msg_.donId;
        uint64  useSubscriptionId = msg_.subscriptionId == 0          ? defaultSubscriptionId : msg_.subscriptionId;

        // Build Chainlink Functions request
        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(msg_.sourceCode);

        if (msg_.args.length > 0) {
            req.setArgs(msg_.args);
        }

        if (msg_.bytesArgs.length > 0) {
            req.setBytesArgs(msg_.bytesArgs);
        }

        // Configure secrets based on automatic detection
        // (SecretsMode is decoded implicitly by field presence)
        if (msg_.encryptedSecretsUrls.length > 0) {
            // User-hosted secrets
            req.addSecretsReference(msg_.encryptedSecretsUrls);
        } else if (msg_.donHostedSecretsVersion > 0) {
            // DON-hosted secrets
            req.addDONHostedSecrets(
                msg_.donHostedSecretsSlotID,
                msg_.donHostedSecretsVersion
            );
        }
        // Otherwise: no secrets

        // Submit to Chainlink Functions with try-catch to handle failures gracefully
        try this._sendRequestSafe(
            req.encodeCBOR(),
            useSubscriptionId,
            gasLimit,
            useDonId
        ) returns (bytes32 requestId) {
            requests[msg_.expiry] = DestinationRequest({
                chainlinkRequestId: requestId,
                timestamp:          block.timestamp,
                expiry:             msg_.expiry,
                market:             msg_.market,
                isCompleted:        false
            });

            requestIdToExpiry[requestId] = msg_.expiry;

            emit ChainlinkRequestSent(requestId, msg_.expiry, msg_.market);

        } catch Error(string memory reason) {
            emit ChainlinkRequestFailed(msg_.expiry, msg_.market, reason);

        } catch (bytes memory) {
            emit ChainlinkRequestFailed(msg_.expiry, msg_.market, "Unknown Chainlink error");
        }
    }

    // =========================================================================
    // CHAINLINK FUNCTIONS CALLBACK
    // =========================================================================

    /**
     * @dev Chainlink Functions callback from the Router on Polygon.
     * Decodes the response and sends it back to RemoteChainlinkCaller via Hyperlane.
     * Expected response format: abi.encode(int256 value, uint256 timestamp)
     */
    function fulfillRequest(
        bytes32 requestId,
        bytes memory response,
        bytes memory err
    ) internal override {
        address expiry = requestIdToExpiry[requestId];
        if (expiry == address(0)) return;   // Unknown requestId - silently ignore

        DestinationRequest storage request = requests[expiry];

        // Guard against stale responses after cancellation or request replacement
        if (request.chainlinkRequestId != requestId) {
            delete requestIdToExpiry[requestId];
            return;
        }

        // Handle Chainlink-side execution errors
        if (err.length > 0) {
            emit ChainlinkRequestFailed(expiry, request.market, "Chainlink execution error");
            delete requests[expiry];
            delete requestIdToExpiry[requestId];
            return;
        }

        // Decode response: abi.encode(int256 value, uint256 timestamp)
        int256  resolvedValue     = 0;
        uint256 resolvedTimestamp = 0;

        try this._decodeResponse(response) returns (int256 v, uint256 t) {
            resolvedValue     = v;
            resolvedTimestamp = t;
        } catch {
            emit ChainlinkRequestFailed(expiry, request.market, "Failed to decode response");
            delete requests[expiry];
            delete requestIdToExpiry[requestId];
            return;
        }

        // Send result back to RemoteChainlinkCaller via Hyperlane
        _sendHyperlaneResponse(request.expiry, resolvedValue, resolvedTimestamp);

        emit ChainlinkResponseReceived(requestId, expiry, resolvedValue, resolvedTimestamp);

        // Clean up storage
        delete requests[expiry];
        delete requestIdToExpiry[requestId];
    }

    // =========================================================================
    // INTERNAL HELPERS
    // =========================================================================

    /**
     * @dev Sends the oracle result back to RemoteChainlinkCaller via Hyperlane.
     * Response format: abi.encode(address expiry, int256 value, uint256 timestamp)
     */
    function _sendHyperlaneResponse(
        address expiry,
        int256  value,
        uint256 timestamp
    ) private {
        bytes memory responseData = abi.encode(expiry, value, timestamp);

        bytes32 messageId = IMailbox(hyperlaneMailbox).dispatch{value: 0}(
            originDomainId,
            addressToBytes32(remoteChainlinkCaller),
            responseData
        );

        emit HyperlaneResponseSent(messageId, expiry, value, timestamp);
    }

    /**
     * @dev External wrapper for _sendRequest to enable try-catch in handle().
     * Self-call pattern - only callable by this contract.
     */
    function _sendRequestSafe(
        bytes memory encodedRequest,
        uint64 subscriptionId,
        uint32 gasLimitValue,
        bytes32 donIdValue
    ) external returns (bytes32) {
        require(msg.sender == address(this), "Only self-calls allowed");
        return _sendRequest(encodedRequest, subscriptionId, gasLimitValue, donIdValue);
    }

    /**
     * @dev External wrapper for response decoding to enable try-catch in fulfillRequest().
     * Self-call pattern - only callable by this contract.
     */
    function _decodeResponse(bytes memory response)
        external view returns (int256 value, uint256 timestamp)
    {
        require(msg.sender == address(this), "Only self-calls allowed");
        return abi.decode(response, (int256, uint256));
    }

    // =========================================================================
    // EMERGENCY OPERATIONS
    // =========================================================================

    /**
     * @dev Emergency: manually cancel a stuck request (owner only).
     * @param expiry Address of the TSP_Expiry whose request to cancel
     */
    function emergencyCancelRequest(address expiry) external onlyOwner {
        DestinationRequest storage request = requests[expiry];
        require(request.chainlinkRequestId != bytes32(0), "Request does not exist");

        delete requestIdToExpiry[request.chainlinkRequestId];
        delete requests[expiry];
    }

    // =========================================================================
    // VIEW HELPERS
    // =========================================================================

    /**
     * @dev Returns complete request info for an expiry.
     */
    function getRequest(address expiry)
        external view returns (DestinationRequest memory)
    {
        return requests[expiry];
    }

    // =========================================================================
    // HYPERLANE ADDRESS UTILS
    // =========================================================================

    function addressToBytes32(address _addr) public pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }

    function bytes32ToAddress(bytes32 _b) public pure returns (address) {
        return address(uint160(uint256(_b)));
    }

    // =========================================================================
    // ETH MANAGEMENT
    // =========================================================================

    function withdrawETH(uint256 _amount) external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No ETH to withdraw");
        uint256 amount = _amount == 0 ? balance : _amount;
        require(amount <= balance, "Insufficient balance");
        (bool success, ) = payable(owner()).call{value: amount}("");
        require(success, "ETH withdrawal failed");
        emit ETHWithdrawn(owner(), amount);
    }

    function getETHBalance() external view returns (uint256) {
        return address(this).balance;
    }

    receive() external payable {
        emit ETHReceived(msg.sender, msg.value, "ETH received (likely Hyperlane refund)");
    }

    fallback() external payable {
        emit ETHReceived(msg.sender, msg.value, "ETH received via fallback");
    }
}
