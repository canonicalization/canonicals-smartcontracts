// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

/**
 * @title Shared enums, interfaces and types
 * @dev Common types used across TSP contracts - centralized to avoid duplication
 *
 * NOTE ON ARCHITECTURE:
 * - TSPOracleData struct  → defined in OracleData_Manager.sol (evolvable with ODM upgrades)
 * - IOracleCaller         → defined in OracleData_Manager.sol (depends on TSPOracleData)
 * - RequestState enum     → defined here (stable, technology-agnostic, shared with IOracleCaller)
 * - HyperlaneMessage      → defined in RemoteChainlinkCaller.sol (only used there)
 */

// =============================================================================
// SHARED ENUMS
// =============================================================================

/**
 * @dev Enum for market verification status - shared across all contracts
 */
enum MarketVerificationStatus { 
    NOT_VERIFIED,  // Market has not requested verification
    PENDING,       // Verification requested, waiting for TSP_Manager decision
    VERIFIED,      // Market verified by TSP_Manager
    REJECTED       // Market verification rejected by TSP_Manager
}

/**
 * @dev Enum for oracle request state - shared across all OracleCaller implementations
 * Defined here because it is stable and technology-agnostic.
 * Used by IOracleCaller (defined in OracleData_Manager.sol) and all OracleCaller contracts.
 */
enum RequestState {
    PENDING,    // Request sent, waiting for response
    COMPLETED,  // Value received and stored in OracleData_Manager
    FAILED      // Request failed or cancelled
}

// =============================================================================
// HYPERLANE INTERFACE
// =============================================================================

/**
 * @title IMailbox
 * @dev Hyperlane mailbox interface for interchain communication
 * Kept in shared interfaces as it is a standard external protocol interface.
 * Used by RemoteChainlinkCaller for cross-chain oracle requests.
 * Note: HyperlaneMessage struct is defined inside RemoteChainlinkCaller.sol
 *       as it is only used there.
 */
interface IMailbox {
    function dispatch(
        uint32 destinationDomain,
        bytes32 recipientAddress,
        bytes calldata messageBody
    ) external payable returns (bytes32 messageId);
}

// =============================================================================
// IORACLEDATA_MANAGER INTERFACE
// =============================================================================

/**
 * @title IOracleData_Manager
 * @dev Interface for OracleData_Manager contract
 *
 * The OracleData_Manager maintains a registry of OracleCallers (identified by
 * their contract address). Each OracleCaller implements IOracleCaller (defined
 * in OracleData_Manager.sol alongside TSPOracleData).
 *
 * Key design points:
 * - oracleCallerAddress is the unique identifier for each OracleCaller
 * - All registry management functions are restricted to TSP owner
 * - _setResolvedValue() only accepts calls from registered OracleCallers
 * - cancelRequest() routes to the correct caller via market.oracleData()
 */
interface IOracleData_Manager {

    // =========================================================================
    // MARKET REGISTRATION
    // =========================================================================

    /**
     * @dev Registers a new TSP_Market as supported (called by TSP_Manager at market creation)
     * @param _market Address of the TSP_Market
     */
    function addSupportedMarket(address _market) external;

    /**
     * @dev Returns whether a market is supported
     * @param _market Address of the TSP_Market
     * @return Whether the market is supported
     */
    function isSupportedMarket(address _market) external view returns (bool);

    // =========================================================================
    // ORACLE CALLER REGISTRY (onlyTSPOwner on implementation)
    // =========================================================================

    /**
     * @dev Registers a new OracleCaller in the registry
     * Reads oracleName and oracleOffchainLink directly from the caller contract.
     * The caller is active by default upon registration.
     * @param _callerAddress Address of the OracleCaller contract
     */
    function registerCaller(address _callerAddress) external;

    /**
     * @dev Activates a previously deactivated OracleCaller
     * @param _callerAddress Address of the OracleCaller contract
     */
    function activateCaller(address _callerAddress) external;

