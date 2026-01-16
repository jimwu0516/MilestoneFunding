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
    address investor3;
    address deployer;

    function setUp() public {
        creator = vm.addr(1);
        investor1 = vm.addr(2);
        investor2 = vm.addr(3);
        investor3 = vm.addr(4);
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

    /*-----------------------TEST CREATE PROJECT-----------------------*/
    function testCreateProject() public {
        string[3] memory milestones = _milestones();
        uint256 softCap = 1 ether;

        vm.deal(creator, softCap / 10);
        vm.prank(creator);
        mf.createProject{value: softCap / 10}(
            "Project A",
            "Description A",
            softCap,
            MilestoneFunding.Category.Technology,
            milestones
        );

        (
            address pCreator,
            string memory name,
            ,
            MilestoneFunding.Category category,
            ,
            uint256 totalFunded,
            ,
            MilestoneFunding.ProjectState state
        ) = mf.getProjectCore(1);
        assertEq(pCreator, creator);
        assertEq(name, "Project A");
        assertEq(uint(category), uint(MilestoneFunding.Category.Technology));
        assertEq(totalFunded, 0);
        assertEq(uint(state), uint(MilestoneFunding.ProjectState.Funding));
    }

    /*-----------------------TEST CANCEL PROJECT-----------------------*/
    function testCancelProject() public {
        string[3] memory milestones = _milestones();
        uint256 softCap = 1 ether;

        // create project
        vm.deal(creator, softCap / 10);
        vm.prank(creator);
        mf.createProject{value: softCap / 10}(
            "Project B",
            "Desc",
            softCap,
            MilestoneFunding.Category.Hardware,
            milestones
        );

        // cancel project
        vm.prank(creator);
        mf.cancelProject(1);

        (, , , , , , , MilestoneFunding.ProjectState state) = mf.getProjectCore(
            1
        );
        assertEq(uint(state), uint(MilestoneFunding.ProjectState.Cancelled));

        vm.prank(owner);
        uint256 ownerClaim = mf.getClaimableOwner();
        assertEq(ownerClaim, softCap / 10);
    }

    /*-----------------------TEST FUND AND CANCEL PROJECT-----------------------*/
    function testFundAndCancelProject() public {
        string[3] memory milestones = _milestones();
        uint256 softCap = 1 ether;
        uint256 bond = softCap / 10;

        vm.deal(creator, bond);
        vm.prank(creator);
        mf.createProject{value: bond}(
            "Project F",
            "Desc",
            softCap,
            MilestoneFunding.Category.Creative,
            milestones
        );

        vm.deal(investor1, 0.6 ether);
        vm.prank(investor1);
        mf.fund{value: 0.6 ether}(1);

        vm.deal(investor2, 0.3 ether);
        vm.prank(investor2);
        mf.fund{value: 0.3 ether}(1);

        vm.prank(creator);
        mf.cancelProject(1);

        (, , , , , , , MilestoneFunding.ProjectState state) = mf.getProjectCore(
            1
        );
        assertEq(uint(state), uint(MilestoneFunding.ProjectState.Cancelled));

        vm.prank(owner);
        uint256 ownerClaim = mf.getClaimableOwner();
        assertEq(ownerClaim, bond / 2);

        uint256 refundPool = mf.refundPool(1);
        assertEq(refundPool, 0.9 ether + bond / 2);

        uint256 investor1BalBefore = investor1.balance;
        vm.prank(investor1);
        mf.claimRefund(1);
        uint256 investor1Refund = investor1.balance - investor1BalBefore;
        assertEq(investor1Refund, (0.6 ether * refundPool) / 0.9 ether);

        uint256 investor2BalBefore = investor2.balance;
        vm.prank(investor2);
        mf.claimRefund(1);
        uint256 investor2Refund = investor2.balance - investor2BalBefore;
        assertEq(investor2Refund, (0.3 ether * refundPool) / 0.9 ether);
    }

    /*-----------------------TEST SUBMIT MILESTONE AND VOTE PASS-----------------------*/
    function testSubmitMilestoneAndVotePass() public {
        string[3] memory milestones = _milestones();
        uint256 softCap = 1 ether;
        uint256 bond = softCap / 10;

        vm.deal(creator, bond);
        vm.prank(creator);
        mf.createProject{value: bond}(
            "Project D",
            "Desc",
            softCap,
            MilestoneFunding.Category.Creative,
            milestones
        );

        vm.deal(investor1, 0.3 ether);
        vm.prank(investor1);
        mf.fund{value: 0.3 ether}(1);

        vm.deal(investor2, 0.3 ether);
        vm.prank(investor2);
        mf.fund{value: 0.3 ether}(1);

        vm.deal(investor3, 0.4 ether);
        vm.prank(investor3);
        mf.fund{value: 0.4 ether}(1);

        vm.prank(creator);
        mf.submitMilestone(1, "QmHash1");

        vm.prank(investor1);
        mf.vote(1, MilestoneFunding.VoteOption.Yes); //0.3

        vm.prank(investor2);
        mf.vote(1, MilestoneFunding.VoteOption.No); //0.3

        vm.prank(investor3);
        mf.vote(1, MilestoneFunding.VoteOption.Yes); //0.4

        (, , , , bool[3] memory finalized) = mf.getProjectVoting(1);
        assertTrue(finalized[0]);

        vm.prank(creator);
        uint256 claimable = mf.getClaimableCreator();
        assertEq(claimable, 200_000_000_000_000_000);
    }

    /*-----------------------TEST SUBMIT MILESTONE AND VOTE FAILED-----------------------*/
    function testSubmitMilestoneAndVoteFailed() public {
        string[3] memory milestones = _milestones();
        uint256 softCap = 1 ether;
        uint256 bond = softCap / 10;

        vm.deal(creator, bond);
        vm.prank(creator);
        mf.createProject{value: bond}(
            "Project D",
            "Desc",
            softCap,
            MilestoneFunding.Category.Creative,
            milestones
        );

        vm.deal(investor1, 0.6 ether);
        vm.prank(investor1);
        mf.fund{value: 0.6 ether}(1);

        vm.deal(investor2, 0.4 ether);
        vm.prank(investor2);
        mf.fund{value: 0.4 ether}(1);

        vm.prank(creator);
        mf.submitMilestone(1, "QmHash1");

        vm.prank(investor1);
        mf.vote(1, MilestoneFunding.VoteOption.No);

        vm.prank(investor2);
        mf.vote(1, MilestoneFunding.VoteOption.No);

        (, , , , , , , MilestoneFunding.ProjectState state) = mf.getProjectCore(
            1
        );
        assertEq(
            uint(state),
            uint(MilestoneFunding.ProjectState.FailureRound1)
        );
    }

    /*-----------------------TEST VOTE FAIL REFUND AND OWNER GETS BOND-----------------------*/
    function testVoteFailRefundAndOwnerGetsBond() public {
        string[3] memory milestones = _milestones();
        uint256 softCap = 1 ether;
        uint256 bond = softCap / 10;

        vm.deal(creator, bond);
        vm.prank(creator);
        mf.createProject{value: bond}(
            "Project D",
            "Desc",
            softCap,
            MilestoneFunding.Category.Creative,
            milestones
        );

        vm.deal(investor1, 0.3 ether);
        vm.prank(investor1);
        mf.fund{value: 0.3 ether}(1);

        vm.deal(investor2, 0.3 ether);
        vm.prank(investor2);
        mf.fund{value: 0.3 ether}(1);

        vm.deal(investor3, 0.4 ether);
        vm.prank(investor3);
        mf.fund{value: 0.4 ether}(1);

        vm.prank(creator);
        mf.submitMilestone(1, "QmHash1");

        vm.prank(investor1);
        mf.vote(1, MilestoneFunding.VoteOption.Yes);
        vm.prank(investor2);
        mf.vote(1, MilestoneFunding.VoteOption.Yes);
        vm.prank(investor3);
        mf.vote(1, MilestoneFunding.VoteOption.Yes);

        vm.prank(creator);
        mf.submitMilestone(1, "QmHash2"); // projectId = 1

        vm.prank(investor1);
        mf.vote(1, MilestoneFunding.VoteOption.No);
        vm.prank(investor2);
        mf.vote(1, MilestoneFunding.VoteOption.No);
        vm.prank(investor3);
        mf.vote(1, MilestoneFunding.VoteOption.No);

        (, , , , , , , MilestoneFunding.ProjectState state) = mf.getProjectCore(
            1
        );
        assertEq(
            uint(state),
            uint(MilestoneFunding.ProjectState.FailureRound2)
        );

        uint256 bal1 = investor1.balance;
        uint256 bal2 = investor2.balance;
        uint256 bal3 = investor3.balance;

        vm.prank(investor1);
        mf.claimAllRefund();
        vm.prank(investor2);
        mf.claimAllRefund();
        vm.prank(investor3);
        mf.claimAllRefund();

        assertEq(investor1.balance - bal1, 0.24 ether);
        assertEq(investor2.balance - bal2, 0.24 ether);
        assertEq(investor3.balance - bal3, 0.32 ether);

        vm.prank(owner);
        uint256 ownerClaim = mf.getClaimableOwner();
        assertEq(ownerClaim, bond);

        vm.prank(creator);
        uint256 creatorClaim = mf.getClaimableCreator();
        assertEq(creatorClaim, 0.2 ether);
    }
}
