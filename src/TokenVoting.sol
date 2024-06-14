// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import {IVotesUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/utils/IVotesUpgradeable.sol";
import {SafeCastUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/math/SafeCastUpgradeable.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

import {IMembership} from "@aragon/osx-commons-contracts/src/plugin/extensions/membership/IMembership.sol";
import {_applyRatioCeiled} from "@aragon/osx-commons-contracts/src/utils/math/Ratio.sol";

import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {MajorityVotingBase} from "./MajorityVotingBase.sol";

contract TokenVoting is IMembership, MajorityVotingBase {
    using SafeCastUpgradeable for uint256;

    bytes4 internal constant TOKEN_VOTING_INTERFACE_ID =
        this.initialize.selector ^ this.getVotingToken.selector;

    IVotesUpgradeable private votingToken;

    error NoVotingPower();

    function initialize(
        IDAO _dao,
        VotingSettings calldata _votingSettings,
        IVotesUpgradeable _token
    ) external initializer {
        __MajorityVotingBase_init(_dao, _votingSettings);

        votingToken = _token;

        emit MembershipContractAnnounced({definingContract: address(_token)});
    }

    function supportsInterface(bytes4 _interfaceId) public view virtual override returns (bool) {
        return
            _interfaceId == TOKEN_VOTING_INTERFACE_ID ||
            _interfaceId == type(IMembership).interfaceId ||
            super.supportsInterface(_interfaceId);
    }

    /// @notice getter function for the voting token.
    /// @dev public function also useful for registering interfaceId
    /// and for distinguishing from majority voting interface.
    /// @return The token used for voting.
    function getVotingToken() public view returns (IVotesUpgradeable) {
        return votingToken;
    }

    /// @inheritdoc MajorityVotingBase
    function totalVotingPower() public view override returns (uint256) {
        return IERC20Upgradeable(address(votingToken)).totalSupply();
    }

    /// @inheritdoc MajorityVotingBase
    function createProposal(
        bytes calldata _metadata,
        bytes32[] calldata _nominees
    ) external override returns (uint256 proposalId) {
        // Check that either `_msgSender` owns enough tokens or has enough voting power from being a delegatee.
        {
            uint256 minProposerVotingPower_ = minProposerVotingPower();

            if (minProposerVotingPower_ != 0) {
                // Because of the checks in `TokenVotingSetup`, we can assume that `votingToken`
                // is an [ERC-20](https://eips.ethereum.org/EIPS/eip-20) token.
                if (
                    votingToken.getVotes(_msgSender()) < minProposerVotingPower_ &&
                    IERC20Upgradeable(address(votingToken)).balanceOf(_msgSender()) <
                    minProposerVotingPower_
                ) {
                    revert ProposalCreationForbidden(_msgSender());
                }
            }
        }

        // todo how calculate the voting power => it is not tied to an specific block due is continuous
        uint256 totalVotingPower_ = totalVotingPower();

        if (totalVotingPower_ == 0) {
            revert NoVotingPower();
        }

        proposalId = _createProposal({
            _creator: _msgSender(),
            _metadata: _metadata,
            _nominees: _nominees
        });

        // Store proposal related information
        Proposal storage proposal_ = proposals[proposalId];

        proposal_.parameters.supportThreshold = supportThreshold();
        proposal_.parameters.minVotingPower = _applyRatioCeiled(
            totalVotingPower_,
            minParticipation()
        );

        // store nominees
        for (uint256 i = 0; i < _nominees.length; i++) {
            proposal_.nominees.push(Nominee({dataHash: _nominees[i], votes: 0}));
            proposal_.nomineePosition[_nominees[i]] = i + 1;
        }

        // ? should allow to vote when creating?
    }

    event Nominated(uint256 proposalId, bytes32 nominee);
    error ProposalNotFound(uint256 proposalId);

    function nominate(uint256 _proposalId, bytes32 _newNominee) external returns (uint256 newIdx) {
        Proposal storage proposal_ = proposals[_proposalId];
        if (proposal_.nominees.length == 0) {
            revert ProposalNotFound(_proposalId);
        }
        newIdx = proposal_.nominees.length;
        proposal_.nominees.push(Nominee({dataHash: _newNominee, votes: 0}));
        emit Nominated(_proposalId, _newNominee);
    }

    /// @inheritdoc IMembership
    function isMember(address _account) external view returns (bool) {
        // A member must own at least one token or have at least one token delegated to her/him.
        return
            votingToken.getVotes(_account) > 0 ||
            IERC20Upgradeable(address(votingToken)).balanceOf(_account) > 0;
    }

    /// @inheritdoc MajorityVotingBase
    function _vote(uint256 _proposalId, bytes32 _voteOption, address _voter) internal override {
        Proposal storage proposal_ = proposals[_proposalId];

        // This could re-enter, though we can assume the governance token is not malicious
        // todo how calculate the voting power
        uint256 votingPower = IERC20Upgradeable(address(votingToken)).balanceOf(_voter);

        // check if the voter has voted before
        bytes32 previousVote = proposal_.voters[_voter];
        uint256 newOptionIdx = proposal_.nomineePosition[_voteOption] - 1;

        if (previousVote != bytes32(0)) {
            uint256 previousOptionIdx = proposal_.nomineePosition[previousVote] - 1;
            // If voter had previously voted, decrease votes
            proposal_.nominees[newOptionIdx].votes += votingPower;
            proposal_.nominees[previousOptionIdx].votes -= votingPower;
        } else {
            proposal_.nominees[newOptionIdx].votes += votingPower;
        }

        proposal_.voters[_voter] = _voteOption;

        emit VoteCast({
            proposalId: _proposalId,
            voter: _voter,
            voteOption: _voteOption,
            votingPower: votingPower
        });
    }

    function validateTopNominees(
        uint256 _proposalId,
        uint256[] calldata _topNominees
    ) external view returns (bool) {
        uint256 biggerVal;
        Proposal storage proposal_ = proposals[_proposalId];
        uint256 length = proposal_.nominees.length;
        uint256 currentVotesValue;
        for (uint256 i = 0; i < length; i++) {
            currentVotesValue = proposal_.nominees[i].votes;
            // get bigger value that is not in topValues
            if (currentVotesValue > biggerVal) {
                // check if is not in topValues
                if (!_isInList(currentVotesValue, _topNominees)) {
                    biggerVal = currentVotesValue;
                }
            }
        }
        // check if this bigger value is bigger than any of the list elements
        return !_isBigger(biggerVal, _topNominees);
    }

    function _isBigger(uint256 value, uint256[] calldata list) internal pure returns (bool) {
        for (uint256 i = 0; i < list.length; i++) {
            if (value > list[i]) {
                return true;
            }
        }
        return false;
    }

    function _isInList(uint256 value, uint256[] calldata list) internal pure returns (bool) {
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == value) {
                return true;
            }
        }
        return false;
    }

    /// @inheritdoc MajorityVotingBase
    function _canVote(
        uint256 _proposalId,
        address _voter,
        bytes32 _voteOption
    ) internal view override returns (bool) {
        Proposal storage proposal_ = proposals[_proposalId];

        // Proposal exists
        if (proposal_.nominees.length == 0) {
            return false;
        }

        // The voter votes `bytes(0)` which is not allowed.
        if (_voteOption == bytes32(0)) {
            return false;
        }

        // nominee has not been nominated
        if (proposal_.nomineePosition[_voteOption] == 0) {
            return false;
        }

        // The voter has no voting power.
        // todo voting power
        if (IERC20Upgradeable(address(votingToken)).balanceOf(_voter) == 0) {
            return false;
        }

        return true;
    }

    uint256[49] private __gap;
}
