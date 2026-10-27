// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {HelperConfig, CodeConstants} from "script/HelperConfig.s.sol";
import {
    CreateSubscription,
    FundSubscription,
    AddConsumer
} from "script/Interactions.s.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";

contract InteractionsTest is Test, CodeConstants {
    HelperConfig public helperConfig;
    CreateSubscription public createSubscriptionScript;
    FundSubscription public fundSubscriptionScript;
    AddConsumer public addConsumerScript;

    address public vrfCoordinator;
    address public linkToken;
    address public account;

    function setUp() public {
        helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfig();
        vrfCoordinator = config.vrfCoordinator;
        linkToken = config.link;
        account = config.account;

        createSubscriptionScript = new CreateSubscription();
        fundSubscriptionScript = new FundSubscription();
        addConsumerScript = new AddConsumer();
    }

    function testCreateSubscriptionCreatesNewSubscription() public {
        if (block.chainid != ANVIL_CHAIN_ID) {
            return;
        }

        (uint256 subId, address returnedCoordinator) = createSubscriptionScript
            .createSubscription(vrfCoordinator, account);

        assertEq(returnedCoordinator, vrfCoordinator);
        assertGt(subId, 0);

        (uint96 balance, uint96 nativeBalance, uint64 reqCount, address owner, address[] memory consumers) =
            VRFCoordinatorV2_5Mock(vrfCoordinator).getSubscription(subId);

        assertEq(balance, 0);
        assertEq(nativeBalance, 0);
        assertEq(reqCount, 0);
        assertEq(owner, account);
        assertEq(consumers.length, 0);
    }

    function testFundSubscriptionIncreasesBalance() public {
        if (block.chainid != ANVIL_CHAIN_ID) {
            return;
        }

        (uint256 subId, ) = createSubscriptionScript.createSubscription(vrfCoordinator, account);

        fundSubscriptionScript.fundSubscription(vrfCoordinator, subId, linkToken, account);

        (uint96 balance, uint96 nativeBalance, , , ) = VRFCoordinatorV2_5Mock(vrfCoordinator).getSubscription(subId);
        assertGt(uint256(balance), 0);
        assertEq(uint256(nativeBalance), 0);
    }

    function testAddConsumerRegistersConsumer() public {
        if (block.chainid != ANVIL_CHAIN_ID) {
            return;
        }

        address consumer = address(0xBEEF);
        (uint256 subId, ) = createSubscriptionScript.createSubscription(vrfCoordinator, account);

        addConsumerScript.addConsumer(consumer, vrfCoordinator, subId, account);

        bool isAdded = VRFCoordinatorV2_5Mock(vrfCoordinator).consumerIsAdded(subId, consumer);
        assertTrue(isAdded);
    }
}
