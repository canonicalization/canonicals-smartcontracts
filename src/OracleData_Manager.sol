// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces.sol";

// =============================================================================
// TSPOracleData STRUCT
// =============================================================================
// Defined here (not in interfaces.sol) so it can evolve with OracleData_Manager
// upgrades without affecting the shared interface file.
// When TSP_Manager.setOracleDataManager() points to a new ODM version,
// that new version can introduce an updated TSPOracleData struct.
// TSP_Market and TSP_Expiry are insulated - they store/pass oracleData as raw bytes.

/**
 * @title TSPOracleData
 * @dev Struct for TSP Oracle Data
 *
 * Common fields are shared by all OracleCallers.
 * oracleCallerAddress identifies which registered IOracleCaller to use.
 * callerParams is opaque bytes decoded only by the specified OracleCaller
 * (e.g. abi.encode(ChainlinkCallerParams{...})). OracleData_Manager never
 * inspects callerParams - it passes it through to the caller as-is.
 *
 * If oracleCallerAddress is address(0), OracleData_Manager uses
 * defaultOracleCallerAddress.
 */
struct TSPOracleData {
    // --- Common fields (all OracleCallers) ---
    string   sourceCode;           // Query/script/identifier for the data source
    string[] args;                 // Generic string arguments
    bytes[]  bytesArgs;            // Generic bytes arguments
    uint256  scale;                // Scale factor for the oracle (e.g. 1e18)

    // --- Caller routing ---
    address  oracleCallerAddress;  // Address of the IOracleCaller to use.
                                   // address(0) → use defaultOracleCallerAddress

    // --- Caller-specific params (opaque - decoded by OracleCaller only) ---
    bytes    callerParams;         // abi.encode(CallerParams{...}) specific to the caller
}

// =============================================================================
// IOracleCaller INTERFACE
// =============================================================================
// Defined here alongside TSPOracleData because requestData() takes TSPOracleData
// as a parameter. Putting it in interfaces.sol would create a circular import.
// All OracleCaller implementations import {TSPOracleData, IOracleCaller} from
// this file.

/**
 * @title IOracleCaller
 * @dev Interface that every OracleCaller implementation must satisfy.
 *
 * Each OracleCaller is an independent contract registered in OracleData_Manager
 * by its contract address. It defines its own:
 *   - CallerParams struct (internal, decoded from TSPOracleData.callerParams)
 *   - REQUEST_TIMEOUT constant
 *   - encodeCallerParams() helper for deployment scripts and frontends
 *
 * All callers report results back via ODM._setResolvedValue().
 */
interface IOracleCaller {

    // -------------------------------------------------------------------------
    // Metadata
    // -------------------------------------------------------------------------

    /**
     * @dev Human-readable name of the oracle source
     * e.g. "Chainlink Functions Local", "Chainlink Functions Remote", "API3 Airnode"
     */
    function oracleName() external view returns (string memory);

    /**
     * @dev Link to the oracle's off-chain documentation or explorer
     * e.g. "https://functions.chain.link", "https://api3.org/explorer"
     */
    function oracleOffchainLink() external view returns (string memory);

    // -------------------------------------------------------------------------
    // Timing
    // -------------------------------------------------------------------------

    /**
     * @dev Maximum duration to wait for a response before cancellation is allowed.
     * Defined per caller - local callers are faster than cross-chain callers.
     * Exposed on the interface so OracleData_Manager and frontends can query it
     * without hardcoding any timing assumptions.
     */
    function REQUEST_TIMEOUT() external view returns (uint256);

    // -------------------------------------------------------------------------
    // Core operations
    // -------------------------------------------------------------------------

    /**
     * @dev Initiates the oracle data fetch for a specific expiry.
     * Called by OracleData_Manager.requestResolvedValue() only.
     * On success, the caller must call back ODM._setResolvedValue().
     * @param _market Address of the TSP_Market
     * @param _expiry Address of the TSP_Expiry
     * @param _oracleData Full TSPOracleData struct (callerParams decoded internally)
     * @param _requester Original user address who initiated the request in TSP_Expiry.
     *        Passed explicitly so OracleCallers can attribute fees and record paidFees.
     *        msg.sender at this level is ODM, not the original user.
     */
    function requestData(
        address _market,
        address _expiry,
        TSPOracleData calldata _oracleData,
        address _requester
    ) external payable;

