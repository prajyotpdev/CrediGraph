// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title SkillCredibility
 * @notice Decentralized skill verification with stake-based endorsements
 * @dev Improved version with security enhancements and better credibility logic
 */
contract SkillCredibility {

    struct SkillProfile {
        bool claimed;
        uint256 credibility; // reputation score based on weighted endorsements
        uint256 endorsementsReceived;
        uint256 lastUpdated; // timestamp for potential time-based features
    }

    struct Endorsement {
        address endorser;
        uint256 stake;
        bool active;
        uint256 timestamp;
    }

    // user => skill => profile
    mapping(address => mapping(bytes32 => SkillProfile)) public skills;

    // user => skill => endorsement list
    mapping(address => mapping(bytes32 => Endorsement[])) public endorsements;

    // endorser => skill => endorsement credibility
    mapping(address => mapping(bytes32 => uint256)) public endorsementCredibility;

    // Track total stakes for potential withdrawal mechanism
    mapping(address => mapping(bytes32 => uint256)) public totalStaked;

    uint256 public constant MIN_ENDORSE_STAKE = 0.01 ether;
    uint256 public constant MIN_CREDIBILITY_TO_ENDORSE = 10;
    uint256 public constant MAX_CREDIBILITY_GAIN = 5; // prevent gaming
    uint256 public constant SLASH_PENALTY = 2; // credibility penalty multiplier

    address public admin;
    bool public paused;

    event SkillClaimed(address indexed user, bytes32 indexed skill, uint256 timestamp);
    event SkillEndorsed(
        address indexed endorser,
        address indexed user,
        bytes32 indexed skill,
        uint256 stake,
        uint256 newCredibility
    );
    event EndorsementSlashed(
        address indexed endorser,
        address indexed user,
        bytes32 indexed skill,
        uint256 slashedStake
    );
    event AdminChanged(address indexed oldAdmin, address indexed newAdmin);
    event ContractPaused(bool paused);

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "Contract is paused");
        _;
    }

    constructor() {
        admin = msg.sender;
    }

    /**
     * @notice Claim a skill to start building credibility
     * @param skill The skill identifier (keccak256 hash)
     */
    function claimSkill(bytes32 skill) external whenNotPaused {
        require(skill != bytes32(0), "Invalid skill");
        require(!skills[msg.sender][skill].claimed, "Already claimed");

        skills[msg.sender][skill] = SkillProfile({
            claimed: true,
            credibility: 1, // bootstrap credibility
            endorsementsReceived: 0,
            lastUpdated: block.timestamp
        });

        emit SkillClaimed(msg.sender, skill, block.timestamp);
    }

    /**
     * @notice Endorse another user's skill with stake
     * @param user The user to endorse
     * @param skill The skill to endorse
     */
    function endorseSkill(
        address user,
        bytes32 skill
    ) external payable whenNotPaused {
        require(user != address(0), "Invalid user");
        require(user != msg.sender, "Cannot endorse yourself");
        require(msg.value >= MIN_ENDORSE_STAKE, "Insufficient stake");
        require(skills[user][skill].claimed, "Skill not claimed");
        require(skills[msg.sender][skill].claimed, "Must claim skill first");

        // Relevance gate: endorser must have credibility in this skill
        require(
            skills[msg.sender][skill].credibility >= MIN_CREDIBILITY_TO_ENDORSE,
            "Not credible enough to endorse"
        );

        // Store endorsement
        endorsements[user][skill].push(
            Endorsement({
                endorser: msg.sender,
                stake: msg.value,
                active: true,
                timestamp: block.timestamp
            })
        );

        // Calculate credibility gain based on endorser's credibility and stake
        uint256 credibilityGain = _calculateCredibilityGain(
            msg.sender,
            skill,
            msg.value
        );

        // Update user's skill credibility
        skills[user][skill].credibility += credibilityGain;
        skills[user][skill].endorsementsReceived += 1;
        skills[user][skill].lastUpdated = block.timestamp;

        // Improve endorser's credibility (smaller gain)
        endorsementCredibility[msg.sender][skill] += 1;

        // Track total staked
        totalStaked[user][skill] += msg.value;

        emit SkillEndorsed(msg.sender, user, skill, msg.value, skills[user][skill].credibility);
    }

    /**
     * @notice Admin function to slash fraudulent endorsements
     * @param user The user whose endorsement to slash
     * @param skill The skill
     * @param index The endorsement index
     */
    function slashEndorsement(
        address user,
        bytes32 skill,
        uint256 index
    ) external onlyAdmin {
        require(index < endorsements[user][skill].length, "Invalid index");

        Endorsement storage e = endorsements[user][skill][index];
        require(e.active, "Already slashed");

        e.active = false;

        // Penalize both the endorser and the endorsed user
        uint256 credibilityPenalty = SLASH_PENALTY;

        if (endorsementCredibility[e.endorser][skill] >= credibilityPenalty) {
            endorsementCredibility[e.endorser][skill] -= credibilityPenalty;
        } else {
            endorsementCredibility[e.endorser][skill] = 0;
        }

        if (skills[user][skill].credibility >= credibilityPenalty) {
            skills[user][skill].credibility -= credibilityPenalty;
        } else {
            skills[user][skill].credibility = 0;
        }

        // Return slashed stake to admin (treasury) for redistribution
        uint256 slashedAmount = e.stake;
        totalStaked[user][skill] -= slashedAmount;

        (bool success, ) = admin.call{value: slashedAmount}("");
        require(success, "Transfer failed");

        emit EndorsementSlashed(e.endorser, user, skill, slashedAmount);
    }

    /**
     * @notice Calculate credibility gain from endorsement
     * @dev Uses endorser's credibility and stake size
     */
    function _calculateCredibilityGain(
        address endorser,
        bytes32 skill,
        uint256 stake
    ) internal view returns (uint256) {
        uint256 endorserCredibility = skills[endorser][skill].credibility;

        // Base gain from stake (1 point per MIN_ENDORSE_STAKE)
        uint256 stakeMultiplier = stake / MIN_ENDORSE_STAKE;

        // Weight by endorser's credibility (logarithmic to prevent excessive inflation)
        uint256 credibilityWeight = _sqrt(endorserCredibility);

        uint256 gain = stakeMultiplier * credibilityWeight / 10;

        // Cap the gain to prevent gaming
        if (gain > MAX_CREDIBILITY_GAIN) {
            gain = MAX_CREDIBILITY_GAIN;
        }

        // Minimum gain of 1
        if (gain == 0) {
            gain = 1;
        }

        return gain;
    }

    /**
     * @notice Integer square root (Babylonian method)
     */
    function _sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }

    /**
     * @notice Get active endorsement count (not slashed)
     */
    function getActiveEndorsementCount(
        address user,
        bytes32 skill
    ) external view returns (uint256) {
        uint256 count = 0;
        Endorsement[] memory userEndorsements = endorsements[user][skill];

        for (uint256 i = 0; i < userEndorsements.length; i++) {
            if (userEndorsements[i].active) {
                count++;
            }
        }

        return count;
    }

    /**
     * @notice Get skill credibility score
     */
    function getSkillCredibility(
        address user,
        bytes32 skill
    ) external view returns (uint256) {
        return skills[user][skill].credibility;
    }

    /**
     * @notice Get total endorsement count (including slashed)
     */
    function getEndorsementCount(
        address user,
        bytes32 skill
    ) external view returns (uint256) {
        return endorsements[user][skill].length;
    }

    /**
     * @notice Get detailed endorsement info
     */
    function getEndorsement(
        address user,
        bytes32 skill,
        uint256 index
    ) external view returns (
        address endorser,
        uint256 stake,
        bool active,
        uint256 timestamp
    ) {
        require(index < endorsements[user][skill].length, "Invalid index");
        Endorsement memory e = endorsements[user][skill][index];
        return (e.endorser, e.stake, e.active, e.timestamp);
    }

    /**
     * @notice Transfer admin role
     */
    function transferAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "Invalid address");
        address oldAdmin = admin;
        admin = newAdmin;
        emit AdminChanged(oldAdmin, newAdmin);
    }

    /**
     * @notice Pause/unpause contract
     */
    function setPaused(bool _paused) external onlyAdmin {
        paused = _paused;
        emit ContractPaused(_paused);
    }

    /**
     * @notice Get contract balance
     */
    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }
}