    /**
     * @dev Deactivates an OracleCaller without removing it from the registry
     * In-flight requests already sent to this caller will still complete normally.
     * New requestResolvedValue() calls using this caller will revert.
     * @param _callerAddress Address of the OracleCaller contract
     */
    function deactivateCaller(address _callerAddress) external;

    /**
     * @dev Sets the default OracleCaller address used when oracleCallerAddress is address(0)
     * Reverts if the target caller is not registered or is inactive.
     * @param _callerAddress Address of the OracleCaller contract to set as default
     */
    function setDefaultOracleCallerAddress(address _callerAddress) external;

    /**
     * @dev Returns the current default OracleCaller address
     * @return The default OracleCaller address
     */
    function defaultOracleCallerAddress() external view returns (address);

    /**
     * @dev Returns the registration and activation status of an OracleCaller
     * @param _callerAddress Address of the OracleCaller contract
     * @return registered Whether the caller is registered
     * @return active Whether the caller is currently active
     */
    function getCallerStatus(address _callerAddress) external view returns (bool registered, bool active);

    // =========================================================================
    // ORACLE REQUEST FLOW
    // =========================================================================

    /**
     * @dev Requests resolved value for a specific expiry (Step 1 - called by TSP_Expiry)
     * Resolves oracleCallerAddress from market oracleData (or uses default if address(0)).
     * Checks caller is registered and active, then delegates to IOracleCaller.requestData().
     * @param _market Address of the TSP_Market
     * @param _expiry Address of the TSP_Expiry to resolve
     * @param _expiryArgs Expiry-specific arguments to override market's base args (empty = use market args)
     * @param _requester Original user address who initiated the request in TSP_Expiry.
     *        Passed explicitly because msg.sender at ODM level is the TSP_Expiry contract,
     *        not the original user. Used by OracleCallers for fee attribution.
     */
    function requestResolvedValue(
        address _market,
        address _expiry,
        string[] calldata _expiryArgs,
        address _requester
    ) external payable;

    /**
     * @dev Checks if the resolved value is ready for an expiry (Step 3 - called by TSP_Expiry)
     * Reverts if value is not yet available.
     * @param _market Address of the TSP_Market
     * @param _expiry Address of the TSP_Expiry to resolve
     */
    function resolveExpiryValue(address _market, address _expiry) external view;

    /**
     * @dev Cancels a pending oracle request for a specific expiry (called by TSP_Expiry)
     * Routes to the correct OracleCaller by reading oracleCallerAddress from market.oracleData().
     * @param _market Address of the TSP_Market
     * @param _expiry Address of the TSP_Expiry
     * @param checkTimeout Whether to enforce timeout check before cancelling
     *        true  = user cancellation: requires PENDING state and timeout elapsed
     *        false = system cancellation: cancels regardless of state
     */
    function cancelRequest(address _market, address _expiry, bool checkTimeout) external;

    /**
     * @dev Notifies OracleData_Manager that an oracle request failed (called by OracleCaller)
     * Allows ODM to clear expiry state so a new request can be made.
     * @param _market Address of the TSP_Market
     * @param _expiry Address of the TSP_Expiry
     * @param reason Human-readable failure reason
     */
    function notifyRequestFailed(address _market, address _expiry, string calldata reason) external;

    /**
     * @dev Stores the resolved value for an expiry (called by registered OracleCallers only)
     * Validates that msg.sender is a registered OracleCaller (no active check - never
     * block an in-flight result even if caller was deactivated after request was sent).
     * @param _market Address of the TSP_Market
     * @param _expiry Address of the TSP_Expiry
     * @param _value The resolved value
     * @param _valueTimestamp Timestamp of the value from the oracle data source
     */
    function _setResolvedValue(
        address _market,
        address _expiry,
        int256 _value,
        uint256 _valueTimestamp
    ) external;

    // =========================================================================
    // RESOLVED VALUE QUERIES
    // =========================================================================

