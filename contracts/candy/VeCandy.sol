// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.30;

interface IVoter {
    function ve() external view returns (address);
    function gauges(address _lp) external view returns (address);
    function gaugeToBribe(address _gauge_addr) external view returns (address);
    function gaugeToFees(address _gauge_addr) external view returns (address);
    function lastVoted(uint256 _venft_id) external view returns (uint256);
    function poolVote(uint256 _venft_id, uint256 _index) external view returns (address);
    function votes(uint256 _venft_id, address _lp) external view returns (uint256);
    function usedWeights(uint256 _venft_id) external view returns (uint256);
}

interface IRewardsDistributor {
    function claimable(uint256 _venft_id) external view returns (uint256);
}

interface IVotingEscrow {
    function token() external view returns (address);
    function decimals() external view returns (uint8);
    function ownerOf(uint256 _venft_id) external view returns (address);
    function balanceOfNFT(uint256 _venft_id) external view returns (uint256);
    function locked(uint256 _venft_id) external view returns (uint128, uint256, bool);
    function ownerToNFTokenIdList(address _account, uint256 _index) external view returns (uint256);
    function voted(uint256 _venft_id) external view returns (bool);
    function delegates(uint256 _venft_id) external view returns (uint256);
    function idToManaged(uint256 _venft_id) external view returns (uint256);
    function escrowType(uint256 _venft_id) external view returns (uint8);
}

interface IGovernor {
    function getVotes(uint256 _venft_id, uint256 _timepoint) external view returns (uint256);
}

/**
 * @title Icarus Finance Ve Candy
 * @author Icarus Finance (https://icarus.finance)
 */
