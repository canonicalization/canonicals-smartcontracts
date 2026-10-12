// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol"; 

import "./interfaces.sol";
import {TSPOracleData, IOracleCaller} from "./OracleData_Manager.sol";

/**
 * @title TSP_Manager
 * @dev Factory contract to create and manage time-series prediction markets.
 * Updated with hybrid verification system, carry migration system, TSP owner fee,
 * and pluggable OracleCaller registry support.
 *
 * Oracle architecture changes:
 * - createTSPMarket() validates that oracleData.oracleCallerAddress is registered
 *   and active in OracleData_Manager before creating the market.
 * - resolvedValueProvider is derived automatically from IOracleCaller.oracleName()
 *   and no longer needs to be supplied by the market creator.
 * - TSPMarketParams no longer includes resolvedValueProvider field.
 */
contract TSP_Manager is ITSP_Manager, Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using Clones for address;

    // TSP Owner Fee Constants
    uint256 public constant MAX_TSP_OWNER_FEE = 2000;      // Maximum 20% (2000 basis points)  TSP owner fee

    // Oracle Requester Reward Constants  
    uint256 public constant MAX_ORACLE_REQUESTER_REWARD = 100;    // Maximum 1% (100 basis points) reward for oracle requester
    uint256 public constant MAX_RESOLVE_CALLER_REWARD   = 100;    // Maximum 1% (100 basis points) reward for resolve caller



    // Struct for storing TSP_Market creation parameters with generic oracle data
    struct TSPMarketParams {
        // Generic oracle data (encoded TSPOracleData - oracleCallerAddress routes to the caller)
        bytes oracleData;
        // Market parameters
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
        uint256 taxFee;                 // value basis points (e.g., "500 = 5.00%")
        // resolvedValueProvider removed - derived automatically from IOracleCaller.oracleName()
        string unitSymbol;              // Unit symbol for the market (e.g., "USD", "ETH", "BTC")
        bool isDated;
        string marketName;
        string marketDescription;
        uint256 oracleRequesterReward;  // Percentage reward for successful oracle requests in basis points (0-500, where 100 = 1%)
        uint256 resolveCallerReward;    // Percentage reward for calling resolve() in basis points (0 = not used)
        uint256 maxUpdatePenalty;       // Maximum update penalty for expiries (in basis points)
        uint256 defaultUpdatePenalty;   // Default update penalty for expiries (in basis points)
    }

    // Implementation contracts
    address public tspMarketImplementation;
    address public tspExpiryImplementation;
    
    // OracleData_Manager address - can be updated multiple times for upgrades
    // This is the "latest" version that will be used for NEW markets
    address public override oracleDataManager;
    
    // Lock flag for OracleData_Manager - once locked, cannot be changed
    bool public oracleDataManagerLocked;

    // Migration support - address of the next version of TSP_Manager
    // This is not initialized (defaults to address(0)) and only editable by owner
    address public tspManagerNextVersion;

    // Creation Fees (in ETH/native token)
    uint256 public marketCreationFees;      // Fee to create a market
    uint256 public expiryCreationFees;      // Fee to create an expiry
    
    // Total fees collected
    uint256 public totalMarketCreationFeesCollected;  // Total market creation fees collected
    uint256 public totalExpiryCreationFeesCollected;  // Total expiry creation fees collected

    // TSP Owner Fee System
    uint256 public tspOwnerFee;                       // TSP owner fee percentage (0-20%) , value basis points (e.g., "1000 = 10.00%")
    uint256 public totalTspOwnerFeesCollected;        // Total TSP owner fees collected from market withdrawals

    // Fee Exemption System
    mapping(address => bool) public feeExemptAddresses;        // Mapping of fee-exempt addresses
    address[] public feeExemptAddressesList;                   // Array of fee-exempt addresses for iteration
    mapping(address => uint256) public feeExemptAddressIndex;  // Mapping to track index in array

    // HYBRID: Market Verification System - Timestamps + Array for chronological order
    mapping(address => uint256) public verificationRequestsTimestamps;  // market → timestamp (0 = no request)
    address[] public verificationRequestsList;                          // markets with pending requests

    // Mapping of supported tokens
    mapping(address => bool) public override supportedTokens;
    
    // Array of supported token addresses for iteration
    address[] public supportedTokensList;
    
    // Mapping of user balances for each token
    mapping(address => mapping(address => uint256)) public userBalances;
    
    // Mapping of TSP_Expiry approval amounts for each user and token
    mapping(address => mapping(address => mapping(address => uint256))) public tspExpiryApprovals;
    
    // Mapping of created TSP_Market instances
    mapping(address => bool) public override registeredTSPMarkets;
    address[] public tspMarketsList;

    // Events
    event TokenAdded(address indexed token);
    event TokenDeposited(address indexed user, address indexed token, uint256 amount);
    event TokenWithdrawn(address indexed user, address indexed token, uint256 amount);
    event TSPExpiryApproved(address indexed user, address indexed tspExpiry, address indexed token, uint256 amount);
    event TSPMarketCreated(address indexed tspMarket, address indexed creator, string marketName, address indexed oracleDataManager, uint256 feesPaid);
    event ExpiryCreated(address indexed tspMarket, address indexed expiry, address indexed creator, uint256 feesPaid);
    event ImplementationsUpdated(address indexed tspMarketImpl, address indexed tspExpiryImpl);
    event OracleDataManagerUpdated(address indexed oldManager, address indexed newManager);
    event OracleDataManagerLocked(address indexed lockedManager);
    
    // Events for fee management
    event MarketCreationFeesUpdated(uint256 oldFees, uint256 newFees);
    event ExpiryCreationFeesUpdated(uint256 oldFees, uint256 newFees);
    event CreationFeesWithdrawn(address indexed recipient, uint256 amount);

    // Event for migration support
    event TSPManagerNextVersionUpdated(address indexed oldNextVersion, address indexed newNextVersion);

    // Events for fee exemption system
    event FeeExemptAddressAdded(address indexed exemptAddress, address indexed addedBy);
    event FeeExemptAddressRemoved(address indexed exemptAddress, address indexed removedBy);
    event FeeExemptionUsed(address indexed exemptAddress, string feeType, uint256 feeAmount);

    // Events for TSP owner fee system
    event TspOwnerFeeUpdated(uint256 oldFee, uint256 newFee);
    event TspOwnerFeeCollected(address indexed market, address indexed marketOwner, address indexed token, uint256 totalAmount, uint256 tspOwnerShare, uint256 marketOwnerShare);

    // HYBRID: Verification events
    event VerificationRequestReceived(address indexed market, address indexed marketOwner, uint256 timestamp);
    event VerificationRequestApproved(address indexed market, address indexed approvedBy, uint256 processedTimestamp);
    event VerificationRequestRejected(address indexed market, address indexed rejectedBy, uint256 processedTimestamp);

    // NEW: Carry migration events
    event CarryMigrationSent(address indexed sourceMarket, address indexed destinationMarket, address indexed nextTspManager, address token, uint256 amount);

    /**
     * @dev Constructor initializes the contract with implementation addresses, creation fees, and TSP owner fee
     * @param _tspMarketImplementation Address of the TSP_Market implementation
     * @param _tspExpiryImplementation Address of the TSP_Expiry implementation
     * @param _marketCreationFees Fee required to create a market (in wei)
     * @param _expiryCreationFees Fee required to create an expiry (in wei)
     * @param _tspOwnerFee TSP owner fee percentage (0-20%)
     */
    constructor(
        address _tspMarketImplementation, 
        address _tspExpiryImplementation,
        uint256 _marketCreationFees,
        uint256 _expiryCreationFees,
        uint256 _tspOwnerFee
    ) Ownable() { 
        require(_tspMarketImplementation != address(0), "Invalid TSP_Market implementation");
        require(_tspExpiryImplementation != address(0), "Invalid TSP_Expiry implementation");
        require(_tspOwnerFee <= MAX_TSP_OWNER_FEE, "TSP owner fee exceeds maximum");
        
        tspMarketImplementation = _tspMarketImplementation;
        tspExpiryImplementation = _tspExpiryImplementation;
        
        // Set initial creation fees
        marketCreationFees = _marketCreationFees;
        expiryCreationFees = _expiryCreationFees;
        
        // Set initial TSP owner fee
        tspOwnerFee = _tspOwnerFee;
        
        // Initialize fee counters
        totalMarketCreationFeesCollected = 0;
        totalExpiryCreationFeesCollected = 0;
        totalTspOwnerFeesCollected = 0;

        // NOTE: tspManagerNextVersion is not initialized (defaults to address(0))
        // It will be set when we want to migrate to a new version
    }

    // =============================================================================
    // CARRY MIGRATION TO NEXT VERSION
    // =============================================================================

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
    ) external override nonReentrant whenNotPaused returns (bool success) {
        // Security: Only registered TSP_Markets can call this function
        require(registeredTSPMarkets[msg.sender], "Caller is not a registered TSP market");
        require(msg.sender == _sourceMarket, "Source market must be the caller");
        
        // Validate destination market (external input that needs validation)
        require(_destinationMarket != address(0), "Invalid destination market");
        
        // Validate destination market info and get its token
        (bool isRegistered, bool isVerified, address destinationToken) = ITSP_ManagerNextVersion(tspManagerNextVersion).getMarketInfo(_destinationMarket);
        require(isRegistered, "Destination market not registered in next version");
        require(isVerified, "Destination market not verified in next version");
        
        // Validate that both source and destination markets use the same token
        require(_token == destinationToken, "Source and destination markets must use the same token");
        
        // Validate next version accepts migrations
        require(
            ITSP_ManagerNextVersion(tspManagerNextVersion).acceptsCarryMigration(),
            "Next version does not accept carry migrations"
        );
        
        // Validate next version supports the token
        require(
            ITSP_ManagerNextVersion(tspManagerNextVersion).supportedTokens(_token),
            "Token not supported in next version"
        );
        
        // Check that we have sufficient balance to transfer
        uint256 contractBalance = IERC20(_token).balanceOf(address(this));
        require(contractBalance >= _carryAmount, "Insufficient token balance for migration");
        
        // Transfer tokens to the next version TSP_Manager
        IERC20(_token).safeTransfer(tspManagerNextVersion, _carryAmount);
        
        // Call the next version to complete the migration
        bool migrationSuccess = ITSP_ManagerNextVersion(tspManagerNextVersion).receiveCarryMigration(
            _sourceMarket,
            _destinationMarket,
            _token,
            _carryAmount,
            address(this)
        );
        
        require(migrationSuccess, "Migration failed in next version");
        
        emit CarryMigrationSent(_sourceMarket, _destinationMarket, tspManagerNextVersion, _token, _carryAmount);
        
        return true;
    }

    // =============================================================================
    // HYBRID: MARKET VERIFICATION SYSTEM WITH CHRONOLOGICAL ORDER
    // =============================================================================

    /**
     * @dev Registers a verification request (called by TSP_Market when requesting verification)
     * @param _market Address of the market requesting verification
     * @param _status Status being set (only PENDING allowed)
     */
    function setMarketVerificationStatus(address _market, MarketVerificationStatus _status) external override {
        require(registeredTSPMarkets[_market], "Market not registered");
        require(msg.sender == _market, "Only market can set its own status");
        require(_status == MarketVerificationStatus.PENDING, "Only PENDING status can be set by market");
        require(verificationRequestsTimestamps[_market] == 0, "Verification request already exists");
        
        // Add to hybrid structure - O(1) operations
        verificationRequestsTimestamps[_market] = block.timestamp;
        verificationRequestsList.push(_market);
        
        emit VerificationRequestReceived(_market, ITSP_Market(_market).owner(), block.timestamp);
    }

    /**
     * @dev Approve a market verification request (only TSP_Manager owner)
     * @param _market Address of the market to approve
     */
    function approveMarketVerification(address _market) external override onlyOwner {
        require(verificationRequestsTimestamps[_market] > 0, "No pending verification request");
        
        // Remove from hybrid structure
        _removeFromVerificationRequests(_market);
        
        // Update market status directly in the market contract
        ITSP_Market(_market).updateVerificationStatus(MarketVerificationStatus.VERIFIED);
        
        emit VerificationRequestApproved(_market, msg.sender, block.timestamp);
    }

    /**
     * @dev Reject a market verification request (only TSP_Manager owner)
     * @param _market Address of the market to reject
     */
    function rejectMarketVerification(address _market) external override onlyOwner {
        require(verificationRequestsTimestamps[_market] > 0, "No pending verification request");
        
        // Remove from hybrid structure
        _removeFromVerificationRequests(_market);
        
        // Update market status directly in the market contract
        ITSP_Market(_market).updateVerificationStatus(MarketVerificationStatus.REJECTED);
        
        emit VerificationRequestRejected(_market, msg.sender, block.timestamp);
    }

    /**
     * @dev Removes a market from verification requests - O(1) operation
     * @param _market Market address to remove
     */
    function _removeFromVerificationRequests(address _market) private {
        // Find market in array and swap with last element
        for (uint256 i = 0; i < verificationRequestsList.length; i++) {
            if (verificationRequestsList[i] == _market) {
                // Swap with last element and pop - breaks order but O(1)
                verificationRequestsList[i] = verificationRequestsList[verificationRequestsList.length - 1];
                verificationRequestsList.pop();
                break;
            }
        }
        
        // Clean up timestamp mapping
        delete verificationRequestsTimestamps[_market];
    }

    /**
     * @dev Returns market verification status by querying the market directly
     * @param _market Address of the market
     * @return The verification status from the market contract
     */
    function getMarketVerificationStatus(address _market) external view override returns (MarketVerificationStatus) {
        return ITSP_Market(_market).marketVerified();
    }

    /**
     * @dev Returns all pending verification requests (unsorted for efficiency)
     * Offchain clients should sort by timestamps for chronological order
     * @return Array of market addresses with pending requests
     */
    function getAllPendingVerificationRequests() external override view returns (address[] memory) {
        return verificationRequestsList;  // O(1) - super efficient!
    }

    /**
     * @dev Returns the number of pending verification requests
     * @return Number of pending requests
     */
    function getPendingVerificationRequestsCount() external override view returns (uint256) {
        return verificationRequestsList.length;  // O(1) - super efficient!
    }

    /**
     * @dev Returns timestamp for a specific verification request
     * @param _market Market address
     * @return Timestamp when request was made (0 if no request)
     */
    function getVerificationRequestTimestamp(address _market) external override view returns (uint256) {
        return verificationRequestsTimestamps[_market];
    }

    /**
     * @dev Check if a market has a pending verification request
     * @param _market Address of the market
     * @return Whether there's a pending verification request
     */
    function hasPendingVerificationRequest(address _market) external override view returns (bool) {
        return verificationRequestsTimestamps[_market] > 0;  // Uses timestamp for duplicate check
    }

    /**
     * @dev Returns comprehensive verification information for a market
     * @param _market Address of the market
     * @return status Verification status (from market contract)
     * @return hasPendingRequest Whether there's a pending request (from timestamp)
     * @return requestTimestamp Timestamp when request was made (0 if no request)
     * @return marketOwner Owner of the market
     * @return marketName Name of the market
     */
    function getMarketVerificationInfo(address _market) external override view returns (
        MarketVerificationStatus status,
        bool hasPendingRequest,
        uint256 requestTimestamp,
        address marketOwner,
        string memory marketName
    ) {
        // Get status from market contract
        status = ITSP_Market(_market).marketVerified();
        requestTimestamp = verificationRequestsTimestamps[_market];
        hasPendingRequest = requestTimestamp > 0;
        
        try ITSP_Market(_market).owner() returns (address owner) {
            marketOwner = owner;
        } catch {
            marketOwner = address(0);
        }
        
        try ITSP_Market(_market).marketName() returns (string memory name) {
            marketName = name;
        } catch {
            marketName = "";
        }
        
        return (status, hasPendingRequest, requestTimestamp, marketOwner, marketName);
    }

    /**
     * @dev Returns verification statistics by querying all markets
     * @return totalMarkets Total number of registered markets
     * @return notVerifiedCount Number of not verified markets
     * @return pendingCount Number of pending verification requests
     * @return verifiedCount Number of verified markets
     * @return rejectedCount Number of rejected markets
     */
    function getVerificationStats() external override view returns (
        uint256 totalMarkets,
        uint256 notVerifiedCount,
        uint256 pendingCount,
        uint256 verifiedCount,
        uint256 rejectedCount
    ) {
        totalMarkets = tspMarketsList.length;
        pendingCount = verificationRequestsList.length;  // O(1) with hybrid approach!
        
        // Count statuses by querying each market
        for (uint256 i = 0; i < totalMarkets; i++) {
            address market = tspMarketsList[i];
            
            // Skip markets with pending requests (already counted)
            if (verificationRequestsTimestamps[market] > 0) {
                continue;
            }
            
            // Get status from market contract
            try ITSP_Market(market).marketVerified() returns (MarketVerificationStatus status) {
                if (status == MarketVerificationStatus.NOT_VERIFIED) {
                    notVerifiedCount++;
                } else if (status == MarketVerificationStatus.VERIFIED) {
                    verifiedCount++;
                } else if (status == MarketVerificationStatus.REJECTED) {
                    rejectedCount++;
                }
            } catch {
                // If we can't read the status, count as not verified
                notVerifiedCount++;
            }
        }
        
        return (totalMarkets, notVerifiedCount, pendingCount, verifiedCount, rejectedCount);
    }

    // =============================================================================
    // TSP OWNER FEE SYSTEM FUNCTIONS (UNCHANGED)
    // =============================================================================

    /**
     * @dev Sets the TSP owner fee percentage (only owner)
     * @param _newTspOwnerFee New TSP owner fee percentage (0-20%)
     */
    function setTspOwnerFee(uint256 _newTspOwnerFee) external onlyOwner {
        require(_newTspOwnerFee <= MAX_TSP_OWNER_FEE, "TSP owner fee exceeds maximum");
        
        uint256 oldFee = tspOwnerFee;
        tspOwnerFee = _newTspOwnerFee;
        
        emit TspOwnerFeeUpdated(oldFee, _newTspOwnerFee);
    }

    /**
     * @dev Returns the current TSP owner fee percentage
     * @return The TSP owner fee percentage, value basis points (e.g., "1000 = 10.00%")
     */
    function getTspOwnerFee() external view override returns (uint256) {
        return tspOwnerFee;
    }

    /**
     * @dev Processes TSP owner fee when market owner withdraws fees (called by TSP_Market)
     * @param _marketOwner Address of the market owner
     * @param _token Address of the token
     * @param _totalAmount Total amount being withdrawn
     * @return marketOwnerAmount Amount that goes to market owner after TSP owner fee
     */
    function processTspOwnerFee(
        address _marketOwner, 
        address _token, 
        uint256 _totalAmount
    ) external override nonReentrant returns (uint256 marketOwnerAmount) {
        require(registeredTSPMarkets[msg.sender], "Caller is not a registered TSP market");
        require(_marketOwner != address(0), "Invalid market owner address");
        require(supportedTokens[_token], "Token not supported");
        require(_totalAmount > 0, "Amount must be greater than 0");
        
        // Calculate TSP owner fee (if any)
        if (tspOwnerFee == 0) {
            // No TSP owner fee - all goes to market owner
            marketOwnerAmount = _totalAmount;
            userBalances[_marketOwner][_token] += marketOwnerAmount;
        } else {
            // Calculate fee split
            uint256 tspOwnerShare = (_totalAmount * tspOwnerFee) / 10000;
            marketOwnerAmount = _totalAmount - tspOwnerShare;
            
            // Update balances
            userBalances[owner()][_token] += tspOwnerShare;        // TSP owner gets their share
            userBalances[_marketOwner][_token] += marketOwnerAmount; // Market owner gets remaining
            
            // Track total TSP owner fees collected
            totalTspOwnerFeesCollected += tspOwnerShare;
            
            emit TspOwnerFeeCollected(msg.sender, _marketOwner, _token, _totalAmount, tspOwnerShare, marketOwnerAmount);
        }
        
        return marketOwnerAmount;
    }

    /**
     * @dev Returns comprehensive TSP owner fee information
     * @return currentFee Current TSP owner fee percentage
     * @return maxFee Maximum allowed TSP owner fee percentage
     * @return totalCollected Total TSP owner fees collected from market withdrawals
     */
    function getTspOwnerFeeInfo() external view returns (
        uint256 currentFee,
        uint256 maxFee,
        uint256 totalCollected
    ) {
        return (
            tspOwnerFee,
            MAX_TSP_OWNER_FEE,
            totalTspOwnerFeesCollected
        );
    }

    // =============================================================================
    // FEE EXEMPTION SYSTEM FUNCTIONS (UNCHANGED)
    // =============================================================================

    /**
     * @dev Adds an address to the fee exemption list (only owner)
     * @param _address Address to exempt from creation fees
     */
    function addFeeExemptAddress(address _address) external onlyOwner whenNotPaused {
        require(_address != address(0), "Cannot exempt zero address");
        require(!feeExemptAddresses[_address], "Address already exempt");
        
        // Add to mapping
        feeExemptAddresses[_address] = true;
        
        // Add to array and track index
        feeExemptAddressIndex[_address] = feeExemptAddressesList.length;
        feeExemptAddressesList.push(_address);
        
        emit FeeExemptAddressAdded(_address, msg.sender);
    }

    /**
     * @dev Removes an address from the fee exemption list (only owner)
     * @param _address Address to remove from exemption
     */
    function removeFeeExemptAddress(address _address) external onlyOwner whenNotPaused {
        require(_address != address(0), "Cannot remove zero address");
        require(feeExemptAddresses[_address], "Address not exempt");
        
        // Remove from mapping
        feeExemptAddresses[_address] = false;
        
        // Remove from array by replacing with last element
        uint256 indexToRemove = feeExemptAddressIndex[_address];
        uint256 lastIndex = feeExemptAddressesList.length - 1;
        
        if (indexToRemove != lastIndex) {
            address lastAddress = feeExemptAddressesList[lastIndex];
            feeExemptAddressesList[indexToRemove] = lastAddress;
            feeExemptAddressIndex[lastAddress] = indexToRemove;
        }
        
        feeExemptAddressesList.pop();
        delete feeExemptAddressIndex[_address];
        
        emit FeeExemptAddressRemoved(_address, msg.sender);
    }

    /**
     * @dev Checks if an address is exempt from creation fees
     * @param _address Address to check
     * @return Whether the address is exempt from fees
     */
    function isFeeExempt(address _address) external view override returns (bool) {
        return feeExemptAddresses[_address];
    }

    /**
     * @dev Returns the number of fee-exempt addresses
     * @return Number of addresses in the exemption list
     */
    function getFeeExemptAddressesCount() external view returns (uint256) {
        return feeExemptAddressesList.length;
    }

    /**
     * @dev Returns all fee-exempt addresses
     * @return Array of all fee-exempt addresses
     */
    function getAllFeeExemptAddresses() external view returns (address[] memory) {
        return feeExemptAddressesList;
    }

    /**
     * @dev Returns a paginated list of fee-exempt addresses
     * @param _offset Starting index
     * @param _limit Maximum number of addresses to return
     * @return addresses Array of fee-exempt addresses
     * @return totalCount Total number of fee-exempt addresses
     */
    function getFeeExemptAddressesPaginated(
        uint256 _offset, 
        uint256 _limit
    ) external view returns (address[] memory addresses, uint256 totalCount) {
        totalCount = feeExemptAddressesList.length;
        
        if (_offset >= totalCount) {
            return (new address[](0), totalCount);
        }
        
        uint256 end = _offset + _limit;
        if (end > totalCount) {
            end = totalCount;
        }
        
        addresses = new address[](end - _offset);
        for (uint256 i = _offset; i < end; i++) {
            addresses[i - _offset] = feeExemptAddressesList[i];
        }
        
        return (addresses, totalCount);
    }

    // =============================================================================
    // EXISTING FUNCTIONS (UNCHANGED)
    // =============================================================================

    /**
     * @dev Sets the next version of TSP_Manager for migration purposes (only owner)
     * @param _nextVersion Address of the next TSP_Manager version (can be address(0) to reset)
     */
    function setTSPManagerNextVersion(address _nextVersion) external onlyOwner {
        address oldNextVersion = tspManagerNextVersion;
        tspManagerNextVersion = _nextVersion;
        
        emit TSPManagerNextVersionUpdated(oldNextVersion, _nextVersion);
    }

    /**
     * @dev Returns the next version of TSP_Manager for migration
     * @return The address of the next TSP_Manager version (address(0) if not set)
     */
    function getTSPManagerNextVersion() external view override returns (address) {
        return tspManagerNextVersion;
    }

    /**
     * @dev Sets the market creation fee (only owner)
     * @param _newFees New fee amount in wei
     */
    function setMarketCreationFees(uint256 _newFees) external onlyOwner {
        uint256 oldFees = marketCreationFees;
        marketCreationFees = _newFees;
        
        emit MarketCreationFeesUpdated(oldFees, _newFees);
    }

    /**
     * @dev Sets the expiry creation fee (only owner)
     * @param _newFees New fee amount in wei
     */
    function setExpiryCreationFees(uint256 _newFees) external onlyOwner {
        uint256 oldFees = expiryCreationFees;
        expiryCreationFees = _newFees;
        
        emit ExpiryCreationFeesUpdated(oldFees, _newFees);
    }

    /**
    * @dev Withdraws all collected creation fees to owner (only owner)
    */
    function withdrawCreationFees() external onlyOwner {
        uint256 totalAvailable = totalMarketCreationFeesCollected + totalExpiryCreationFeesCollected;
        require(totalAvailable > 0, "No fees available to withdraw");
        require(address(this).balance >= totalAvailable, "Insufficient contract balance");
        
        // Reset fee counters since we're withdrawing everything
        totalMarketCreationFeesCollected = 0;
        totalExpiryCreationFeesCollected = 0;
        
        // Transfer all fees to owner
        payable(owner()).transfer(totalAvailable);
        
        emit CreationFeesWithdrawn(owner(), totalAvailable);
    }

    /**
     * @dev Processes expiry creation fee payment (called by TSP_Market)
     * Updated to support fee exemption
     * @param _creator Address of the expiry creator
     * @param _expiry Address of the created expiry
     */
    function processExpiryCreationFee(address _creator, address _expiry) external override payable {
        require(registeredTSPMarkets[msg.sender], "Caller is not a registered TSP market");
        
        uint256 actualFeesPaid = 0;
        
        // Check if creator is exempt from fees
        if (feeExemptAddresses[_creator]) {
            // Creator is exempt - no fee required
            actualFeesPaid = 0;
            
            // Refund all payment since no fee is required
            if (msg.value > 0) {
                payable(_creator).transfer(msg.value);
            }
            
            emit FeeExemptionUsed(_creator, "expiry", expiryCreationFees);
        } else {
            // Creator is not exempt - fee required
            require(msg.value >= expiryCreationFees, "Insufficient expiry creation fee");
            
            actualFeesPaid = expiryCreationFees;
            
            // Track fees collected
            totalExpiryCreationFeesCollected += expiryCreationFees;
            
            // Refund excess payment if any
            if (msg.value > expiryCreationFees) {
                payable(_creator).transfer(msg.value - expiryCreationFees);
            }
        }
        
        emit ExpiryCreated(msg.sender, _expiry, _creator, actualFeesPaid);
    }

    /**
     * @dev Sets or updates the OracleData_Manager address (can be called multiple times for upgrades)
     * @param _oracleDataManager The address of the OracleData_Manager contract
     */
    function setOracleDataManager(address _oracleDataManager) external onlyOwner whenNotPaused{
        require(!oracleDataManagerLocked, "OracleData_Manager is locked and cannot be changed");
        require(_oracleDataManager != address(0), "Invalid OracleData_Manager address");
        
        address oldManager = oracleDataManager;
        oracleDataManager = _oracleDataManager;
        
        emit OracleDataManagerUpdated(oldManager, _oracleDataManager);
    }

    /**
     * @dev Locks the OracleData_Manager address permanently (can only be called once by owner)
     * Once locked, the OracleData_Manager address cannot be changed anymore
     */
    function lockOracleDataManager() external onlyOwner {
        require(!oracleDataManagerLocked, "OracleData_Manager already locked");
        require(oracleDataManager != address(0), "Cannot lock with zero address");
        
        oracleDataManagerLocked = true;
        
        emit OracleDataManagerLocked(oracleDataManager);
    }

    /**
     * @dev Updates the implementation addresses
     * @param _tspMarketImplementation New TSP_Market implementation address
     * @param _tspExpiryImplementation New TSP_Expiry implementation address
     */
    function updateImplementations(
        address _tspMarketImplementation, 
        address _tspExpiryImplementation
    ) external onlyOwner whenNotPaused {
        require(_tspMarketImplementation != address(0), "Invalid TSP_Market implementation");
        require(_tspExpiryImplementation != address(0), "Invalid TSP_Expiry implementation");
        
        tspMarketImplementation = _tspMarketImplementation;
        tspExpiryImplementation = _tspExpiryImplementation;
        
        emit ImplementationsUpdated(_tspMarketImplementation, _tspExpiryImplementation);
    }

    /**
     * @dev Adds a new supported token
     * @param _token Address of the token to add
     */
    function addToken(address _token) external onlyOwner whenNotPaused{
        require(_token != address(0), "Invalid token address");
        require(!supportedTokens[_token], "Token already supported");
        
        supportedTokens[_token] = true;
        supportedTokensList.push(_token);
        
        emit TokenAdded(_token);
    }

    /**
     * @dev Allows users to deposit tokens
     * @param _token Address of the token to deposit
     * @param _amount Amount to deposit
     */
    function deposit(address _token, uint256 _amount) external {
        require(supportedTokens[_token], "Token not supported");
        require(_amount > 0, "Amount must be greater than 0");
        
        // Transfer tokens from user to this contract
        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
        
        // Update user balance
        userBalances[msg.sender][_token] += _amount;
        
        emit TokenDeposited(msg.sender, _token, _amount);
    }

    /**
     * @dev Allows users to withdraw tokens
     * @param _token Address of the token to withdraw
     * @param _amount Amount to withdraw
     */
    function withdraw(address _token, uint256 _amount) external whenNotPaused {
        require(supportedTokens[_token], "Token not supported");
        require(_amount > 0, "Amount must be greater than 0");
        require(userBalances[msg.sender][_token] >= _amount, "Insufficient balance");
        
        // Update user balance
        userBalances[msg.sender][_token] -= _amount;
        
        // Transfer tokens to user
        IERC20(_token).safeTransfer(msg.sender, _amount);
        
        emit TokenWithdrawn(msg.sender, _token, _amount);
    }

    /**
     * @dev Allows users to withdraw all their tokens of a specific type
     * @param _token Address of the token to withdraw
     */
    function withdrawAll(address _token) external whenNotPaused {
        require(supportedTokens[_token], "Token not supported");
        uint256 amount = userBalances[msg.sender][_token];
        require(amount > 0, "No balance to withdraw");
        
        // Update user balance
        userBalances[msg.sender][_token] = 0;
        
        // Transfer tokens to user
        IERC20(_token).safeTransfer(msg.sender, amount);
        
        emit TokenWithdrawn(msg.sender, _token, amount);
    }

    /**
     * @dev Approves a TSP_Expiry to spend tokens on user's behalf
     * @param _tspExpiry Address of the TSP_Expiry
     * @param _token Address of the token
     * @param _amount Amount to approve
     */
    function approveTspExpiry(address _tspExpiry, address _token, uint256 _amount) external {
        require(supportedTokens[_token], "Token not supported");
        require(_amount > 0, "Amount must be greater than 0");
        require(userBalances[msg.sender][_token] >= _amount, "Insufficient balance");
        
        // Update approval
        tspExpiryApprovals[msg.sender][_tspExpiry][_token] = _amount;
        
        emit TSPExpiryApproved(msg.sender, _tspExpiry, _token, _amount);
    }

    /**
     * @dev Updates user balances when a user makes a prediction
     * @param _user Address of the user
     * @param _token Address of the token
     * @param _amount Amount to deduct
     */
    function updateUserBalanceForPrediction(
        address _user, 
        address _token, 
        uint256 _amount
    ) external override {
        require(registeredTSPMarkets[ITSP_Expiry(msg.sender).tspMarket()], "Caller is not from a registered TSP market");
        require(ITSP_Market(ITSP_Expiry(msg.sender).tspMarket()).isPendingExpiry(msg.sender), "Expiry not in pending state");
        require(tspExpiryApprovals[_user][msg.sender][_token] >= _amount, "Insufficient approval");
        require(userBalances[_user][_token] >= _amount, "Insufficient balance");
        
        // Update user balance and approval
        userBalances[_user][_token] -= _amount;
        tspExpiryApprovals[_user][msg.sender][_token] -= _amount;
    }

    /**
     * @dev Updates user balances when a user wins or receives a refund
     * @param _user Address of the user
     * @param _token Address of the token
     * @param _amount Amount to add
     */
    function updateUserBalanceForReward(
        address _user, 
        address _token, 
        uint256 _amount
    ) external override {
        require(registeredTSPMarkets[ITSP_Expiry(msg.sender).tspMarket()], "Caller is not from a registered TSP market");
        require(
            ITSP_Market(ITSP_Expiry(msg.sender).tspMarket()).isPendingExpiry(msg.sender) ||
            ITSP_Market(ITSP_Expiry(msg.sender).tspMarket()).isClosedExpiry(msg.sender),
            "Caller is not from a registered Expiry in pending or closed state"
        );

        // Update user balance
        userBalances[_user][_token] += _amount;
    }

    // /**
    //  * @dev Updates user balances when a TSP_Market Owner withdrawFees (UPDATED - now calls processTspOwnerFee)
    //  * @param _user Address of the TSP_Market Owner 
    //  * @param _token Address of the token
    //  * @param _amount Amount to add
    //  */
    // function updateUserBalanceForFeeReward(
    //     address _user, 
    //     address _token, 
    //     uint256 _amount
    // ) external override {
    //     require(registeredTSPMarkets[msg.sender], "Caller is not from a registered TSP market");
        
    //     // This function is now replaced by processTspOwnerFee for new behavior
    //     // But we keep it for backward compatibility (direct balance update)
    //     userBalances[_user][_token] += _amount;
    // }

    /**
     * @dev Creates a new TSP_Market.
     * Oracle caller is validated and resolvedValueProvider derived automatically from IOracleCaller.oracleName().
     * @param _params Parameters for creating the new TSP_Market
     * @return tspMarket Address of the newly created TSP_Market
     */
    function createTSPMarket(TSPMarketParams memory _params) external payable whenNotPaused returns (address tspMarket) {
        require(supportedTokens[_params.tsToken], "Token not supported");
        require(oracleDataManager != address(0), "OracleData_Manager not set");
        require(_params.oracleData.length > 0, "Oracle data cannot be empty");
        require(bytes(_params.marketName).length > 0, "Market name cannot be empty");
        require(bytes(_params.unitSymbol).length > 0, "Unit symbol cannot be empty");
        require(_params.oracleRequesterReward <=  MAX_ORACLE_REQUESTER_REWARD && _params.oracleRequesterReward > 0, "Oracle requester reward exceeds maximum or not greater than 0"); 
        require(_params.resolveCallerReward <= MAX_RESOLVE_CALLER_REWARD, "Resolve caller reward exceeds maximum");
        require(_params.maxUpdatePenalty > 0, "Max update penalty must be greater than 0");
        require(_params.maxUpdatePenalty <= 10000, "Max update penalty cannot exceed 100%");
        require(_params.defaultUpdatePenalty > 0, "Default update penalty must be greater than 0");
        require(_params.defaultUpdatePenalty <= _params.maxUpdatePenalty, "Default penalty must be <= max penalty");

        // --- Oracle Caller Validation ---
        // Decode oracleData to resolve which OracleCaller will be used for this market.
        // Fail fast here - no orphan markets with invalid oracle configuration.
        TSPOracleData memory oracleDataStruct = abi.decode(_params.oracleData, (TSPOracleData));

        address resolvedCallerAddr = oracleDataStruct.oracleCallerAddress != address(0)
            ? oracleDataStruct.oracleCallerAddress
            : IOracleData_Manager(oracleDataManager).defaultOracleCallerAddress();

        require(resolvedCallerAddr != address(0), "No OracleCaller configured - set oracleCallerAddress or configure a default");

        (bool registered, bool active) = IOracleData_Manager(oracleDataManager).getCallerStatus(resolvedCallerAddr);
        require(registered, "OracleCaller not registered in OracleData_Manager");
        require(active, "OracleCaller is deactivated - cannot create market");

        // Derive resolvedValueProvider automatically from the OracleCaller's name
        string memory resolvedValueProvider = IOracleCaller(resolvedCallerAddr).oracleName();
        // ---
        
        uint256 actualFeesPaid = 0;
        
        // Check if creator is exempt from fees
        if (feeExemptAddresses[msg.sender]) {
            // Creator is exempt - no fee required
            actualFeesPaid = 0;
            
            // Refund all payment since no fee is required
            if (msg.value > 0) {
                payable(msg.sender).transfer(msg.value);
            }
            
            emit FeeExemptionUsed(msg.sender, "market", marketCreationFees);
        } else {
            // Creator is not exempt - fee required
            require(msg.value >= marketCreationFees, "Insufficient market creation fee");
            
            actualFeesPaid = marketCreationFees;
            
            // Track fees collected
            totalMarketCreationFeesCollected += marketCreationFees;
            
            // Refund excess payment if any
            if (msg.value > marketCreationFees) {
                payable(msg.sender).transfer(msg.value - marketCreationFees);
            }
        }
        
        // Clone the TSP_Market implementation
        tspMarket = tspMarketImplementation.clone();
        
        // IMPORTANT: Register market with OracleData_Manager BEFORE initialization
        // because initialize() calls isSupportedMarket() to validate registration
        IOracleData_Manager(oracleDataManager).addSupportedMarket(tspMarket);
        
        // Create initialization parameters for TSP_Market
        ITSP_Market.TSPMarketInitParams memory initParams = ITSP_Market.TSPMarketInitParams({
            oracleData: _params.oracleData,  // TSP_Market stores oracle data
            oracleDataManager: oracleDataManager,  // Pass current oracleDataManager to market
            tsType: _params.tsType,
            tsToken: _params.tsToken,
            minStake: _params.minStake,
            multiplier: _params.multiplier,
            timeCost: _params.timeCost,
            alpha: _params.alpha,
            tsMin: _params.tsMin,
            tsMax: _params.tsMax,
            forecastingPeriod: _params.forecastingPeriod,
            observationPeriod: _params.observationPeriod,
            resolutionPeriod: _params.resolutionPeriod,
            sigma: _params.sigma,
            carryNoticePeriod: _params.carryNoticePeriod,
            taxFee: _params.taxFee,                         // value basis points (e.g., "500 = 5.00%")
            creationFeesPaid: actualFeesPaid,               // Pass actual fees paid (0 if exempt)
            resolvedValueProvider: resolvedValueProvider,   // Derived from IOracleCaller.oracleName()
            unitSymbol: _params.unitSymbol,                 // Pass unit symbol
            isDated: _params.isDated,                       // Pass isDated to market initialization
            owner: msg.sender,
            tspManager: address(this),
            tspExpiryImplementation: tspExpiryImplementation,
            marketName: _params.marketName,
            marketDescription: _params.marketDescription,
            oracleRequesterReward: _params.oracleRequesterReward,
            resolveCallerReward: _params.resolveCallerReward,
            maxUpdatePenalty: _params.maxUpdatePenalty,
            defaultUpdatePenalty: _params.defaultUpdatePenalty
        });
        
        // Initialize the TSP_Market (now that it's registered in OracleData_Manager)
        ITSP_Market(tspMarket).initialize(initParams);
        
        // Register the new TSP_Market in TSP_Manager
        registeredTSPMarkets[tspMarket] = true;
        tspMarketsList.push(tspMarket);
        
        emit TSPMarketCreated(tspMarket, msg.sender, _params.marketName, oracleDataManager, actualFeesPaid);
        
        return tspMarket;
    }

    /**
     * @dev Returns whether the OracleData_Manager is locked
     * @return Whether the OracleData_Manager address is locked
     */
    function isOracleDataManagerLocked() external view returns (bool) {
        return oracleDataManagerLocked;
    }

    /**
     * @dev Returns the number of supported tokens
     * @return Number of supported tokens
     */
    function getSupportedTokensCount() external view returns (uint256) {
        return supportedTokensList.length;
    }

    /**
     * @dev Returns the list of supported tokens
     * @return Array of supported token addresses
    */
    function getAllSupportedTokens() public view returns (address[] memory) {
        return supportedTokensList;
    }

    /**
     * @dev Returns the number of TSP_Market instances
     * @return Number of TSP_Market instances
     */
    function getTSPMarketsCount() external view returns (uint256) {
        return tspMarketsList.length;
    }

    /**
     * @dev Returns the balance of a user for a specific token
     * @param _user Address of the user
     * @param _token Address of the token
     * @return Balance of the user for the token
     */
    function getUserBalance(address _user, address _token) external view returns (uint256) {
        return userBalances[_user][_token];
    }

    /**
     * @dev Returns the approval amount of a user for a specific TSP_Expiry and token
     * @param _user Address of the user
     * @param _tspExpiry Address of the TSP_Expiry
     * @param _token Address of the token
     * @return Approval amount
     */
    function getTspExpiryApproval(address _user, address _tspExpiry, address _token) external view returns (uint256) {
        return tspExpiryApprovals[_user][_tspExpiry][_token];
    }

    /**
     * @dev Returns the total contract balance available for fee withdrawal
     * @return Total ETH balance of the contract
     */
    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /**
     * @dev Returns fee information including exemption stats
     * @return marketFees Current market creation fee
     * @return expiryFees Current expiry creation fee
     * @return totalMarketFees Total market fees collected
     * @return totalExpiryFees Total expiry fees collected
     */
    function getFeeInfo() external view override returns (
        uint256 marketFees,
        uint256 expiryFees,
        uint256 totalMarketFees,
        uint256 totalExpiryFees
    ) {
        return (
            marketCreationFees,
            expiryCreationFees,
            totalMarketCreationFeesCollected,
            totalExpiryCreationFeesCollected
        );
    }

    /**
     * @dev Returns comprehensive fee information including exemption details, TSP owner fee, and verification stats
     * @return marketFees Current market creation fee
     * @return expiryFees Current expiry creation fee
     * @return totalMarketFees Total market fees collected
     * @return totalExpiryFees Total expiry fees collected
     * @return exemptAddressesCount Number of fee-exempt addresses
     * @return contractBalance Current contract balance available for withdrawal
     * @return tspOwnerFeePercentage Current TSP owner fee percentage
     * @return totalTspOwnerFees Total TSP owner fees collected from market withdrawals
     */
    function getComprehensiveFeeInfo() external view returns (
        uint256 marketFees,
        uint256 expiryFees,
        uint256 totalMarketFees,
        uint256 totalExpiryFees,
        uint256 exemptAddressesCount,
        uint256 contractBalance,
        uint256 tspOwnerFeePercentage,
        uint256 totalTspOwnerFees
    ) {
        return (
            marketCreationFees,
            expiryCreationFees,
            totalMarketCreationFeesCollected,
            totalExpiryCreationFeesCollected,
            feeExemptAddressesList.length,
            address(this).balance,
            tspOwnerFee,
            totalTspOwnerFeesCollected
        );
    }

    /**
     * @dev Fallback function to receive ETH
     */
    receive() external payable {
        // Allow contract to receive ETH
    }



    // =============================================================================
    // PAUSABLE FUNCTIONS - ADD THESE NEW FUNCTIONS
    // =============================================================================

    /**
     * @dev Pauses all pausable functions in the contract
     * Only the owner can call this function
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev Unpauses all pausable functions in the contract
     * Only the owner can call this function
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Check if the contract is currently paused
     * @return Whether the contract is paused
     */
    function isPaused() external view returns (bool) {
        return paused();
    }
}

