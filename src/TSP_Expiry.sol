// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "./interfaces.sol";
import "./MathUtils.sol";

/**
 * @title TSP_Expiry
 * @dev Contract that manages predictions for a specific expiry date
 * Updated to store creation fees paid, resolvedValueProvider, unitSymbol, and oracle requester rewards
 */
contract TSP_Expiry is ITSP_Expiry {
    using MathUtils for uint256;

    // Maximum number of predictions supported per expiry
    uint256 public constant MAX_PREDICTIONS = 1000;

    // Status of the expiry
    Status public status;
    
    // Expiry parameters
    uint256 public expiryTime;
    uint256 public minStake;
    uint256 public multiplier;
    int256 public tsMin;
    int256 public tsMax;
    uint256 public sigma;
    uint256 public taxFee;       // value basis points (e.g., "500 = 5.00%")
    uint256 public timeCost;     // Time cost rate r for adjustment factor
    uint256 public alpha;        // Alpha factor to overweight winning predictions 

    // Update penalty rate for decreasing predictions (1.25%)
    uint256 public updatePenalty; // Update penalty for this expiry (in basis points) // basis points (125/10000 = 0.0125)  

    uint256 public oracleRequesterReward;// Oracle requester reward percentage (in basis points)
    uint256 public resolveCallerReward;  // Resolve caller reward percentage (in basis points)

    // Post-resolve state: saved during resolve(), consumed by claimReward()
    uint256 public winnerRewardPool;     // Total pool available for winner claims
    uint256 public totalAdjustedStake;   // Sum of all winners' adjusted stakes (denominator for shares)

    // Post-cancel state: saved during cancel(), consumed by withdrawStake()
    uint256 public stakeRefundRate;      // Basis points forecasters get back (10000 if no oracle requester, else 10000 - oracleRequesterReward)
    uint256 public observationPeriod;
    uint256 public resolutionPeriod;
    
    // Time parameters
    uint256 public creationTime;
    uint256 public startTime;
    uint256 public timeoutTime;
    uint256 public endTime;
    
    // Amount parameters
    uint256 public carriedAmount;
    uint256 public stakePool;
    uint256 public feeAmount;
    uint256 public creationFeesPaid; // Store creation fees paid for this expiry
    
    // Resolved value provider (inherited from market)
    string public resolvedValueProvider;
    
    // Unit symbol (inherited from market)
    string public unitSymbol;

    // Expiry name
    string public expiryName; 

    // isDated flag - inherited from market, set once at creation, not updatable
    bool public isDated;

    // Expiry-specific oracle arguments
    string[] public expiryArgs;
    
    // Reference addresses
    address public owner;
    address public override tspMarket;
    address public tspManager;
    address public tsToken;

    // Oracle requester tracking
    address public oracleRequester;  // Address of user who called requestResolvedValue
    
    // Time-series type
    uint8 public tsType;
    
    // Struct for prediction
    // Storage layout (5 slots):
    //   slot 0: forecaster (20B) + timeToExpiryYears uint96 (12B)  = 32B
    //   slot 1: stakedAmount uint256                                = 32B
    //   slot 2: predictedValue int256                               = 32B
    //   slot 3: rewardAmount uint256                                = 32B
    //   slot 4: timestamp uint96 (12B) + claimed bool (1B) + stakeWithdrawn bool (1B) = 14B
    struct Prediction {
        address forecaster;           // slot 0: 20 bytes
        uint96  timeToExpiryYears;    // slot 0: 12 bytes — pre-computed at predict(), packed with forecaster
        uint256 stakedAmount;         // slot 1
        int256  predictedValue;       // slot 2
        uint256 rewardAmount;         // slot 3 — set after claimReward()
        uint96  timestamp;            // slot 4: 12 bytes — packed with bools
        bool    claimed;              // slot 4: set after claimReward()
        bool    stakeWithdrawn;       // slot 4: set after withdrawStake()
    }
    
    // Prediction book (array of predictions)
    Prediction[] public predictionBook;
    
    // Resolved value and timestamp
    int256 public resolvedValue;
    uint256 public resolvedTimestamp;
    uint256 public resolvedValueTimestamp;  // Timestamp from the oracle data itself
    
    // Events
    event PredictionMade(address indexed forecaster, uint256 indexed predictionIndex, uint256 stakedAmount, int256 predictedValue);
    event PredictionUpdated(address indexed forecaster, address indexed expiry, uint256 indexed predictionIndex, uint256 decreasedAmount, uint256 penaltyAmount, uint256 returnedAmount, uint256 newStakedAmount, bool wasFullWithdrawal);
    event ExpiryResolved(address indexed expiry, int256 resolvedValue, uint256 timestamp);
    event ExpiryCancelled(uint256 timestamp);
    event ExpiryFailed(uint256 timestamp);
    event ExpiryResolutionTriggered(address indexed market, address indexed expiry);
    event OracleRequestCancelled(address indexed caller, uint256 timestamp);
    event OracleRequestInitiated(address indexed caller, address indexed market, address indexed expiry, uint256 timestamp);

    // NEW: Oracle requester reward events
    event OracleRequesterRewarded(address indexed expiry, address indexed oracleRequester, uint256 rewardAmount);

    // NEW: Resolve caller reward event
    event ResolveCallerRewarded(address indexed expiry, address indexed resolveCaller, uint256 rewardAmount);

    // NEW: Winner claim event
    event RewardClaimed(address indexed forecaster, uint256 indexed predictionIndex, uint256 rewardAmount);

    // NEW: Stake withdrawal event (after cancellation)
    event StakeWithdrawn(address indexed forecaster, uint256 indexed predictionIndex, uint256 refundAmount);

    // Modifier to ensure caller is owner
    modifier onlyOwner() {
        require(msg.sender == owner, "Caller is not the owner");
        _;
    }

    // Modifier to ensure caller is TSP_Market
    modifier onlyTSPMarket() {
        require(msg.sender == tspMarket, "Caller is not the TSP_Market");
        _;
    }

    /**
     * @dev Initializes the contract
     * @param params Initialization parameters (now includes creationFeesPaid, resolvedValueProvider, and unitSymbol)
     */
    function initialize(TSPExpiryInitParams calldata params) external override {
        require(tspMarket == address(0), "Already initialized");
        require(msg.sender == params.tspMarket, "Only TSP_Market can initialize");
        require(params.tspMarket != address(0), "Invalid TSP_Market address");
        require(params.tspManager != address(0), "Invalid TSP_Manager address");
        require(params.tsToken != address(0), "Invalid token address");
        require(params.owner != address(0), "Invalid owner address");
        require(params.expiryTime > block.timestamp, "Expiry time must be in the future");
        require(params.startTime < params.timeoutTime, "Start time must be before timeout time");
        require(params.timeoutTime < params.expiryTime, "Timeout time must be before expiry time");
        require(params.tsMin < params.tsMax, "Min must be less than max");
        require(params.multiplier > 0, "Multiplier must be greater than 0");
        require(params.taxFee <= 10000, "Tax fee must be <= 100%");
        require(params.tsType <= 1, "Invalid time-series type");
        require(bytes(params.resolvedValueProvider).length > 0, "Resolved value provider cannot be empty");
        require(bytes(params.unitSymbol).length > 0, "Unit symbol cannot be empty");

        //  Extreme values near int256 limits
        require(params.tsMin > type(int256).min, "tsMin too negative");
        require(params.tsMax < type(int256).max, "tsMax too positive");
        
        // Ensure alpha is within the valid range: 0 <= alpha < 2/m^2
        uint256 m_squared = (params.multiplier * params.multiplier) / MathUtils.SCALE;
        require(params.alpha < (2 * MathUtils.SCALE * MathUtils.SCALE) / m_squared, "Alpha too large");

        require(params.updatePenalty > 0, "Update penalty must be greater than 0");
        require(params.updatePenalty <= 10000, "Update penalty cannot exceed 100%");

        // Initialize variables
        expiryTime = params.expiryTime;
        minStake = params.minStake;
        multiplier = params.multiplier;
        tsMin = params.tsMin;
        tsMax = params.tsMax;
        sigma = params.sigma;
        taxFee = params.taxFee;
        timeCost = params.timeCost;
        alpha = params.alpha;
        oracleRequesterReward = params.oracleRequesterReward; // Store oracle requester reward in basis points
        resolveCallerReward = params.resolveCallerReward;     // Store resolve caller reward in basis points
        observationPeriod = params.observationPeriod;
        resolutionPeriod = params.resolutionPeriod;
        startTime = params.startTime;
        timeoutTime = params.timeoutTime;
        carriedAmount = params.carriedAmount;
        creationFeesPaid = params.creationFeesPaid; // Store creation fees paid
        
        // Initialize resolvedValueProvider and unitSymbol from parameters
        resolvedValueProvider = params.resolvedValueProvider;
        unitSymbol = params.unitSymbol;

        // Store isDated from parameters (inherited from market, not updatable)
        isDated = params.isDated;
        
        owner = params.owner;
        tspMarket = params.tspMarket;
        tspManager = params.tspManager;
        tsToken = params.tsToken;
        tsType = params.tsType;
        
        creationTime = block.timestamp;
        status = Status.PENDING;

        // Initialize oracle requester to zero address
        oracleRequester = address(0);

        // Add to initialization
        updatePenalty = params.updatePenalty;

        // Store expiry-specific oracle arguments
        //expiryArgs = params.expiryArgs;
        for (uint256 i = 0; i < params.expiryArgs.length; i++) {
            expiryArgs.push(params.expiryArgs[i]);
        }

        // Store expiry name
        expiryName = params.expiryName; 
    }

    /**
     * @dev Makes a prediction
     * @param _predictedValue Predicted value
     * @param _stakedAmount Staked amount
     */
    function predict(int256 _predictedValue, uint256 _stakedAmount) external override {
        require(predictionBook.length < MAX_PREDICTIONS, "Prediction cap reached");
        require(status == Status.PENDING, "Expiry is not in pending state");
        require(block.timestamp >= startTime, "Forecasting period has not started");
        require(block.timestamp < timeoutTime, "Forecasting period has ended");
        require(_stakedAmount >= minStake, "Staked amount is less than minimum");
        require(_predictedValue >= tsMin && _predictedValue <= tsMax, "Predicted value out of range");
        
        // Update TSP_Manager balances
        ITSP_Manager(tspManager).updateUserBalanceForPrediction(
            msg.sender, 
            tsToken, 
            _stakedAmount
        );
        
        // Pre-compute timeToExpiryYears once at prediction time.
        // Packed with forecaster in slot 0 - no extra SSTORE cost.
        // Eliminates MathUtils.div in _isWinner for every prediction checked during resolve().
        uint96 tteYears = uint96(
            MathUtils.div((expiryTime - block.timestamp) * MathUtils.SCALE, 31536000 * MathUtils.SCALE)
        );

        // Add prediction to prediction book
        predictionBook.push(Prediction({
            forecaster:        msg.sender,
            timeToExpiryYears: tteYears,
            stakedAmount:      _stakedAmount,
            predictedValue:    _predictedValue,
            rewardAmount:      0,
            timestamp:         uint96(block.timestamp),
            claimed:           false,
            stakeWithdrawn:    false
        }));
        
        // Update stake pool
        stakePool += _stakedAmount;

        // Get the index of the newly created prediction
        uint256 predictionIndex = predictionBook.length - 1;
        
        emit PredictionMade(msg.sender, predictionIndex, _stakedAmount, _predictedValue);
    }


    /**
    * @dev Allows forecaster to decrease their staked amount with penalty
    * @param _predictionIndex Index of prediction in predictionBook array
    * @param _decreaseAmount Amount to decrease from stake (ignored if _withdrawAll is true)
    * @param _withdrawAll If true, withdraws entire staked amount
    */
    function updatePrediction(uint256 _predictionIndex, uint256 _decreaseAmount, bool _withdrawAll) external {
        // Validation checks
        require(_predictionIndex < predictionBook.length, "Invalid prediction index");
        require(status == Status.PENDING, "Expiry is not in pending state");
        require(block.timestamp >= startTime, "Forecasting period has not started");
        require(block.timestamp < timeoutTime, "Forecasting period has ended");
        
        // Get prediction and validate ownership
        Prediction storage prediction = predictionBook[_predictionIndex];
        require(msg.sender == prediction.forecaster, "Only prediction owner can update");
        require(prediction.stakedAmount > 0, "No stake to withdraw");
        
        // Determine actual decrease amount
        uint256 actualDecreaseAmount;
        if (_withdrawAll) {
            // Full withdrawal - take entire stake
            actualDecreaseAmount = prediction.stakedAmount;
        } else {
            // Partial withdrawal - validate amount
            require(_decreaseAmount > 0, "Decrease amount must be greater than 0");
            require(
                _decreaseAmount <= prediction.stakedAmount, 
                "Decrease amount exceeds staked amount"
            );
            actualDecreaseAmount = _decreaseAmount;
        }
        
        // Calculate penalty and return amount
        uint256 penaltyAmount = (actualDecreaseAmount * updatePenalty) / 10000;
        uint256 returnAmount = actualDecreaseAmount - penaltyAmount;
        
        // Calculate new staked amount
        uint256 newStakedAmount = prediction.stakedAmount - actualDecreaseAmount;

        // Verify remaining stake meets minimum requirement for partial withdrawals
        if (!_withdrawAll) {
            require(newStakedAmount >= minStake, "Remaining stake must be >= minStake");
        }
        
        // Update prediction state
        prediction.stakedAmount = newStakedAmount;
        
        // Update global state
        stakePool -= actualDecreaseAmount;
        carriedAmount += penaltyAmount;
        
        // Return funds to forecaster (minus penalty)
        if (returnAmount > 0) {
            ITSP_Manager(tspManager).updateUserBalanceForReward(
                msg.sender,
                tsToken,
                returnAmount
            );
        }
        
        // Emit event
        emit PredictionUpdated(msg.sender, address(this), _predictionIndex, actualDecreaseAmount, penaltyAmount, returnAmount, newStakedAmount,_withdrawAll);
    }

    /**
     * @dev Resolves the expiry
     */
    function resolve() external override {
        require(status == Status.PENDING, "Expiry is not in pending state");
        require(block.timestamp >= expiryTime, "Expiry time has not passed");
        require(block.timestamp < expiryTime + resolutionPeriod, "Resolution period has ended");
        require(predictionBook.length > 0, "No predictions made");

        // Ensure expiry value is resolved in OracleData_Manager (Step 3)
        _ensureExpiryResolved();

        // Get and process the time-series value from the oracle
        _setResolvedValue();
        
        // Calculate fees (tax) from the total staked amount
        uint256 totalFees = (stakePool * taxFee) / 10000;
        
        // Process winners: pay immediate rewards, save winner state for claimReward()
        _processWinnersAndDistributeRewards(totalFees, msg.sender);

        // Update status and time
        status = Status.RESOLVED;
        endTime = block.timestamp;
        
        // Update TSP_Market with collected fees (always full taxFee - no resolver exemption)
        ITSP_Market(tspMarket).onExpiryResolved(totalFees);
        
        emit ExpiryResolved(address(this), resolvedValue, block.timestamp);
    }

    /**
    * @dev Requests resolved value from OracleData_Manager (Step 1: NEW FUNCTION)
    * This function allows anyone to trigger the oracle request for this expiry
    * Only callable when expiry is in RESOLVING stage
    * @dev Now payable to cover Hyperlane dispatch fees
    */
    function requestResolvedValue() external payable override {
        require(status == Status.PENDING, "Expiry is not in pending state");
        require(getStage() == Stage.RESOLVING, "Expiry must be in RESOLVING stage");
        require(oracleRequester == address(0), "Oracle request already exists"); 
        
        // Get OracleData_Manager from TSP_Market
        address oracleDataManager = ITSP_Market(tspMarket).oracleDataManager();
        require(oracleDataManager != address(0), "OracleData_Manager not set");
        
        // Call OracleData_Manager to request resolved value, passing ETH for fees
        // Pass msg.sender as requester so OracleCaller can attribute the fee correctly.
        // At ODM level msg.sender is this expiry contract, not the original user,
        // so the requester must be forwarded explicitly.
        IOracleData_Manager(oracleDataManager).requestResolvedValue{value: msg.value}(tspMarket, address(this), expiryArgs, msg.sender);

        // Save the address of who requested the oracle value
        oracleRequester = msg.sender;
        
        emit OracleRequestInitiated(msg.sender, tspMarket, address(this), block.timestamp);
    }

    /**
     * @dev Ensures the expiry value is resolved in OracleData_Manager (Step 3)
     */
    function _ensureExpiryResolved() private {
        // Get oracleDataManager from TSP_Market (not TSP_Manager)
        address oracleDataManager = ITSP_Market(tspMarket).oracleDataManager();
        require(oracleDataManager != address(0), "OracleData_Manager not set");
        
        // This will revert if value is not ready with message "Value not ready - call requestResolvedValue first"
        IOracleData_Manager(oracleDataManager).resolveExpiryValue(tspMarket, address(this));
        
        emit ExpiryResolutionTriggered(tspMarket, address(this));
    }
    
    /**
     * @dev Sets the resolved value from the OracleData_Manager with clipping
     */
    function _setResolvedValue() private {
        // Get the resolved value from the OracleData_Manager via TSP_Market
        address oracleDataManager = ITSP_Market(tspMarket).oracleDataManager();        
        // Get resolved value with both timestamps
        (int256 tsValue, uint256 timestamp, uint256 valueTimestamp) = IOracleData_Manager(oracleDataManager).getResolvedValueWithTimestamps(tspMarket, address(this));
        
        // Store the timestamps
        resolvedTimestamp = timestamp;
        resolvedValueTimestamp = valueTimestamp; // Timestamp from the oracle data itself
        
        // Clip the value to the min/max range as specified
        if (tsValue < tsMin) {
            resolvedValue = tsMin;
        } else if (tsValue > tsMax) {
            resolvedValue = tsMax;
        } else {
            resolvedValue = tsValue;
        }
    }

    /**
    * @dev Cancels oracle request (Step 4: NEW FUNCTION)
    * If caller is the oracleDataManager, bypass timeout check (checkTimeout = false)
    * Otherwise, enforce timeout check (checkTimeout = true)
    */
    function cancelOracleRequest() external override {
        require(status == Status.PENDING, "Expiry is not in pending state");
        require(getStage() == Stage.RESOLVING, "Expiry must be in RESOLVING stage");
        require(oracleRequester != address(0), "No pending oracle request");
        
        // Get OracleData_Manager from TSP_Market
        address oracleDataManager = ITSP_Market(tspMarket).oracleDataManager();
        require(oracleDataManager != address(0), "OracleData_Manager not set");
        
        // Determine checkTimeout based on caller
        // If caller is oracleDataManager, set checkTimeout to false (bypass timeout)
        // Otherwise, set checkTimeout to true (enforce timeout)
        bool checkTimeout = (msg.sender != oracleDataManager);
        
        // Call OracleData_Manager to cancel the request with appropriate checkTimeout
        IOracleData_Manager(oracleDataManager).cancelRequest(tspMarket, address(this), checkTimeout);

        // Reset the oracle requester since request was cancelled
        oracleRequester = address(0);
        
        emit OracleRequestCancelled(msg.sender, block.timestamp);
    }

    /**
     * @dev Clears oracle requester when OracleCaller reports a failure (called by ODM).
     */
    function notifyOracleCallerRequestFailed() external override {
        // Get OracleData_Manager from TSP_Market
        address oracleDataManager = ITSP_Market(tspMarket).oracleDataManager();
        require(oracleDataManager != address(0), "OracleData_Manager not set");
        require(msg.sender == oracleDataManager, "Caller is not OracleData_Manager");

        // If already cleared, exit silently
        if (oracleRequester == address(0)) {
            return;
        }

        oracleRequester = address(0);
        emit OracleRequestCancelled(msg.sender, block.timestamp);
    }

    /**
     * @dev Cancels the expiry when not resolved before the end of the resolution period.
     * Pays oracle requester immediately from the total pool (stakePool + carriedAmount).
     * Remaining carry goes back to the carry pool.
     * Stake refunds are NOT processed here - each forecaster must call withdrawStake().
     */
    function cancel() external override {
        require(status == Status.PENDING, "Expiry is not in pending state");
        require(
            block.timestamp >= expiryTime + resolutionPeriod,
            "Can only cancel after resolution period ends"
        );
        require(predictionBook.length > 0, "No predictions made. You can Close the expiry.");

        // Update status and time
        status = Status.CANCELLED;
        endTime = block.timestamp;

        // Total pool: staked funds + carried amount
        uint256 totalPool = stakePool + carriedAmount;

        // Effective oracle rate: only apply if an oracle requester actually exists.
        // If oracleRequester == address(0) (no request made, or request was cancelled/failed),
        // no reward was earned - forecasters get full refund and full carry returns to pool.
        uint256 effectiveOracleRate = (oracleRequester != address(0)) ? oracleRequesterReward : 0;

        // Save refund rate for use in withdrawStake() - decided once here, not recomputed per claim
        stakeRefundRate = 10000 - effectiveOracleRate;

        // Oracle requester takes their percentage of the total pool (0 if no requester)
        uint256 oracleRequesterRewardAmount = (totalPool * effectiveOracleRate) / 10000;
        _payOracleRequesterReward(oracleRequesterRewardAmount);

        // Remaining carried amount (net of oracle requester's share of it) goes back to carry pool
        // The stakePool remainder stays in the contract for forecasters to pull via withdrawStake()
        uint256 carryRemainder = carriedAmount - (carriedAmount * effectiveOracleRate) / 10000;
        ITSP_Market(tspMarket).onExpiryCancelled(carryRemainder);

        emit ExpiryCancelled(block.timestamp);
    }

    /**
     * @dev Withdraws a forecaster's staked amount (minus oracle requester's share) after cancellation.
     * Must be called by the prediction's forecaster after the expiry is CANCELLED.
     * Each prediction can only be withdrawn once. Gas cost is O(1) - no loops.
     * @param _predictionIndex Index of the prediction in predictionBook
     */
    function withdrawStake(uint256 _predictionIndex) external {
        require(status == Status.CANCELLED, "Expiry not cancelled");
        require(_predictionIndex < predictionBook.length, "Invalid prediction index");

        Prediction storage prediction = predictionBook[_predictionIndex];

        require(msg.sender == prediction.forecaster, "Not prediction owner");
        require(prediction.stakedAmount > 0, "No stake to withdraw");
        require(!prediction.stakeWithdrawn, "Already withdrawn");

        // Mark as withdrawn before external call (re-entrancy guard pattern)
        prediction.stakeWithdrawn = true;

        // Refund = stakedAmount * stakeRefundRate (set during cancel() - accounts for whether oracle requester existed)
        uint256 refundAmount = (prediction.stakedAmount * stakeRefundRate) / 10000;

        ITSP_Manager(tspManager).updateUserBalanceForReward(
            msg.sender,
            tsToken,
            refundAmount
        );

        emit StakeWithdrawn(msg.sender, _predictionIndex, refundAmount);
    }

    /**
     * @dev Closes the expiry if no predictions were made
     */
    function close() external override {
        require(status == Status.PENDING, "Expiry is not in pending state");
        require(block.timestamp >= timeoutTime, "Forecasting period has not ended");
        require(predictionBook.length == 0, "Predictions have been made");
        
        // Update status and time
        status = Status.FAILED;
        endTime = block.timestamp;
        
        // Transfer carried amount to carry pool
        ITSP_Market(tspMarket).onExpiryFailed(carriedAmount);
        
        emit ExpiryFailed(block.timestamp);
    }

    /**
     * @dev Returns the current stage of the expiry
     * @return Stage of the expiry
     */
    function getStage() public view override returns (Stage) {
        if (status != Status.PENDING) {
            return Stage.CLOSED;
        }
        
        if (block.timestamp < startTime) {
            return Stage.NOT_STARTED;
        }
        
        if (block.timestamp < timeoutTime) {
            return Stage.FORECASTING;
        }

        // Check for CLOSING stage - when timeout passed and no predictions made
        if (( block.timestamp >= timeoutTime) && predictionBook.length == 0) {
            return Stage.CLOSING;
        }
        
        if (block.timestamp < expiryTime) {
            return Stage.OBSERVING;
        }
        
        if (block.timestamp < expiryTime + resolutionPeriod) {
            return Stage.RESOLVING;
        }
        
        return Stage.CANCELLING;
    }
    
    /**
     * @dev Returns the number of predictions
     * @return Number of predictions
     */
    function getPredictionCount() external view returns (uint256) {
        return predictionBook.length;
    }

    // =============================================================================
    // NEW: ORACLE REQUESTER REWARD FUNCTIONS
    // =============================================================================

    /**
     * @dev Pays the oracle requester reward by updating their balance in TSP_Manager
     * @param rewardAmount Amount to pay to the oracle requester
     */
    function _payOracleRequesterReward(uint256 rewardAmount) private {
        if (oracleRequester != address(0) && rewardAmount > 0) {
            ITSP_Manager(tspManager).updateUserBalanceForReward(
                oracleRequester,
                tsToken,
                rewardAmount
            );
            
            emit OracleRequesterRewarded(address(this), oracleRequester, rewardAmount);
        }
    }

    /**
     * @dev Pays the resolve caller reward by updating their balance in TSP_Manager
     * @param resolveCaller Address that called resolve()
     * @param rewardAmount Amount to pay to the resolve caller
     */
    function _payResolveCallerReward(address resolveCaller, uint256 rewardAmount) private {
        if (resolveCaller != address(0) && rewardAmount > 0) {
            ITSP_Manager(tspManager).updateUserBalanceForReward(
                resolveCaller,
                tsToken,
                rewardAmount
            );

            emit ResolveCallerRewarded(address(this), resolveCaller, rewardAmount);
        }
    }
    
    /**
     * @dev Calculates the prediction error based on time-series type
     * @param predictedValue The predicted value
     * @param _tsType Cached tsType (avoids repeated SLOAD in loop)
     * @param _resolvedValue Cached resolvedValue (avoids repeated SLOAD in loop)
     * @return error The calculated error
     */
    function _calculateError(int256 predictedValue, uint8 _tsType, int256 _resolvedValue) private pure returns (uint256) {
        if (_tsType == 0) { // Normal
            return MathUtils.abs(_resolvedValue, predictedValue);
        } else { // Lognormal

             // Calculate |log(X_res/X_p)| using PRBMath for high precision
            require(_resolvedValue > 0 && predictedValue > 0, "Values must be positive for lognormal");
            
            // Convert to unsigned integers
            uint256 resolvedValueUint = uint256(_resolvedValue);
            uint256 predictedValueUint = uint256(predictedValue);
            
            // Calculate ratio: X_res / X_p using PRBMath for precision
            uint256 ratio = MathUtils.div(
                resolvedValueUint, 
                predictedValueUint 
            );
            
            // Calculate |ln(ratio)| using the new lnAbs function
            return MathUtils.lnAbs(ratio);
        }
    }
    
    /**
     * @dev Determines if a prediction is a winner and calculates its adjusted stake
     * @param predictionIndex The index of the prediction in the prediction book
     * @param params Cached market parameters struct - replaces 7 individual parameters,
     *               uses a single stack slot to avoid "stack too deep" compiler error.
     *               params.tsType and params.resolvedValue are passed individually to _calculateError.
     * @param stakedAmount Passed in by caller (already read for zero-check) - avoids a second SLOAD
     * @return isWinner Whether the prediction is a winner
     * @return adjustedStake The adjusted stake if winner, 0 otherwise
     */
    function _isWinner(
        uint256 predictionIndex,
        MarketParams memory params,
        uint256 stakedAmount
    ) private view returns (bool, uint256) {
        // Read predictedValue (slot 2, cold SLOAD) and timeToExpiryYears (slot 0, cold SLOAD in
        // _computeTotalAdjustedStake; warm SLOAD in claimReward() since forecaster check already
        // touched slot 0 above). timestamp is no longer needed here - timeToExpiryYears was
        // pre-computed at predict() time, eliminating one MathUtils.div per prediction.
        int256  predictedValue    = predictionBook[predictionIndex].predictedValue;    // slot 2 - cold SLOAD
        uint256 timeToExpiryYears = predictionBook[predictionIndex].timeToExpiryYears; // slot 0 - cold or warm SLOAD

        // Calculate error - pass params.tsType and params.resolvedValue individually
        uint256 error = _calculateError(predictedValue, params.tsType, params.resolvedValue);

        // Calculate the denominator: sigma² * T_p (sigmaSq pre-computed in MarketParams)
        uint256 denominator = MathUtils.mul(params.sigmaSq, timeToExpiryYears);
        
        // Calculate (error_p²)/(sigma² * T_p)
        // uint256 criteriaValue = MathUtils.div(squaredError, denominator);
        uint256 criteriaValue = MathUtils.div(MathUtils.mul(error, error), denominator);
        
        // Check if prediction is a winner: criteriaValue <= multiplierSq (pre-computed in MarketParams)
        if (criteriaValue <= params.multiplierSq) {
            // Calculate adjustment factor
            // uint256 timeFactor = MathUtils.mul(params.timeCost, timeToExpiryYears);
            // uint256 timeAdjustment = MathUtils.exp(timeFactor);
            uint256 timeAdjustment = MathUtils.exp(MathUtils.mul(params.timeCost, timeToExpiryYears));

            uint256 errorAdjustment = MathUtils.SCALE - MathUtils.div(MathUtils.mul(params.alpha, criteriaValue), (2 * MathUtils.SCALE));
            
            uint256 adjustmentFactor = MathUtils.mul(timeAdjustment, errorAdjustment);
            
            // Calculate a_p * S_p
            uint256 adjustedStake = MathUtils.mul(adjustmentFactor, stakedAmount);
            return (true, adjustedStake);
        }
        
        return (false, 0);
    }
    
  
    // Market parameters struct - cached once from storage before the winner loop.
    // Groups immutable-during-resolution storage vars into a single memory slot,
    // avoiding "stack too deep" errors and eliminating SLOADs x N iterations.
    // sigmaSq and multiplierSq are pre-computed once instead of N times inside _isWinner.
    // expiryTime removed - no longer needed since timeToExpiryYears is stored in each Prediction.
    struct MarketParams {
        uint256 timeCost;
        uint256 alpha;
        uint8   tsType;
        int256  resolvedValue;
        uint256 sigmaSq;      // Pre-computed: MathUtils.mul(sigma, sigma)
        uint256 multiplierSq; // Pre-computed: MathUtils.mul(multiplier, multiplier)
    }

    /**
     * @dev Processes winners after resolution:
     *  1. Pays oracle requester and resolve caller immediately.
     *  2. Saves winnerRewardPool and totalAdjustedStake to storage.
     *  No storage writes per prediction - the winner loop is pure reads.
     *  Winners collect their share by calling claimReward(), which recomputes
     *  _isWinner() for their specific prediction (O(1) per claim).
     * @param totalFees The tax fees (already removed from totalAvailable)
     * @param resolver The address that called resolve()
     */
    function _processWinnersAndDistributeRewards(
        uint256 totalFees,
        address resolver
    ) private {
        // Total funds available for rewards (stakePool net of fees, plus any carried amount)
        uint256 totalAvailable = stakePool - totalFees + carriedAmount;

        // Calculate immediate payouts (basis points)
        uint256 oracleRequesterRewardAmount = (totalAvailable * oracleRequesterReward) / 10000;
        uint256 resolveCallerRewardAmount   = (totalAvailable * resolveCallerReward)   / 10000;

        // Pay oracle requester and resolve caller immediately
        _payOracleRequesterReward(oracleRequesterRewardAmount);
        _payResolveCallerReward(resolver, resolveCallerRewardAmount);

        // Remaining pool for winners (or carry pool if no winners)
        uint256 rewardPool = totalAvailable - oracleRequesterRewardAmount - resolveCallerRewardAmount;

        // Read-only pass: sum adjustedStakes of all winners (no storage writes)
        uint256 adjStakeSum = _computeTotalAdjustedStake();

        if (adjStakeSum == 0) {
            // No winners: send entire reward pool to carry pool
            if (rewardPool > 0) {
                ITSP_Market(tspMarket).addToCarryPool(rewardPool);
            }
            return;
        }

        // Save to storage so claimReward() can compute individual shares
        winnerRewardPool   = rewardPool;
        totalAdjustedStake = adjStakeSum;
    }

    /**
     * @dev Computes the sum of adjustedStakes for all winning predictions.
     * Pure read-only pass - zero storage writes.
     * Builds MarketParams once (7 SLOADs total) then iterates with only warm reads.
     * @return adjStakeSum Sum of all winners' adjustedStakes (0 if no winners)
     */
    function _computeTotalAdjustedStake() private view returns (uint256 adjStakeSum) {
        uint256 len = predictionBook.length;

        MarketParams memory params = MarketParams({
            timeCost:      timeCost,
            alpha:         alpha,
            tsType:        tsType,
            resolvedValue: resolvedValue,
            sigmaSq:       MathUtils.mul(sigma, sigma),
            multiplierSq:  MathUtils.mul(multiplier, multiplier)
        });

        for (uint256 i = 0; i < len; i++) {
            uint256 stakedAmount = predictionBook[i].stakedAmount; // cold SLOAD - cached here for zero-check and _isWinner
            if (stakedAmount == 0) continue;

            (bool isWinner, uint256 adjustedStake) = _isWinner(i, params, stakedAmount);
            if (isWinner) {
                adjStakeSum += adjustedStake;
            }
        }
    }
    
    /**
     * @dev Claims reward for a single winning prediction.
     * Must be called by the prediction's forecaster after the expiry is RESOLVED.
     * Each prediction can only be claimed once.
     * Recomputes _isWinner() on the spot - O(1), no stored adjustedStake needed.
     * @param _predictionIndex Index of the prediction in predictionBook
     */
    function claimReward(uint256 _predictionIndex) external override {
        require(status == Status.RESOLVED, "Expiry not resolved");
        require(_predictionIndex < predictionBook.length, "Invalid prediction index");

        Prediction storage prediction = predictionBook[_predictionIndex];

        require(msg.sender == prediction.forecaster, "Not prediction owner");
        require(!prediction.claimed, "Already claimed");

        // Recompute winner status and adjustedStake (same deterministic math as resolve())
        // Reading prediction.forecaster (slot 0) above already warmed slot 0, so the
        // timeToExpiryYears read inside _isWinner costs only 100 gas (warm SLOAD).
        MarketParams memory params = MarketParams({
            timeCost:      timeCost,
            alpha:         alpha,
            tsType:        tsType,
            resolvedValue: resolvedValue,
            sigmaSq:       MathUtils.mul(sigma, sigma),
            multiplierSq:  MathUtils.mul(multiplier, multiplier)
        });

        // Read stakedAmount once - passed to _isWinner to avoid a second storage read inside it
        uint256 stakedAmount = prediction.stakedAmount;

        (bool isWinner, uint256 adjustedStake) = _isWinner(_predictionIndex, params, stakedAmount);

        require(isWinner, "Not a winner");
        require(totalAdjustedStake > 0, "No winner pool (resolve error)");

        // Mark as claimed before external call (re-entrancy guard pattern)
        prediction.claimed = true;

        // Compute proportional share: reward = (adjustedStake / totalAdjustedStake) * winnerRewardPool
        uint256 reward = (adjustedStake * winnerRewardPool) / totalAdjustedStake;

        // Save for historical reference
        prediction.rewardAmount = reward;

        // Transfer reward via TSP_Manager
        ITSP_Manager(tspManager).updateUserBalanceForReward(
            msg.sender,
            tsToken,
            reward
        );

        emit RewardClaimed(msg.sender, _predictionIndex, reward);
    }

    /**
    * @dev Returns the length of expiry args array
    * @return The length of the expiryArgs array
    */
    function getExpiryArgsLength() external view override returns (uint256) {
        return expiryArgs.length;
    }

}