    /**
     * @dev Returns whether an expiry has been resolved
     * @param _market Address of the TSP_Market
     * @param _expiry Address of the TSP_Expiry
     * @return Whether the expiry is resolved
     */
    function isExpiryResolved(address _market, address _expiry) external view returns (bool);

    /**
     * @dev Returns the resolved value and storage timestamp for a specific expiry
     * @param _market Address of the TSP_Market
     * @param _expiry Address of the TSP_Expiry
     * @return resolvedValue The resolved value
     * @return timestamp When the value was stored in OracleData_Manager
     */
    function getResolvedValue(
        address _market,
        address _expiry
    ) external view returns (int256 resolvedValue, uint256 timestamp);

    /**
     * @dev Returns the resolved value with both timestamps for a specific expiry
     * @param _market Address of the TSP_Market
     * @param _expiry Address of the TSP_Expiry
     * @return resolvedValue The resolved value
     * @return timestamp When the value was stored in OracleData_Manager
     * @return valueTimestamp Timestamp of the value from the oracle data source
     */
    function getResolvedValueWithTimestamps(
        address _market,
        address _expiry
    ) external view returns (int256 resolvedValue, uint256 timestamp, uint256 valueTimestamp);

    // =========================================================================
    // ORACLE DATA HELPERS (common fields only - callerParams is opaque)
    // =========================================================================

    /**
     * @dev Returns the source code for a market (from oracleData common fields)
     * @param _market Address of the TSP_Market
     * @return The source code string
     */
    function getSourceCode(address _market) external view returns (string memory);

    /**
     * @dev Returns the string arguments for a market (from oracleData common fields)
     * @param _market Address of the TSP_Market
     * @return The args array
     */
    function getArgs(address _market) external view returns (string[] memory);

    /**
     * @dev Returns the scale factor for a market (from oracleData common fields)
     * @param _market Address of the TSP_Market
     * @return The scale factor
     */
    function getScale(address _market) external view returns (uint256);

    /**
     * @dev Extracts the scale factor directly from encoded oracle data bytes
     * @param _oracleData Encoded oracle data bytes
     * @return The scale factor
     */
    function extractScaleFromOracleData(bytes calldata _oracleData) external pure returns (uint256);

    /**
     * @dev Validates common fields of oracle data and checks oracleCallerAddress is registered+active
     * Does NOT validate callerParams - that is the OracleCaller's responsibility.
     * @param _oracleData Encoded oracle data to validate
     * @return isValid Whether the oracle data is valid
     */
    function validateOracleData(bytes calldata _oracleData) external view returns (bool);
}

// =============================================================================
// ITSP_MANAGERNEXTVERSION INTERFACE
// =============================================================================

/**
 * @title ITSP_ManagerNextVersion
 * @dev Interface for next version TSP_Manager contract for carry migration
 */
interface ITSP_ManagerNextVersion {
    /**
     * @dev Receives carry migration from previous TSP_Manager version
     * @param _sourceMarket Address of the source market in previous version
     * @param _destinationMarket Address of the destination market in this version
     * @param _token Address of the token being migrated
     * @param _carryAmount Amount of carry being migrated
     * @param _previousTspManager Address of the previous TSP_Manager
     * @return success Whether the migration was successful
     */
    function receiveCarryMigration(
        address _sourceMarket,
        address _destinationMarket,
        address _token,
        uint256 _carryAmount,
        address _previousTspManager
    ) external returns (bool success);

    /**
     * @dev Returns whether a market is registered and verified in this TSP_Manager version
     * @param _market Address of the market
     * @return isRegistered Whether the market is registered
     * @return isVerified Whether the market is verified
     * @return marketToken Token used by the market
     */
    function getMarketInfo(address _market) external view returns (
        bool isRegistered,
        bool isVerified,
        address marketToken
    );

    /**
     * @dev Returns whether this contract accepts carry migrations
     * @return Whether carry migrations are accepted
     */
    function acceptsCarryMigration() external view returns (bool);

