// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

/**
 * @title Raffle Contract
 * @author Ukanna Raymond
 * @notice This contract is for creating a sample raffle system where users can participate in a raffle by sending a certain amount of ether. The contract will randomly select a winner from the participants and transfer the collected funds to the winner.
 * @dev Implements Chainlink VRFv2.5
 */

contract Raffle is VRFConsumerBaseV2Plus {
    /* Errors */
    error Raffle__NotEnoughETHEntered();
    error Raffle__TransferFailed();
    error Raffle__RaffleNotOpen();
    error Raffle__UpkeepNotNeeded(uint256 balance, uint256 playersLength, uint256 raffleState);
    error Raffle__InvalidRecipient();

    /* Type Declarations */
    enum RaffleState {
        OPEN, //0
        CALCULATING //1
    }

    /* State Variables */
    uint16 private constant REQUEST_CONFIRMATIONS = 3;
    uint32 private constant NUM_WORDS = 1;
    uint256 private immutable i_entranceFee;
    //@dev The interval in seconds for selecting a winner.
    uint256 private immutable i_interval;
    bytes32 private immutable i_keyHash;
    uint256 private immutable i_subscriptionId;
    uint32 private immutable i_callbackGasLimit;
    address payable[] private s_players;
    uint256 private s_lastWinnerSelectionTime;
    address private s_recentWinner;
    RaffleState private s_raffleState;
    uint256 private constant FEE_PERCENTAGE = 5;
    uint256 private constant PERCENTAGE_DENOMINATOR = 100;

    address payable private immutable i_feeRecipient;

    uint256 private s_accumulatedFees;
    mapping(address => uint256) private s_pendingWinnings;

    /* Events */
    event RaffleEntered(address indexed player);
    event WinnerPicked(address indexed winner);

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

        s_lastWinnerSelectionTime = block.timestamp;
        s_raffleState = RaffleState.OPEN;
        i_feeRecipient = payable(msg.sender);
    }

    function enterRaffle() external payable {
        if (msg.value < i_entranceFee) {
            revert Raffle__NotEnoughETHEntered();
        }
        if (s_raffleState != RaffleState.OPEN) {
            revert Raffle__RaffleNotOpen();
        }
        s_players.push(payable(msg.sender));
        emit RaffleEntered(msg.sender);
    }

    /**
     * @dev This is the function that the Chainlink nodes will call to see if the lottery is ready
     * to have a winner picked.
     * The following should be true in order for upkeepNeeded to be true;
     * 1. The time interval has passed between raffle runs
     * 2. The lottery is open.
     * 3. The contract has ETH.
     * implicitly, your subscription has LINK
     * @param - ignored
     * @return upkeepNeeded - true if it's time to restart the lottery
     * @return - ignored
     */
    function checkUpkeep(
        bytes memory /* checkData */
    )
        public
        view
        returns (
            bool upkeepNeeded,
            bytes memory /* */
        )
    {
        // Check to see if enough time has passed since the last winner selection
        bool timeHasPassed = (block.timestamp - s_lastWinnerSelectionTime >= i_interval);
        bool isOpen = s_raffleState == RaffleState.OPEN;
        bool hasBalance = address(this).balance > 0;
        bool hasPlayers = s_players.length > 0;
        upkeepNeeded = timeHasPassed && isOpen && hasBalance && hasPlayers;
        return (upkeepNeeded, "");
    }

    // Be automatically called
    function performUpkeep(
        bytes calldata /* performData */
    )
        external
    {
        // Check to see if conditions are met
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
                // Set nativePayment to true to pay for VRF requests with Sepolia ETH instead of LINK
                VRFV2PlusClient.ExtraArgsV1({nativePayment: false})
            )
        });
        s_vrfCoordinator.requestRandomWords(request);
    }

    function fulfillRandomWords(
        uint256,
        /* requestId */
        uint256[] calldata randomWords
    )
        internal
        override
    {
        uint256 indexOfWinner = randomWords[0] % s_players.length;
        address payable recentWinner = s_players[indexOfWinner];

        uint256 rafflePool = address(this).balance - s_accumulatedFees;
        uint256 fee = (rafflePool * FEE_PERCENTAGE) / PERCENTAGE_DENOMINATOR;
        uint256 winnerPrize = rafflePool - fee;

        s_recentWinner = recentWinner;
        s_accumulatedFees += fee;
        s_pendingWinnings[recentWinner] += winnerPrize;

        s_raffleState = RaffleState.OPEN;
        s_players = new address payable[](0);
        s_lastWinnerSelectionTime = block.timestamp;

        emit WinnerPicked(recentWinner);
    }

    function withdrawWinnings(address payable recipient) external {
        if (recipient == address(0)) {
            revert Raffle__InvalidRecipient();
        }

        uint256 amount = s_pendingWinnings[msg.sender];

        if (amount == 0) {
            revert Raffle__TransferFailed();
        }

        s_pendingWinnings[msg.sender] = 0;

        (bool success,) = recipient.call{value: amount}("");

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

    function getPendingWinnings(address player) external view returns (uint256) {
        return s_pendingWinnings[player];
    }

    function getAccumulatedFees() external view returns (uint256) {
        return s_accumulatedFees;
    }

    function getFeeRecipient() external view returns (address) {
        return i_feeRecipient;
    }
}