    /**
     * @dev Cancels a pending oracle request for a specific expiry.
     * Called by OracleData_Manager.cancelRequest() only.
     * @param _expiry Address of the TSP_Expiry
     * @param checkTimeout Whether to enforce timeout check before cancelling
     *        true  = user cancellation: requires PENDING state and timeout elapsed
     *        false = system cancellation: cancels regardless of state (e.g. ODM reset)
     */
    function cancelRequest(address _expiry, bool checkTimeout) external;

    // -------------------------------------------------------------------------
    // State inspection
    // -------------------------------------------------------------------------

    /**
     * @dev Returns whether a pending request exists for the given expiry
     * @param _expiry Address of the TSP_Expiry
     */
    function hasRequest(address _expiry) external view returns (bool);

    /**
     * @dev Returns the current state of the oracle request for the given expiry
     * @param _expiry Address of the TSP_Expiry
     * @return RequestState enum value (PENDING, COMPLETED, FAILED)
     */
    function getRequestState(address _expiry) external view returns (RequestState);

    // -------------------------------------------------------------------------
    // Anti-spam fee getters
    // All OracleCaller implementations must expose their current fee thresholds.
    // -------------------------------------------------------------------------

    /**
     * @dev Returns the fee in wei required to call requestData for a VERIFIED market.
     * Verified markets have lower fees - their JS source and API are tested and stable.
     */
    function verifiedMarketFee() external view returns (uint256);

    /**
     * @dev Returns the fee in wei required to call requestData for a non-verified market.
     * Higher than verifiedMarketFee - reflects increased spam and failure risk.
     */
    function unverifiedMarketFee() external view returns (uint256);

    // -------------------------------------------------------------------------
    // Params encoding helper
    // -------------------------------------------------------------------------

    /**
     * @dev Encodes a caller-specific CallerParams struct into bytes suitable for
     * TSPOracleData.callerParams. Used by deployment scripts and frontends at
     * market creation time.
     * Each caller defines its own CallerParams struct internally and knows how
     * to encode/decode it. The raw bytes input here is the ABI-encoded struct.
     * @param _rawParams ABI-encoded CallerParams struct
     * @return Encoded bytes ready to be stored in TSPOracleData.callerParams
     */
    function encodeCallerParams(bytes calldata _rawParams) external pure returns (bytes memory);
}

// =============================================================================
// OracleData_Manager CONTRACT
// =============================================================================

/**
 * @title OracleData_Manager
 * @dev Central hub for oracle data routing and resolved value storage.
 *
 * Maintains a registry of IOracleCaller implementations (identified by their
 * contract address). At market creation time TSP_Manager validates the chosen
 * caller is registered and active. At resolution time TSP_Expiry calls
 * requestResolvedValue() which routes to the correct IOracleCaller.
 *
 * Key invariants:
 * - oracleCallerAddress is the unique, on-chain verifiable identifier
 * - deactivating a caller blocks new requests but never cancels in-flight ones
 * - _setResolvedValue() accepts calls from registered callers regardless of active state
 * - cancelRequest() resolves the caller from market.oracleData() - no extra mapping
 * - ExpiryValue storage and ResolvedValueRejected logic are unchanged from v1
 *
 * Upgradeable via TSP_Manager.setOracleDataManager().
 * Markets bake the ODM address at creation - they never follow TSP_Manager changes.
 */
