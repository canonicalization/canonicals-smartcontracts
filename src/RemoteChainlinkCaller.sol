// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import {IOracleCaller, TSPOracleData} from "./OracleData_Manager.sol";
import {IOracleData_Manager, IMailbox, RequestState, MarketVerificationStatus, ITSP_Market} from "./interfaces.sol";

// =============================================================================
// HYPERLANE MESSAGE STRUCT
// =============================================================================
// Defined here (not in interfaces.sol) because it is an implementation detail
// of the cross-chain Chainlink oracle path. Only RemoteChainlinkCaller (source)
// and RemoteChainlinkCallerDestination (destination) use this struct.
// RemoteChainlinkCallerDestination imports it from this file.

/**
 * @dev Cross-chain message sent from RemoteChainlinkCaller (Autonity) to
 * RemoteChainlinkCallerDestination (Polygon) via Hyperlane.
 * Contains all fields needed to submit a Chainlink Functions request on Polygon.
 */
struct HyperlaneMessage {
    address market;
    address expiry;
    // Common oracle fields
    string  sourceCode;
    string[] args;
    bytes[] bytesArgs;
    uint256 scale;                        // Included for destination-side reference
    // Caller-specific Chainlink params (decoded from CallerParams)
    uint64  subscriptionId;
    bytes32 donId;
    bytes   encryptedSecretsUrls;
    uint8   donHostedSecretsSlotID;
    uint64  donHostedSecretsVersion;
}

// =============================================================================
// REMOTE CHAINLINK CALLER CONTRACT
// =============================================================================

/**
 * @title RemoteChainlinkCaller
 * @dev IOracleCaller implementation for chains without native Chainlink Functions support.
 *
 * Deployed on chains like Autonity that cannot call Chainlink directly.
 * Sends oracle requests cross-chain to RemoteChainlinkCallerDestination on Polygon
 * via Hyperlane, receives results back via Hyperlane handle().
 *
 * Architecture position:
 *   TSP_Expiry → ODM.requestResolvedValue()
 *             → RemoteChainlinkCaller.requestData()         [this chain, e.g. Autonity]
 *             → Hyperlane dispatch → HyperlaneMessage
 *             → RemoteChainlinkCallerDestination.handle()   [Polygon]
 *             → Chainlink Functions Router                  [Polygon]
 *             → RemoteChainlinkCallerDestination.fulfillRequest()
 *             → Hyperlane dispatch → abi.encode(expiry, value, timestamp)
 *             → RemoteChainlinkCaller.handle()              [this chain]
 *             → ODM._setResolvedValue()
 *             → TSP_Expiry continues resolution
 *
 * Key design decisions:
 * - oracleDataManager is immutable - set in constructor, never changes
 * - Hyperlane config (mailbox, domainId) locked after first set
 * - remoteChainlinkCallerDestination (Polygon address) locked after first set
 * - CallerParams decoded from TSPOracleData.callerParams - identical structure to
 *   LocalChainlinkCaller but defined independently (self-contained contracts)
 * - REQUEST_TIMEOUT = 30 minutes (cross-chain latency vs 5 min for local)
 * - requestData() and cancelRequest() restricted to ODM only (onlyODM)
 * - handle() restricted to Hyperlane mailbox only (onlyHyperlaneMailbox)
 * - Response format from destination: abi.encode(address expiry, int256 value, uint256 timestamp)
 */
