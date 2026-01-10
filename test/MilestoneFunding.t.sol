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

    function _milestones() internal pure returns (string[3] memory m) {
        m[0] = "Milestone 1";
        m[1] = "Milestone 2";
        m[2] = "Milestone 3";
    }

    function testCreateProject() public {
        uint256 softCap = 10 ether;
        uint256 bond = softCap / 10;

        vm.deal(creator, bond);
        vm.prank(creator);
        mf.createProject{value: bond}(
            "Test Project",
            "Description",
            softCap,
            MilestoneFunding.Category.Technology,
            _milestones()
        );

        (
            address projCreator,
            string memory name,
            ,
            ,
            uint256 softCapWei,
            ,
            uint256 bondWei,
            MilestoneFunding.ProjectState state
        ) = mf.getProjectCore(1);

        assertEq(projCreator, creator);
        assertEq(name, "Test Project");
        assertEq(softCapWei, softCap);
        assertEq(bondWei, bond);
        assertEq(uint(state), uint(MilestoneFunding.ProjectState.Funding));
    }

    function testCancelProject() public {
        uint256 softCap = 10 ether;
        uint256 bond = softCap / 10;

        vm.deal(creator, bond);
        vm.prank(creator);
        mf.createProject{value: bond}(
            "Test",
            "Desc",
            softCap,
            MilestoneFunding.Category.Technology,
            _milestones()
        );

        vm.deal(investor1, 6 ether);
        vm.prank(investor1);
        mf.fund{value: 6 ether}(1);

        vm.deal(investor2, 3 ether);
        vm.prank(investor2);
        mf.fund{value: 3 ether}(1);

        vm.prank(creator);
        mf.cancelProject(1);

        (, , , , , , , MilestoneFunding.ProjectState state) = mf.getProjectCore(
            1
        );
        assertEq(uint(state), uint(MilestoneFunding.ProjectState.Cancelled));

        uint256 i1Before = investor1.balance;
        uint256 i2Before = investor2.balance;

        vm.prank(investor1);
        mf.claimInvestor();

        vm.prank(investor2);
        mf.claimInvestor();

        assertEq(investor1.balance - i1Before, 6 ether + (bond * 6) / 9);
        assertEq(investor2.balance - i2Before, 3 ether + (bond * 3) / 9);
    }

    function testFundAndSnapshot() public {
        uint256 softCap = 10 ether;
        uint256 bond = softCap / 10;

        vm.deal(creator, bond);
        vm.prank(creator);
        mf.createProject{value: bond}(
            "Project",
            "Desc",
            softCap,
            MilestoneFunding.Category.Technology,
            _milestones()
        );

        vm.deal(investor1, 6 ether);
        vm.prank(investor1);
        mf.fund{value: 6 ether}(1);

        vm.deal(investor2, 4 ether);
        vm.prank(investor2);
        mf.fund{value: 4 ether}(1);

        (
            ,
            ,
            ,
            ,
            uint256 totalFunded,
            ,
            ,
            MilestoneFunding.ProjectState state
        ) = mf.getProjectCore(1);

        assertEq(totalFunded, 10 ether);
        assertEq(
            uint(state),
            uint(MilestoneFunding.ProjectState.BuildingStage1)
        );
    }

    function testSubmitMilestoneAndVotePass() public {
        uint256 softCap = 10 ether;
        uint256 bond = softCap / 10;

        vm.deal(creator, bond);
        vm.prank(creator);
        mf.createProject{value: bond}(
            "Project",
            "Desc",
            softCap,
            MilestoneFunding.Category.Technology,
            _milestones()
        );

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

        (, , , , , , , MilestoneFunding.ProjectState state) = mf.getProjectCore(
            1
        );
        assertEq(
            uint(state),
            uint(MilestoneFunding.ProjectState.BuildingStage2)
        );
    }

    function testVoteFailRefundAndOwnerGetsBond() public {
        uint256 softCap = 10 ether;
        uint256 bond = softCap / 10;

        vm.deal(creator, bond);
        vm.prank(creator);
        mf.createProject{value: bond}(
            "Project",
            "Desc",
            softCap,
            MilestoneFunding.Category.Technology,
            _milestones()
        );

        vm.deal(investor1, 6 ether);
        vm.prank(investor1);
        mf.fund{value: 6 ether}(1);

        vm.deal(investor2, 4 ether);
        vm.prank(investor2);
        mf.fund{value: 4 ether}(1);

        vm.prank(creator);
        mf.submitMilestone(1, "QmFail");

        vm.prank(investor1);
        mf.vote(1, MilestoneFunding.VoteOption.No);

        vm.prank(investor2);
        mf.vote(1, MilestoneFunding.VoteOption.Yes);

        (, , , , , , , MilestoneFunding.ProjectState state) = mf.getProjectCore(
            1
        );
        assertEq(
            uint(state),
            uint(MilestoneFunding.ProjectState.FailureRound1)
        );

        vm.prank(investor1);
        mf.claimInvestor();
        vm.prank(investor2);
        mf.claimInvestor();

        uint256 ownerBefore = owner.balance;
        vm.prank(owner);
        mf.claimOwner();
        assertEq(owner.balance - ownerBefore, bond);
    }

    function testClaimCreator() public {
        uint256 softCap = 10 ether;
        uint256 bond = softCap / 10;

        vm.deal(creator, bond);
        vm.prank(creator);
        mf.createProject{value: bond}(
            "Test Project",
            "Description",
            softCap,
            MilestoneFunding.Category.Technology,
            _milestones()
        );

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
}
