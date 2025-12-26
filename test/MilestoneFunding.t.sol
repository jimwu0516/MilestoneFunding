// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/MilestoneFunding.sol";

contract MilestoneFundingTest is Test {
    MilestoneFunding public mf;
    address owner;
    address creator;
    address investor1;
    address investor2;
    address deployer;

    function setUp() public {
        creator = vm.addr(1);
        investor1 = vm.addr(2);
        investor2 = vm.addr(3);
        deployer = vm.addr(100);

        vm.prank(deployer);
        mf = new MilestoneFunding();
        owner = deployer;
    }

    function testCreateProject() public {
        uint256 softCap = 10 ether;
        uint256 bond = softCap / 10;

        vm.deal(creator, bond);
        vm.prank(creator);
        mf.createProject{value: bond}(
            "Test Project",
            "Description",
            softCap / 1 ether
        );

        (
            address projCreator,
            string memory name,
            ,
            uint256 softCapWei,
            ,
            uint256 bondWei,
            string memory state
        ) = mf.getProjectCore(1);
        assertEq(projCreator, creator);
        assertEq(name, "Test Project");
        assertEq(softCapWei, softCap);
        assertEq(bondWei, bond);
        assertEq(state, "Funding");
    }

    function testFundAndSnapshot() public {
        uint256 softCap = 10 ether;
        uint256 bond = softCap / 10;

        vm.deal(creator, bond);
        vm.prank(creator);
        mf.createProject{value: bond}("Project", "Desc", softCap / 1 ether);

        vm.deal(investor1, 6 ether);
        vm.prank(investor1);
        mf.fund{value: 6 ether}(1);

        vm.deal(investor2, 4 ether);
        vm.prank(investor2);
        mf.fund{value: 4 ether}(1);

        (, , , uint256 totalFunded, , , string memory state) = mf
            .getProjectCore(1);
        assertEq(totalFunded, 10 ether);
        assertEq(state, "BuildingStage1");
    }

    function testSubmitMilestoneAndVote() public {
        uint256 softCap = 10 ether;
        uint256 bond = softCap / 10;

        vm.deal(creator, bond);
        vm.prank(creator);
        mf.createProject{value: bond}("Project", "Desc", softCap / 1 ether);

        vm.deal(investor1, 6 ether);
        vm.prank(investor1);
        mf.fund{value: 6 ether}(1);

        vm.deal(investor2, 4 ether);
        vm.prank(investor2);
        mf.fund{value: 4 ether}(1);

        vm.prank(creator);
        mf.submitMilestone(1, "QmHash1");

        (, , , , , , string memory state) = mf.getProjectCore(1);
        assertEq(state, "VotingRound1");

        vm.prank(investor1);
        mf.vote(1, MilestoneFunding.VoteOption.Yes);

        vm.prank(investor2);
        mf.vote(1, MilestoneFunding.VoteOption.Yes);

        (
            ,
            ,
            uint256[3] memory yesWeight,
            uint256[3] memory noWeight,
            bool[3] memory finalized
        ) = mf.getProjectVoting(1);
        assertTrue(finalized[0]);
        assertTrue(yesWeight[0] > 0);
        assertEq(noWeight[0], 0);

        (, , , , , , state) = mf.getProjectCore(1);
        assertEq(state, "BuildingStage2");
    }

    function testClaimCreator() public {
        uint256 softCap = 10 ether;
        uint256 bond = softCap / 10;

        vm.deal(creator, bond);
        vm.prank(creator);
        mf.createProject{value: bond}("Project", "Desc", softCap / 1 ether);

        vm.deal(investor1, 6 ether);
        vm.prank(investor1);
        mf.fund{value: 6 ether}(1);

        vm.deal(investor2, 4 ether);
        vm.prank(investor2);
        mf.fund{value: 4 ether}(1);

        vm.prank(creator);
        mf.submitMilestone(1, "QmHash1");

        vm.prank(investor1);
        mf.vote(1, MilestoneFunding.VoteOption.Yes);
        vm.prank(investor2);
        mf.vote(1, MilestoneFunding.VoteOption.Yes);

        uint256 balanceBefore = creator.balance;
        vm.prank(creator);
        mf.claimCreator();
        uint256 balanceAfter = creator.balance;

        assertEq(balanceAfter - balanceBefore, 2 ether);
    }

    function testVoteFailRefundInvestorAndOwnerGetsBond() public {
        uint256 softCap = 10 ether;
        uint256 bond = softCap / 10;

        vm.deal(creator, bond);
        vm.prank(creator);
        mf.createProject{value: bond}("Project", "Desc", softCap / 1 ether);

        vm.deal(investor1, 6 ether);
        vm.prank(investor1);
        mf.fund{value: 6 ether}(1);

        vm.deal(investor2, 4 ether);
        vm.prank(investor2);
        mf.fund{value: 4 ether}(1);

        (, , , uint256 totalFunded, , , string memory state) = mf.getProjectCore(1);
        assertEq(totalFunded, 10 ether);
        assertEq(state, "BuildingStage1");

        vm.prank(creator);
        mf.submitMilestone(1, "QmFailHash");

        (, , , , , , state) = mf.getProjectCore(1);
        assertEq(state, "VotingRound1");

        vm.prank(investor1);
        mf.vote(1, MilestoneFunding.VoteOption.No);

        vm.prank(investor2);
        mf.vote(1, MilestoneFunding.VoteOption.Yes);

        (, , , , , , state) = mf.getProjectCore(1);
        assertEq(state, "FailureRound1");

        uint256 inv1Before = investor1.balance;
        uint256 inv2Before = investor2.balance;

        vm.prank(investor1);
        mf.claimInvestor();

        vm.prank(investor2);
        mf.claimInvestor();

        uint256 inv1After = investor1.balance;
        uint256 inv2After = investor2.balance;

        assertEq(inv1After - inv1Before, 6 ether);
        assertEq(inv2After - inv2Before, 4 ether);

        uint256 ownerBefore = owner.balance;

        vm.prank(owner);
        mf.claimOwner();

        uint256 ownerAfter = owner.balance;

        assertEq(ownerAfter - ownerBefore, bond);
    }
}