contract RemoteChainlinkCaller is IOracleCaller, Ownable, ReentrancyGuard {

    // =========================================================================
    // CALLER-SPECIFIC TYPES
    // =========================================================================

    /**
     * @dev Secrets mode for Chainlink Functions - identical semantics to
     * LocalChainlinkCaller.SecretsMode, defined independently (self-contained).
     */
    enum SecretsMode {
        NONE,            // No secrets
        ENCRYPTED_URLS,  // User-hosted secrets via encrypted URLs
        DON_HOSTED       // DON-hosted secrets via slot ID + version
    }

    /**
     * @dev Caller-specific parameters stored opaquely in TSPOracleData.callerParams.
     * Decoded only inside this contract. Identical field set to
     * LocalChainlinkCaller.CallerParams - market creators use the same encoding
     * regardless of which caller is active.
     */
    struct CallerParams {
        uint64      subscriptionId;
        bytes32     donId;
        SecretsMode secretsMode;
        bytes       encryptedSecretsUrls;
        uint8       donHostedSecretsSlotID;
        uint64      donHostedSecretsVersion;
    }

    /**
     * @dev Internal state for a pending cross-chain oracle request.
     */
    struct RemoteRequest {
        RequestState state;
        address      market;
        uint256      requestTimestamp;
        int256       resolvedValue;
        uint256      responseTimestamp;
        uint256      resolvedValueTimestamp;
    }

    // =========================================================================
    // STATE VARIABLES
    // =========================================================================

    /// @dev OracleData_Manager address - immutable, set in constructor
    address public immutable oracleDataManager;

    /// @dev RemoteChainlinkCallerDestination contract address on Polygon
    address public remoteChainlinkCallerDestination;

    /// @dev Lock: once set, remoteChainlinkCallerDestination cannot be changed
    bool public remoteCallerLocked;

    /// @dev Hyperlane mailbox address on this chain
    address public hyperlaneMailbox;

    /// @dev Trusted Relayer ISM address for Hyperlane message verification
    address public trustedRelayerISM;

    /// @dev Destination chain domain ID for Hyperlane (e.g. Polygon domain ID)
    uint32 public destinationDomainId;

    /// @dev Lock: once set, Hyperlane config cannot be changed
    bool public hyperlaneConfigLocked;

    /// @dev Pending requests indexed by expiry address
    mapping(address => RemoteRequest) public chainlinkRequests;

    // =========================================================================
    // FEE MANAGEMENT STATE
    // =========================================================================

    /// @dev Fee required (in wei) when calling requestData for a VERIFIED market.
    ///      Lower than unverified fee - verified markets have tested JS and stable APIs.
    ///      Kept by this contract from msg.value; remainder forwarded to Hyperlane.
    uint256 public verifiedMarketFee;

    /// @dev Fee required (in wei) when calling requestData for a non-verified market.
    ///      Higher than verified fee - unverified markets carry higher spam risk.
    uint256 public unverifiedMarketFee;

    /// @dev Cumulative ETH paid per requester address across all requestData calls.
    ///      Indexed by the original user address forwarded from TSP_Expiry.
    ///      Never decremented - permanent audit trail for the withdrawal contract.
    mapping(address => uint256) public paidFees;

    /// @dev Address that receives ETH on withdraw/withdrawAll. Can be a wallet or a smart contract.
    ///      Must implement receive() or fallback() if it is a contract.
    ///      Only the TSP owner can set or update this address.
    address public withdrawalTarget;

    // =========================================================================
    // CONSTANTS
    // =========================================================================

    /// @dev 30 minutes - accommodates cross-chain latency (Hyperlane + Chainlink roundtrip)
    uint256 private constant _REQUEST_TIMEOUT = 30 minutes;

    // =========================================================================
    // EVENTS
    // =========================================================================

    event RequestSent(
        address indexed expiry,
        address indexed market,
        uint256 timestamp
    );
    event ValueReceived(
        address indexed expiry,
        address indexed market,
        int256  value,
        uint256 responseTimestamp,
        uint256 valueTimestamp
    );
    event RequestCancelledEvent(address indexed expiry, uint256 timestamp);
    event HyperlaneConfigUpdated(address indexed mailbox, uint32 destinationDomainId);
    event HyperlaneConfigLocked(address indexed mailbox, uint32 destinationDomainId);
    event RemoteCallerUpdated(address indexed oldCaller, address indexed newCaller);
    event RemoteCallerLocked(address indexed caller);
    event HyperlaneMessageSent(bytes32 indexed messageId, address indexed market, address indexed expiry);
    event ETHReceived(address indexed sender, uint256 amount, string reason);
    event ETHWithdrawn(address indexed recipient, uint256 amount);

    // Fee management events
    event FeePaid(address indexed requester, address indexed market, uint256 amount, bool marketVerified);
    event WithdrawalTargetUpdated(address indexed oldTarget, address indexed newTarget);
    event VerifiedMarketFeeUpdated(uint256 oldFee, uint256 newFee);
    event UnverifiedMarketFeeUpdated(uint256 oldFee, uint256 newFee);
    event FeesWithdrawn(address indexed target, uint256 amount);

    // =========================================================================
    // MODIFIERS
    // =========================================================================

    modifier onlyODM() {
        require(msg.sender == oracleDataManager, "Caller is not the OracleData_Manager");
        _;
    }

    modifier onlyHyperlaneMailbox() {
        require(msg.sender == hyperlaneMailbox, "Caller is not the Hyperlane mailbox");
        _;
    }

    // =========================================================================
    // CONSTRUCTOR
    // =========================================================================

    /**
     * @dev Deploys RemoteChainlinkCaller.
     * Hyperlane config and destination caller address are set post-deployment
     * via separate locked setters.
     * @param _oracleDataManager Address of the OracleData_Manager (immutable)
     */
    /**
     * @dev Deploys RemoteChainlinkCaller.
     * Hyperlane config and destination caller address are set post-deployment
     * via separate locked setters.
     * @param _oracleDataManager    Address of the OracleData_Manager (immutable)
     * @param _verifiedMarketFee    Initial fee in wei for VERIFIED market requests (kept by this contract)
     * @param _unverifiedMarketFee  Initial fee in wei for non-verified market requests (kept by this contract)
     */
    constructor(
        address _oracleDataManager,
        uint256 _verifiedMarketFee,
        uint256 _unverifiedMarketFee
    ) Ownable() {
        require(_oracleDataManager != address(0), "Invalid OracleData_Manager address");
        require(_unverifiedMarketFee >= _verifiedMarketFee, "Unverified fee must be >= verified fee");

        oracleDataManager   = _oracleDataManager;
        verifiedMarketFee   = _verifiedMarketFee;
        unverifiedMarketFee = _unverifiedMarketFee;
    }

    // =========================================================================
    // POST-DEPLOYMENT CONFIGURATION (owner only, each locked after first set)
    // =========================================================================

    /**
     * @dev Sets Hyperlane configuration. Locked after first call - cannot be changed.
     * @param _hyperlaneMailbox Address of the Hyperlane mailbox on this chain
     * @param _destinationDomainId Hyperlane domain ID of the destination chain (e.g. Polygon)
     */
    function setHyperlaneConfig(address _hyperlaneMailbox, uint32 _destinationDomainId)
        external onlyOwner
    {
        require(!hyperlaneConfigLocked, "Hyperlane config already locked");
        require(_hyperlaneMailbox != address(0), "Invalid mailbox address");

        hyperlaneMailbox  = _hyperlaneMailbox;
        destinationDomainId = _destinationDomainId;
        hyperlaneConfigLocked = true;

        emit HyperlaneConfigUpdated(_hyperlaneMailbox, _destinationDomainId);
        emit HyperlaneConfigLocked(_hyperlaneMailbox, _destinationDomainId);
    }

    /**
     * @dev Sets the trusted relayer ISM address for Hyperlane message verification.
     * Can be updated (not locked) - ISM may need rotation.
     * @param _trustedRelayerISM Address of the trusted relayer ISM contract
     */
    function setTrustedRelayerISM(address _trustedRelayerISM) external onlyOwner {
        require(_trustedRelayerISM != address(0), "Invalid ISM address");
        trustedRelayerISM = _trustedRelayerISM;
    }

    /**
     * @dev Sets the RemoteChainlinkCallerDestination address on the destination chain.
     * Locked after first call - cannot be changed.
     * @param _remoteChainlinkCallerDestination Address of the destination caller (e.g. on Polygon)
     */
    function setRemoteChainlinkCallerDestination(address _remoteChainlinkCallerDestination)
        external onlyOwner
    {
        require(!remoteCallerLocked, "RemoteChainlinkCallerDestination already locked");
        require(_remoteChainlinkCallerDestination != address(0), "Invalid destination caller address");

        address old = remoteChainlinkCallerDestination;
        remoteChainlinkCallerDestination = _remoteChainlinkCallerDestination;
        remoteCallerLocked = true;

        emit RemoteCallerUpdated(old, _remoteChainlinkCallerDestination);
        emit RemoteCallerLocked(_remoteChainlinkCallerDestination);
    }

    /**
     * @dev Returns the Hyperlane ISM address for incoming message verification.
     */
    function interchainSecurityModule() external view returns (address) {
        return trustedRelayerISM;
    }

    /**
     * @dev Returns whether the Hyperlane config is locked.
     */
    function isHyperlaneConfigLocked() external view returns (bool) {
        return hyperlaneConfigLocked;
    }

    /**
     * @dev Returns whether the destination caller is locked.
     */
    function isRemoteCallerLocked() external view returns (bool) {
        return remoteCallerLocked;
    }

    // =========================================================================
    // IOracleCaller - METADATA
    // =========================================================================

    /**
     * @inheritdoc IOracleCaller
     */
    function oracleName() external pure override returns (string memory) {
        return "Chainlink Functions Remote";
    }

    /**
     * @inheritdoc IOracleCaller
     */
    function oracleOffchainLink() external pure override returns (string memory) {
        return "https://functions.chain.link";
    }

    /**
     * @inheritdoc IOracleCaller
     * @dev 30 minutes - accommodates full cross-chain roundtrip latency.
     */
    function REQUEST_TIMEOUT() external pure override returns (uint256) {
        return _REQUEST_TIMEOUT;
    }

    // =========================================================================
    // IOracleCaller - CORE OPERATIONS
    // =========================================================================

    /**
     * @inheritdoc IOracleCaller
     * @dev Called by OracleData_Manager.requestResolvedValue() only (onlyODM).
     *
     * Decodes CallerParams from oracleData.callerParams, builds a HyperlaneMessage
     * from both common oracle fields and caller-specific params, then dispatches
     * cross-chain to RemoteChainlinkCallerDestination via Hyperlane.
     *
     * ETH (msg.value) is forwarded to the Hyperlane mailbox to pay dispatch fees.
     */
    function requestData(
        address _market,
        address _expiry,
        TSPOracleData calldata _oracleData,
        address _requester
    ) external payable override onlyODM {
        require(_market    != address(0), "Invalid market address");
        require(_expiry    != address(0), "Invalid expiry address");
        require(_requester != address(0), "Invalid requester address");
        require(hyperlaneMailbox != address(0), "Hyperlane not configured");
        require(remoteChainlinkCallerDestination != address(0), "Destination caller not set");
        require(bytes(_oracleData.sourceCode).length > 0, "Source code cannot be empty");
        require(!hasRequest(_expiry), "Request already pending for this expiry");

        // -------------------------------------------------------
        // FEE ENFORCEMENT
        // -------------------------------------------------------
        // Determine required platform fee based on market verification status.
        // msg.value must cover BOTH this platform fee AND the Hyperlane dispatch fee.
        // The platform fee is retained in this contract; the remainder is forwarded
        // to the Hyperlane mailbox to pay cross-chain dispatch costs.
        MarketVerificationStatus verificationStatus = ITSP_Market(_market).marketVerified();
        bool isVerified = (verificationStatus == MarketVerificationStatus.VERIFIED);
        uint256 requiredFee = isVerified ? verifiedMarketFee : unverifiedMarketFee;

        require(msg.value >= requiredFee, "Insufficient fee for oracle request");

        // Record the platform fee in the permanent per-requester history.
        paidFees[_requester] += requiredFee;

        emit FeePaid(_requester, _market, requiredFee, isVerified);

        // Remainder of msg.value after deducting platform fee is forwarded to Hyperlane.
        uint256 hyperlaneValue = msg.value - requiredFee;
        // -------------------------------------------------------

        // Decode caller-specific params
        CallerParams memory params = abi.decode(_oracleData.callerParams, (CallerParams));

        // Validate CallerParams
        require(params.subscriptionId > 0,  "Invalid subscription ID");
        require(params.donId != bytes32(0), "Invalid DON ID");
        _validateSecretsMode(params);

        // Store request state
        RemoteRequest storage req = chainlinkRequests[_expiry];
        req.state            = RequestState.PENDING;
        req.market           = _market;
        req.requestTimestamp = block.timestamp;

        // Build and dispatch the cross-chain Hyperlane message,
        // forwarding only the Hyperlane portion of msg.value (not the platform fee).
        _sendHyperlaneMessage(_market, _expiry, _oracleData, params, hyperlaneValue);

        emit RequestSent(_expiry, _market, block.timestamp);
    }

    /**
     * @inheritdoc IOracleCaller
     * @dev Called by OracleData_Manager.cancelRequest() only (onlyODM).
     *
     * checkTimeout = true  → user-initiated: requires PENDING state + 30 min elapsed
     * checkTimeout = false → system-initiated: cancels regardless of state
     *
     * Note: Cross-chain cancellation on the destination side is not possible from here.
     * The destination request may still complete after this cancellation.
     * If the destination later calls back via handle(), the stale response is dropped
     * (requestTimestamp == 0 check in _setResolvedValue).
     */
    function cancelRequest(address _expiry, bool checkTimeout) external override onlyODM {
        require(_expiry != address(0), "Invalid expiry address");

        RemoteRequest storage req = chainlinkRequests[_expiry];
        require(req.requestTimestamp > 0, "Request does not exist");

        if (checkTimeout) {
            require(req.state == RequestState.PENDING, "Request is not pending");
            require(
                block.timestamp >= req.requestTimestamp + _REQUEST_TIMEOUT,
                "Request timeout not reached"
            );
        }

        req.state             = RequestState.FAILED;
        req.responseTimestamp = block.timestamp;
        req.requestTimestamp  = 0;   // Sentinel: marks request as cancelled - stale handle() responses will be ignored

        emit RequestCancelledEvent(_expiry, block.timestamp);
    }

    // =========================================================================
    // IOracleCaller - STATE INSPECTION
    // =========================================================================

    /**
     * @inheritdoc IOracleCaller
     */
    function hasRequest(address _expiry) public view override returns (bool) {
        return chainlinkRequests[_expiry].requestTimestamp != 0;
    }

    /**
     * @inheritdoc IOracleCaller
     */
    function getRequestState(address _expiry)
        external view override returns (RequestState)
    {
        require(hasRequest(_expiry), "No request exists for this expiry");
        return chainlinkRequests[_expiry].state;
    }

    // =========================================================================
    // IOracleCaller - PARAMS ENCODING HELPER
    // =========================================================================

    /**
     * @inheritdoc IOracleCaller
     * @dev Decodes _rawParams as CallerParams and re-encodes for storage in
     * TSPOracleData.callerParams. Used by deployment scripts and frontends at
     * market creation time. Identical interface to LocalChainlinkCaller - * market creators can use the same encoding workflow regardless of which
     * caller is active.
     */
    function encodeCallerParams(bytes calldata _rawParams)
        external pure override returns (bytes memory)
    {
        CallerParams memory params = abi.decode(_rawParams, (CallerParams));
        return abi.encode(params);
    }

    // =========================================================================
    // HYPERLANE - INCOMING RESPONSE HANDLER
    // =========================================================================

    /**
     * @dev Receives the oracle response from RemoteChainlinkCallerDestination via Hyperlane.
     * Called by the Hyperlane mailbox on this chain after the destination has fulfilled
     * the Chainlink Functions request and dispatched the result.
     *
     * Message body format: abi.encode(address expiry, int256 value, uint256 valueTimestamp)
     *
     * Guards:
     * - msg.sender must be Hyperlane mailbox
     * - _origin must match destinationDomainId
     * - _sender must match remoteChainlinkCallerDestination
     * - request must still exist (requestTimestamp != 0) - stale responses after
     *   cancellation are silently dropped
     */
    function handle(
        uint32 _origin,
        bytes32 _sender,
        bytes calldata _messageBody
    ) external onlyHyperlaneMailbox {
        // Validate origin and sender - return silently rather than revert
        // to avoid blocking Hyperlane gas estimation
        if (destinationDomainId == 0 || hyperlaneMailbox == address(0)) return;
        if (_origin != destinationDomainId) return;
        if (bytes32ToAddress(_sender) != remoteChainlinkCallerDestination) return;

        // Decode response with try-catch - decoding failures must not revert
        try this._decodeHyperlaneResponse(_messageBody)
            returns (address expiry, int256 value, uint256 valueTimestamp)
        {
            _setResolvedValue(expiry, value, valueTimestamp);
        } catch {
            // Decoding failure - silently ignore, cannot recover
        }
    }

    // =========================================================================
    // INTERNAL HELPERS
    // =========================================================================

    /**
     * @dev Builds a HyperlaneMessage from common oracle fields + decoded CallerParams
     * and dispatches it to RemoteChainlinkCallerDestination via Hyperlane.
     * ETH (msg.value) is forwarded to cover Hyperlane dispatch fees.
     */
    function _sendHyperlaneMessage(
        address _market,
        address _expiry,
        TSPOracleData calldata _oracleData,
        CallerParams memory _params,
        uint256 _hyperlaneValue
    ) private {
        HyperlaneMessage memory msg_ = HyperlaneMessage({
            market:                  _market,
            expiry:                  _expiry,
            sourceCode:              _oracleData.sourceCode,
            args:                    _oracleData.args,
            bytesArgs:               _oracleData.bytesArgs,
            scale:                   _oracleData.scale,
            subscriptionId:          _params.subscriptionId,
            donId:                   _params.donId,
            encryptedSecretsUrls:    _params.encryptedSecretsUrls,
            donHostedSecretsSlotID:  _params.donHostedSecretsSlotID,
            donHostedSecretsVersion: _params.donHostedSecretsVersion
        });

        bytes memory messageBody = abi.encode(msg_);

        // Forward only the Hyperlane portion of msg.value (platform fee already retained)
        bytes32 messageId = IMailbox(hyperlaneMailbox).dispatch{value: _hyperlaneValue}(
            destinationDomainId,
            addressToBytes32(remoteChainlinkCallerDestination),
            messageBody
        );

        emit HyperlaneMessageSent(messageId, _market, _expiry);
    }

    /**
     * @dev Stores the resolved value and forwards it to OracleData_Manager.
     * Silently drops stale responses where request was cancelled (requestTimestamp == 0).
     */
    function _setResolvedValue(
        address _expiry,
        int256  _value,
        uint256 _valueTimestamp
    ) private {
        RemoteRequest storage req = chainlinkRequests[_expiry];

        // Stale response guard - request was cancelled while cross-chain roundtrip was in flight
        if (req.requestTimestamp == 0) return;

        req.state                  = RequestState.COMPLETED;
        req.resolvedValue          = _value;
        req.responseTimestamp      = block.timestamp;
        req.resolvedValueTimestamp = _valueTimestamp;

        address market = req.market;

        emit ValueReceived(_expiry, market, _value, block.timestamp, _valueTimestamp);

        // Deliver result to OracleData_Manager
        IOracleData_Manager(oracleDataManager)._setResolvedValue(
            market,
            _expiry,
            _value,
            _valueTimestamp
        );
    }

    /**
     * @dev Validates CallerParams secrets configuration consistency.
     */
    function _validateSecretsMode(CallerParams memory params) internal pure {
        if (params.secretsMode == SecretsMode.ENCRYPTED_URLS) {
            require(
                params.encryptedSecretsUrls.length > 0,
                "ENCRYPTED_URLS mode requires encryptedSecretsUrls"
            );
            require(
                params.donHostedSecretsSlotID == 0 && params.donHostedSecretsVersion == 0,
                "ENCRYPTED_URLS mode must not have DON-hosted secrets fields"
            );
        } else if (params.secretsMode == SecretsMode.DON_HOSTED) {
            require(
                params.donHostedSecretsVersion > 0,
                "DON_HOSTED mode requires donHostedSecretsVersion > 0"
            );
            require(
                params.encryptedSecretsUrls.length == 0,
                "DON_HOSTED mode must not have encryptedSecretsUrls"
            );
        } else {
            require(
                params.encryptedSecretsUrls.length == 0,
                "NONE mode must not have encryptedSecretsUrls"
            );
            require(
                params.donHostedSecretsSlotID == 0 && params.donHostedSecretsVersion == 0,
                "NONE mode must not have DON-hosted secrets fields"
            );
        }
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

    /**
     * @dev External wrapper for Hyperlane response decoding to enable try-catch in handle().
     * Self-call pattern - only callable by this contract.
     * Response format: abi.encode(address expiry, int256 value, uint256 timestamp)
     */
    function _decodeHyperlaneResponse(bytes calldata _messageBody)
        external view returns (address expiry, int256 value, uint256 timestamp)
    {
        require(msg.sender == address(this), "Only self-calls allowed");
        return abi.decode(_messageBody, (address, int256, uint256));
    }

    // =========================================================================
    // VIEW HELPERS
    // =========================================================================

    /**
     * @dev Returns complete request information for an expiry.
     */
    function getRequest(address _expiry)
        external view returns (RemoteRequest memory)
    {
        return chainlinkRequests[_expiry];
    }

    // =========================================================================
    // FEE ADMIN FUNCTIONS (owner only)
    // =========================================================================

    /**
     * @dev Sets the fee required for oracle requests on VERIFIED markets.
     * Only callable by the TSP owner (contract owner).
     * Must be <= unverifiedMarketFee.
     * @param _fee New fee in wei
     */
    function setVerifiedMarketFee(uint256 _fee) external onlyOwner {
        require(_fee <= unverifiedMarketFee, "Verified fee must be <= unverified fee");
        uint256 old = verifiedMarketFee;
        verifiedMarketFee = _fee;
        emit VerifiedMarketFeeUpdated(old, _fee);
    }

    /**
     * @dev Sets the fee required for oracle requests on non-verified markets.
     * Only callable by the TSP owner (contract owner).
     * Must be >= verifiedMarketFee.
     * @param _fee New fee in wei
     */
    function setUnverifiedMarketFee(uint256 _fee) external onlyOwner {
        require(_fee >= verifiedMarketFee, "Unverified fee must be >= verified fee");
        uint256 old = unverifiedMarketFee;
        unverifiedMarketFee = _fee;
        emit UnverifiedMarketFeeUpdated(old, _fee);
    }

    /**
     * @dev Sets or updates the withdrawal target address.
     * Only callable by the TSP owner (contract owner).
     * The target can be an EOA wallet or a smart contract.
     * If a smart contract, it MUST implement receive() or fallback() to accept ETH.
     * @param _target New withdrawal target address (must be non-zero)
     */
    function setWithdrawalTarget(address _target) external onlyOwner {
        require(_target != address(0), "Invalid withdrawal target address");
        address old = withdrawalTarget;
        withdrawalTarget = _target;
        emit WithdrawalTargetUpdated(old, _target);
    }

    // =========================================================================
    // ETH MANAGEMENT
    // Retained platform fees and any Hyperlane refunds are both held here.
    // =========================================================================

    /**
     * @dev Withdraws a specific amount of ETH to the withdrawalTarget address.
     * Only callable by the TSP owner (contract owner).
     * Uses call{value}("") for compatibility with both EOA and smart contract targets.
     * Protected by ReentrancyGuard to prevent target contracts calling back during withdrawal.
     * @param _amount Amount in wei to withdraw (must be > 0 and <= contract balance)
     */
    function withdraw(uint256 _amount) external onlyOwner nonReentrant {
        require(withdrawalTarget != address(0), "Withdrawal target not set");
        require(_amount > 0, "Amount must be greater than 0");
        require(_amount <= address(this).balance, "Insufficient balance");

        (bool success, ) = payable(withdrawalTarget).call{value: _amount}("");
        require(success, "ETH withdrawal failed");

        emit FeesWithdrawn(withdrawalTarget, _amount);
    }

    /**
     * @dev Withdraws the entire ETH balance to the withdrawalTarget address.
     * Only callable by the TSP owner (contract owner).
     * Uses call{value}("") for compatibility with both EOA and smart contract targets.
     * Protected by ReentrancyGuard to prevent target contracts calling back during withdrawal.
     * Reverts if withdrawalTarget is not set, balance is zero, or transfer fails.
     */
    function withdrawAll() external onlyOwner nonReentrant {
        require(withdrawalTarget != address(0), "Withdrawal target not set");
        uint256 balance = address(this).balance;
        require(balance > 0, "No ETH to withdraw");

        (bool success, ) = payable(withdrawalTarget).call{value: balance}("");
        require(success, "ETH withdrawal failed");

        emit FeesWithdrawn(withdrawalTarget, balance);
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