    /**
     * @dev Returns whether a token is supported for carry migration
     * @param _token Address of the token
     * @return Whether the token is supported
     */
    function supportedTokens(address _token) external view returns (bool);
}

// =============================================================================
// ITSP_MANAGER INTERFACE
// =============================================================================

/**
 * @title ITSP_Manager
 * @dev Interface for TSP_Manager contract
 */
interface ITSP_Manager {
    /**
     * @dev Updates user balance when a user makes a prediction (deduct)
     * @param _user Address of the user
     * @param _token Address of the token
     * @param _amount Amount to deduct
     */
    function updateUserBalanceForPrediction(address _user, address _token, uint256 _amount) external;

    /**
     * @dev Updates user balance when a user wins or receives a refund (add)
     * @param _user Address of the user
     * @param _token Address of the token
     * @param _amount Amount to add
     */
    function updateUserBalanceForReward(address _user, address _token, uint256 _amount) external;

    // /**
    //  * @dev Updates user balance when a market owner withdraws fees
    //  * @param _user Address of the market owner
    //  * @param _token Address of the token
    //  * @param _amount Amount to add
    //  */
    // function updateUserBalanceForFeeReward(address _user, address _token, uint256 _amount) external;

    /**
     * @dev Processes expiry creation fee payment (called by TSP_Market)
     * @param _creator Address of the expiry creator
     * @param _expiry Address of the created expiry
     */
    function processExpiryCreationFee(address _creator, address _expiry) external payable;

    /**
     * @dev Processes TSP owner fee when market owner withdraws fees
     * @param _marketOwner Address of the market owner
     * @param _token Address of the token
     * @param _totalAmount Total amount being withdrawn
     * @return marketOwnerAmount Amount that goes to market owner after TSP owner fee
     */
    function processTspOwnerFee(
        address _marketOwner,
        address _token,
        uint256 _totalAmount
    ) external returns (uint256 marketOwnerAmount);

    /**
     * @dev Migrates carry pool to next TSP_Manager version (called by TSP_Market)
     * @param _sourceMarket Address of the source market (caller)
     * @param _destinationMarket Address of the destination market in next version
     * @param _token Address of the token
     * @param _carryAmount Amount of carry to migrate
     * @return success Whether the migration was successful
     */
    function migrateCarryToNextVersion(
        address _sourceMarket,
        address _destinationMarket,
        address _token,
        uint256 _carryAmount
    ) external returns (bool success);

    /**
     * @dev Registers a market verification request (called by TSP_Market)
     * @param _market Address of the market
     * @param _status New verification status (only PENDING allowed from market)
     */
    function setMarketVerificationStatus(
        address _market,
        MarketVerificationStatus _status
    ) external;

    /**
     * @dev Returns whether a token is supported
     * @param _token Address of the token
     * @return Whether the token is supported
     */
    function supportedTokens(address _token) external view returns (bool);

    /**
     * @dev Returns whether a TSP_Market is registered
     * @param _tspMarket Address of the TSP_Market
     * @return Whether the TSP_Market is registered
     */
    function registeredTSPMarkets(address _tspMarket) external view returns (bool);

    /**
     * @dev Returns the current OracleData_Manager address
     * @return The OracleData_Manager address
     */
    function oracleDataManager() external view returns (address);

    /**
     * @dev Returns fee information
     * @return marketFees Current market creation fee
     * @return expiryFees Current expiry creation fee
     * @return totalMarketFees Total market fees collected
     * @return totalExpiryFees Total expiry fees collected
     */
    function getFeeInfo() external view returns (
        uint256 marketFees,
        uint256 expiryFees,
        uint256 totalMarketFees,
        uint256 totalExpiryFees
    );

    /**
     * @dev Returns whether an address is exempt from creation fees
     * @param _address Address to check
     * @return Whether the address is fee-exempt
     */
    function isFeeExempt(address _address) external view returns (bool);

    /**
     * @dev Returns the current TSP owner fee percentage
     * @return The TSP owner fee percentage in basis points
     */
    function getTspOwnerFee() external view returns (uint256);

