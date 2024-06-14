// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";

import {DAO} from "@aragon/osx/core/dao/DAO.sol";

import {console} from "forge-std/Test.sol";
import {TokenVoting} from "../src/TokenVoting.sol";
import {TokenVotingSetup} from "../src/TokenVotingSetup.sol";
import {GovernanceERC20} from "../src/ERC20/governance/GovernanceERC20.sol";
import {GovernanceWrappedERC20} from "../src/ERC20/governance/GovernanceWrappedERC20.sol";
import {AragonTest} from "./base/AragonTest.sol";
import {MajorityVotingBase} from "../../src/MajorityVotingBase.sol";

contract TestAttacks is AragonTest {
    IDAO internal dao;
    TokenVoting tv;
    GovernanceERC20 baseToken;
    GovernanceWrappedERC20 token;

    TokenVotingSetup setup;

    function _setUp(address[] memory _voters) internal {
        baseToken = new GovernanceERC20(
            IDAO(dao),
            "Test",
            "TST",
            GovernanceERC20.MintSettings(new address[](0), new uint256[](0))
        );
        setup = new TokenVotingSetup(baseToken, token);

        uint256[] memory amounts = new uint256[](_voters.length);
        for (uint256 i = 0; i < _voters.length; i++) {
            uint256 amount = _randomNumber(1000);
            amounts[i] = amount == 0 ? i : amount;
        }

        bytes memory setupData = abi.encode(
            MajorityVotingBase.VotingSettings(10, 50, 1),
            TokenVotingSetup.TokenSettings(address(token), baseToken.name(), baseToken.symbol()),
            GovernanceERC20.MintSettings(_voters, amounts)
        );

        (DAO _dao, address _plugin) = createMockDaoWithPlugin(setup, setupData);

        dao = _dao;
        tv = TokenVoting(_plugin);
    }

    function test_createProposalAndVote(
        bytes32[] memory nominees,
        address[] memory _voters
    ) public {
        bytes memory metadata = "test_metadata";

        // skip not realistic examples
        if (_voters.length == 0 || _hasZeroAddr(_voters)) return;
        if (nominees.length <= 1 || _hasBytesZero(nominees)) return;

        _setUp(_voters);

        // create proposal
        vm.startPrank(_voters[0]);
        uint256 proposalId = tv.createProposal(metadata, nominees);
        vm.stopPrank();
        // make some members vote
        _vote(_voters, nominees);

        uint256[] memory votes = _printNominees(proposalId);
        uint256[] memory sortedVotes = bubbleSort(votes);

        // validate the winner
        uint256 amountOfValues = _randomNumber(nominees.length < 7 ? nominees.length - 1 : 7);
        amountOfValues = amountOfValues == 0 ? 1 : amountOfValues;

        // assert the top n elements for the sorted list are correct ones
        assertTrue(
            tv.validateTopNominees(proposalId, _getLastNElements(sortedVotes, amountOfValues))
        );

        assertFalse(tv.validateTopNominees(proposalId, _getRandomValues(amountOfValues)));
    }

    // helpers
    function _vote(address[] memory _voters, bytes32[] memory _nominees) internal {
        for (uint256 i = 0; i < _voters.length; i++) {
            vm.startPrank(_voters[i]);
            tv.vote(0, _nominees[_randomNumber(_nominees.length)]);
            vm.stopPrank();
        }
    }

    function _randomNumber(uint256 _max) internal view returns (uint256) {
        return uint256(keccak256(abi.encodePacked(block.timestamp, msg.sender))) % _max;
    }

    function _printNominees(uint256 proposalId) internal view returns (uint256[] memory votes) {
        (, MajorityVotingBase.Nominee[] memory nominees) = tv.getProposal(proposalId);
        votes = new uint256[](nominees.length);

        for (uint256 i = 0; i < nominees.length; i++) {
            console.logBytes32(nominees[i].dataHash);
            console.log(nominees[i].votes);
            votes[i] = nominees[i].votes;
        }
    }

    function _hasZeroAddr(address[] memory _voters) internal pure returns (bool) {
        for (uint256 i = 0; i < _voters.length; i++) {
            if (_voters[i] == address(0)) return true;
        }
        return false;
    }

    function _hasBytesZero(bytes32[] memory _nominees) internal pure returns (bool) {
        for (uint256 i = 0; i < _nominees.length; i++) {
            if (_nominees[i] == bytes32(0)) return true;
        }
        return false;
    }

    function bubbleSort(uint[] memory data) public view returns (uint[] memory) {
        uint n = data.length;
        for (uint i = 0; i < n; i++) {
            for (uint j = 0; j < n - 1; j++) {
                if (data[j] > data[j + 1]) {
                    (data[j], data[j + 1]) = (data[j + 1], data[j]);
                }
            }
        }
        return data;
    }

    function _getLastNElements(
        uint256[] memory data,
        uint256 n
    ) internal view returns (uint256[] memory) {
        uint256[] memory result = new uint256[](n);

        for (uint256 i = 0; i < n; i++) {
            console.log("i", i);
            result[i] = data[data.length - 1 - i];
        }
        return result;
    }

    function _getRandomValues(uint256 n) internal view returns (uint256[] memory) {
        uint256[] memory result = new uint256[](n);

        for (uint256 i = 0; i < n; i++) {
            console.log("i", i);
            result[i] = 0;
        }
        return result;
    }
}
