// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MilestoneFunding is Ownable, ReentrancyGuard {
    uint256 constant MIN_INVEST = 1e14;

    constructor() Ownable(msg.sender) {}

    /*-----------------------ENUM-----------------------*/

    enum ProjectState {
        Cancelled,
        Funding,
        BuildingStage1,
        VotingRound1,
        FailureRound1,
        BuildingStage2,
        VotingRound2,
        FailureRound2,
        BuildingStage3,
        VotingRound3,
        FailureRound3,
        Completed
    }

    enum Category {
        Technology,
        Hardware,
        Creative,
        Education,
        SocialImpact,
        Research,
        Business,
        Community
    }

    enum VoteOption {
        None,
        Yes,
        No
    }

    /*-----------------------STRUCT-----------------------*/

    struct InvestorInfo {
        uint256 amount;
        uint32 weight;
        VoteOption[3] votes;
        bool exists;
        bool refunded;
    }

    struct Project {
        address creator;
        string name;
        string description;
        Category category;
        uint256 softCapWei;
        uint256 totalFunded;
        uint256 bond;
        ProjectState state;
        string[3] milestoneDescriptions;
        string[3] milestoneHashes;
        bool[3] finalized;
        uint256 snapshotTotalWeight;
        address[] investorList;
        mapping(address => InvestorInfo) investors;
        uint256[3] yesWeight;
        uint256[3] noWeight;
        uint256[3] votedWeight;
    }

    /*-----------------------STORAGE-----------------------*/

    uint256 public projectCount;
    mapping(uint256 => Project) private projects;

    mapping(address => uint256) public claimableCreator;
    mapping(address => uint256) public claimableOwner;
    mapping(uint256 => uint256) public refundPool;

    /*-----------------------EVENTS-----------------------*/

    event ProjectCreated(
        uint256 indexed projectId,
        string name,
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
    event Claim(
        address indexed user, 
        uint256 amount, 
        string role
    );
    event ProjectCancelled(
        uint256 indexed projectId
    );
    event MilestoneReleased(
        uint256 indexed projectId,
        uint256 milestone,
        address indexed recipient,
        uint256 amount
    );
    event VotingStarted(
        uint256 indexed projectId,
        string projectName,
        uint256 milestone,
        address[] investors
    );


    /*-----------------------CREATE PROJECT-----------------------*/

    function createProject(
        string calldata name,
        string calldata description,
        uint256 softCapWei,
        Category category,
        string[3] calldata milestoneDescriptions
    ) external payable {
        require(softCapWei >= MIN_INVEST, "Soft cap too low");
        uint256 bondWei = softCapWei / 10;
        require(msg.value == bondWei, "Bond must be 10%");

        require(
            bytes(description).length > 0 && bytes(description).length <= 1024,
            "Invalid description"
        );
        for (uint i = 0; i < 3; i++) {
            require(
                bytes(milestoneDescriptions[i]).length > 0 &&
                    bytes(milestoneDescriptions[i]).length <= 256,
                "Invalid milestone"
            );
        }
        require(uint(category) <= uint(Category.Community), "Invalid category");

        projectCount++;
        Project storage p = projects[projectCount];
        p.creator = msg.sender;
        p.name = name;
        p.description = description;
        p.category = category;
        p.softCapWei = softCapWei;
        p.bond = bondWei;
        p.state = ProjectState.Funding;
        p.milestoneDescriptions = milestoneDescriptions;

        emit ProjectCreated(projectCount, name, softCapWei, msg.sender);
    }

    /*-----------------------FUNDING-----------------------*/

    function fund(uint256 projectId) external payable nonReentrant {
        Project storage p = projects[projectId];
        require(p.state == ProjectState.Funding, "Not funding");
        require(msg.value >= MIN_INVEST, "Investment too small");

        uint256 remaining = p.softCapWei - p.totalFunded;
        require(remaining > 0, "Already funded");

        uint256 accepted = msg.value;
        uint256 refund = 0;
        if (msg.value > remaining) {
            accepted = remaining;
            refund = msg.value - remaining;
        }

        InvestorInfo storage inv = p.investors[msg.sender];
        if (!inv.exists) {
            inv.exists = true;
            p.investorList.push(msg.sender);
        }

        uint32 prevWeight = inv.weight;
        inv.amount += accepted;
        inv.weight = _weight(inv.amount);
        p.snapshotTotalWeight = p.snapshotTotalWeight + inv.weight - prevWeight;

        p.totalFunded += accepted;

        emit Funded(projectId, msg.sender, accepted);

        if (p.totalFunded >= p.softCapWei) {
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
        require(
            p.state == ProjectState.Funding,
            "Can only cancel during Funding"
        );

        p.state = ProjectState.Cancelled;
        uint256 totalFunded = p.totalFunded;
        uint256 bond = p.bond;

        if (totalFunded == 0) {
            claimableOwner[owner()] += bond;
        } else {
            uint256 halfBond = bond / 2;
            uint256 remainingBond = bond - halfBond;
            claimableOwner[owner()] += halfBond;
            refundPool[projectId] = totalFunded + remainingBond;
        }

        emit ProjectCancelled(projectId);
        p.bond = 0;
    }

    /*-----------------------MILESTONE & VOTE-----------------------*/

    function submitMilestone(
        uint256 projectId,
        string calldata ipfsHash
    ) external {
        Project storage p = projects[projectId];
        require(msg.sender == p.creator, "Not creator");

        uint256 len = bytes(ipfsHash).length;
        require(len > 0 && len <= 128, "Invalid IPFS hash");

        uint256 m = _currentMilestoneIndex(p);
        require(p.state == ProjectState(uint8(ProjectState.BuildingStage1) + m * 3), "Not building stage");
        require(bytes(p.milestoneHashes[m]).length == 0, "Already submitted");
        p.milestoneHashes[m] = ipfsHash;
        p.state = ProjectState(uint8(ProjectState.VotingRound1) + m * 3);

        emit MilestoneSubmitted(projectId, m, ipfsHash);
        emit VotingStarted(projectId, p.name, m+1, p.investorList);
    }

    function vote(uint256 projectId, VoteOption option) external {
        Project storage p = projects[projectId];
        InvestorInfo storage inv = p.investors[msg.sender];

        uint256 m = _currentMilestoneIndex(p);
        require(inv.votes[m] == VoteOption.None, "Already voted");
        require(p.state == ProjectState(uint8(ProjectState.VotingRound1) + m * 3), "Not in voting stage");
        require(option == VoteOption.Yes || option == VoteOption.No,"Invalid vote option");


        inv.votes[m] = option;

        uint256 w = inv.weight;

        if (option == VoteOption.Yes) {
            p.yesWeight[m] += w;
        } else {
            p.noWeight[m] += w;
        }

        p.votedWeight[m] += w;

        emit Voted(projectId, msg.sender, m, option);

        _tryFinalize(p, projectId, m);
    }

    function _tryFinalize(
        Project storage p,
        uint256 projectId,
        uint256 m
    ) internal {
        uint256 yes = p.yesWeight[m];
        uint256 no = p.noWeight[m];
        uint256 voted = p.votedWeight[m];
        uint256 total = p.snapshotTotalWeight;

        bool quorum = voted * 100 >= total * 70;

        if (!quorum) return;

        if (no * 100 >= total * 40) {
            _finalize(p, projectId, m, false);
        } else if (yes > no + (total - voted)) {
            _finalize(p, projectId, m, true);
        }
    }

    function _finalize(
        Project storage p,
        uint256 projectId,
        uint256 m,
        bool passed
    ) internal {
        require(!p.finalized[m], "Already finalized");
        p.finalized[m] = true;
        emit VoteFinalized(projectId, m, passed);
        _handleResult(p, projectId, m, passed);
    }

    function _handleResult(
        Project storage p,
        uint256 projectId,
        uint256 m,
        bool passed
    ) internal {
        uint256 released;
        uint256[3] memory milestonesPerc = [
            uint256(20),
            uint256(30),
            uint256(50)
        ];
        for (uint i = 0; i < m; i++)
            released += (p.totalFunded * milestonesPerc[i]) / 100;

        if (!passed) {
            p.state = ProjectState(uint8(ProjectState.FailureRound1) + m * 3);
            claimableOwner[owner()] += p.bond;
            refundPool[projectId] = p.totalFunded - released;
        } else {
            uint256 release = (p.totalFunded * milestonesPerc[m]) / 100;
            claimableCreator[p.creator] += release;

            emit MilestoneReleased(projectId, m + 1, p.creator, release);

            if (m == 2) {
                claimableCreator[p.creator] += p.bond;
                p.state = ProjectState.Completed;
            } else {
                p.state = ProjectState(
                    uint8(ProjectState.BuildingStage2) + m * 3
                );
            }
        }
    }

    /*-----------------------CLAIM FUNCTIONS-----------------------*/

    function claimCreator() external nonReentrant {
        uint256 amount = claimableCreator[msg.sender];
        require(amount > 0, "Nothing to claim");
        claimableCreator[msg.sender] = 0;
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok);
        emit Claim(msg.sender, amount, "CREATOR");
    }

    function claimOwner() external nonReentrant {
        require(msg.sender == owner(), "Only owner");
        uint256 amount = claimableOwner[msg.sender];
        require(amount > 0, "Nothing to claim");
        claimableOwner[msg.sender] = 0;
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok);
        emit Claim(msg.sender, amount, "OWNER");
    }

    function claimRefund(uint256 projectId) external nonReentrant {
        Project storage p = projects[projectId];
        InvestorInfo storage inv = p.investors[msg.sender];
        require(inv.exists && !inv.refunded, "No refund");
        require(_isRefundAvailable(p), "Refund not available");

        uint256 amount = (inv.amount * refundPool[projectId]) / p.totalFunded;
        inv.refunded = true;
        inv.amount = 0;

        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok);
        emit Claim(msg.sender, amount, "INVESTOR");
    }

    function claimAllRefund() external nonReentrant {
        uint256 totalPayout = 0;

        for (uint256 i = 1; i <= projectCount; i++) {
            Project storage p = projects[i];
            InvestorInfo storage inv = p.investors[msg.sender];

            if (!inv.exists || inv.refunded) continue;
            if (!_isRefundAvailable(p)) continue;
            if (inv.amount == 0) continue;

            uint256 refund = (inv.amount * refundPool[i]) / p.totalFunded;

            inv.refunded = true;
            inv.amount = 0;

            totalPayout += refund;
        }

        require(totalPayout > 0, "Nothing to claim");

        (bool ok, ) = msg.sender.call{value: totalPayout}("");
        require(ok, "Transfer failed");

        emit Claim(msg.sender, totalPayout, "INVESTORALL");
    }

    /*-----------------------UTILS-----------------------*/

    function _currentMilestoneIndex(
        Project storage p
    ) internal view returns (uint256) {
        uint8 s = uint8(p.state);
        if (
            s == uint8(ProjectState.BuildingStage1) ||
            s == uint8(ProjectState.VotingRound1) ||
            s == uint8(ProjectState.FailureRound1)
        ) return 0;
        if (
            s == uint8(ProjectState.BuildingStage2) ||
            s == uint8(ProjectState.VotingRound2) ||
            s == uint8(ProjectState.FailureRound2)
        ) return 1;
        if (
            s == uint8(ProjectState.BuildingStage3) ||
            s == uint8(ProjectState.VotingRound3) ||
            s == uint8(ProjectState.FailureRound3)
        ) return 2;
        revert("No current milestone");
    }

    function _isRefundAvailable(
        Project storage p
    ) internal view returns (bool) {
        uint s = uint(p.state);
        return s == 0 || s == 4 || s == 7 || s == 10;
    }

    function _weight(uint256 invest) internal pure returns (uint32) {
        if (invest == 0) return 0;
        uint256 w = _log2(invest + 1) * 1e5;
        if (w > type(uint32).max) w = type(uint32).max;
        // casting to 'uint32' is safe because [explain why]
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32(w);
    }

    function _log2(uint256 x) internal pure returns (uint256 y) {
        uint256 n = 0;
        if (x >= 2 ** 128) {
            x >>= 128;
            n += 128;
        }
        if (x >= 2 ** 64) {
            x >>= 64;
            n += 64;
        }
        if (x >= 2 ** 32) {
            x >>= 32;
            n += 32;
        }
        if (x >= 2 ** 16) {
            x >>= 16;
            n += 16;
        }
        if (x >= 2 ** 8) {
            x >>= 8;
            n += 8;
        }
        if (x >= 2 ** 4) {
            x >>= 4;
            n += 4;
        }
        if (x >= 2 ** 2) {
            x >>= 2;
            n += 2;
        }
        if (x >= 2 ** 1) {
            n += 1;
        }
        return n;
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
            Category category,
            uint256 softCapWei,
            uint256 totalFunded,
            uint256 bond,
            ProjectState state
        )
    {
        Project storage p = projects[projectId];
        return (
            p.creator,
            p.name,
            p.description,
            p.category,
            p.softCapWei,
            p.totalFunded,
            p.bond,
            p.state
        );
    }

    function getProjectVoting(
        uint256 projectId
    )
        external
        view
        returns (
            uint256 totalWeight,
            uint256[3] memory yesWeight,
            uint256[3] memory noWeight,
            bool[3] memory finalized
        )
    {
        Project storage p = projects[projectId];
        return (p.snapshotTotalWeight, p.yesWeight, p.noWeight, p.finalized);
    }

    function getProjectMeta(
        uint256 projectId
    )
        external
        view
        returns (string[3] memory milestoneHashes, address[] memory investors)
    {
        Project storage p = projects[projectId];
        return (p.milestoneHashes, p.investorList);
    }

    function getAllInvestments(
        uint256 projectId
    ) external view returns (address[] memory, uint256[] memory) {
        Project storage p = projects[projectId];
        uint256 len = p.investorList.length;
        uint256[] memory investments = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            address inv = p.investorList[i];
            investments[i] = p.investors[inv].amount;
        }

        return (p.investorList, investments);
    }

    function getProjectState(
        uint256 projectId
    ) public view returns (string memory) {
        Project storage p = projects[projectId];

        string[12] memory states = [
            "Cancelled",
            "Funding",
            "BuildingStage1",
            "VotingRound1",
            "FailureRound1",
            "BuildingStage2",
            "VotingRound2",
            "FailureRound2",
            "BuildingStage3",
            "VotingRound3",
            "FailureRound3",
            "Completed"
        ];

        return states[uint(p.state)];
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
            Category[] memory categories,
            uint256[] memory softCaps,
            uint256[] memory totalFundeds,
            uint256[] memory bonds,
            ProjectState[] memory states,
            uint256[] memory investments,
            string[3][] memory milestones
        )
    {
        uint256 count = 0;
        for (uint256 i = 1; i <= projectCount; i++) {
            if (projects[i].investors[msg.sender].exists) {
                count++;
            }
        }

        projectIds = new uint256[](count);
        creators = new address[](count);
        names = new string[](count);
        descriptions = new string[](count);
        categories = new Category[](count);
        softCaps = new uint256[](count);
        totalFundeds = new uint256[](count);
        bonds = new uint256[](count);
        states = new ProjectState[](count);
        investments = new uint256[](count);
        milestones = new string[3][](count);

        uint256 index = 0;
        for (uint256 i = 1; i <= projectCount; i++) {
            if (projects[i].investors[msg.sender].exists) {
                Project storage p = projects[i];
                projectIds[index] = i;
                creators[index] = p.creator;
                names[index] = p.name;
                descriptions[index] = p.description;
                categories[index] = p.category;
                softCaps[index] = p.softCapWei;
                totalFundeds[index] = p.totalFunded;
                bonds[index] = p.bond;
                states[index] = p.state;
                investments[index] = p.investors[msg.sender].amount;
                milestones[index] = p.milestoneDescriptions;
                index++;
            }
        }
    }

    function getMilestoneDescriptions(
        uint256 projectId
    ) external view returns (string[3] memory) {
        return projects[projectId].milestoneDescriptions;
    }

    function getClaimableCreator() external view returns (uint256) {
        return claimableCreator[msg.sender];
    }

    function getClaimableOwner() external view returns (uint256) {
        return claimableOwner[msg.sender];
    }

    function getAllClaimableRefund()
        external
        view
        returns (uint256 totalRefund)
    {
        totalRefund = 0;

        for (uint256 i = 1; i <= projectCount; i++) {
            Project storage p = projects[i];
            InvestorInfo storage inv = p.investors[msg.sender];

            if (!inv.exists || inv.refunded) continue;
            if (!_isRefundAvailable(p)) continue;

            uint256 refund = (inv.amount * refundPool[i]) / p.totalFunded;
            totalRefund += refund;
        }
    }

    function getMyVotes(
        uint256 projectId,
        address user
    ) external view returns (VoteOption[3] memory) {
        return projects[projectId].investors[user].votes;
    }
}