    /**
     * @dev Returns the next version TSP_Manager address
     * @return The next version address (address(0) if not set)
     */
    function getTSPManagerNextVersion() external view returns (address);

    /**
     * @dev Returns market verification status by querying the market directly
     * @param _market Address of the market
     * @return The verification status from the market contract
     */
    function getMarketVerificationStatus(address _market) external view returns (MarketVerificationStatus);

    /**
     * @dev Returns all pending verification requests
     * @return Array of market addresses with pending requests
     */
    function getAllPendingVerificationRequests() external view returns (address[] memory);

    /**
     * @dev Returns the number of pending verification requests
     * @return Number of pending requests
     */
    function getPendingVerificationRequestsCount() external view returns (uint256);

    /**
     * @dev Returns timestamp for a specific verification request
     * @param _market Market address
     * @return Timestamp when request was made (0 if no request)
     */
    function getVerificationRequestTimestamp(address _market) external view returns (uint256);

    /**
     * @dev Returns whether a market has a pending verification request
     * @param _market Address of the market
     * @return Whether there is a pending verification request
     */
    function hasPendingVerificationRequest(address _market) external view returns (bool);

    /**
     * @dev Returns comprehensive verification information for a market
     * @param _market Address of the market
     * @return status Verification status
     * @return hasPendingRequest Whether there is a pending request
     * @return requestTimestamp Timestamp when request was made (0 if no request)
     * @return marketOwner Owner of the market
     * @return marketName Name of the market
     */
    function getMarketVerificationInfo(address _market) external view returns (
        MarketVerificationStatus status,
        bool hasPendingRequest,
        uint256 requestTimestamp,
        address marketOwner,
        string memory marketName
    );

    /**
     * @dev Returns verification statistics across all markets
     * @return totalMarkets Total number of registered markets
     * @return notVerifiedCount Number of not-verified markets
     * @return pendingCount Number of pending verification requests
     * @return verifiedCount Number of verified markets
     * @return rejectedCount Number of rejected markets
     */
    function getVerificationStats() external view returns (
        uint256 totalMarkets,
        uint256 notVerifiedCount,
        uint256 pendingCount,
        uint256 verifiedCount,
        uint256 rejectedCount
    );

    /**
     * @dev Approves a market verification request (only TSP_Manager owner)
     * @param _market Address of the market to approve
     */
    function approveMarketVerification(address _market) external;

    /**
     * @dev Rejects a market verification request (only TSP_Manager owner)
     * @param _market Address of the market to reject
     */
    function rejectMarketVerification(address _market) external;

    /**
     * @dev Returns the maximum oracle requester reward constant
     * @return Maximum oracle requester reward in basis points
     */
    function MAX_ORACLE_REQUESTER_REWARD() external pure returns (uint256);

    /**
     * @dev Returns the maximum resolve caller reward constant
     * @return Maximum resolve caller reward in basis points
     */
    function MAX_RESOLVE_CALLER_REWARD() external pure returns (uint256);
}

// =============================================================================
// ITSP_MARKET INTERFACE
// =============================================================================

/**
 * @title ITSP_Market
 * @dev Interface for TSP_Market contract
 */
interface ITSP_Market {
    /**
     * @dev Enum for time-series type
     */
    enum TSType { NORMAL, LOGNORMAL }

    /**
     * @dev Struct for TSP_Market initialization parameters
     * oracleDataManager is captured at creation time from TSP_Manager - immutable per market.
     * resolvedValueProvider is derived automatically from IOracleCaller.oracleName().
     */
    struct TSPMarketInitParams {
        bytes oracleData;              // Encoded TSPOracleData stored in market
        address oracleDataManager;     // ODM address captured at creation - never follows TSP_Manager changes
        uint8 tsType;
        address tsToken;
        uint256 minStake;
        uint256 multiplier;
        uint256 timeCost;
        uint256 alpha;
        int256 tsMin;
        int256 tsMax;
        uint256 forecastingPeriod;
        uint256 observationPeriod;
        uint256 resolutionPeriod;
        uint256 sigma;
        uint256 carryNoticePeriod;
        uint256 taxFee;
        uint256 creationFeesPaid;
        string resolvedValueProvider;  // Derived from IOracleCaller.oracleName() at market creation
        string unitSymbol;
        bool isDated;
        address owner;
        address tspManager;
        address tspExpiryImplementation;
        string marketName;
        string marketDescription;
        uint256 oracleRequesterReward;
        uint256 resolveCallerReward;
        uint256 maxUpdatePenalty;
        uint256 defaultUpdatePenalty;
    }

