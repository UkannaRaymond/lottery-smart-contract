// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {DeployRaffle} from "script/DeployRaffle.s.sol";
import {Raffle} from "src/Raffle.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {Vm} from "forge-std/Vm.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
import {CodeConstants} from "script/HelperConfig.s.sol";

contract RaffleTest is Test, CodeConstants {
    Raffle public raffle;
    HelperConfig public helperConfig;

    uint256 entranceFee;
    uint256 interval;
    address vrfCoordinator;
    bytes32 gasLane;
    uint256 subscriptionId;
    uint32 callbackGasLimit;

    address public PLAYER = makeAddr("player");
    uint256 public constant STARTING_PLAYER_BALANCE = 10 ether;

    event RaffleEntered(address indexed player);
    event WinnerPicked(address indexed winner);
    event FeesWithdrawn(address indexed recipient, uint256 amount);

    modifier raffleEntered() {
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);
        _;
    }

    modifier skipFork() {
        if (block.chainid != ANVIL_CHAIN_ID) {
            return;
        }
        _;
    }

    function setUp() external {
        DeployRaffle deployer = new DeployRaffle();
        (raffle, helperConfig) = deployer.deployRaffle();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfig();
        entranceFee = config.entranceFee;
        interval = config.interval;
        vrfCoordinator = config.vrfCoordinator;
        gasLane = config.gasLane;
        callbackGasLimit = config.callbackGasLimit;
        subscriptionId = config.subscriptionId;

        vm.deal(PLAYER, STARTING_PLAYER_BALANCE);
    }

    function testRaffleInitializesInOpenState() public view {
        assert(raffle.getRaffleState() == Raffle.RaffleState.OPEN);
    }

    function testRaffleRevertWhenEntranceFeeISNotEnough() public {
        vm.prank(PLAYER);
        vm.expectRevert(Raffle.Raffle__NotEnoughETHEntered.selector);
        raffle.enterRaffle();
    }

    function testRaffleUpdatesPlayersWhenTheyEnter() public {
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
        address playerUpdated = raffle.getPlayer(0);
        assert(playerUpdated == PLAYER);
    }

    function testPlayerCannotEnterRaffleTwiceInSameRound() public {
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();

        vm.expectRevert(Raffle.Raffle__AlreadyEntered.selector);
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
    }

    function testEnteringRaffleEmitsEvent() public {
        vm.prank(PLAYER);
        vm.expectEmit(true, false, false, false, address(raffle));
        emit RaffleEntered(PLAYER);

        raffle.enterRaffle{value: entranceFee}();
    }

    function testPlayersBarredInRaffleCalculatingState() public raffleEntered {
        raffle.performUpkeep("");

        vm.expectRevert(Raffle.Raffle__RaffleNotOpen.selector);
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
    }

    function testCheckUpkeepReturnsFalseIfItHasNoBalance() public {
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);

        (bool upKeepNeeded,) = raffle.checkUpkeep("");

        assert(!upKeepNeeded);
    }

    function testCheckUpkeepReturnsFalseIfRaffleIsntOpen() public raffleEntered {
        raffle.performUpkeep("");

        (bool upKeepNeeded,) = raffle.checkUpkeep("");
        assert(!upKeepNeeded);
    }

    function testPerformUpKeepCanOnlyRunIfCheckUpKeepIsTrue() public raffleEntered {
        raffle.performUpkeep("");
    }

    function testPerformUpkeepRevertIfCheckUpkeepIsFalse() public {
        uint256 currentBalance = 0;
        uint256 numberPlayers = 0;
        Raffle.RaffleState rState = raffle.getRaffleState();

        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
        currentBalance = currentBalance + entranceFee;
        numberPlayers = 1;

        vm.expectRevert(
            abi.encodeWithSelector(Raffle.Raffle__UpkeepNotNeeded.selector, currentBalance, numberPlayers, rState)
        );
        raffle.performUpkeep("");
    }

    function testPerformUpkeepUpdatesRaffleStateAndEmitRequestId() public raffleEntered {
        vm.recordLogs();
        raffle.performUpkeep("");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1];

        // Assert
        Raffle.RaffleState raffleState = raffle.getRaffleState();
        assert(uint256(requestId) > 0);
        assert(uint256(raffleState) == 1);
    }

    function testFulfillRandomWordsCanOnlyBeCalledAfterPerformUpkeep(uint256 randomRequestId) public raffleEntered {
        vm.expectRevert(VRFCoordinatorV2_5Mock.InvalidRequest.selector);
        VRFCoordinatorV2_5Mock(vrfCoordinator).fulfillRandomWords(randomRequestId, address(raffle));
    }

    function testWithdrawWinningsRevertsWhenCallerHasNoWinnings() public {
        vm.expectRevert(Raffle.Raffle__TransferFailed.selector);
        vm.prank(PLAYER);
        raffle.withdrawWinnings();
    }

    function testWithdrawFeesRevertsWhenCallerIsNotFeeRecipient() public {
        vm.expectRevert(Raffle.Raffle__NotFeeRecipient.selector);
        vm.prank(PLAYER);
        raffle.withdrawFees();
    }

    function testFulFillRandomWordsPicksAWinnerResetsAndSendsMoney() public raffleEntered skipFork {
        uint256 additionalEntrants = 3;
        address expectedWinner = address(1);

        for (uint256 i = 1; i <= additionalEntrants; i++) {
            address newPlayer = address(uint160(i));
            hoax(newPlayer, 1 ether);
            raffle.enterRaffle{value: entranceFee}();
        }

        uint256 startingTimeStamp = raffle.getLastTimeStamp();
        uint256 winnerStartingBalance = expectedWinner.balance;

        // Arrange the expected prize after the 5% fee.
        uint256 totalPrizePool = entranceFee * 4;
        uint256 fee = (totalPrizePool * 5) / 100;
        uint256 expectedPrize = totalPrizePool - fee;
        address feeRecipient = raffle.getFeeRecipient();
        uint256 feeRecipientStartingBalance = feeRecipient.balance;

        // Act: request randomness.
        vm.recordLogs();
        raffle.performUpkeep("");

        Vm.Log[] memory entries = vm.getRecordedLogs();
        uint256 requestId = uint256(entries[1].topics[1]);

        // Force random word 1, selecting player index 1.
        uint256[] memory randomWords = new uint256[](1);
        randomWords[0] = 1;

        VRFCoordinatorV2_5Mock(vrfCoordinator).fulfillRandomWordsWithOverride(requestId, address(raffle), randomWords);

        // Assert: winner selected and raffle reset.
        assert(raffle.getRecentWinner() == expectedWinner);
        assert(uint256(raffle.getRaffleState()) == 0);
        assert(raffle.getNumberOfPlayers() == 0);
        assert(raffle.getPendingWinnings(expectedWinner) == expectedPrize);
        assert(raffle.getAccumulatedFees() == fee);
        assert(raffle.getLastTimeStamp() > startingTimeStamp);

        // Withdraw winnings as the winner.
        vm.prank(expectedWinner);
        raffle.withdrawWinnings();

        assert(expectedWinner.balance == winnerStartingBalance + expectedPrize);
        assert(raffle.getPendingWinnings(expectedWinner) == 0);

        // Withdraw accumulated fees as the fee recipient.
        vm.expectEmit(true, false, false, true, address(raffle));
        emit FeesWithdrawn(feeRecipient, fee);
        vm.prank(feeRecipient);
        raffle.withdrawFees();

        assert(feeRecipient.balance == feeRecipientStartingBalance + fee);
        assert(raffle.getAccumulatedFees() == 0);
    }
}
