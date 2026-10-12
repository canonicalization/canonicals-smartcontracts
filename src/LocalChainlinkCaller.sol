// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@chainlink/contracts/v0.8/functions/v1_0_0/FunctionsClient.sol";
import "@chainlink/contracts/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";

import {IOracleCaller, TSPOracleData} from "./OracleData_Manager.sol";
import {IOracleData_Manager, RequestState, MarketVerificationStatus, ITSP_Market} from "./interfaces.sol";

/**
 * @title LocalChainlinkCaller
 * @dev IOracleCaller implementation for chains with native Chainlink Functions support.
 *
 * Calls Chainlink Functions Router directly on the same chain - no Hyperlane,
 * no cross-chain messaging. Suitable for Polygon, Ethereum, Avalanche, etc.
 *
 * Architecture position:
 *   TSP_Expiry → ODM.requestResolvedValue()
 *             → LocalChainlinkCaller.requestData()
 *             → Chainlink Functions Router (same chain)
 *             → fulfillRequest() callback
 *             → ODM._setResolvedValue()
 *             → TSP_Expiry continues resolution
 *
 * Key design decisions:
 * - oracleDataManager set in constructor - immutable
 * - gasLimit is a contract-level config adjustable by owner, NOT in CallerParams
 * - CallerParams struct is defined internally - fully self-contained
 * - SecretsMode enum makes secrets mutual exclusivity explicit
 * - REQUEST_TIMEOUT = 5 minutes (local call - no cross-chain latency)
 * - requestData() and cancelRequest() are restricted to ODM only (onlyODM)
 * - Response format: abi.encode(int256 value, uint256 timestamp)
 */
