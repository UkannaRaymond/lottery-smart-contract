// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

/**
 * @title Raffle
 * @author Ukanna Raymond
 * @notice Allows participants to enter a raffle by paying an entrance fee.
 * @notice Uses Chainlink VRF v2.5 to select a random winner.
 * @dev Accumulates a 5% fee for the deployer and uses pull payments
 *      so winners and the fee recipient withdraw their funds separately.
 */

contract Raffle is VRFConsumerBaseV2Plus {
    /* Errors */
    error Raffle__NotEnoughETHEntered();
    error Raffle__TransferFailed();
    error Raffle__RaffleNotOpen();
    error Raffle__AlreadyEntered();
    error Raffle__NotFeeRecipient();
    error Raffle__UnexpectedRequestId();
    error Raffle__UpkeepNotNeeded(uint256 balance, uint256 playersLength, uint256 raffleState);

    /* Type Declarations */
    enum RaffleState {
        OPEN, //0
        CALCULATING //1
    }

    /* Configuration */
    uint16 private constant REQUEST_CONFIRMATIONS = 3;
    uint32 private constant NUM_WORDS = 1;

    uint256 private immutable i_entranceFee; // Minimum entry payment in wei.
    uint256 private immutable i_interval; // Minimum time between raffle rounds, in seconds.
    bytes32 private immutable i_keyHash; // Chainlink VRF gas lane.
    uint256 private immutable i_subscriptionId; // Chainlink VRF subscription ID.
    uint32 private immutable i_callbackGasLimit; // Maximum gas allocated to the VRF callback.

    /* Raffle state */
    address payable[] private s_players;
    mapping(address => uint256) private s_playerEntryRound; // Round in which each address last entered.
    uint256 private s_roundId; // Current raffle round identifier.
    uint256 private s_lastWinnerSelectionTime; // Timestamp of the last completed round.
    address private s_recentWinner;
    RaffleState private s_raffleState;
    uint256 private s_lastRequestId; // Most recent Chainlink VRF request ID.
    uint256 private s_currentRaffleAmount; // Entry funds belonging to the current round.

    /* Prize and fee accounting */
    uint256 private constant FEE_PERCENTAGE = 5;
    uint256 private constant PERCENTAGE_DENOMINATOR = 100;

    address payable private immutable i_feeRecipient;
    uint256 private s_accumulatedFees; // Fees available for withdrawal.
    mapping(address => uint256) private s_pendingWinnings; // Unwithdrawn prizes owed to winners.

    /* Events */
    event RaffleEntered(address indexed player);
    event WinnerPicked(address indexed winner);
    event RequestedRaffleWinner(uint256 indexed requestId);
    event WinningsWithdrawn(address indexed winner, uint256 amount);
    event FeesWithdrawn(address indexed recipient, uint256 amount);

    constructor(
        uint256 entranceFee,
        uint256 interval,
        address vrfCoordinator,
        bytes32 gasLane,
        uint256 subscriptionId,
        uint32 callbackGasLimit
    ) VRFConsumerBaseV2Plus(vrfCoordinator) {
        i_entranceFee = entranceFee;
        i_interval = interval;
        i_keyHash = gasLane;
        i_subscriptionId = subscriptionId;
        i_callbackGasLimit = callbackGasLimit;

        s_roundId = 1;
        s_lastWinnerSelectionTime = block.timestamp;
        s_raffleState = RaffleState.OPEN;
        i_feeRecipient = payable(msg.sender);
    }

    /**
     * @notice Enters the current raffle.
     * @dev Each address may enter once per round. Payments above the minimum
     *      entrance fee are accepted and added to the current prize pool.
     * @dev Reverts if the payment is insufficient, the raffle is closed,
     *      or the caller has already entered the current round.
     */
    function enterRaffle() external payable {
        if (msg.value < i_entranceFee) {
            revert Raffle__NotEnoughETHEntered();
        }
        if (s_raffleState != RaffleState.OPEN) {
            revert Raffle__RaffleNotOpen();
        }
        if (s_playerEntryRound[msg.sender] == s_roundId) {
            revert Raffle__AlreadyEntered();
        }

        s_players.push(payable(msg.sender));
        s_playerEntryRound[msg.sender] = s_roundId;
        s_currentRaffleAmount += msg.value;

        emit RaffleEntered(msg.sender);
    }

    /**
     * @notice Checks whether the raffle is ready to select a winner.
     * @dev Upkeep is needed when the interval has elapsed, the raffle is open,
     *      and the current round has players and entry funds.
     * @return upkeepNeeded Whether the raffle is ready for upkeep.
     * @return performData Empty data because no additional input is required.
     */
    function checkUpkeep(
        bytes memory /* checkData */
    )
        public
        view
        returns (bool upkeepNeeded, bytes memory performData)
    {
        // forge-lint: disable-next-line(block-timestamp)
        bool timeHasPassed = block.timestamp - s_lastWinnerSelectionTime >= i_interval;

        bool isOpen = s_raffleState == RaffleState.OPEN;
        bool hasBalance = s_currentRaffleAmount > 0;
        bool hasPlayers = s_players.length > 0;

        upkeepNeeded = timeHasPassed && isOpen && hasBalance && hasPlayers;

        return (upkeepNeeded, "");
    }

    /**
     * @notice Requests a random word to select the raffle winner.
     * @dev Closes the raffle to new entries before requesting randomness.
     *      Only proceeds when the upkeep conditions are satisfied.
     */
    function performUpkeep(
        bytes calldata /* performData */
    )
        external
    {
        (bool upKeepNeeded,) = checkUpkeep("");

        if (!upKeepNeeded) {
            revert Raffle__UpkeepNotNeeded(address(this).balance, s_players.length, uint256(s_raffleState));
        }

        s_raffleState = RaffleState.CALCULATING;

        VRFV2PlusClient.RandomWordsRequest memory request = VRFV2PlusClient.RandomWordsRequest({
            keyHash: i_keyHash,
            subId: i_subscriptionId,
            requestConfirmations: REQUEST_CONFIRMATIONS,
            callbackGasLimit: i_callbackGasLimit,
            numWords: NUM_WORDS,
            extraArgs: VRFV2PlusClient._argsToBytes(
                // Pay for VRF requests using LINK rather than native ETH.
                VRFV2PlusClient.ExtraArgsV1({nativePayment: false})
            )
        });

        uint256 requestId = s_vrfCoordinator.requestRandomWords(request);
        s_lastRequestId = requestId;
        // The request ID is only available after the coordinator call returns.
        // forge-lint: disable-next-line(reentrancy-events)
        emit RequestedRaffleWinner(requestId);
    }

    /**
     * @notice Processes the random word returned by Chainlink VRF.
     * @dev Selects a winner, credits the winner's prize, accumulates the fee,
     *      and opens the next round. ETH transfers happen through withdrawals.
     * @param requestId The Chainlink VRF request identifier.
     * @param randomWords Random words returned by the VRF coordinator.
     */
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal override {
        if (s_raffleState != RaffleState.CALCULATING || requestId != s_lastRequestId) {
            revert Raffle__UnexpectedRequestId();
        }

        uint256 indexOfWinner = randomWords[0] % s_players.length;
        address payable recentWinner = s_players[indexOfWinner];

        s_recentWinner = recentWinner;

        uint256 rafflePool = s_currentRaffleAmount;
        uint256 fee = (rafflePool * FEE_PERCENTAGE) / PERCENTAGE_DENOMINATOR;
        uint256 winnerPrize = rafflePool - fee;

        s_recentWinner = recentWinner;
        s_currentRaffleAmount = 0;
        s_accumulatedFees += fee;
        s_pendingWinnings[recentWinner] += winnerPrize;

        s_roundId++;
        s_raffleState = RaffleState.OPEN;
        s_players = new address payable[](0);
        s_lastWinnerSelectionTime = block.timestamp;

        emit WinnerPicked(recentWinner);
    }

    /**
     * @notice Withdraws the caller's accumulated raffle winnings.
     * @dev Uses checks-effects-interactions to prevent repeated claims.
     *      Reverts if the caller has no winnings or the ETH transfer fails.
     */
    function withdrawWinnings() external {
        uint256 amount = s_pendingWinnings[msg.sender];

        if (amount == 0) {
            revert Raffle__TransferFailed();
        }

        s_pendingWinnings[msg.sender] = 0;

        emit WinningsWithdrawn(msg.sender, amount);

        (bool success,) = msg.sender.call{value: amount}("");

        if (!success) {
            revert Raffle__TransferFailed();
        }
    }

    /**
     * @notice Withdraws accumulated raffle fees to the designated recipient.
     * @dev Only the configured fee recipient may withdraw fees.
     */
    function withdrawFees() external {
        if (msg.sender != i_feeRecipient) {
            revert Raffle__NotFeeRecipient();
        }

        uint256 amount = s_accumulatedFees;

        if (amount == 0) {
            return;
        }

        s_accumulatedFees = 0;

        emit FeesWithdrawn(i_feeRecipient, amount);

        (bool success,) = i_feeRecipient.call{value: amount}("");

        if (!success) {
            revert Raffle__TransferFailed();
        }
    }

    /**
     * Getter function to retrieve the entrance fee for the raffle.
     * @return The entrance fee in wei.
     */
    function getEntranceFee() external view returns (uint256) {
        return i_entranceFee;
    }

    function getRaffleState() external view returns (RaffleState) {
        return s_raffleState;
    }

    function getPlayer(uint256 indexOfPlayers) external view returns (address) {
        return s_players[indexOfPlayers];
    }

    function getNumberOfPlayers() external view returns (uint256) {
        return s_players.length;
    }

    function getLastRequestId() external view returns (uint256) {
        return s_lastRequestId;
    }

    function getPendingWinnings(address player) external view returns (uint256) {
        return s_pendingWinnings[player];
    }

    function getRecentWinner() external view returns (address) {
        return s_recentWinner;
    }

    function getAccumulatedFees() external view returns (uint256) {
        return s_accumulatedFees;
    }

    function getFeeRecipient() external view returns (address) {
        return i_feeRecipient;
    }

    function getRoundId() external view returns (uint256) {
        return s_roundId;
    }
}
