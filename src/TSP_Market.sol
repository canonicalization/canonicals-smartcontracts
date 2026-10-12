// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "./interfaces.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title TSP_Market
 * @dev Contract that represents a prediction market for a specific time-series data.
 * Updated with optimized verification system, carry transfer system, expiry creation fee support,
 * creation fees storage, resolvedValueProvider, unitSymbol, fee exemption support, TSP owner fee,
 * forecastingPeriod for expiries, and carry migration to next TSP_Manager version.
 *
 * Oracle architecture changes:
 * - resolvedValueProvider is still stored here and passed to each expiry, but is now derived
 *   automatically by TSP_Manager from IOracleCaller.oracleName() at market creation time.
 *   Market creators no longer supply it manually.
 * - getDecodedOracleData() removed - it returned Chainlink-specific fields (subscriptionId,
 *   donId) that no longer exist in TSPOracleData. Common fields (sourceCode, args, scale)
 *   remain accessible via IOracleData_Manager.getSourceCode/getArgs/getScale().
 * - oracleData bytes and oracleDataManager address are unchanged - immutable per market.
 */
contract TSP_Market is ITSP_Market, ReentrancyGuard{
    using Clones for address;

    // TSP Market  Owner Max Tax Fee Constants
    uint256 public constant MAX_MARKET_OWNER_TAX_FEE = 1000;      // Maximum 10%  // value basis points (e.g., "1000 = 10.00%")


    // Market verification status - now stored only in market (no central tracking)
    MarketVerificationStatus public override marketVerified;

    // Market active status - initialized to true, can only be set to false once
    bool public isActive;

    // Accept carry transfer flag
    bool public override acceptCarryTransfer;

    // TSP_Manager address
    address public tspManager;
    
    // OracleData_Manager address (stored at creation time)
    address public oracleDataManager;
    
    // Market name
    string public marketName;

    // Market description
    string public marketDescription;
    
    // Oracle data stored in this market
    bytes public oracleData;
    
    // isDated flag - set once at creation, not updatable
    bool public isDated;

    // Creation fee paid for this market
    uint256 public creationFeesPaid;
    
    // Resolved value provider - stored at creation, derived by TSP_Manager from IOracleCaller.oracleName()
    // Passed to each expiry for display purposes. Not editable after creation.
    string public resolvedValueProvider;
    
    // Unit symbol for the market (e.g., "USD", "ETH", "BTC")
    string public unitSymbol;
    
    // Time-series type
    TSType public tsType;
    
    // Token used for the prediction market
    address public tsToken;
    
    // Minimum stake amount
    uint256 public minStake;
    
    // Multiplier for prediction market
    uint256 public multiplier;
    
    // Time cost rate
    uint256 public timeCost;
    
    // Alpha adjustment factor
    uint256 public alpha;

    // Maximum update penalty that can be set for any expiry (set once at market creation, in basis points)
    uint256 public maxUpdatePenalty;

    // Default update penalty used when expiry creator sets 0 (set once at market creation, in basis points)
    uint256 public defaultUpdatePenalty;
    
    // Min and max values for the time-series
    int256 public tsMin;
    int256 public tsMax;
    
    // Time periods
    uint256 public forecastingPeriod;
    uint256 public observationPeriod;
    uint256 public resolutionPeriod;
    
    // Standard deviation
    uint256 public sigma;
    
    // Carry notice period (NOT EDITABLE after creation)
    uint256 public carryNoticePeriod;
    
    // Tax fee percentage : value basis points (e.g., "500 = 5.00%")
    uint256 public taxFee;

    // Oracle requester reward percentage
    uint256 public oracleRequesterReward;

    // Resolve caller reward percentage (market default, overridable per expiry)
    uint256 public resolveCallerReward;
    
    // Carry pool amount
    uint256 public carryPool;
    
    // Fee pool amount
    uint256 public feePool;
    
    // TSP_Expiry implementation address
    address public tspExpiryImplementation;
    
    // Owner of the contract
    address public owner;

    // Arrays for expiries
    address[] public pendingExpiries;
    address[] public closedExpiries;
    
    // Mapping to check if an expiry is in pending state
    mapping(address => bool) public override isPendingExpiry;
    
    // Mapping to check if an expiry is in closed state
    mapping(address => bool) public override isClosedExpiry;

    // Events
    event ExpiryAdded(address indexed expiry, uint256 expiryTime, uint256 feesPaid);
    event ExpiryResolved(address indexed expiry, uint256 resolvedTime);
    event ExpiryCancelled(address indexed expiry, uint256 carriedAmount, uint256 cancelledTime);
    event ExpiryFailed(address indexed expiry, uint256 failedTime, uint256 carriedAmount);
    event FeesWithdrawn(uint256 totalAmount, uint256 marketOwnerAmount, uint256 tspOwnerAmount);
    event ParametersUpdated();
    event CarryPoolFunded(uint256 amount);
    event ExpiryResolutionRequest(address indexed expiry);
    
    // OPTIMIZED: Simplified verification events
    event VerificationRequested(address indexed market, address indexed owner);
    event VerificationStatusUpdated(address indexed market, MarketVerificationStatus indexed status);
    
    // Carry transfer events
    event AcceptCarryTransferUpdated(bool acceptCarryTransfer);
    event CarryTransferred(address indexed fromMarket, address indexed toMarket, uint256 amount);
    event CarryReceived(address indexed fromMarket, uint256 amount);

    // NEW: Carry migration events
    event CarryMigrationInitiated(address indexed destinationMarket, address indexed nextTspManager, address token, uint256 amount);
    event CarryMigrationCompleted(address indexed destinationMarket, address indexed nextTspManager, address token, uint256 amount);
    event CarryMigrationFailed(address indexed destinationMarket, address indexed nextTspManager, address token, uint256 amount, string reason);

    // Event emitted when market is closed
    event MarketClosed(address indexed owner, uint256 timestamp);

    // Modifier to ensure caller is owner
    modifier onlyOwner() {
        require(msg.sender == owner, "Caller is not the owner");
        _;
    }

    // Modifier to ensure caller is TSP_Manager
    modifier onlyManager() {
        require(msg.sender == tspManager, "Caller is not the manager");
        _;
    }

    // Modifier to ensure caller is a pending expiry
    modifier onlyPendingExpiry() {
        require(isPendingExpiry[msg.sender], "Caller is not a pending expiry");
        _;
    }

    // Modifier to ensure caller is a registered market (for carry transfers)
    modifier onlyRegisteredMarket() {
        require(ITSP_Manager(tspManager).registeredTSPMarkets(msg.sender), "Caller is not a registered market");
        _;
    }

    // Modifier to ensure market is active
    modifier onlyActiveMarket() {
        require(isActive, "Market is not active");
        _;
    }

    // Struct for TSP_Expiry parameters (includes forecastingPeriod)
    struct TSPExpiryParams {
        uint256 expiryTime;
        uint256 forecastingPeriod;      // Custom forecasting period for this expiry (0 = use market default)
        uint256 minStake;               // 0 = use market default
        uint256 multiplier;             // 0 = use market default
        int256 tsMin;                   // 0 = use market default
        int256 tsMax;                   // 0 = use market default
        uint256 sigma;                  // 0 = use market default
        uint256 taxFee;                 // 0 = use market default
        uint256 observationPeriod;      // 0 = use market default
        uint256 resolutionPeriod;       // 0 = use market default
        uint256 timeCost;               // 0 = use market default
        uint256 alpha;                  // 0 = use market default
        uint256 oracleRequesterReward;  // 0 = use market default, otherwise in basis points (100=1%)
        uint256 resolveCallerReward;    // 0 = use market default, otherwise in basis points (100=1%)
        uint256 updatePenalty;          // 0 = use market's defaultUpdatePenalty, otherwise must be <= market's maxUpdatePenalty
        string[] expiryArgs;            // Expiry-specific oracle arguments
        string expiryName;
    }
    
    /**
     * @dev Initializes the contract
     * @param params Initialization parameters (includes oracle data, oracleDataManager, creationFeesPaid, resolvedValueProvider,isDated and unitSymbol)
     */
    function initialize(TSPMarketInitParams calldata params) external override {
        require(params.tspManager != address(0), "Invalid manager address");
        require(msg.sender == params.tspManager, "Only TSP_Manager can initialize");
        require(owner == address(0), "Already initialized");
        require(params.tsToken != address(0), "Invalid token address");
        require(params.owner != address(0), "Invalid owner address");       
        require(params.tspExpiryImplementation != address(0), "Invalid implementation address");
        require(params.oracleDataManager != address(0), "Invalid oracleDataManager address");
        require(params.tsType <= uint8(TSType.LOGNORMAL), "Invalid time-series type");
        require(params.tsMin < params.tsMax, "Min must be less than max");
        require(params.multiplier > 0, "Multiplier must be greater than 0");
        require(params.carryNoticePeriod <= params.forecastingPeriod, "Notice period must be <= forecasting period");
        //require(params.taxFee <= 100, "Tax fee must be <= 100%");
        require(params.taxFee <= MAX_MARKET_OWNER_TAX_FEE, "TaxFee is > MAX_MARKET_OWNER_TAX_FEE");
        require(bytes(params.marketName).length > 0, "Market name cannot be empty");
        require(bytes(params.resolvedValueProvider).length > 0, "Resolved value provider cannot be empty");
        require(bytes(params.unitSymbol).length > 0, "Unit symbol cannot be empty");
        require(params.oracleData.length > 0, "Oracle data cannot be empty");
        require(params.sigma > 0, "Sigma must be greater than 0");
        // Validate update penalty parameters
        require(params.maxUpdatePenalty > 0, "Max update penalty must be greater than 0");
        require(params.maxUpdatePenalty <= 10000, "Max update penalty cannot exceed 100%");
        require(params.defaultUpdatePenalty > 0, "Default update penalty must be greater than 0");
        //require(params.defaultUpdatePenalty <= 10000, "Default update penalty cannot exceed 100%");
        require(params.defaultUpdatePenalty <= params.maxUpdatePenalty, "Default penalty must be <= max penalty");


        // Initialize verification flags - start as NOT_VERIFIED
        marketVerified = MarketVerificationStatus.NOT_VERIFIED;
        acceptCarryTransfer = false;
        
        // Store oracleDataManager address (captured at creation time)
        oracleDataManager = params.oracleDataManager;
        
        // Validate that this market is registered in OracleData_Manager
        require(IOracleData_Manager(oracleDataManager).isSupportedMarket(address(this)), "Market not registered in OracleData_Manager");
        
        // Store oracle data in this market
        oracleData = params.oracleData;

        // Store isDated from parameters (not editable after creation)
        isDated = params.isDated;
        
        // Store creation fees paid for this market
        creationFeesPaid = params.creationFeesPaid;
        
        // Store resolvedValueProvider and unitSymbol from parameters (not editable after creation)
        resolvedValueProvider = params.resolvedValueProvider;
        unitSymbol = params.unitSymbol;
        
        // Validate oracle data using OracleData_Manager (it knows how to decode)
        require(IOracleData_Manager(oracleDataManager).validateOracleData(params.oracleData), "Invalid oracle data format");
        
        // Validate tsMin > scale for lognormal type (get scale from OracleData_Manager)
        if (params.tsType == uint8(TSType.LOGNORMAL)) {
            //uint256 scale = IOracleData_Manager(oracleDataManager).extractScaleFromOracleData(params.oracleData);
            //require(params.tsMin > scale, "For lognormal type, tsMin must be > scale");  //JF: To verify
            require(params.tsMin > 0, "For lognormal type, tsMin must be > 0");
        }
        
        // Initialize variables
        marketName = params.marketName;
        marketDescription = params.marketDescription;
        
        // Initialize market parameters
        tsType = TSType(params.tsType);
        tsToken = params.tsToken;
        minStake = params.minStake;
        multiplier = params.multiplier;
        timeCost = params.timeCost;
        alpha = params.alpha;
        tsMin = params.tsMin;
        tsMax = params.tsMax;
        forecastingPeriod = params.forecastingPeriod;
        observationPeriod = params.observationPeriod;
        resolutionPeriod = params.resolutionPeriod;
        sigma = params.sigma;
        carryNoticePeriod = params.carryNoticePeriod;  // Set once at creation, not editable
        taxFee = params.taxFee;
        oracleRequesterReward = params.oracleRequesterReward;
        resolveCallerReward = params.resolveCallerReward;
        maxUpdatePenalty = params.maxUpdatePenalty;  // Set once at creation, not editable
        defaultUpdatePenalty = params.defaultUpdatePenalty;  // Set once at creation, not editable
        owner = params.owner;
        tspManager = params.tspManager;
        tspExpiryImplementation = params.tspExpiryImplementation;


        // Set market as active by default
        isActive = true;
    }

    // =============================================================================
    // NEW: CARRY MIGRATION TO NEXT TSP_MANAGER VERSION
    // =============================================================================

    /**
     * @dev Migrates carry pool to a market in the next TSP_Manager version (only market owner)
     * @param _destinationMarket Address of the destination market in next TSP_Manager version
     * @return success Whether the migration was successful
     */
    function migrateCarryToNextVersion(address _destinationMarket) external onlyOwner returns (bool success) {
        require(carryPool > 0, "No carry pool to migrate");
        require(_destinationMarket != address(0), "Invalid destination market");
        require(_destinationMarket != address(this), "Cannot migrate to same market");
        
        // Get next TSP_Manager version from current TSP_Manager
        address nextTspManager = ITSP_Manager(tspManager).getTSPManagerNextVersion();
        require(nextTspManager != address(0), "Next TSP_Manager version not set");
        require(nextTspManager != tspManager, "Next version cannot be same as current");
        
        uint256 migrateAmount = carryPool;
        address token = tsToken;
        
        emit CarryMigrationInitiated(_destinationMarket, nextTspManager, token, migrateAmount);
        
        // Call TSP_Manager to migrate (will revert on failure, never return false)
        bool migrationSuccess = ITSP_Manager(tspManager).migrateCarryToNextVersion(
            address(this),      // source market (this contract)
            _destinationMarket, // destination market in next version
            token,              // token to migrate
            migrateAmount       // amount to migrate
        );
        
        // If we reach here, migration succeeded (otherwise it would have reverted)
        require(migrationSuccess, "Migration should not return false");
        carryPool = 0;
        emit CarryMigrationCompleted(_destinationMarket, nextTspManager, token, migrateAmount);
        return true;
    }

    // =============================================================================
    // OPTIMIZED: SIMPLIFIED MARKET VERIFICATION FUNCTIONS
    // =============================================================================

    /**
     * @dev Request verification from TSP_Manager (only market owner)
     * OPTIMIZED: Only updates local status and registers with TSP_Manager
     */
    function requestVerification() external override onlyOwner onlyActiveMarket{
        require(marketVerified == MarketVerificationStatus.NOT_VERIFIED, "Market already treated or has a pending request");
        
        // Update local status to pending
        marketVerified = MarketVerificationStatus.PENDING;
        
        // Register verification request with TSP_Manager (simplified!)
        ITSP_Manager(tspManager).setMarketVerificationStatus(address(this), MarketVerificationStatus.PENDING);
        
        emit VerificationRequested(address(this), owner);
        emit VerificationStatusUpdated(address(this), MarketVerificationStatus.PENDING);
    }

    /**
     * @dev Update verification status (called by TSP_Manager only)
     * OPTIMIZED: Direct status update, no central tracking needed
     * @param _status New verification status (VERIFIED or REJECTED)
     */
    function updateVerificationStatus(MarketVerificationStatus _status) external override onlyManager {
        require(
            _status == MarketVerificationStatus.VERIFIED || 
            _status == MarketVerificationStatus.REJECTED,
            "Invalid status update"
        );
        require(marketVerified == MarketVerificationStatus.PENDING, "No pending verification request");
        
        marketVerified = _status;
        emit VerificationStatusUpdated(address(this), _status);
    }

    // =============================================================================
    // CARRY TRANSFER FUNCTIONS (UNCHANGED)
    // =============================================================================

    /**
     * @dev Set accept carry transfer flag (only market owner)
     * @param _acceptCarryTransfer Whether to accept carry transfers
     */
    function setAcceptCarryTransfer(bool _acceptCarryTransfer) external onlyOwner onlyActiveMarket{
        acceptCarryTransfer = _acceptCarryTransfer;
        emit AcceptCarryTransferUpdated(_acceptCarryTransfer);
    }

    
    /**
     * @dev Transfer all carry pool to another verified market (only market owner)
     * OPTIMIZED: Direct market-to-market verification check
     * @param _toMarket Address of the destination market
     */
    function transferCarryPool(address _toMarket) external onlyOwner {
        require(carryPool > 0, "No carry pool to transfer");
        require(_toMarket != address(0), "Invalid destination market");
        require(_toMarket != address(this), "Cannot transfer to same market");
        require(ITSP_Manager(tspManager).registeredTSPMarkets(_toMarket), "Destination market not registered");
        
        // OPTIMIZED: Direct verification check instead of going through TSP_Manager
        require(ITSP_Market(_toMarket).marketVerified() == MarketVerificationStatus.VERIFIED, "Destination market must be verified");
        require(ITSP_Market(_toMarket).acceptCarryTransfer(), "Destination market does not accept carry transfers");
        
        uint256 transferAmount = carryPool;
        carryPool = 0;
        
        // Execute the transfer
        ITSP_Market(_toMarket).receiveCarryTransfer(transferAmount, address(this));
        
        emit CarryTransferred(address(this), _toMarket, transferAmount);
    }

    /**
     * @dev Receive carry transfer from another market (called by source market)
     * OPTIMIZED: Removed redundant validation (already done in transferCarryPool)
     * @param _amount Amount being transferred
     * @param _fromMarket Address of the source market
     */
    function receiveCarryTransfer(uint256 _amount, address _fromMarket) external override onlyRegisteredMarket {
        // All validation already done in transferCarryPool (which all markets have identically)
        // Add to carry pool
        carryPool += _amount;
        
        emit CarryReceived(_fromMarket, _amount);
    }

    // =============================================================================
    // EXISTING FUNCTIONS (UNCHANGED)
    // =============================================================================

    /**
     * @dev Updates parameters (removed _carryNoticePeriod - not editable after creation)
     * @param _minStake New minimum stake amount
     * @param _multiplier New multiplier
     * @param _timeCost New time cost rate
     * @param _alpha New alpha adjustment factor
     * @param _tsMin New minimum value of the time-series
     * @param _tsMax New maximum value of the time-series
     * @param _forecastingPeriod New forecasting period
     * @param _observationPeriod New observation period
     * @param _resolutionPeriod New resolution period
     * @param _sigma New sigma value
     * @param _taxFee New tax fee : value basis points (e.g., "500 = 5.00%")
     */
    function updateParameters(
        uint256 _minStake,
        uint256 _multiplier,
        uint256 _timeCost,
        uint256 _alpha,
        int256 _tsMin,
        int256 _tsMax,
        uint256 _forecastingPeriod,
        uint256 _observationPeriod,
        uint256 _resolutionPeriod,
        uint256 _sigma,
        uint256 _taxFee
    ) external onlyOwner onlyActiveMarket {
        require(_tsMin < _tsMax, "Min must be less than max");
        require(_multiplier > 0, "Multiplier must be greater than 0");
        //require(_taxFee <= 100, "Tax fee must be <= 100%");
        require(_taxFee <= MAX_MARKET_OWNER_TAX_FEE, "TaxFee is > MAX_MARKET_OWNER_TAX_FEE");
        require(_sigma > 0, "Sigma must be greater than 0");
        
        // // Validate tsMin > scale for lognormal type (use this market's OracleData_Manager)
        // if (tsType == TSType.LOGNORMAL) {
        //     uint256 scale = IOracleData_Manager(oracleDataManager).extractScaleFromOracleData(oracleData);
        //     require(_tsMin > scale, "For lognormal type, tsMin must be > scale");
        // }
        // Validate tsMin > scale for lognormal type (use this market's OracleData_Manager)
        if (tsType == TSType.LOGNORMAL) {
            require(_tsMin > 0, "For lognormal type, tsMin must be > 0");
        }
        
        // Update parameters (carryNoticePeriod is NOT updated - set once at creation)
        minStake = _minStake;
        multiplier = _multiplier;
        timeCost = _timeCost;
        alpha = _alpha;
        tsMin = _tsMin;
        tsMax = _tsMax;
        forecastingPeriod = _forecastingPeriod;
        observationPeriod = _observationPeriod;
        resolutionPeriod = _resolutionPeriod;
        sigma = _sigma;
        taxFee = _taxFee;
        
        emit ParametersUpdated();
    }

    // Temporary storage for expiry creation to reduce stack usage
    struct ExpiryCreationData {
        uint256 expiryTime;
        uint256 forecastingPeriod;      // Store custom forecasting period
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
        uint256 feesPaid;                   // Store the fees paid for this expiry
        uint256 oracleRequesterReward; 
        uint256 resolveCallerReward;
        uint256 updatePenalty;
        string[] expiryArgs;               // Expiry-specific oracle arguments
        string expiryName; 
    }
    


    /**
    * @dev Adds a new expiry (supports custom forecastingPeriod per expiry)
    * SECURITY FIX: Uses local variables instead of global storage to prevent race conditions
    * @param _params Parameters for the new expiry (TSPExpiryParams struct)
    * @return expiry Address of the newly created expiry
    */
    function addExpiry(TSPExpiryParams memory _params) external payable onlyOwner onlyActiveMarket nonReentrant returns (address expiry) {
        
      
        
        // SECURITY FIX: Use local variable instead of global storage
        ExpiryCreationData memory localExpiryData;
     
        // SECURITY FIX: Pass local variable to preparation function
        _prepareExpiryCreationData(_params, localExpiryData);

        require(localExpiryData.taxFee <= MAX_MARKET_OWNER_TAX_FEE, "TaxFee is > MAX_MARKET_OWNER_TAX_FEE");

          // Validate tsMin > scale for lognormal type (get scale from OracleData_Manager)
        if (uint8(tsType) == uint8(TSType.LOGNORMAL)) {
            //uint256 scale = IOracleData_Manager(oracleDataManager).extractScaleFromOracleData(params.oracleData);
            //require(_params.tsMin > scale, "For lognormal type, tsMin must be > scale");  //JF: To verify
            require(localExpiryData.tsMin > 0, "For lognormal type, tsMin must be > 0");
        }
        
        
        // Use local data for validation (same logic as before)
        require(_params.expiryTime > block.timestamp + localExpiryData.forecastingPeriod + localExpiryData.observationPeriod, 
                "Expiry must be after forecasting and observation periods");
        require(localExpiryData.startTime >= block.timestamp, "Start time must be in the future");
        
        // Clone the TSP_Expiry implementation
        expiry = tspExpiryImplementation.clone();
        
        // Process expiry creation fee and store in local data
        localExpiryData.feesPaid = _processExpiryCreationFee(expiry);
        
        // SECURITY FIX: Pass local data to initialization function
        _initializeExpiry(expiry, localExpiryData);
        
        // Add to pending expiries
        pendingExpiries.push(expiry);
        isPendingExpiry[expiry] = true;
        
        emit ExpiryAdded(expiry, _params.expiryTime, localExpiryData.feesPaid);
        
        return expiry;
    }

    /**
     * @dev Processes expiry creation fee by forwarding payment to TSP_Manager (with exemption support)
     * @param _expiry Address of the created expiry
     * @return feesPaid Amount of fees paid
     */
    function _processExpiryCreationFee(address _expiry) private returns (uint256 feesPaid) {
        // Check if caller is exempt BEFORE requiring fee payment
        // Get fee exemption status from TSP_Manager
        bool isExempt = _isUserFeeExempt(msg.sender);
        
        if (isExempt) {
            // User is exempt - no fee required, forward call with any ETH sent for refund
            ITSP_Manager(tspManager).processExpiryCreationFee{value: msg.value}(msg.sender, _expiry);
            return 0; // No fees paid by exempt user
        } else {
            // User is not exempt - check fee requirement
            (, uint256 expiryCreationFees, , ) = ITSP_Manager(tspManager).getFeeInfo();
            require(msg.value >= expiryCreationFees, "Insufficient expiry creation fee");
            
            // Forward the fee payment to TSP_Manager
            ITSP_Manager(tspManager).processExpiryCreationFee{value: msg.value}(msg.sender, _expiry);
            return expiryCreationFees; // Return actual fee amount
        }
    }

    /**
     * @dev HELPER: Check if a user is exempt from fees (calls TSP_Manager)
     * @param _user Address to check
     * @return Whether the user is exempt from fees
     */
    function _isUserFeeExempt(address _user) private view returns (bool) {
        // Call TSP_Manager to check exemption status
        try ITSP_Manager(tspManager).isFeeExempt(_user) returns (bool exempt) {
            return exempt;
        } catch {
            // If the call fails (old TSP_Manager version), assume not exempt
            return false;
        }
    }
    
   /**
    * @dev Prepares expiry creation data from parameters (supports custom forecastingPeriod)
    * SECURITY FIX: Now takes local data as parameter instead of using global storage
    * @param _params The expiry parameters
    * @param localExpiryData Local data structure to populate
    */
    function _prepareExpiryCreationData(TSPExpiryParams memory _params, ExpiryCreationData memory localExpiryData) private view {
        // Use default values if not specified (same logic as before)
        localExpiryData.expiryTime = _params.expiryTime;
        
        // Use custom forecasting period if specified, otherwise use market default
        localExpiryData.forecastingPeriod = _params.forecastingPeriod > 0 ? _params.forecastingPeriod : forecastingPeriod;
        
        localExpiryData.minStake = _params.minStake > 0 ? _params.minStake : minStake;
        localExpiryData.multiplier = _params.multiplier > 0 ? _params.multiplier : multiplier;
        localExpiryData.tsMin = _params.tsMin != 0 ? _params.tsMin : tsMin;
        localExpiryData.tsMax = _params.tsMax != 0 ? _params.tsMax : tsMax;
        localExpiryData.sigma = _params.sigma > 0 ? _params.sigma : sigma;
        localExpiryData.taxFee = _params.taxFee > 0 ? _params.taxFee : taxFee;
        localExpiryData.observationPeriod = _params.observationPeriod > 0 ? _params.observationPeriod : observationPeriod;
        localExpiryData.resolutionPeriod = _params.resolutionPeriod > 0 ? _params.resolutionPeriod : resolutionPeriod;
        localExpiryData.timeCost = _params.timeCost > 0 ? _params.timeCost : timeCost;
        localExpiryData.alpha = _params.alpha > 0 ? _params.alpha : alpha;

        // ADD THIS BLOCK - Oracle requester reward logic with validation
        if (_params.oracleRequesterReward > 0) {
            // Validate against TSP_Manager maximum
            require(_params.oracleRequesterReward <= ITSP_Manager(tspManager).MAX_ORACLE_REQUESTER_REWARD(), 
                    "Oracle requester reward exceeds maximum");
            localExpiryData.oracleRequesterReward = _params.oracleRequesterReward;
        } else {
            // Use market default
            localExpiryData.oracleRequesterReward = oracleRequesterReward;
        }

        // Resolve caller reward: use expiry-specific value if provided, else fall back to market default
        if (_params.resolveCallerReward > 0) {
            require(_params.resolveCallerReward <= ITSP_Manager(tspManager).MAX_RESOLVE_CALLER_REWARD(),
                    "Resolve caller reward exceeds maximum");
            localExpiryData.resolveCallerReward = _params.resolveCallerReward;
        } else {
            localExpiryData.resolveCallerReward = resolveCallerReward;
        }

        //  Update penalty logic with validation
        if (_params.updatePenalty > 0) {
            // Validate against market maximum
            require(_params.updatePenalty <= maxUpdatePenalty, 
                    "Update penalty exceeds maximum");
            localExpiryData.updatePenalty = _params.updatePenalty;
        } else {
            // Use default value
            localExpiryData.updatePenalty = defaultUpdatePenalty;
        }

        // Copy expiry-specific oracle arguments
        localExpiryData.expiryArgs = _params.expiryArgs;

        // Copy expiry name
        localExpiryData.expiryName = _params.expiryName;
      
        // Calculate start and timeout times using the (potentially custom) forecasting period
        localExpiryData.startTime = localExpiryData.expiryTime - localExpiryData.forecastingPeriod - localExpiryData.observationPeriod;
        localExpiryData.timeoutTime = localExpiryData.expiryTime - localExpiryData.observationPeriod;
        
        // Calculate carried amount (use market's carryNoticePeriod which is fixed at creation)
        localExpiryData.carriedAmount = 0;
        if (carryPool > 0 && localExpiryData.timeoutTime - block.timestamp >= carryNoticePeriod) {
            localExpiryData.carriedAmount = carryPool;
            // NOTE: carryPool will be modified in _initializeExpiry after successful creation
        }
        
        // Initialize feesPaid to 0 (will be set during processing)
        localExpiryData.feesPaid = 0;
    }
    
    /**
    * @dev Initializes an expiry contract
    * SECURITY FIX: Now takes local data as parameter instead of using global storage
    * @param expiry The address of the expiry contract
    * @param localExpiryData Local expiry creation data
    */
    function _initializeExpiry(address expiry, ExpiryCreationData memory localExpiryData) private {
        // Create parameters for TSP_Expiry initialization from local data (same logic as before)
        ITSP_Expiry.TSPExpiryInitParams memory expiryParams;
        
        // Fill basic parameters
        expiryParams.expiryTime = localExpiryData.expiryTime;
        expiryParams.minStake = localExpiryData.minStake;
        expiryParams.multiplier = localExpiryData.multiplier;
        expiryParams.tsMin = localExpiryData.tsMin;
        expiryParams.tsMax = localExpiryData.tsMax;
        expiryParams.sigma = localExpiryData.sigma;
        expiryParams.taxFee = localExpiryData.taxFee;
        
        // Fill time parameters
        expiryParams.timeCost = localExpiryData.timeCost;
        expiryParams.alpha = localExpiryData.alpha;
        expiryParams.observationPeriod = localExpiryData.observationPeriod;
        expiryParams.resolutionPeriod = localExpiryData.resolutionPeriod;
        expiryParams.startTime = localExpiryData.startTime;
        expiryParams.timeoutTime = localExpiryData.timeoutTime;
        
        // Fill amount parameters
        expiryParams.carriedAmount = localExpiryData.carriedAmount;
        expiryParams.creationFeesPaid = localExpiryData.feesPaid;
        expiryParams.oracleRequesterReward = localExpiryData.oracleRequesterReward; 
        expiryParams.resolveCallerReward   = localExpiryData.resolveCallerReward;
        
        // Fill resolvedValueProvider  unitSymbol, and isDated from market
        expiryParams.resolvedValueProvider = resolvedValueProvider;
        expiryParams.unitSymbol = unitSymbol;
        expiryParams.isDated = isDated;  // Pass isDated from market to expiry
        
        // Fill address parameters
        expiryParams.owner = owner;
        expiryParams.tspMarket = address(this);
        expiryParams.tspManager = tspManager;
        expiryParams.tsToken = tsToken;
        
        // Fill type parameters
        expiryParams.tsType = uint8(tsType);

        expiryParams.updatePenalty = localExpiryData.updatePenalty;

        // Copy expiry-specific oracle arguments
        expiryParams.expiryArgs = localExpiryData.expiryArgs;

        // Copy expiry name
        expiryParams.expiryName = localExpiryData.expiryName;
        
        // SECURITY FIX: Only modify contract state after successful validation
        // Update carry pool if it was used
        if (localExpiryData.carriedAmount > 0) {
            carryPool -= localExpiryData.carriedAmount;
        }
        
        // Initialize the TSP_Expiry
        ITSP_Expiry(expiry).initialize(expiryParams);
    }

    /**
     * @dev Called by an expiry when it is resolved
     * @param _feeAmount Fee amount to add to fee pool
     */
    function onExpiryResolved(uint256 _feeAmount) external override onlyPendingExpiry {
        // Remove from pending expiries
        _removeFromPendingExpiries(msg.sender);
        
        // Add to closed expiries
        closedExpiries.push(msg.sender);
        isClosedExpiry[msg.sender] = true;
        
        // Add fee to fee pool
        feePool += _feeAmount;
        
        emit ExpiryResolved(msg.sender, block.timestamp);
    }

    /**
     * @dev Called by an expiry when it is cancelled (If the expiry is not resolved before the end of the ResolutionPeriod)
     * @param _carriedAmount Carried amount to add to carry pool
     */
    function onExpiryCancelled(uint256 _carriedAmount) external override onlyPendingExpiry {
        // Remove from pending expiries
        _removeFromPendingExpiries(msg.sender);
        
        // Add to closed expiries
        closedExpiries.push(msg.sender);
        isClosedExpiry[msg.sender] = true;

        // Add carried amount to carry pool
        carryPool += _carriedAmount;
        
        emit ExpiryCancelled(msg.sender, _carriedAmount, block.timestamp);
    }

    /**
     * @dev Called by an expiry when it fails (no predictions)
     * @param _carriedAmount Carried amount to add to carry pool
     */
    function onExpiryFailed(uint256 _carriedAmount) external override onlyPendingExpiry {
        // Remove from pending expiries
        _removeFromPendingExpiries(msg.sender);
        
        // Add to closed expiries
        closedExpiries.push(msg.sender);
        isClosedExpiry[msg.sender] = true;
        
        // Add carried amount to carry pool
        carryPool += _carriedAmount;
        
        emit ExpiryFailed(msg.sender, block.timestamp, _carriedAmount );
    }

    /**
     * @dev Called by an expiry when there are no winners
     * @param _amount Amount to add to carry pool
     */
    function addToCarryPool(uint256 _amount) external override onlyPendingExpiry {
        // Add amount to carry pool
        carryPool += _amount;
        
        emit CarryPoolFunded(_amount);
    }

    /**
     * @dev Withdraws fees from the fee pool (supports TSP owner fee)
     * @param _amount Amount to withdraw
     */
    function withdrawFees(uint256 _amount) external onlyOwner {
        require(_amount > 0 && _amount <= feePool, "Invalid amount");
        require(pendingExpiries.length == 0, "Cannot withdraw with pending expiries");
        
        // Update fee pool
        feePool -= _amount;
        
        // Process TSP owner fee through TSP_Manager
        uint256 marketOwnerAmount = ITSP_Manager(tspManager).processTspOwnerFee(
            owner, 
            tsToken, 
            _amount
        );
        
        // Calculate TSP owner amount for event
        uint256 tspOwnerAmount = _amount - marketOwnerAmount;
        
        emit FeesWithdrawn(_amount, marketOwnerAmount, tspOwnerAmount);
    }

    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================


    /**
     * @dev Returns the number of pending expiries
     * @return Number of pending expiries
     */
    function getPendingExpiriesCount() external view returns (uint256) {
        return pendingExpiries.length;
    }

    /**
     * @dev Returns the number of closed expiries
     * @return Number of closed expiries
     */
    function getClosedExpiriesCount() external view returns (uint256) {
        return closedExpiries.length;
    }


    /**
     * @dev Returns current expiry creation fee from TSP_Manager
     * @return Current expiry creation fee
     */
    function getExpiryCreationFee() external view returns (uint256) {
        (, uint256 expiryCreationFees, , ) = ITSP_Manager(tspManager).getFeeInfo();
        return expiryCreationFees;
    }

    /**
     * @dev Returns current TSP owner fee from TSP_Manager
     * @return Current TSP owner fee percentage
     */
    function getTspOwnerFee() external view returns (uint256) {
        return ITSP_Manager(tspManager).getTspOwnerFee();
    }

    /**
     * @dev Returns market verification information
     * @return status Current verification status
     * @return acceptTransfer Whether market accepts carry transfers
     * @return carryAmount Current carry pool amount
     */
    function getMarketVerificationInfo() external view returns (
        MarketVerificationStatus status,
        bool acceptTransfer,
        uint256 carryAmount
    ) {
        return (marketVerified, acceptCarryTransfer, carryPool);
    }

    /**
     * @dev Removes an expiry from the pending expiries array
     * @param _expiry Address of the expiry to remove
     */
    function _removeFromPendingExpiries(address _expiry) private {
        require(isPendingExpiry[_expiry], "Expiry not in pending state");
        
        // Find the index of the expiry
        uint256 index = 0;
        bool found = false;
        for (uint256 i = 0; i < pendingExpiries.length; i++) {
            if (pendingExpiries[i] == _expiry) {
                index = i;
                found = true;
                break;
            }
        }
        
        require(found, "Expiry not found");
        
        // Remove from array by replacing with last element and reducing length
        pendingExpiries[index] = pendingExpiries[pendingExpiries.length - 1];
        pendingExpiries.pop();
        
        // Update mapping
        isPendingExpiry[_expiry] = false;
    }

    /**
     * @dev Fallback function to receive ETH (for fee processing)
     */
    receive() external payable {
        // Allow contract to receive ETH
    }


    /**
     * @dev Closes the TSP Market permanently (can only be called once by owner)
     * @notice Once closed, the market cannot be reopened
     */
    function closeTSPMarket() external onlyOwner {
        require(isActive, "Market is already closed");        
        isActive = false;
        acceptCarryTransfer = false;       
        emit MarketClosed(msg.sender, block.timestamp);
    }
}