contract VeCandy {
    uint256 public constant MAX_RESULTS = 1000;
    // Basically max gauges for a veNFT, this one is tricky, but
    // we can't go crazy with it due to memory limitations...
    uint256 public constant MAX_PAIRS = 30;

    struct LpVotes {
        address lp;
        uint256 weight;
    }

    struct VeNFT {
        uint256 id;
        address account;
        uint8 decimals;
        uint128 amount;
        uint256 voting_amount;
        uint256 governance_amount;
        uint256 rebase_amount;
        uint256 expires_at;
        uint256 voted_at;
        LpVotes[] votes;
        address token;
        bool permanent;
        uint256 delegate_id;
        uint256 managed_id;
    }

    // State variables
    IVoter public voter;
    address public token;
    IVotingEscrow public ve;
    IRewardsDistributor public dist;
    IGovernor public gov;

    /**
     * @dev Sets up our external contract addresses
     */
    constructor(address _voter, address _rewards_distributor, address _gov) {
        voter = IVoter(_voter);
        ve = IVotingEscrow(voter.ve());
        token = ve.token();
        dist = IRewardsDistributor(_rewards_distributor);
        gov = IGovernor(_gov);
    }

    /**
     * @notice Returns a collection of veNFT data
     * @param _limit The max amount of veNFTs to return
     * @param _offset The amount of veNFTs to skip
     * @return Array for VeNFT structs
     */
    function all(uint256 _limit, uint256 _offset) external view returns (VeNFT[] memory) {
        VeNFT[] memory tempCol = new VeNFT[](_limit);
        uint256 colCount = 0;
        uint256 toSkip = _offset;
        
        for (uint256 index = 0; index < MAX_RESULTS && colCount < _limit; index++) {
            if (ve.ownerOf(index) == address(0)) {
                continue;
            }
            
            // Skip veNFTs for offset (applied after filtering)
            if (toSkip > 0) {
                toSkip--;
                continue;
            }
            
            tempCol[colCount] = _byId(index);
            colCount++;
        }
        
        // Resize array to actual size
        VeNFT[] memory col = new VeNFT[](colCount);
        for (uint256 i = 0; i < colCount; i++) {
            col[i] = tempCol[i];
        }
        
        return col;
    }

    /**
     * @notice Returns user collection of veNFT data
     * @param _account The account address
     * @return Array for VeNFT structs
     */
    function byAccount(address _account) external view returns (VeNFT[] memory) {
        if (_account == address(0)) {
            return new VeNFT[](0);
        }
        
        VeNFT[] memory tempCol = new VeNFT[](MAX_RESULTS);
        uint256 colCount = 0;
        
        for (uint256 index = 0; index < MAX_RESULTS; index++) {
            uint256 venft_id = ve.ownerToNFTokenIdList(_account, index);
            
            if (venft_id == 0) {
                break;
            }
            
            tempCol[colCount] = _byId(venft_id);
            colCount++;
        }
        
        // Resize array to actual size
        VeNFT[] memory col = new VeNFT[](colCount);
        for (uint256 i = 0; i < colCount; i++) {
            col[i] = tempCol[i];
        }
        
        return col;
    }

    /**
     * @notice Returns VeNFT data at a specific stored index
     * @param _id The index to lookup
     * @return VeNFT struct
     */
    function byId(uint256 _id) external view returns (VeNFT memory) {
        return _byId(_id);
    }

    /**
     * @notice Returns VeNFT data based on the index/ID
     * @param _id The index/ID to lookup
     * @return VeNFT struct
     */
    function _byId(uint256 _id) internal view returns (VeNFT memory) {
        address account = ve.ownerOf(_id);
        
        if (account == address(0)) {
            return VeNFT({
                id: 0,
                account: address(0),
                decimals: 0,
                amount: 0,
                voting_amount: 0,
                governance_amount: 0,
                rebase_amount: 0,
                expires_at: 0,
                voted_at: 0,
                votes: new LpVotes[](0),
                token: address(0),
                permanent: false,
                delegate_id: 0,
                managed_id: 0
            });
        }
        
        (uint128 amount, uint256 expires_at, bool perma) = ve.locked(_id);
        uint256 last_voted = 0;
        uint256 governance_amount = 0;
        uint8 escrowType = ve.escrowType(_id);
        
        // Skip gov amount fetching for (m)veNFTs
        if (address(gov) != address(0) && escrowType < 2) {
            governance_amount = gov.getVotes(_id, block.timestamp);
        }
        
        uint256 delegate_id = ve.delegates(_id);
        uint256 managed_id = ve.idToManaged(_id);
        
        if (managed_id != 0 || ve.voted(_id)) {
            last_voted = voter.lastVoted(_id);
        }
        
        uint256 vote_weight = voter.usedWeights(_id);
        // Since we don't have a way to see how many pools we voted...
        uint256 left_weight = vote_weight;
        
        // Count actual votes first to size the array properly
        uint256 voteCount = 0;
        for (uint256 index = 0; index < MAX_PAIRS && left_weight > 0; index++) {
            address lp = voter.poolVote(_id, index);
            if (lp == address(0)) {
                break;
            }
            uint256 weight = voter.votes(_id, lp);
            if (weight > 0) {
                voteCount++;
                left_weight = left_weight > weight ? left_weight - weight : 0;
            }
        }
        
        // Now create the votes array with the correct size
        LpVotes[] memory votes = new LpVotes[](voteCount);
        left_weight = vote_weight;
        uint256 voteIndex = 0;
        
        for (uint256 index = 0; index < MAX_PAIRS && left_weight > 0 && voteIndex < voteCount; index++) {
            address lp = voter.poolVote(_id, index);
            if (lp == address(0)) {
                break;
            }
            
            uint256 weight = voter.votes(_id, lp);
            if (weight > 0) {
                votes[voteIndex] = LpVotes({
                    lp: lp,
                    weight: weight
                });
                voteIndex++;
                // Remove counted weight to see if there are other pool votes left...
                left_weight = left_weight > weight ? left_weight - weight : 0;
            }
        }
        
        return VeNFT({
            id: _id,
            account: account,
            decimals: ve.decimals(),
            amount: amount,
            voting_amount: ve.balanceOfNFT(_id),
            governance_amount: governance_amount,
            rebase_amount: dist.claimable(_id),
            expires_at: expires_at,
            voted_at: last_voted,
            votes: votes,
            token: token,
            permanent: perma,
            delegate_id: delegate_id,
            managed_id: managed_id
        });
    }
}
