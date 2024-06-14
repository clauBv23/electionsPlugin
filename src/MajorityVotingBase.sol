// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import {ERC165Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {SafeCastUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/math/SafeCastUpgradeable.sol";

// solhint-disable-next-line max-line-length
import {ProposalUpgradeable} from "@aragon/osx-commons-contracts/src/plugin/extensions/proposal/ProposalUpgradeable.sol";
import {RATIO_BASE, RatioOutOfBounds} from "@aragon/osx-commons-contracts/src/utils/math/Ratio.sol";
import {PluginUUPSUpgradeable} from "@aragon/osx-commons-contracts/src/plugin/PluginUUPSUpgradeable.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";

import {IMajorityVoting} from "./IMajorityVoting.sol";

abstract contract MajorityVotingBase is
    IMajorityVoting,
    Initializable,
    ERC165Upgradeable,
    PluginUUPSUpgradeable,
    ProposalUpgradeable
{
    using SafeCastUpgradeable for uint256;

    /// @notice A container for the majority voting settings that will be applied as parameters on proposal creation.
    /// @param votingMode A parameter to select the vote mode.
    /// In standard mode (0), early execution and vote replacement are disabled.
    /// In early execution mode (1), a proposal can be executed early before the end date
    /// if the vote outcome cannot mathematically change by more voters voting.
    /// In vote replacement mode (2), voters can change their vote multiple times
    /// and only the latest vote option is tallied.
    /// @param supportThreshold The support threshold value.
    /// Its value has to be in the interval [0, 10^6] defined by `RATIO_BASE = 10**6`.
    /// @param minParticipation The minimum participation value.
    /// Its value has to be in the interval [0, 10^6] defined by `RATIO_BASE = 10**6`.
    /// @param minDuration The minimum duration of the proposal vote in seconds.
    /// @param minProposerVotingPower The minimum voting power required to create a proposal.
    struct VotingSettings {
        // VotingMode votingMode;
        uint32 supportThreshold;
        uint32 minParticipation;
        // uint64 minDuration;
        uint256 minProposerVotingPower;
    }

    /// @notice A container for proposal-related information.
    /// @param executed Whether the proposal is executed or not.
    /// @param parameters The proposal parameters at the time of the proposal creation.
    /// @param tally The vote tally of the proposal.
    /// @param voters The votes casted by the voters.
    /// @param actions The actions to be executed when the proposal passes.
    /// @param allowFailureMap A bitmap allowing the proposal to succeed, even if individual actions might revert.
    /// If the bit at index `i` is 1, the proposal succeeds even if the `i`th action reverts.
    /// A failure map value of 0 requires every action to not revert.
    struct Proposal {
        ProposalParameters parameters;
        mapping(address => bytes32) voters;
        Nominee[] nominees;
        mapping(bytes32 => uint256) nomineePosition; // is not index is position (idx + 1)
    }

    /// @notice A container for the proposal parameters at the time of proposal creation.
    /// @param votingMode A parameter to select the vote mode.
    /// @param supportThreshold The support threshold value.
    /// The value has to be in the interval [0, 10^6] defined by `RATIO_BASE = 10**6`.
    /// @param startDate The start date of the proposal vote.
    /// @param endDate The end date of the proposal vote.
    /// @param snapshotBlock The number of the block prior to the proposal creation.
    /// @param minVotingPower The minimum voting power needed.
    struct ProposalParameters {
        uint32 supportThreshold;
        uint256 minVotingPower;
    }

    /// @notice The [ERC-165](https://eips.ethereum.org/EIPS/eip-165) interface ID of the contract.
    bytes4 internal constant MAJORITY_VOTING_BASE_INTERFACE_ID =
        // this.minDuration.selector ^
        this.minProposerVotingPower.selector ^
            // this.votingMode.selector ^
            this.totalVotingPower.selector ^
            this.getProposal.selector ^
            this.updateVotingSettings.selector ^
            this.createProposal.selector;

    /// @notice The ID of the permission required to call the `updateVotingSettings` function.
    bytes32 public constant UPDATE_VOTING_SETTINGS_PERMISSION_ID =
        keccak256("UPDATE_VOTING_SETTINGS_PERMISSION");

    /// @notice A mapping between proposal IDs and proposal information.
    // solhint-disable-next-line named-parameters-mapping
    mapping(uint256 => Proposal) internal proposals;

    /// @notice The struct storing the voting settings.
    VotingSettings private votingSettings;

    /// @notice Thrown if a date is out of bounds.
    /// @param limit The limit value.
    /// @param actual The actual value.
    error DateOutOfBounds(uint64 limit, uint64 actual);

    /// @notice Thrown if the minimal duration value is out of bounds (less than one hour or greater than 1 year).
    /// @param limit The limit value.
    /// @param actual The actual value.
    error MinDurationOutOfBounds(uint64 limit, uint64 actual);

    /// @notice Thrown when a sender is not allowed to create a proposal.
    /// @param sender The sender address.
    error ProposalCreationForbidden(address sender);

    /// @notice Thrown if an account is not allowed to cast a vote. This can be because the vote
    /// - has not started,
    /// - has ended,
    /// - was executed, or
    /// - the account doesn't have voting powers.
    /// @param proposalId The ID of the proposal.
    /// @param account The address of the _account.
    /// @param voteOption The chosen vote option.
    error VoteCastForbidden(uint256 proposalId, address account, bytes32 voteOption);

    /// @notice Thrown if the proposal execution is forbidden.
    /// @param proposalId The ID of the proposal.
    error ProposalExecutionForbidden(uint256 proposalId);

    /// @notice Emitted when the voting settings are updated.
    /// @param supportThreshold The support threshold value.
    /// @param minParticipation The minimum participation value.
    /// @param minDuration The minimum duration of the proposal vote in seconds.
    /// @param minProposerVotingPower The minimum voting power required to create a proposal.
    event VotingSettingsUpdated(
        // VotingMode votingMode,
        uint32 supportThreshold,
        uint32 minParticipation,
        uint64 minDuration,
        uint256 minProposerVotingPower
    );

    /// @notice Initializes the component to be used by inheriting contracts.
    /// @dev This method is required to support [ERC-1822](https://eips.ethereum.org/EIPS/eip-1822).
    /// @param _dao The IDAO interface of the associated DAO.
    /// @param _votingSettings The voting settings.
    // solhint-disable-next-line func-name-mixedcase
    function __MajorityVotingBase_init(
        IDAO _dao,
        VotingSettings calldata _votingSettings
    ) internal onlyInitializing {
        __PluginUUPSUpgradeable_init(_dao);
        _updateVotingSettings(_votingSettings);
    }

    /// @notice Checks if this or the parent contract supports an interface by its ID.
    /// @param _interfaceId The ID of the interface.
    /// @return Returns `true` if the interface is supported.
    function supportsInterface(
        bytes4 _interfaceId
    )
        public
        view
        virtual
        override(ERC165Upgradeable, PluginUUPSUpgradeable, ProposalUpgradeable)
        returns (bool)
    {
        return
            _interfaceId == MAJORITY_VOTING_BASE_INTERFACE_ID ||
            _interfaceId == type(IMajorityVoting).interfaceId ||
            super.supportsInterface(_interfaceId);
    }

    /// @inheritdoc IMajorityVoting
    function vote(uint256 _proposalId, bytes32 _voteOption) public virtual {
        address account = _msgSender();

        if (!_canVote(_proposalId, account, _voteOption)) {
            revert VoteCastForbidden({
                proposalId: _proposalId,
                account: account,
                voteOption: _voteOption
            });
        }
        _vote(_proposalId, _voteOption, account);
    }

    // solhint-disable no-empty-blocks
    /// @inheritdoc IMajorityVoting
    function getVoteOption(
        uint256 _proposalId,
        address _voter
    ) public view virtual returns (VoteOption) {
        // return proposals[_proposalId].voters[_voter];
    }

    /// @inheritdoc IMajorityVoting
    function canVote(
        uint256 _proposalId,
        address _voter,
        bytes32 _voteOption
    ) public view virtual returns (bool) {
        return _canVote(_proposalId, _voter, _voteOption);
    }

    /// @inheritdoc IMajorityVoting
    function isSupportThresholdReached(uint256 _proposalId) public view virtual returns (bool) {}

    /// @inheritdoc IMajorityVoting
    function isSupportThresholdReachedEarly(
        uint256 _proposalId
    ) public view virtual returns (bool) {}

    /// @inheritdoc IMajorityVoting
    function isMinParticipationReached(uint256 _proposalId) public view virtual returns (bool) {}

    /// @inheritdoc IMajorityVoting
    function supportThreshold() public view virtual returns (uint32) {
        return votingSettings.supportThreshold;
    }

    /// @inheritdoc IMajorityVoting
    function minParticipation() public view virtual returns (uint32) {
        return votingSettings.minParticipation;
    }

    /// @notice Returns the minimum voting power required to create a proposal stored in the voting settings.
    /// @return The minimum voting power required to create a proposal.
    function minProposerVotingPower() public view virtual returns (uint256) {
        return votingSettings.minProposerVotingPower;
    }

    /// @notice Returns the total voting power checkpointed for a specific block number.
    /// @return The total voting power.
    function totalVotingPower() public view virtual returns (uint256);

    /// @notice Returns all information for a proposal vote by its ID.
    /// @param _proposalId The ID of the proposal.
    /// @return parameters The parameters of the proposal vote.
    function getProposal(
        uint256 _proposalId
    )
        public
        view
        virtual
        returns (ProposalParameters memory parameters, Nominee[] memory nominees)
    {
        Proposal storage proposal_ = proposals[_proposalId];

        parameters = proposal_.parameters;
        nominees = proposal_.nominees;
    }

    /// @notice Updates the voting settings.
    /// @param _votingSettings The new voting settings.
    function updateVotingSettings(
        VotingSettings calldata _votingSettings
    ) external virtual auth(UPDATE_VOTING_SETTINGS_PERMISSION_ID) {
        _updateVotingSettings(_votingSettings);
    }

    /// @notice Creates a new majority voting proposal.
    /// @param _metadata The metadata of the proposal.
    /// The call does not revert if early execution is not possible.
    /// @return proposalId The ID of the proposal.
    function createProposal(
        bytes calldata _metadata,
        bytes32[] calldata _nominees
    ) external virtual returns (uint256 proposalId);

    /// @notice Internal function to cast a vote. It assumes the queried vote exists.
    /// @param _proposalId The ID of the proposal.
    /// @param _voteOption The nominee to vote for.after
    /// The call does not revert if early execution is not possible.
    function _vote(uint256 _proposalId, bytes32 _voteOption, address _voter) internal virtual;

    /// @notice Internal function to execute a vote. It assumes the queried proposal exists.
    /// @param _proposalId The ID of the proposal.
    function _execute(uint256 _proposalId) internal virtual {}

    /// @notice Internal function to check if a voter can vote. It assumes the queried proposal exists.
    /// @param _proposalId The ID of the proposal.
    /// @param _voter The address of the voter to check.
    /// @param  _voteOption Whether the voter abstains, supports or opposes the proposal.
    /// @return Returns `true` if the given voter can vote on a certain proposal and `false` otherwise.
    function _canVote(
        uint256 _proposalId,
        address _voter,
        bytes32 _voteOption
    ) internal view virtual returns (bool);

    /// @notice Internal function to check if a proposal vote is still open.
    /// @param proposal_ The proposal struct.
    /// @return True if the proposal vote is open, false otherwise.
    function _isProposalOpen(Proposal storage proposal_) internal view virtual returns (bool) {
        // uint64 currentTime = block.timestamp.toUint64();
        // return
        //     proposal_.parameters.startDate <= currentTime &&
        //     currentTime < proposal_.parameters.endDate;
        // // &&
        // !proposal_.executed;
    }

    /// @notice Internal function to update the plugin-wide proposal vote settings.
    /// @param _votingSettings The voting settings to be validated and updated.
    function _updateVotingSettings(VotingSettings calldata _votingSettings) internal virtual {
        // Require the support threshold value to be in the interval [0, 10^6-1],
        // because `>` comparision is used in the support criterion and >100% could never be reached.
        if (_votingSettings.supportThreshold > RATIO_BASE - 1) {
            revert RatioOutOfBounds({
                limit: RATIO_BASE - 1,
                actual: _votingSettings.supportThreshold
            });
        }

        // Require the minimum participation value to be in the interval [0, 10^6],
        // because `>=` comparision is used in the participation criterion.
        // if (_votingSettings.minParticipation > RATIO_BASE) {
        //     revert RatioOutOfBounds({limit: RATIO_BASE, actual: _votingSettings.minParticipation});
        // }

        // if (_votingSettings.minDuration < 60 minutes) {
        //     revert MinDurationOutOfBounds({limit: 60 minutes, actual: _votingSettings.minDuration});
        // }

        // if (_votingSettings.minDuration > 365 days) {
        //     revert MinDurationOutOfBounds({limit: 365 days, actual: _votingSettings.minDuration});
        // }

        votingSettings = _votingSettings;

        // emit VotingSettingsUpdated({
        //     votingMode: _votingSettings.votingMode,
        //     supportThreshold: _votingSettings.supportThreshold,
        //     minParticipation: _votingSettings.minParticipation,
        //     minDuration: _votingSettings.minDuration,
        //     minProposerVotingPower: _votingSettings.minProposerVotingPower
        // });
    }

    /// @notice This empty reserved space is put in place to allow future versions to add
    /// new variables without shifting down storage in the inheritance chain
    /// (see [OpenZeppelin's guide about storage gaps]
    /// (https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps)).
    uint256[47] private __gap;
}
