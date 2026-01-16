// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MilestoneFunding is Ownable, ReentrancyGuard {
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

    struct ProjectCore {
        address creator;
        Category category;
        uint256 softCapWei;
        uint256 totalFunded;
        uint256 bond;
        ProjectState state;
    }

    struct ProjectMeta {
        string name;
        string description;
        string[3] milestoneDescriptions;
        string[3] milestoneHashes;
    }

    struct ProjectVoting {
        uint256 snapshotTotalFund;
        uint256 snapshotTotalWeight;
        uint256[3] yesWeight;
        uint256[3] noWeight;
        bool[3] finalized;
    }

    /*-----------------------STORAGE-----------------------*/

    uint256 public projectCount;

    mapping(uint256 => ProjectCore) public projectCore;
    mapping(uint256 => ProjectMeta) public projectMeta;
    mapping(uint256 => ProjectVoting) public projectVoting;

    mapping(uint256 => mapping(address => uint256)) public invested;
    mapping(uint256 => mapping(address => bool)) public isInvestor;
    mapping(uint256 => mapping(address => VoteOption[3])) public votes;
    mapping(uint256 => address[]) public investors;

    mapping(uint256 => mapping(address => uint256)) public snapshotWeight;

    /*-----------------------CLAIM LEDGERS-----------------------*/

    mapping(address => uint256) public claimableCreator;
    mapping(address => uint256) public claimableOwner;

    mapping(uint256 => uint256) public refundPool;
    mapping(uint256 => mapping(address => bool)) public refundClaimed;

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
    event Claim(address indexed user, uint256 amount, string role);
    event ProjectCancelled(uint256 indexed projectId);

    /*-----------------------CREATE PROJECT-----------------------*/

    function createProject(
        string calldata name,
        string calldata description,
        uint256 softCapWei,
        Category category,
        string[3] calldata milestoneDescriptions
    ) external payable {
        require(
            softCapWei >= 100000000000000,
            "Soft cap must be >= 0.0001 ETH"
        );

        uint256 bondWei = softCapWei / 10;
        require(msg.value == bondWei, "Bond = 10%");

        require(bytes(description).length > 0, "Description required");
        require(bytes(description).length <= 1024, "Description too long");

        for (uint i = 0; i < 3; i++) {
            require(
                bytes(milestoneDescriptions[i]).length > 0,
                "Empty milestone description"
            );
            require(bytes(milestoneDescriptions[i]).length <= 256, "Too long");
        }
        require(uint(category) <= uint(Category.Community), "Invalid category");

        projectCount++;
        uint256 projectId = projectCount;

        projectCore[projectId] = ProjectCore({
            creator: msg.sender,
            category: category,
            softCapWei: softCapWei,
            totalFunded: 0,
            bond: bondWei,
            state: ProjectState.Funding
        });

        projectMeta[projectId] = ProjectMeta({
            name: name,
            description: description,
            milestoneDescriptions: milestoneDescriptions,
            milestoneHashes: ["", "", ""]
        });

        projectVoting[projectId] = ProjectVoting({
            snapshotTotalFund: 0,
            snapshotTotalWeight: 0,
            yesWeight: [uint256(0), 0, 0],
            noWeight: [uint256(0), 0, 0],
            finalized: [false, false, false]
        });

        emit ProjectCreated(projectId, name, softCapWei, msg.sender);
    }

    /*-----------------------FUNDING-----------------------*/

    function fund(uint256 projectId) external payable nonReentrant {
        ProjectCore storage c = projectCore[projectId];
        require(c.state == ProjectState.Funding, "Not funding");
        require(msg.value >= 100000000000000, "Value must be >= 0.0001 ETH");

        uint256 remaining = c.softCapWei - c.totalFunded;
        require(remaining > 0, "Already funded");

        uint256 accepted = msg.value;
        uint256 refund;

        if (msg.value > remaining) {
            accepted = remaining;
            refund = msg.value - remaining;
        }

        if (!isInvestor[projectId][msg.sender]) {
            isInvestor[projectId][msg.sender] = true;
            investors[projectId].push(msg.sender);
        }

        invested[projectId][msg.sender] += accepted;
        c.totalFunded += accepted;

        emit Funded(projectId, msg.sender, accepted);

        if (c.totalFunded >= c.softCapWei) {
            _snapshot(projectId);
            c.state = ProjectState.BuildingStage1;
        }

        if (refund > 0) {
            (bool ok, ) = msg.sender.call{value: refund}("");
            require(ok, "Refund failed");
        }
    }

    function cancelProject(uint256 projectId) external nonReentrant {
        ProjectCore storage c = projectCore[projectId];
        require(msg.sender == c.creator, "Not creator");
        require(c.state == ProjectState.Funding, "Can only cancel in Funding");

        c.state = ProjectState.Cancelled;

        uint256 totalFunded = c.totalFunded;
        uint256 bond = c.bond;

        if (totalFunded == 0) {
            claimableOwner[owner()] += bond;
        } else {
            claimableOwner[owner()] += bond / 2;
            uint256 investorBond = bond - (bond / 2);
            refundPool[projectId] = totalFunded + investorBond;
        }

        emit ProjectCancelled(projectId);
        c.bond = 0;
    }

    function _snapshot(uint256 projectId) internal {
        ProjectCore storage c = projectCore[projectId];
        ProjectVoting storage v = projectVoting[projectId];

        uint256 totalWeight;
        v.snapshotTotalFund = c.totalFunded;

        for (uint256 i = 0; i < investors[projectId].length; i++) {
            address inv = investors[projectId][i];
            uint256 amount = invested[projectId][inv];
            uint256 w = _weight(amount, v.snapshotTotalFund);
            snapshotWeight[projectId][inv] = w;
            totalWeight += w;
        }

        v.snapshotTotalWeight = totalWeight;
    }

    /*-----------------------MILESTONE-----------------------*/

    function submitMilestone(
        uint256 projectId,
        string calldata ipfsHash
    ) external {
        ProjectCore storage c = projectCore[projectId];
        ProjectMeta storage m = projectMeta[projectId];
        require(msg.sender == c.creator, "Not creator");

        uint256 len = bytes(ipfsHash).length;
        require(len > 0, "IPFS hash required");
        require(len <= 128, "IPFS hash too long");

        if (len == 46) {
            bytes memory hashBytes = bytes(ipfsHash);
            require(
                hashBytes[0] == "Q" && hashBytes[1] == "m",
                "Invalid CIDv0"
            );
        }

        uint256 milestone;
        if (c.state == ProjectState.BuildingStage1) {
            milestone = 0;
            c.state = ProjectState.VotingRound1;
        } else if (c.state == ProjectState.BuildingStage2) {
            milestone = 1;
            c.state = ProjectState.VotingRound2;
        } else if (c.state == ProjectState.BuildingStage3) {
            milestone = 2;
            c.state = ProjectState.VotingRound3;
        } else {
            revert("Wrong stage");
        }

        m.milestoneHashes[milestone] = ipfsHash;
        emit MilestoneSubmitted(projectId, milestone, ipfsHash);
    }

    function vote(uint256 projectId, VoteOption option) external {
        require(
            option == VoteOption.Yes || option == VoteOption.No,
            "Invalid vote option"
        );
        require(isInvestor[projectId][msg.sender], "Not investor");

        ProjectVoting storage v = projectVoting[projectId];
        uint256 mIndex = _currentMilestone(projectId);

        require(!v.finalized[mIndex], "Finalized");
        require(
            votes[projectId][msg.sender][mIndex] == VoteOption.None,
            "Voted"
        );

        votes[projectId][msg.sender][mIndex] = option;
        uint256 w = snapshotWeight[projectId][msg.sender];
        require(w > 0, "No voting weight");

        if (option == VoteOption.Yes) v.yesWeight[mIndex] += w;
        else v.noWeight[mIndex] += w;

        emit Voted(projectId, msg.sender, mIndex, option);
        _tryFinalize(projectId, mIndex);
    }

    /*-----------------------FINALIZE-----------------------*/

    function _tryFinalize(uint256 projectId, uint256 m) internal {
        ProjectVoting storage v = projectVoting[projectId];

        uint256 yes = v.yesWeight[m];
        uint256 no = v.noWeight[m];
        uint256 total = v.snapshotTotalWeight;

        uint256 voted = yes + no;
        uint256 remaining = total > voted ? total - voted : 0;

        if (voted * 100 < total * 70) return;

        if (no * 100 >= total * 40) {
            _finalize(projectId, m, false);
            return;
        }

        if (yes > no + remaining) {
            _finalize(projectId, m, true);
        }
    }

    function _finalize(uint256 projectId, uint256 m, bool passed) internal {
        ProjectVoting storage v = projectVoting[projectId];
        require(!v.finalized[m], "Already finalized");
        v.finalized[m] = true;

        emit VoteFinalized(projectId, m, passed);
        _handleResult(projectId, m, passed);
    }

    function _handleResult(uint256 projectId, uint256 m, bool passed) internal {
        ProjectCore storage c = projectCore[projectId];
        uint256 alreadyReleased;

        for (uint256 i = 0; i < m; i++) {
            if (i == 0) alreadyReleased += (c.totalFunded * 20) / 100;
            else if (i == 1) alreadyReleased += (c.totalFunded * 30) / 100;
            else if (i == 2) alreadyReleased += (c.totalFunded * 50) / 100;
        }

        if (!passed) {
            if (m == 0) c.state = ProjectState.FailureRound1;
            else if (m == 1) c.state = ProjectState.FailureRound2;
            else c.state = ProjectState.FailureRound3;

            claimableOwner[owner()] += c.bond;
            refundPool[projectId] = c.totalFunded - alreadyReleased;
            return;
        }

        uint256 release;
        if (m == 0) {
            release = (c.totalFunded * 20) / 100;
            c.state = ProjectState.BuildingStage2;
        } else if (m == 1) {
            release = (c.totalFunded * 30) / 100;
            c.state = ProjectState.BuildingStage3;
        } else {
            release = (c.totalFunded * 50) / 100;
            c.state = ProjectState.Completed;
            claimableCreator[c.creator] += c.bond;
        }

        claimableCreator[c.creator] += release;
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
        ProjectCore storage c = projectCore[projectId];
        require(
            c.state == ProjectState.Cancelled ||
                c.state == ProjectState.FailureRound1 ||
                c.state == ProjectState.FailureRound2 ||
                c.state == ProjectState.FailureRound3,
            "Refund not available"
        );

        require(!refundClaimed[projectId][msg.sender], "Already claimed");
        uint256 investedAmount = invested[projectId][msg.sender];
        require(investedAmount > 0, "No investment");

        uint256 amount = (investedAmount * refundPool[projectId]) /
            c.totalFunded;
        refundClaimed[projectId][msg.sender] = true;
        invested[projectId][msg.sender] = 0;

        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok);

        emit Claim(msg.sender, amount, "INVESTOR");
    }

    function claimAllRefund() external nonReentrant {
        uint256 totalPayout;

        for (uint256 i = 1; i <= projectCount; i++) {
            ProjectCore storage c = projectCore[i];
            if (!_isRefundAvailable(i)) continue;
            if (refundClaimed[i][msg.sender]) continue;
            uint256 investedAmount = invested[i][msg.sender];
            if (investedAmount == 0) continue;

            uint256 refund = (investedAmount * refundPool[i]) / c.totalFunded;
            refundClaimed[i][msg.sender] = true;
            invested[i][msg.sender] = 0;

            totalPayout += refund;
        }

        require(totalPayout > 0, "Nothing to claim");
        (bool ok, ) = msg.sender.call{value: totalPayout}("");
        require(ok);

        emit Claim(msg.sender, totalPayout, "INVESTORALL");
    }

    /*-----------------------UTILS-----------------------*/

    function _currentMilestone(
        uint256 projectId
    ) internal view returns (uint256) {
        ProjectCore storage c = projectCore[projectId];
        if (
            c.state == ProjectState.VotingRound1 ||
            c.state == ProjectState.FailureRound1
        ) return 0;
        if (
            c.state == ProjectState.VotingRound2 ||
            c.state == ProjectState.FailureRound2
        ) return 1;
        if (
            c.state == ProjectState.VotingRound3 ||
            c.state == ProjectState.FailureRound3
        ) return 2;
        revert("Not voting or failed milestone");
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

    function _isRefundAvailable(
        uint256 projectId
    ) internal view returns (bool) {
        ProjectCore storage c = projectCore[projectId];
        return (c.state == ProjectState.Cancelled ||
            c.state == ProjectState.FailureRound1 ||
            c.state == ProjectState.FailureRound2 ||
            c.state == ProjectState.FailureRound3);
    }

    /*-----------------------GET FUNCTIONS-----------------------*/

    function getProjectCore(
        uint256 projectId
    )
        external
        view
        returns (
            address creator,
            Category category,
            uint256 softCapWei,
            uint256 totalFunded,
            uint256 bond,
            ProjectState state
        )
    {
        ProjectCore storage c = projectCore[projectId];
        return (
            c.creator,
            c.category,
            c.softCapWei,
            c.totalFunded,
            c.bond,
            c.state
        );
    }

    function getProjectVoting(
        uint256 projectId
    )
        external
        view
        returns (
            uint256 snapshotTotalFund,
            uint256 totalWeight,
            uint256[3] memory yesWeight,
            uint256[3] memory noWeight,
            bool[3] memory finalized
        )
    {
        ProjectVoting storage v = projectVoting[projectId];
        return (
            v.snapshotTotalFund,
            v.snapshotTotalWeight,
            v.yesWeight,
            v.noWeight,
            v.finalized
        );
    }

    function getProjectMeta(uint256 projectId)
        external
        view
        returns (
            string memory name,
            string memory description,
            string[3] memory milestoneDescriptions,
            string[3] memory milestoneHashes
        )
    {
        ProjectMeta storage m = projectMeta[projectId];
        return (
            m.name,
            m.description,
            m.milestoneDescriptions,
            m.milestoneHashes
        );
    }

    function getAllInvestments(
        uint256 projectId
    ) external view returns (address[] memory, uint256[] memory) {
        address[] storage invs = investors[projectId];
        uint256 len = invs.length;
        uint256[] memory investments = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            investments[i] = invested[projectId][invs[i]];
        }

        return (invs, investments);
    }

    function getProjectState(
        uint256 projectId
    ) public view returns (string memory) {
        ProjectCore storage c = projectCore[projectId];

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

        return states[uint(c.state)];
    }

    function getMilestoneDescriptions(
        uint256 projectId
    ) external view returns (string[3] memory) {
        return projectMeta[projectId].milestoneDescriptions;
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
        returns (uint256)
    {

        uint256 totalRefund;

        for (uint256 i = 1; i <= projectCount; i++) {
            ProjectCore storage c = projectCore[i];

            if (
                c.state != ProjectState.Cancelled &&
                c.state != ProjectState.FailureRound1 &&
                c.state != ProjectState.FailureRound2 &&
                c.state != ProjectState.FailureRound3
            ) {
                continue;
            }

            if (refundClaimed[i][msg.sender]) continue;

            uint256 investedAmount = invested[i][msg.sender];
            if (investedAmount == 0) continue;

            uint256 refund = (investedAmount * refundPool[i]) / c.totalFunded;
            totalRefund += refund;
        }

        return totalRefund;
    }

    function getMyVotes(
        uint256 projectId,
        address user
    ) external view returns (VoteOption[3] memory) {
        return votes[projectId][user];
    }
}