contract LocalChainlinkCaller is IOracleCaller, FunctionsClient, Ownable, ReentrancyGuard {
    using FunctionsRequest for FunctionsRequest.Request;

    // =========================================================================
    // CALLER-SPECIFIC TYPES
    // Defined inside this contract - self-contained, no shared dependencies.
    // =========================================================================

    /**
     * @dev Secrets mode for Chainlink Functions.
     * Makes mutual exclusivity explicit at encoding time.
     */
    enum SecretsMode {
        NONE,            // No secrets
        ENCRYPTED_URLS,  // User-hosted secrets via encrypted URLs
        DON_HOSTED       // DON-hosted secrets via slot ID + version
    }

    /**
     * @dev Caller-specific parameters stored opaquely in TSPOracleData.callerParams.
     * Encoded via abi.encode(CallerParams{...}) at market creation time using
     * encodeCallerParams(). Decoded only inside this contract.
     */
    struct CallerParams {
        uint64      subscriptionId;              // Chainlink subscription ID
        bytes32     donId;                       // Chainlink DON ID
        SecretsMode secretsMode;                 // Which secrets mode to use
        bytes       encryptedSecretsUrls;        // Used if secretsMode = ENCRYPTED_URLS
        uint8       donHostedSecretsSlotID;      // Used if secretsMode = DON_HOSTED
        uint64      donHostedSecretsVersion;     // Used if secretsMode = DON_HOSTED
    }

    /**
     * @dev Internal state for a pending Chainlink request.
     */
    struct LocalRequest {
        bytes32      chainlinkRequestId;   // Request ID returned by Chainlink
        RequestState state;                // Current state of the request
        address      market;               // TSP_Market address
        uint256      requestTimestamp;     // When the request was sent
        int256       resolvedValue;        // Value received from Chainlink
        uint256      resolvedValueTimestamp; // Timestamp from oracle data source
    }

    // =========================================================================
    // STATE VARIABLES
    // =========================================================================

    /// @dev OracleData_Manager address - immutable, set in constructor
    address public immutable oracleDataManager;

    /// @dev Gas limit for Chainlink Functions calls - contract-level config
    uint32 public gasLimit;

    /// @dev Pending requests indexed by expiry address
    mapping(address => LocalRequest) public requests;

    /// @dev Reverse lookup: Chainlink requestId -> expiry address
    mapping(bytes32 => address) public requestIdToExpiry;

    // =========================================================================
    // FEE MANAGEMENT STATE
    // =========================================================================

    /// @dev Fee required (in wei) when calling requestData for a VERIFIED market.
    ///      Lower than unverified fee - verified markets have tested JS and stable APIs.
    uint256 public verifiedMarketFee;

    /// @dev Fee required (in wei) when calling requestData for a non-verified market.
    ///      Higher than verified fee - unverified markets carry higher spam risk.
    uint256 public unverifiedMarketFee;

    /// @dev Cumulative ETH paid per requester address across all requestData calls.
    ///      Indexed by the original user address forwarded from TSP_Expiry.
    ///      Never decremented - permanent audit trail for the withdrawal contract.
    mapping(address => uint256) public paidFees;

    /// @dev Address that receives ETH on withdraw(). Can be a wallet or a smart contract.
    ///      Must implement receive() or fallback() if it is a contract.
    ///      Only the TSP owner can set or update this address.
    address public withdrawalTarget;

    // =========================================================================
    // CONSTANTS
    // =========================================================================

    /// @dev Maximum wait time before cancellation is allowed.
    /// 5 minutes - sufficient for a local same-chain Chainlink Functions call.
    /// @dev 5 minutes - local Chainlink call has no cross-chain latency
    uint256 private constant _REQUEST_TIMEOUT = 5 minutes; 

    // =========================================================================
    // EVENTS
    // =========================================================================

    event RequestSent(
        bytes32 indexed chainlinkRequestId,
        address indexed expiry,
        address indexed market,
        uint256 timestamp
    );
    event RequestFulfilled(
        bytes32 indexed chainlinkRequestId,
        address indexed expiry,
        int256  value,
        uint256 valueTimestamp
    );
    event RequestFailed(
        address indexed expiry,
        address indexed market,
        string  reason
    );
    event RequestCancelled(
        address indexed expiry,
        uint256 timestamp
    );
    event GasLimitUpdated(uint32 oldGasLimit, uint32 newGasLimit);
    event ETHReceived(address indexed sender, uint256 amount);
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

    /// @dev Restricts requestData() and cancelRequest() to OracleData_Manager only
    modifier onlyODM() {
        require(msg.sender == oracleDataManager, "Caller is not the OracleData_Manager");
        _;
    }

    // =========================================================================
    // CONSTRUCTOR
    // =========================================================================

    /**
     * @dev Deploys LocalChainlinkCaller.
     * @param _functionsRouter    Address of the Chainlink Functions Router on this chain
     * @param _gasLimit           Gas limit for Chainlink Functions executions
     * @param _oracleDataManager  Address of the OracleData_Manager (immutable)
     * @param _verifiedMarketFee  Initial fee in wei required for verified market requests
     * @param _unverifiedMarketFee Initial fee in wei required for non-verified market requests
     */
    constructor(
        address _functionsRouter,
        uint32  _gasLimit,
        address _oracleDataManager,
        uint256 _verifiedMarketFee,
        uint256 _unverifiedMarketFee
    )
        FunctionsClient(_functionsRouter)
        Ownable()
    {
        require(_functionsRouter   != address(0), "Invalid Functions Router address");
        require(_gasLimit          > 0,           "Gas limit must be greater than 0");
        require(_oracleDataManager != address(0), "Invalid OracleData_Manager address");
        require(_unverifiedMarketFee >= _verifiedMarketFee, "Unverified fee must be >= verified fee");

        gasLimit             = _gasLimit;
        oracleDataManager    = _oracleDataManager;
        verifiedMarketFee    = _verifiedMarketFee;
        unverifiedMarketFee  = _unverifiedMarketFee;
    }

    // =========================================================================
    // IOracleCaller - METADATA
    // =========================================================================

    /**
     * @inheritdoc IOracleCaller
     */
    function oracleName() external pure override returns (string memory) {
        return "Chainlink Functions Local";
    }

    /**
     * @inheritdoc IOracleCaller
     */
    function oracleOffchainLink() external pure override returns (string memory) {
        return "https://functions.chain.link";
    }

    /**
     * @inheritdoc IOracleCaller
     * @dev Exposed so OracleData_Manager and frontends can query timeout without
     * hardcoding any timing assumptions.
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
     * Decodes CallerParams from oracleData.callerParams, builds a
     * FunctionsRequest, and calls _sendRequest() directly on the Chainlink
     * Functions Router deployed on this same chain.
     *
     * Fee logic:
     *   - Reads market verification status from TSP_Market.marketVerified()
     *   - Requires msg.value >= verifiedMarketFee  (if market is VERIFIED)
     *   - Requires msg.value >= unverifiedMarketFee (otherwise)
     *   - Records msg.value in paidFees[_requester] for audit and withdrawal tracking
     *   - Retains the fee in this contract; owner withdraws via withdraw()
     *
     * The response is received via fulfillRequest() callback from Chainlink.
     * Expected response format: abi.encode(int256 value, uint256 timestamp)
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
        require(bytes(_oracleData.sourceCode).length > 0, "Source code cannot be empty");
        require(!hasRequest(_expiry), "Request already pending for this expiry");

        // -------------------------------------------------------
        // FEE ENFORCEMENT
        // -------------------------------------------------------
        // Determine required fee based on market verification status.
        // VERIFIED markets have lower fees (tested JS, stable APIs).
        // All other statuses (NOT_VERIFIED, PENDING, REJECTED) use the
        // higher unverified fee to reflect higher spam/failure risk.
        MarketVerificationStatus verificationStatus = ITSP_Market(_market).marketVerified();
        bool isVerified = (verificationStatus == MarketVerificationStatus.VERIFIED);
        uint256 requiredFee = isVerified ? verifiedMarketFee : unverifiedMarketFee;

        require(msg.value >= requiredFee, "Insufficient fee for oracle request");

        // Record the payment in the permanent per-requester history.
        // msg.value (not requiredFee) is recorded so any surplus is also tracked.
        paidFees[_requester] += msg.value;

        emit FeePaid(_requester, _market, msg.value, isVerified);
        // -------------------------------------------------------

        // Decode caller-specific params from opaque callerParams bytes
        CallerParams memory params = abi.decode(_oracleData.callerParams, (CallerParams));

        // Validate CallerParams
        require(params.subscriptionId > 0,    "Invalid subscription ID");
        require(params.donId != bytes32(0),   "Invalid DON ID");
        _validateSecretsMode(params);

        // Build Chainlink Functions request
        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(_oracleData.sourceCode);

        if (_oracleData.args.length > 0) {
            req.setArgs(_oracleData.args);
        }

        if (_oracleData.bytesArgs.length > 0) {
            req.setBytesArgs(_oracleData.bytesArgs);
        }

        // Configure secrets based on SecretsMode
        if (params.secretsMode == SecretsMode.ENCRYPTED_URLS) {
            req.addSecretsReference(params.encryptedSecretsUrls);
        } else if (params.secretsMode == SecretsMode.DON_HOSTED) {
            req.addDONHostedSecrets(
                params.donHostedSecretsSlotID,
                params.donHostedSecretsVersion
            );
        }
        // SecretsMode.NONE: no secrets configured

        // Send request directly to Chainlink Functions Router on this chain
        // Uses try-catch so failures are handled gracefully without reverting
        try this._sendRequestSafe(
            req.encodeCBOR(),
            params.subscriptionId,
            gasLimit,
            params.donId
        ) returns (bytes32 chainlinkRequestId) {
            // Store request state
            requests[_expiry] = LocalRequest({
                chainlinkRequestId:    chainlinkRequestId,
                state:                 RequestState.PENDING,
                market:                _market,
                requestTimestamp:      block.timestamp,
                resolvedValue:         0,
                resolvedValueTimestamp: 0
            });

            requestIdToExpiry[chainlinkRequestId] = _expiry;

            emit RequestSent(chainlinkRequestId, _expiry, _market, block.timestamp);

        } catch Error(string memory reason) {
            emit RequestFailed(_expiry, _market, reason);
            revert(string(abi.encodePacked("Chainlink request failed: ", reason)));

        } catch (bytes memory) {
            emit RequestFailed(_expiry, _market, "Unknown Chainlink error");
            revert("Chainlink request failed: unknown error");
        }
    }

    /**
     * @inheritdoc IOracleCaller
     * @dev Called by OracleData_Manager.cancelRequest() only (onlyODM).
     *
     * checkTimeout = true  → user-initiated: requires PENDING state + timeout elapsed
     * checkTimeout = false → system-initiated: cancels regardless of state
     */
    function cancelRequest(address _expiry, bool checkTimeout) external override onlyODM {
        require(_expiry != address(0), "Invalid expiry address");

        LocalRequest storage req = requests[_expiry];
        require(req.chainlinkRequestId != bytes32(0), "No request exists for this expiry");

        if (checkTimeout) {
            require(req.state == RequestState.PENDING, "Request is not pending");
            require(
                block.timestamp >= req.requestTimestamp + _REQUEST_TIMEOUT,
                "Request timeout not yet elapsed"
            );
        }

        // Mark as failed and clean up storage
        req.state = RequestState.FAILED;
        bytes32 chainlinkRequestId = req.chainlinkRequestId;

        delete requestIdToExpiry[chainlinkRequestId];
        delete requests[_expiry];

        emit RequestCancelled(_expiry, block.timestamp);
    }

    // =========================================================================
    // IOracleCaller - STATE INSPECTION
    // =========================================================================

    /**
     * @inheritdoc IOracleCaller
     */
    function hasRequest(address _expiry) public view override returns (bool) {
        return requests[_expiry].chainlinkRequestId != bytes32(0);
    }

    /**
     * @inheritdoc IOracleCaller
     */
    function getRequestState(address _expiry) external view override returns (RequestState) {
        require(hasRequest(_expiry), "No request exists for this expiry");
        return requests[_expiry].state;
    }

    // =========================================================================
    // IOracleCaller - PARAMS ENCODING HELPER
    // =========================================================================

    /**
     * @inheritdoc IOracleCaller
     * @dev Decodes _rawParams as CallerParams and re-encodes for storage in
     * TSPOracleData.callerParams. Used by deployment scripts and frontends
     * at market creation time.
     *
     * Example usage (off-chain):
     *   bytes memory encoded = abi.encode(CallerParams({
     *       subscriptionId: 123,
     *       donId: 0x...,
     *       secretsMode: SecretsMode.DON_HOSTED,
     *       encryptedSecretsUrls: "",
     *       donHostedSecretsSlotID: 1,
     *       donHostedSecretsVersion: 1700000000
     *   }));
     *   bytes memory callerParams = LocalChainlinkCaller.encodeCallerParams(encoded);
     */
    function encodeCallerParams(bytes calldata _rawParams)
        external pure override returns (bytes memory)
    {
        // Decode to validate structure, then re-encode
        CallerParams memory params = abi.decode(_rawParams, (CallerParams));
        return abi.encode(params);
    }

    // =========================================================================
    // CHAINLINK FUNCTIONS CALLBACK
    // =========================================================================

    /**
     * @dev Chainlink Functions callback - called by the Functions Router after
     * the off-chain computation completes.
     *
     * Expected response format: abi.encode(int256 value, uint256 timestamp)
     * where timestamp is the data point's own timestamp from the oracle source.
     *
     * On success: calls ODM._setResolvedValue() to store the value.
     * On error or decode failure: marks request as FAILED and emits RequestFailed.
     */
    function fulfillRequest(
        bytes32 requestId,
        bytes memory response,
        bytes memory err
    ) internal override {
        // Look up which expiry this response belongs to
        address expiry = requestIdToExpiry[requestId];
        if (expiry == address(0)) {
            // Unknown requestId - may have been cancelled already, ignore silently
            return;
        }

        LocalRequest storage req = requests[expiry];

        // Guard against stale responses after cancellation or request replacement
        if (req.chainlinkRequestId != requestId) {
            delete requestIdToExpiry[requestId];
            return;
        }

        // Handle Chainlink-side execution errors
        if (err.length > 0) {
            address market = req.market;
            emit RequestFailed(expiry, req.market, "Chainlink execution error");
            req.state = RequestState.FAILED;
            delete requestIdToExpiry[requestId];
            delete requests[expiry];
            try IOracleData_Manager(oracleDataManager).notifyRequestFailed(
                market,
                expiry,
                "Chainlink execution error"
            ) {
                // Notification succeeded
            } catch {
                // Do not revert on notification failure
            }
            return;
        }

        // Decode response: abi.encode(int256 value, uint256 timestamp)
        int256  resolvedValue;
        uint256 resolvedTimestamp;
        try this._decodeResponse(response) returns (int256 v, uint256 t) {
            resolvedValue     = v;
            resolvedTimestamp = t;
        } catch {
            address market = req.market;
            emit RequestFailed(expiry, req.market, "Failed to decode Chainlink response");
            req.state = RequestState.FAILED;
            delete requestIdToExpiry[requestId];
            delete requests[expiry];
            try IOracleData_Manager(oracleDataManager).notifyRequestFailed(
                market,
                expiry,
                "Failed to decode Chainlink response"
            ) {
                // Notification succeeded
            } catch {
                // Do not revert on notification failure
            }
            return;
        }

        address market = req.market;

        // Mark as completed and clean up storage before external call (re-entrancy safety)
        req.state = RequestState.COMPLETED;
        delete requestIdToExpiry[requestId];
        delete requests[expiry];

        emit RequestFulfilled(requestId, expiry, resolvedValue, resolvedTimestamp);

        // Deliver result to OracleData_Manager
        IOracleData_Manager(oracleDataManager)._setResolvedValue(
            market,
            expiry,
            resolvedValue,
            resolvedTimestamp
        );
    }

    // =========================================================================
    // OWNER CONFIGURATION
    // =========================================================================

    /**
     * @dev Updates the gas limit for Chainlink Functions calls.
     * @param _gasLimit New gas limit (must be > 0)
     */
    function setGasLimit(uint32 _gasLimit) external onlyOwner {
        require(_gasLimit > 0, "Gas limit must be greater than 0");
        uint32 old = gasLimit;
        gasLimit = _gasLimit;
        emit GasLimitUpdated(old, _gasLimit);
    }

    /**
     * @dev Sets the fee required for oracle requests on VERIFIED markets.
     * Only callable by the TSP owner (contract owner).
     * Must be <= unverifiedMarketFee (verified markets always pay less or equal).
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

    /**
     * @dev Withdraws a specific amount of fee ETH to the withdrawalTarget address.
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

    // =========================================================================
    // INTERNAL HELPERS
    // =========================================================================

    /**
     * @dev Validates CallerParams secrets configuration consistency.
     * Enforces mutual exclusivity between SecretsMode and the corresponding fields.
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
            // SecretsMode.NONE
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

    /**
     * @dev External wrapper for _sendRequest to enable try-catch in requestData().
     * Only callable by this contract itself (self-call pattern).
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
     * Only callable by this contract itself (self-call pattern).
     * Response format: abi.encode(int256 value, uint256 timestamp)
     */
    function _decodeResponse(bytes memory response)
        external view returns (int256 value, uint256 timestamp)
    {
        require(msg.sender == address(this), "Only self-calls allowed");
        return abi.decode(response, (int256, uint256));
    }

    // =========================================================================
    // ETH MANAGEMENT
    // Chainlink Functions may refund unused subscription fees in ETH.
    // For fee collection, use withdraw() instead.
    // =========================================================================

    /**
     * @dev Returns the current ETH balance of this contract.
     */
    function getETHBalance() external view returns (uint256) {
        return address(this).balance;
    }

    receive() external payable {
        emit ETHReceived(msg.sender, msg.value);
    }

    fallback() external payable {
        emit ETHReceived(msg.sender, msg.value);
    }
}
