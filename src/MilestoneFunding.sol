// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MilestoneFunding is Ownable, ReentrancyGuard {
    constructor() Ownable(msg.sender) {}

    /*-----------------------ENUM-----------------------*/

    enum ProjectState {
        Funding,
        Cancelled,
        BuildingStage1,
        VotingRound1,
        BuildingStage2,
        VotingRound2,
        BuildingStage3,
        VotingRound3,
        Completed,
        FailureRound1,
        FailureRound2,
        FailureRound3
    }

    enum VoteOption {
        None,
        Yes,
        No
    }

    /*-----------------------STRUCT-----------------------*/

    struct Project {
        address creator;
        string name;
        string description;
        uint256 softCapWei;
        uint256 totalFunded;
        uint256 bond;
        ProjectState state;
        address[] investors;
        mapping(address => uint256) invested;
        mapping(address => bool) isInvestor;
        uint256 snapshotTotalFund;
        uint256 snapshotTotalWeight;
        mapping(address => uint256) snapshotInvest;
        mapping(address => VoteOption[3]) votes;
        uint256[3] yesWeight;
        uint256[3] noWeight;
        bool[3] finalized;
        string[3] milestoneHashes;
    }

    /*-----------------------STORAGE-----------------------*/

    uint256 public projectCount;
    mapping(uint256 => Project) private projects;

    /*-----------------------CLAIM LEDGERS-----------------------*/

    mapping(address => uint256) public claimableInvestor;
    mapping(address => uint256) public claimableCreator;
    mapping(address => uint256) public claimableOwner;

    /*-----------------------EVENTS-----------------------*/

    event ProjectCreated(
        uint256 indexed projectId,
        string name,
        string description,
        uint256 softCapWei,
        address indexed creator
    );

    event Funded(
        uint256 indexed projectId,
        address indexed investor,
        uint256 amount
    );
    event MilestoneSubmitted(
        uint256 indexed projectId,
        uint256 milestone,
        string ipfsHash
    );
    event Voted(
        uint256 indexed projectId,
        address indexed voter,
        uint256 milestone,
        VoteOption vote
    );
    event VoteFinalized(
        uint256 indexed projectId,
        uint256 milestone,
        bool passed
    );
    event Claim(address indexed user, uint256 amount, string role);
    event ProjectCancelled(uint256 indexed projectId);

    /*-----------------------CREATE PROJECT-----------------------*/

    function createProject(
        string calldata name,
        string calldata description,
        uint256 softCapWei
    ) external payable {
        require(softCapWei > 0, "Soft cap = 0");

        uint256 bondWei = softCapWei / 10;
        require(msg.value == bondWei, "Bond = 10%");

        projectCount++;
        Project storage p = projects[projectCount];

        p.creator = msg.sender;
        p.name = name;
        p.description = description;
        p.softCapWei = softCapWei;
        p.bond = bondWei;
        p.state = ProjectState.Funding;

        emit ProjectCreated(
            projectCount,
            name,
            description,
            softCapWei,
            msg.sender
        );
    }

    /*-----------------------FUNDING-----------------------*/

    function fund(uint256 projectId) external payable nonReentrant {
        Project storage p = projects[projectId];
        require(p.state == ProjectState.Funding, "Not funding");
        require(msg.value > 0, "Zero value");

        uint256 remaining = p.softCapWei - p.totalFunded;
        require(remaining > 0, "Already funded");

        uint256 accepted = msg.value;
        uint256 refund;

        if (msg.value > remaining) {
            accepted = remaining;
            refund = msg.value - remaining;
        }

        if (!p.isInvestor[msg.sender]) {
            p.isInvestor[msg.sender] = true;
            p.investors.push(msg.sender);
        }

        p.invested[msg.sender] += accepted;
        p.totalFunded += accepted;

        emit Funded(projectId, msg.sender, accepted);

        if (p.totalFunded >= p.softCapWei) {
            _snapshot(p);
            p.state = ProjectState.BuildingStage1;
        }

        if (refund > 0) {
            (bool ok, ) = msg.sender.call{value: refund}("");
            require(ok, "Refund failed");
        }
    }

    function cancelProject(uint256 projectId) external nonReentrant {
        Project storage p = projects[projectId];

        require(msg.sender == p.creator, "Not creator");
        require(p.state == ProjectState.Funding, "Can only cancel in Funding");

        p.state = ProjectState.Cancelled;

        uint256 totalFunded = p.totalFunded;
        uint256 bond = p.bond;

        for (uint256 i = 0; i < p.investors.length; i++) {
            address inv = p.investors[i];
            uint256 investedAmount = p.invested[inv];

            if (investedAmount > 0) {
                uint256 refund = investedAmount;

                if (bond > 0 && totalFunded > 0) {
                    uint256 bondShare = (bond * investedAmount) / totalFunded;
                    refund += bondShare;
                }

                claimableInvestor[inv] += refund;
                p.invested[inv] = 0;
            }
        }

        emit ProjectCancelled(projectId);

        p.bond = 0;
    }

    function _snapshot(Project storage p) internal {
        uint256 totalWeight;
        p.snapshotTotalFund = p.totalFunded;

        for (uint256 i = 0; i < p.investors.length; i++) {
            address inv = p.investors[i];
            uint256 amount = p.invested[inv];
            p.snapshotInvest[inv] = amount;
            totalWeight += _weight(amount, p.snapshotTotalFund);
        }

        p.snapshotTotalWeight = totalWeight;
    }

    function submitMilestone(
        uint256 projectId,
        string calldata ipfsHash
    ) external {
        Project storage p = projects[projectId];
        require(msg.sender == p.creator, "Not creator");

        uint256 m;
        if (p.state == ProjectState.BuildingStage1) m = 0;
        else if (p.state == ProjectState.BuildingStage2) m = 1;
        else if (p.state == ProjectState.BuildingStage3) m = 2;
        else revert("Wrong stage");

        p.milestoneHashes[m] = ipfsHash;
        p.state = ProjectState(uint256(ProjectState.VotingRound1) + m * 2);

        emit MilestoneSubmitted(projectId, m, ipfsHash);
    }

    function vote(uint256 projectId, VoteOption option) external {
        Project storage p = projects[projectId];
        require(p.isInvestor[msg.sender], "Not investor");
        require(
            option == VoteOption.Yes || option == VoteOption.No,
            "Invalid vote option"
        );

        uint256 m = _currentMilestone(p);
        require(!p.finalized[m], "Finalized");
        require(p.votes[msg.sender][m] == VoteOption.None, "Voted");

        p.votes[msg.sender][m] = option;
        uint256 w = _weight(p.snapshotInvest[msg.sender], p.snapshotTotalFund);

        if (option == VoteOption.Yes) p.yesWeight[m] += w;
        else p.noWeight[m] += w;

        emit Voted(projectId, msg.sender, m, option);

        _tryFinalize(p, projectId, m);
    }

    /*-----------------------FINALIZE LOGIC-----------------------*/

    function _tryFinalize(
        Project storage p,
        uint256 projectId,
        uint256 m
    ) internal {
        uint256 yes = p.yesWeight[m];
        uint256 no = p.noWeight[m];
        uint256 total = p.snapshotTotalWeight;

        uint256 voted = yes + no;
        uint256 remaining = total > voted ? total - voted : 0;

        if (voted * 100 < total * 70) return;

        if (no * 100 >= total * 40) {
            _finalize(p, projectId, m, false);
            return;
        }

        if (yes > no + remaining) {
            _finalize(p, projectId, m, true);
        }
    }

    function _finalize(
        Project storage p,
        uint256 projectId,
        uint256 m,
        bool passed
    ) internal {
        require(!p.finalized[m], "Done");
        p.finalized[m] = true;

        emit VoteFinalized(projectId, m, passed);
        _handleResult(p, m, passed);
    }

    /*-----------------------HANDLE RESULT-----------------------*/

    function _handleResult(Project storage p, uint256 m, bool passed) internal {
        uint256 alreadyReleased;

        for (uint256 i = 0; i < m; i++) {
            if (i == 0) alreadyReleased += (p.totalFunded * 20) / 100;
            if (i == 1) alreadyReleased += (p.totalFunded * 30) / 100;
            if (i == 2) alreadyReleased += (p.totalFunded * 50) / 100;
        }

        if (!passed) {
            p.state = ProjectState(uint256(ProjectState.FailureRound1) + m);
            claimableOwner[owner()] += p.bond;

            uint256 refundTotal = p.totalFunded - alreadyReleased;
            for (uint256 i = 0; i < p.investors.length; i++) {
                address inv = p.investors[i];
                uint256 refund = (refundTotal * p.invested[inv]) /
                    p.totalFunded;
                if (refund > 0) claimableInvestor[inv] += refund;
            }
            return;
        }

        uint256 release;
        if (m == 0) {
            release = (p.totalFunded * 20) / 100;
            p.state = ProjectState.BuildingStage2;
        } else if (m == 1) {
            release = (p.totalFunded * 30) / 100;
            p.state = ProjectState.BuildingStage3;
        } else {
            release = (p.totalFunded * 50) / 100;
            p.state = ProjectState.Completed;
            claimableCreator[p.creator] += p.bond;
        }

        claimableCreator[p.creator] += release;
    }

    /*-----------------------CLAIM FUNCTIONS-----------------------*/

    function claimInvestor() external nonReentrant {
        uint256 amount = claimableInvestor[msg.sender];
        require(amount > 0, "Nothing");
        claimableInvestor[msg.sender] = 0;
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok);
        emit Claim(msg.sender, amount, "INVESTOR");
    }

    function claimCreator() external nonReentrant {
        uint256 amount = claimableCreator[msg.sender];
        require(amount > 0, "Nothing");
        claimableCreator[msg.sender] = 0;
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok);
        emit Claim(msg.sender, amount, "CREATOR");
    }

    function claimOwner() external nonReentrant {
        require(msg.sender == owner(), "Only owner");
        uint256 amount = claimableOwner[msg.sender];
        require(amount > 0, "Nothing");
        claimableOwner[msg.sender] = 0;
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok);
        emit Claim(msg.sender, amount, "OWNER");
    }

    /*-----------------------UTILS-----------------------*/

    function _currentMilestone(
        Project storage p
    ) internal view returns (uint256) {
        if (p.state == ProjectState.VotingRound1) return 0;
        if (p.state == ProjectState.VotingRound2) return 1;
        if (p.state == ProjectState.VotingRound3) return 2;
        revert("Not voting");
    }

    function _weight(
        uint256 invest,
        uint256 total
    ) internal pure returns (uint256) {
        if (invest == 0 || total == 0) return 0;
        return (_sqrt(invest * 1e18) * _log(invest + 1)) / _log(total + 1);
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    function _log(uint256 x) internal pure returns (uint256) {
        uint256 n;
        while (x > 1) {
            x >>= 1;
            n++;
        }
        return n * 1e18;
    }

    /*-----------------------GET FUNCTION-----------------------*/

    function getProjectCore(
        uint256 projectId
    )
        external
        view
        returns (
            address creator,
            string memory name,
            string memory description,
            uint256 softCapWei,
            uint256 totalFunded,
            uint256 bond,
            string memory state
        )
    {
        Project storage p = projects[projectId];
        return (
            p.creator,
            p.name,
            p.description,
            p.softCapWei,
            p.totalFunded,
            p.bond,
            getProjectState(projectId)
        );
    }

    function getProjectVoting(
        uint256 projectId
    )
        external
        view
        returns (
            uint256 snapshotTotalFund,
            uint256 snapshotTotalWeight,
            uint256[3] memory yesWeight,
            uint256[3] memory noWeight,
            bool[3] memory finalized
        )
    {
        Project storage p = projects[projectId];
        return (
            p.snapshotTotalFund,
            p.snapshotTotalWeight,
            p.yesWeight,
            p.noWeight,
            p.finalized
        );
    }

    function getProjectMeta(
        uint256 projectId
    )
        external
        view
        returns (string[3] memory milestoneHashes, address[] memory investors)
    {
        Project storage p = projects[projectId];
        return (p.milestoneHashes, p.investors);
    }

    function getAllInvestments(
        uint256 projectId
    ) external view returns (address[] memory, uint256[] memory) {
        Project storage p = projects[projectId];
        uint256 len = p.investors.length;
        uint256[] memory investments = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            investments[i] = p.invested[p.investors[i]];
        }

        return (p.investors, investments);
    }

    function getProjectState(
        uint256 projectId
    ) public view returns (string memory) {
        Project storage p = projects[projectId];

        if (p.state == ProjectState.Funding) return "Funding";
        if (p.state == ProjectState.Cancelled) return "Cancelled";
        if (p.state == ProjectState.BuildingStage1) return "BuildingStage1";
        if (p.state == ProjectState.VotingRound1) return "VotingRound1";
        if (p.state == ProjectState.BuildingStage2) return "BuildingStage2";
        if (p.state == ProjectState.VotingRound2) return "VotingRound2";
        if (p.state == ProjectState.BuildingStage3) return "BuildingStage3";
        if (p.state == ProjectState.VotingRound3) return "VotingRound3";
        if (p.state == ProjectState.Completed) return "Completed";
        if (p.state == ProjectState.FailureRound1) return "FailureRound1";
        if (p.state == ProjectState.FailureRound2) return "FailureRound2";
        if (p.state == ProjectState.FailureRound3) return "FailureRound3";

        return "Unknown";
    }

    function getAllFundingProjects() external view returns (uint256[] memory) {
        uint256 count;

        for (uint256 i = 1; i <= projectCount; i++) {
            if (projects[i].state == ProjectState.Funding) {
                count++;
            }
        }

        uint256[] memory fundingProjects = new uint256[](count);
        uint256 index = 0;

        for (uint256 i = 1; i <= projectCount; i++) {
            if (projects[i].state == ProjectState.Funding) {
                fundingProjects[index] = i;
                index++;
            }
        }

        return fundingProjects;
    }

    function getMyInvestedProjects()
        external
        view
        returns (
            uint256[] memory projectIds,
            address[] memory creators,
            string[] memory names,
            string[] memory descriptions,
            uint256[] memory softCaps,
            uint256[] memory totalFundeds,
            uint256[] memory bonds,
            string[] memory states,
            uint256[] memory investments
        )
    {
        uint256 count;

        for (uint256 i = 1; i <= projectCount; i++) {
            if (projects[i].isInvestor[msg.sender]) {
                count++;
            }
        }

        projectIds = new uint256[](count);
        creators = new address[](count);
        names = new string[](count);
        descriptions = new string[](count);
        softCaps = new uint256[](count);
        totalFundeds = new uint256[](count);
        bonds = new uint256[](count);
        states = new string[](count);
        investments = new uint256[](count);

        uint256 index = 0;

        for (uint256 i = 1; i <= projectCount; i++) {
            if (projects[i].isInvestor[msg.sender]) {
                Project storage p = projects[i];
                projectIds[index] = i;
                creators[index] = p.creator;
                names[index] = p.name;
                descriptions[index] = p.description;
                softCaps[index] = p.softCapWei;
                totalFundeds[index] = p.totalFunded;
                bonds[index] = p.bond;
                states[index] = getProjectState(i);
                investments[index] = p.invested[msg.sender];
                index++;
            }
        }
    }

    function getClaimableInvestor() external view returns (uint256) {
        return claimableInvestor[msg.sender];
    }

    function getClaimableCreator() external view returns (uint256) {
        return claimableCreator[msg.sender];
    }
}