    /**
     * @dev Initializes the market contract
     * @param params Initialization parameters
     */
    function initialize(TSPMarketInitParams calldata params) external;

    /**
     * @dev Called by an expiry when it is resolved
     * @param _feeAmount Fee amount to add to fee pool
     */
    function onExpiryResolved(uint256 _feeAmount) external;

    /**
     * @dev Called by an expiry when it is cancelled
     * @param _carriedAmount Carried amount to add to carry pool
     */
    function onExpiryCancelled(uint256 _carriedAmount) external;

    /**
     * @dev Called by an expiry when it fails (no predictions)
     * @param _carriedAmount Carried amount to add to carry pool
     */
    function onExpiryFailed(uint256 _carriedAmount) external;

    /**
     * @dev Called by an expiry when there are no winners
     * @param _amount Amount to add to carry pool
     */
    function addToCarryPool(uint256 _amount) external;

    /**
     * @dev Receives carry transfer from another market
     * @param _amount Amount being transferred
     * @param _fromMarket Address of the source market
     */
    function receiveCarryTransfer(uint256 _amount, address _fromMarket) external;

    /**
     * @dev Returns true if the expiry is pending
     * @param expiry Address of the expiry
     */
    function isPendingExpiry(address expiry) external view returns (bool);

    /**
     * @dev Returns true if the expiry is closed
     * @param expiry Address of the expiry
     */
    function isClosedExpiry(address expiry) external view returns (bool);

    /**
     * @dev Returns the encoded oracle data stored in this market
     * @return Oracle data as raw bytes (TSPOracleData abi-encoded)
     */
    function oracleData() external view returns (bytes memory);

    /**
     * @dev Returns the OracleData_Manager address used by this market
     * Immutable - baked at creation time, never follows TSP_Manager ODM changes.
     * @return The OracleData_Manager address
     */
    function oracleDataManager() external view returns (address);

    /**
     * @dev Returns market verification status (stored locally in market)
     * @return The verification status
     */
    function marketVerified() external view returns (MarketVerificationStatus);

    /**
     * @dev Returns whether market accepts carry transfers
     * @return Whether the market accepts carry transfers
     */
    function acceptCarryTransfer() external view returns (bool);

    /**
     * @dev Updates verification status (called by TSP_Manager only)
     * @param _status New verification status (VERIFIED or REJECTED)
     */
    function updateVerificationStatus(MarketVerificationStatus _status) external;

    /**
     * @dev Returns the market owner address
     */
    function owner() external view returns (address);

    /**
     * @dev Returns the market name
     */
    function marketName() external view returns (string memory);

    /**
     * @dev Returns the market description
     */
    function marketDescription() external view returns (string memory);

    /**
     * @dev Requests verification from TSP_Manager (only market owner)
     */
    function requestVerification() external;
}

// =============================================================================
// ITSP_EXPIRY INTERFACE
// =============================================================================

/**
 * @title ITSP_Expiry
 * @dev Interface for TSP_Expiry contract
 */
interface ITSP_Expiry {
    /**
     * @dev Enum for expiry status
     */
    enum Status { PENDING, FAILED, RESOLVED, CANCELLED }

    /**
     * @dev Enum for expiry lifecycle stage
     */
    enum Stage { NOT_STARTED, FORECASTING, OBSERVING, RESOLVING, CANCELLING, CLOSING, CLOSED }