contract OracleData_Manager is Ownable, IOracleData_Manager {

    // =========================================================================
    // STRUCTS
    // =========================================================================

    /**
     * @dev Registry entry for a registered OracleCaller
     */
    struct OracleCallerEntry {
        address callerAddress;       // Address of the IOracleCaller contract
        string  oracleName;          // Mirrored from IOracleCaller.oracleName()
        string  oracleOffchainLink;  // Mirrored from IOracleCaller.oracleOffchainLink()
        bool    active;              // Whether new requests can use this caller
        uint256 registeredAt;        // Block timestamp when registered
        uint256 lastStatusChangedAt; // Block timestamp of last activate/deactivate
    }

    /**
     * @dev Storage for a resolved expiry value
     */
    struct ExpiryValue {
        int256  resolvedValue;    // The oracle value
        uint256 timestamp;        // When it was stored in ODM
        uint256 valueTimestamp;   // Timestamp of the value from the oracle source
        bool    isResolved;
    }

    // =========================================================================
    // STATE VARIABLES
    // =========================================================================

    /// @dev TSP_Manager address - immutable after deployment
    address public immutable tspManager;

    /// @dev OracleCaller registry indexed by caller contract address
    mapping(address => OracleCallerEntry) public oracleCallers;

    /// @dev Ordered list of registered caller addresses for enumeration
    address[] public oracleCallerAddresses;

    /// @dev Default caller used when TSPOracleData.oracleCallerAddress is address(0)
    address public defaultOracleCallerAddress;

    /// @dev Supported markets registry
    mapping(address => bool) public supportedMarkets;

    /// @dev Ordered list of supported markets for enumeration
    address[] public supportedMarketsList;

    /// @dev Resolved values indexed by market → expiry
    mapping(address => mapping(address => ExpiryValue)) public resolvedExpiries;

    // =========================================================================
    // EVENTS
    // =========================================================================

    event MarketAdded(address indexed market);
    event ExpiryResolved(
        address indexed market,
        address indexed expiry,
        int256  resolvedValue,
        uint256 timestamp,
        uint256 valueTimestamp
    );
    event RequestInitiated(address indexed market, address indexed expiry, address indexed callerAddress);
    event RequestCancelled(address indexed market, address indexed expiry);
    event OracleRequestFailed(address indexed market, address indexed expiry, string reason);
    event ResolvedValueRejected(
        address indexed market,
        address indexed expiry,
        int256  value,
        uint256 valueTimestamp,
        uint256 expiryTime,
        string  reason
    );

    // OracleCaller registry events
    event OracleCallerRegistered(address indexed callerAddress, string oracleName);
    event OracleCallerActivated(address indexed callerAddress, address indexed byOwner);
    event OracleCallerDeactivated(address indexed callerAddress, address indexed byOwner);
    event DefaultCallerChanged(address indexed oldCallerAddress, address indexed newCallerAddress, address indexed byOwner);

    // =========================================================================
    // MODIFIERS
    // =========================================================================

    modifier onlyTSPManager() {
        require(msg.sender == tspManager, "Caller is not the TSP_Manager");
        _;
    }

    modifier onlyTSPOwner() {
        require(
            msg.sender == Ownable(tspManager).owner(),
            "Caller is not the TSP owner"
        );
        _;
    }

    modifier onlyRegisteredCaller() {
        require(
            oracleCallers[msg.sender].callerAddress != address(0),
            "Caller is not a registered OracleCaller"
        );
        _;
    }

    // =========================================================================
    // CONSTRUCTOR
    // =========================================================================

    /**
     * @dev Deploys OracleData_Manager.
     * @param _tspManager Address of the TSP_Manager
     */
    constructor(address _tspManager) Ownable() {
        require(_tspManager != address(0), "Invalid TSP_Manager address");
        tspManager = _tspManager;
    }

    // =========================================================================
    // ORACLE CALLER REGISTRY - onlyTSPOwner
    // =========================================================================

    /**
     * @dev Registers a new OracleCaller in the registry.
     * Reads oracleName and oracleOffchainLink directly from the caller contract.
     * The caller is active by default upon registration.
     * @param _callerAddress Address of the IOracleCaller contract to register
     */
    function registerCaller(address _callerAddress) external override onlyTSPOwner {
        require(_callerAddress != address(0), "Invalid caller address");
        require(
            oracleCallers[_callerAddress].callerAddress == address(0),
            "Caller already registered"
        );

        // Read metadata directly from the caller contract
        string memory name = IOracleCaller(_callerAddress).oracleName();
        string memory link = IOracleCaller(_callerAddress).oracleOffchainLink();

        oracleCallers[_callerAddress] = OracleCallerEntry({
            callerAddress:       _callerAddress,
            oracleName:          name,
            oracleOffchainLink:  link,
            active:              true,
            registeredAt:        block.timestamp,
            lastStatusChangedAt: block.timestamp
        });

        oracleCallerAddresses.push(_callerAddress);

        emit OracleCallerRegistered(_callerAddress, name);
    }

    /**
     * @dev Activates a previously deactivated OracleCaller.
     * @param _callerAddress Address of the OracleCaller to activate
     */
    function activateCaller(address _callerAddress) external override onlyTSPOwner {
        require(
            oracleCallers[_callerAddress].callerAddress != address(0),
            "Caller not registered"
        );
        require(!oracleCallers[_callerAddress].active, "Caller already active");

        oracleCallers[_callerAddress].active = true;
        oracleCallers[_callerAddress].lastStatusChangedAt = block.timestamp;

        emit OracleCallerActivated(_callerAddress, msg.sender);
    }

    /**
     * @dev Deactivates an OracleCaller without removing it from the registry.
     * New requestResolvedValue() calls using this caller will revert.
     * In-flight requests already forwarded to this caller still complete normally
     * because _setResolvedValue() has no active check.
     * @param _callerAddress Address of the OracleCaller to deactivate
     */
    function deactivateCaller(address _callerAddress) external override onlyTSPOwner {
        require(
            oracleCallers[_callerAddress].callerAddress != address(0),
            "Caller not registered"
        );
        require(oracleCallers[_callerAddress].active, "Caller already inactive");
        require(
            _callerAddress != defaultOracleCallerAddress,
            "Cannot deactivate the default caller - set a new default first"
        );

        oracleCallers[_callerAddress].active = false;
        oracleCallers[_callerAddress].lastStatusChangedAt = block.timestamp;

        emit OracleCallerDeactivated(_callerAddress, msg.sender);
    }

    /**
     * @dev Sets the default OracleCaller used when TSPOracleData.oracleCallerAddress
     * is address(0). Reverts if the target caller is not registered or inactive.
     * @param _callerAddress Address of the OracleCaller to set as default
     */
    function setDefaultOracleCallerAddress(address _callerAddress) external override onlyTSPOwner {
        require(
            oracleCallers[_callerAddress].callerAddress != address(0),
            "Caller not registered"
        );
        require(oracleCallers[_callerAddress].active, "Cannot set an inactive caller as default");

        address old = defaultOracleCallerAddress;
        defaultOracleCallerAddress = _callerAddress;

        emit DefaultCallerChanged(old, _callerAddress, msg.sender);
    }

    /**
     * @dev Returns the registration and activation status of an OracleCaller.
     * Used by TSP_Manager.createMarket() to validate the chosen caller.
     * @param _callerAddress Address of the OracleCaller contract
     * @return registered Whether the caller is registered
     * @return active Whether the caller is currently active
     */
    function getCallerStatus(address _callerAddress)
        external view override
        returns (bool registered, bool active)
    {
        OracleCallerEntry storage entry = oracleCallers[_callerAddress];
        registered = entry.callerAddress != address(0);
        active = registered && entry.active;
    }

    /**
     * @dev Returns the number of registered OracleCallers
     */
    function getOracleCallersCount() external view returns (uint256) {
        return oracleCallerAddresses.length;
    }

    // =========================================================================
    // MARKET REGISTRATION
    // =========================================================================

    /**
     * @dev Registers a new TSP_Market as supported.
     * Called by TSP_Manager at market creation time.
     * @param _market Address of the TSP_Market
     */
    function addSupportedMarket(address _market) external override onlyTSPManager {
        require(_market != address(0), "Invalid market address");
        require(!isSupportedMarket(_market), "Market already supported");

        supportedMarkets[_market] = true;
        supportedMarketsList.push(_market);

        emit MarketAdded(_market);
    }

    /**
     * @dev Returns whether a market is registered in this ODM instance
     * @param _market Address of the TSP_Market
     */
    function isSupportedMarket(address _market) public view override returns (bool) {
        return supportedMarkets[_market];
    }

    /**
     * @dev Returns the total number of supported markets
     */
    function getSupportedMarketsCount() external view returns (uint256) {
        return supportedMarketsList.length;
    }

    // =========================================================================
    // ORACLE REQUEST FLOW
    // =========================================================================

    /**
     * @dev Requests resolved value for a specific expiry. Step 1 of resolution.
     *
     * Called exclusively by TSP_Expiry.requestResolvedValue() (enforced by
     * require msg.sender == _expiry). Resolves the OracleCaller from
     * market.oracleData(), checks it is registered and active, applies
     * expiryArgs override if provided, then delegates to IOracleCaller.requestData().
     *
     * @param _market Address of the TSP_Market
     * @param _expiry Address of the TSP_Expiry (must be msg.sender)
     * @param _expiryArgs Expiry-specific args overriding oracleData.args (empty = use market args)
     * @param _requester Original user address who initiated the request in TSP_Expiry.
     *        Forwarded as-is to IOracleCaller.requestData() for fee attribution.
     */
    function requestResolvedValue(
        address _market,
        address _expiry,
        string[] calldata _expiryArgs,
        address _requester
    ) external payable override {
        require(isSupportedMarket(_market), "Market not supported");
        require(_expiry != address(0), "Invalid expiry address");
        require(msg.sender == _expiry, "Only the expiry can request its own resolved value");
        require(_validateExpiryMarket(_market, _expiry), "Expiry does not belong to the specified market");
        require(_isExpiryInResolvingStage(_expiry), "Expiry must be in RESOLVING stage");
        require(!isExpiryResolved(_market, _expiry), "Expiry already resolved");

        // Load and decode oracle data from the market
        bytes memory rawOracleData = ITSP_Market(_market).oracleData();
        require(rawOracleData.length > 0, "Oracle data cannot be empty");
        TSPOracleData memory oracleDataStruct = abi.decode(rawOracleData, (TSPOracleData));

        // Apply expiryArgs override if provided
        if (_expiryArgs.length > 0) {
            oracleDataStruct.args = _expiryArgs;
        }

        // Resolve which caller to use
        address callerAddr = oracleDataStruct.oracleCallerAddress != address(0)
            ? oracleDataStruct.oracleCallerAddress
            : defaultOracleCallerAddress;

        require(callerAddr != address(0), "No OracleCaller configured");

        OracleCallerEntry storage entry = oracleCallers[callerAddr];
        require(entry.callerAddress != address(0), "OracleCaller not registered");
        require(entry.active, "OracleCaller is deactivated");

        // Delegate to the OracleCaller - passes ETH for fees and forwards requester
        IOracleCaller(callerAddr).requestData{value: msg.value}(_market, _expiry, oracleDataStruct, _requester);

        emit RequestInitiated(_market, _expiry, callerAddr);
    }

    /**
     * @dev Checks whether the resolved value is ready for an expiry. Step 3 of resolution.
     * Called by TSP_Expiry before reading the value. Reverts if not yet resolved.
     * @param _market Address of the TSP_Market
     * @param _expiry Address of the TSP_Expiry (must be msg.sender)
     */
    function resolveExpiryValue(address _market, address _expiry) external view override {
        require(isSupportedMarket(_market), "Market not supported");
        require(_expiry != address(0), "Invalid expiry address");
        require(msg.sender == _expiry, "Only the expiry can resolve its own value");
        require(_validateExpiryMarket(_market, _expiry), "Expiry does not belong to the specified market");

        if (!isExpiryResolved(_market, _expiry)) {
            revert("Value not ready - call requestResolvedValue first");
        }
        // Value is ready - returns successfully. Expiry will call getResolvedValue next.
    }

    /**
     * @dev Cancels a pending oracle request for a specific expiry.
     * Called by TSP_Expiry.cancelOracleRequest().
     * Reads oracleCallerAddress from market.oracleData() to route to the correct caller.
     * No pendingRequestCaller mapping needed - the market is the single source of truth.
     * @param _market Address of the TSP_Market
     * @param _expiry Address of the TSP_Expiry (must be msg.sender)
     * @param checkTimeout Whether to enforce timeout check before cancelling
     */
    function cancelRequest(
        address _market,
        address _expiry,
        bool checkTimeout
    ) external override {
        require(isSupportedMarket(_market), "Market not supported");
        require(_expiry != address(0), "Invalid expiry address");
        require(msg.sender == _expiry, "Only the expiry can cancel its own request");
        require(_validateExpiryMarket(_market, _expiry), "Expiry does not belong to the specified market");

        // Resolve the caller from market.oracleData()
        bytes memory rawOracleData = ITSP_Market(_market).oracleData();
        TSPOracleData memory oracleDataStruct = abi.decode(rawOracleData, (TSPOracleData));

        address callerAddr = oracleDataStruct.oracleCallerAddress != address(0)
            ? oracleDataStruct.oracleCallerAddress
            : defaultOracleCallerAddress;

        require(callerAddr != address(0), "No OracleCaller configured");
        require(oracleCallers[callerAddr].callerAddress != address(0), "OracleCaller not registered");

        // Forward cancellation - no active check needed here
        IOracleCaller(callerAddr).cancelRequest(_expiry, checkTimeout);

        emit RequestCancelled(_market, _expiry);
    }

    /**
     * @dev Notifies ODM that an oracle request failed.
     * Called by a registered OracleCaller so ODM can clear the expiry state.
     */
    function notifyRequestFailed(
        address _market,
        address _expiry,
        string calldata reason
    ) external override onlyRegisteredCaller {
        require(isSupportedMarket(_market), "Market not supported");
        require(_expiry != address(0), "Invalid expiry address");
        require(_validateExpiryMarket(_market, _expiry), "Expiry does not belong to the specified market");

        // Clear the oracle requester on the expiry so it can be retried
        try ITSP_Expiry(_expiry).notifyOracleCallerRequestFailed() {
            // Successfully cleared
        } catch {
            // If clearing fails, continue without reverting
            // so the system does not get stuck
        }

        emit OracleRequestFailed(_market, _expiry, reason);
    }

    /**
     * @dev Stores the resolved value for an expiry.
     * Called back by a registered IOracleCaller after it receives the oracle value.
     *
     * Security: only registered callers can call this (onlyRegisteredCaller modifier).
     * No active check - a caller deactivated after a request was sent must still be
     * able to deliver its result. Blocking it would freeze the expiry permanently.
     *
     * For dated expiries: validates that valueTimestamp > expiryTime.
     * If validation fails: emits ResolvedValueRejected and cancels the oracle request
     * so the expiry can retry with a fresh requestResolvedValue() call.
     *
     * @param _market Address of the TSP_Market
     * @param _expiry Address of the TSP_Expiry
     * @param _value The resolved value from the oracle source
     * @param _valueTimestamp Timestamp of the value at the oracle source
     */
    function _setResolvedValue(
        address _market,
        address _expiry,
        int256  _value,
        uint256 _valueTimestamp
    ) external override onlyRegisteredCaller {

        // Dated expiry: validate the value timestamp is after expiry time
        bool isDated = ITSP_Expiry(_expiry).isDated();
        if (isDated) {
            uint256 expiryTime = ITSP_Expiry(_expiry).expiryTime();

            if (_valueTimestamp <= expiryTime) {
                emit ResolvedValueRejected(
                    _market, _expiry, _value, _valueTimestamp, expiryTime,
                    "Value timestamp must be greater than expiry time"
                );

                // Cancel the oracle request so the expiry can retry
                try ITSP_Expiry(_expiry).cancelOracleRequest() {
                    // Successfully cancelled
                } catch {
                    // If cancellation fails, continue without reverting
                    // so the system does not get stuck
                }

                return;
            }
        }

        // Store the resolved value
        resolvedExpiries[_market][_expiry] = ExpiryValue({
            resolvedValue:  _value,
            timestamp:      block.timestamp,
            valueTimestamp: _valueTimestamp,
            isResolved:     true
        });

        emit ExpiryResolved(_market, _expiry, _value, block.timestamp, _valueTimestamp);
    }

    // =========================================================================
    // RESOLVED VALUE QUERIES
    // =========================================================================

    /**
     * @dev Returns whether an expiry has been resolved
     */
    function isExpiryResolved(address _market, address _expiry)
        public view override returns (bool)
    {
        require(isSupportedMarket(_market), "Market not supported");
        return resolvedExpiries[_market][_expiry].isResolved;
    }

    /**
     * @dev Returns the resolved value and storage timestamp
     */
    function getResolvedValue(address _market, address _expiry)
        external view override returns (int256, uint256)
    {
        require(isSupportedMarket(_market), "Market not supported");
        require(isExpiryResolved(_market, _expiry), "Expiry not resolved");

        ExpiryValue storage v = resolvedExpiries[_market][_expiry];
        return (v.resolvedValue, v.timestamp);
    }

    /**
     * @dev Returns the resolved value with both timestamps
     */
    function getResolvedValueWithTimestamps(address _market, address _expiry)
        external view override
        returns (int256 resolvedValue, uint256 timestamp, uint256 valueTimestamp)
    {
        require(isSupportedMarket(_market), "Market not supported");
        require(isExpiryResolved(_market, _expiry), "Expiry not resolved");

        ExpiryValue storage v = resolvedExpiries[_market][_expiry];
        return (v.resolvedValue, v.timestamp, v.valueTimestamp);
    }

    // =========================================================================
    // ORACLE DATA HELPERS - common fields only
    // =========================================================================

    /**
     * @dev Returns the source code for a market (common field)
     */
    function getSourceCode(address _market)
        external view override returns (string memory)
    {
        require(isSupportedMarket(_market), "Market not supported");
        TSPOracleData memory data = _decodeOracleData(ITSP_Market(_market).oracleData());
        return data.sourceCode;
    }

    /**
     * @dev Returns the string arguments for a market (common field)
     */
    function getArgs(address _market)
        external view override returns (string[] memory)
    {
        require(isSupportedMarket(_market), "Market not supported");
        TSPOracleData memory data = _decodeOracleData(ITSP_Market(_market).oracleData());
        return data.args;
    }

    /**
     * @dev Returns the scale factor for a market (common field)
     */
    function getScale(address _market)
        external view override returns (uint256)
    {
        require(isSupportedMarket(_market), "Market not supported");
        TSPOracleData memory data = _decodeOracleData(ITSP_Market(_market).oracleData());
        return data.scale;
    }

    /**
     * @dev Extracts scale directly from encoded oracle data bytes
     */
    function extractScaleFromOracleData(bytes calldata _oracleData)
        external pure override returns (uint256)
    {
        TSPOracleData memory data = abi.decode(_oracleData, (TSPOracleData));
        return data.scale;
    }

    /**
     * @dev Validates common fields of oracle data and checks the oracleCallerAddress
     * is registered and active (or that a valid default exists).
     * Does NOT validate callerParams - that is the OracleCaller's responsibility.
     * @param _oracleData Encoded oracle data bytes to validate
     * @return isValid Whether the oracle data passes all common field checks
     */
    function validateOracleData(bytes calldata _oracleData)
        external view override returns (bool)
    {
        try this._tryDecodeOracleData(_oracleData) returns (TSPOracleData memory data) {
            // Validate common fields
            if (bytes(data.sourceCode).length == 0) return false;
            if (data.scale == 0) return false;

            // Resolve which caller would be used
            address callerAddr = data.oracleCallerAddress != address(0)
                ? data.oracleCallerAddress
                : defaultOracleCallerAddress;

            if (callerAddr == address(0)) return false;

            // Check caller is registered and active
            OracleCallerEntry storage entry = oracleCallers[callerAddr];
            if (entry.callerAddress == address(0)) return false;
            if (!entry.active) return false;

            return true;
        } catch {
            return false;
        }
    }

    /**
     * @dev External wrapper used by validateOracleData() via try/catch.
     * The external call allows catching abi.decode failures gracefully.
     */
    function _tryDecodeOracleData(bytes calldata _oracleData)
        external pure returns (TSPOracleData memory)
    {
        return abi.decode(_oracleData, (TSPOracleData));
    }

    // =========================================================================
    // INTERNAL HELPERS
    // =========================================================================

    /**
     * @dev Decodes raw oracle data bytes into TSPOracleData.
     * Internal helper - common fields only. callerParams is returned as opaque bytes.
     * Changed from external to internal (no longer needed outside this contract).
     */
    function _decodeOracleData(bytes memory _oracleData)
        internal pure returns (TSPOracleData memory)
    {
        return abi.decode(_oracleData, (TSPOracleData));
    }

    /**
     * @dev Validates that an expiry belongs to the specified market.
     * Two-level check: market registered in TSP_Manager + expiry registered in market.
     */
    function _validateExpiryMarket(address _market, address _expiry)
        private view returns (bool)
    {
        if (!ITSP_Manager(tspManager).registeredTSPMarkets(_market)) {
            return false;
        }

        try ITSP_Expiry(_expiry).tspMarket() returns (address claimedMarket) {
            return claimedMarket == _market &&
                (ITSP_Market(_market).isPendingExpiry(_expiry) ||
                 ITSP_Market(_market).isClosedExpiry(_expiry));
        } catch {
            return false;
        }
    }

    /**
     * @dev Returns whether the expiry is currently in the RESOLVING stage.
     */
    function _isExpiryInResolvingStage(address _expiry) private view returns (bool) {
        try ITSP_Expiry(_expiry).getStage() returns (ITSP_Expiry.Stage stage) {
            return stage == ITSP_Expiry.Stage.RESOLVING;
        } catch {
            return false;
        }
    }
}