    /**
     * @dev Struct for TSP_Expiry initialization parameters
     * resolvedValueProvider is inherited from TSP_Market (which derives it from IOracleCaller.oracleName())
     */
    struct TSPExpiryInitParams {
        uint256 expiryTime;
        uint256 minStake;
        uint256 multiplier;
        int256 tsMin;
        int256 tsMax;
        uint256 sigma;
        uint256 taxFee;
        uint256 timeCost;
        uint256 alpha;
        uint256 observationPeriod;
        uint256 resolutionPeriod;
        uint256 startTime;
        uint256 timeoutTime;
        uint256 carriedAmount;
        uint256 creationFeesPaid;
        string resolvedValueProvider;  // Inherited from market - derived from IOracleCaller.oracleName()
        string unitSymbol;             // Unit symbol inherited from market
        bool isDated;                  // Whether the expiry is dated (inherited from market, not updatable)
        address owner;
        address tspMarket;
        address tspManager;
        address tsToken;
        uint8 tsType;
        uint256 oracleRequesterReward;
        uint256 resolveCallerReward; // Basis points paid to whoever calls resolve()
        uint256 updatePenalty;
        string[] expiryArgs;
        string expiryName;
    }

    /**
     * @dev Initializes the expiry contract
     * @param params Initialization parameters
     */
    function initialize(TSPExpiryInitParams calldata params) external;

    /**
     * @dev Makes a prediction
     * @param _predictedValue Predicted value
     * @param _stakedAmount Staked amount
     */
    function predict(int256 _predictedValue, uint256 _stakedAmount) external;

    /**
     * @dev Allows forecaster to decrease their staked amount with penalty
     * @param _predictionIndex Index of prediction in predictionBook array
     * @param _decreaseAmount Amount to decrease from stake (ignored if _withdrawAll is true)
     * @param _withdrawAll If true, withdraws entire staked amount
     */
    function updatePrediction(
        uint256 _predictionIndex,
        uint256 _decreaseAmount,
        bool _withdrawAll
    ) external;

    /**
     * @dev Resolves the expiry
     */
    function resolve() external;

    /**
     * @dev Claims reward for a winning prediction (called by forecaster after resolve)
     * @param _predictionIndex Index of the prediction in predictionBook
     */
    function claimReward(uint256 _predictionIndex) external;

    /**
     * @dev Requests resolved value from OracleData_Manager
     * Anyone can call this to trigger the oracle request for this expiry.
     * Payable to cover cross-chain fees (e.g. Hyperlane) if required by the OracleCaller.
     */
    function requestResolvedValue() external payable;

    /**
     * @dev Cancels the expiry
     */
    function cancel() external;

    /**
     * @dev Withdraws a forecaster's stake after cancellation (pull model)
     * @param _predictionIndex Index of the prediction in predictionBook
     */
    function withdrawStake(uint256 _predictionIndex) external;

    /**
     * @dev Closes the expiry if no predictions were made
     */
    function close() external;

    /**
     * @dev Cancels a pending oracle request
     */
    function cancelOracleRequest() external;

    /**
     * @dev Clears oracle requester when OracleCaller reports a failure
     * Callable only by OracleData_Manager
     */
    function notifyOracleCallerRequestFailed() external;

    /**
     * @dev Returns the current lifecycle stage of the expiry
     */
    function getStage() external view returns (Stage);

    /**
     * @dev Returns whether the expiry is dated
     */
    function isDated() external view returns (bool);

    /**
     * @dev Returns the expiry time
     */
    function expiryTime() external view returns (uint256);

    /**
     * @dev Returns a specific expiry-specific oracle argument by index
     * @param index Index in the expiryArgs array
     */
    function expiryArgs(uint256 index) external view returns (string memory);

    /**
     * @dev Returns the length of the expiryArgs array
     */
    function getExpiryArgsLength() external view returns (uint256);

    /**
     * @dev Returns the parent TSP_Market address
     */
    function tspMarket() external view returns (address);
}