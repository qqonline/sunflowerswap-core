pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./SunflowerToken.sol";

interface ISunflowerMainV1 {
    function userInfo(uint256 pid, address account) external view returns (uint256);
}

// SunflowerMain is the master of Sunflower. He can make Sunflower and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once SFR is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract SunflowerMainV2 is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;     // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of SFRs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accSunflowerPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accSunflowerPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. SFRs to distribute per block.
        uint256 lastRewardBlock;  // Last block number that SFRs distribution occurs.
        uint256 accSunflowerPerShare; // Accumulated SFRs per share, times 1e12. See below.
        // Lock LP, until the end of mining.
        bool lock;
        uint256 totalAmount;
    }

    // The SFR TOKEN!
    SunflowerToken public sunflower;
    // Dev address.
    address public devaddr;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when SFR mining starts.
    uint256 public startBlock;
    uint256 public halfPeriod;
    uint256 public maxSupply;

    ISunflowerMainV1 public sunflowerMainV1;
    IERC20 public pcc;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    constructor(
        SunflowerToken _sunflower,
        address _devaddr,
        uint256 _startBlock,
        uint256 _halfPeriod,
        uint256 _maxSupply,
        ISunflowerMainV1 _sunflowerMainV1,
        IERC20 _pcc
    ) public {
        sunflower = _sunflower;
        devaddr = _devaddr;
        startBlock = _startBlock;
        halfPeriod = _halfPeriod;
        maxSupply = _maxSupply;
        sunflowerMainV1 = _sunflowerMainV1;
        pcc = _pcc;
    }

    function getPccBalanceV1() public view returns (uint256) {
        if(sunflower.totalSupply() >=  halfPeriod && poolInfo[3].allocPoint == 0){
            return 0;
        }
        return pcc.balanceOf(address(sunflowerMainV1));
    }

    function getAmountV1(address _account) public view returns (uint256) {
        if(sunflower.totalSupply() >=  halfPeriod && poolInfo[3].allocPoint == 0){
            return 0;
        }
        return sunflowerMainV1.userInfo(3, _account);
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }


    function setStartBlock(uint256 _startBlock) public onlyOwner {
        require(block.number < startBlock);
        startBlock = _startBlock;
    }


    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(uint256 _allocPoint, IERC20 _lpToken, bool _withUpdate, bool _lock) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accSunflowerPerShare: 0,
            lock: _lock,
            totalAmount: 0
        }));
    }

    // Update the given pool's SFR allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    function getBlockRewardNow() public view returns (uint256) {
        return getBlockReward(sunflower.totalSupply());
    }

    // Reduce by 50% per halfPeriod.
    function getBlockReward(uint256 totalSupply) public view returns (uint256) {
        if(totalSupply >= maxSupply) return 0;
        uint256 nth = totalSupply / halfPeriod;
        if(0 == nth)     { return 15625000000000000; }
        else if(1 == nth){ return  7813000000000000; }
        else if(2 == nth){ return  3906000000000000; }
        else if(3 == nth){ return  1953000000000000; }
        else if(4 == nth){ return   977000000000000; }
        else             { return   488000000000000; }
    }

    function getBlockRewards(uint256 from, uint256 to) public view returns (uint256) {
        if(from < startBlock){
            from = startBlock;
        }
        if(from >= to){
            return 0;
        }
        uint256 totalSupply = sunflower.totalSupply();
        if(totalSupply >= maxSupply) return 0;
        uint256 blockReward = getBlockReward(totalSupply);
        uint256 blockGap = to.sub(from);
        uint256 rewards = blockGap.mul(blockReward);
        if(rewards.add(totalSupply) > maxSupply){
            if(totalSupply > maxSupply){
                return 0;
            }else{
                return maxSupply.sub(totalSupply);
            }
        }
        return rewards;
    }

    // View function to see pending SFRs on frontend.
    function pendingSunflower(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accSunflowerPerShare = pool.accSunflowerPerShare;
        if(_pid == 3){
            uint256 lpSupply = pool.totalAmount.add(getPccBalanceV1());
            if (block.number > pool.lastRewardBlock && lpSupply != 0 && sunflower.totalSupply() < halfPeriod) {
                uint256 blockRewards = getBlockRewards(pool.lastRewardBlock, block.number);
                uint256 sunflowerReward = blockRewards.mul(9).div(10).mul(pool.allocPoint).div(totalAllocPoint);
                accSunflowerPerShare = accSunflowerPerShare.add(sunflowerReward.mul(1e12).div(lpSupply));
            }
            return user.amount.add(getAmountV1(_user)).mul(accSunflowerPerShare).div(1e12).sub(user.rewardDebt);
        }else{
            uint256 lpSupply = pool.totalAmount;
            if (block.number > pool.lastRewardBlock && lpSupply != 0) {
                uint256 blockRewards = getBlockRewards(pool.lastRewardBlock, block.number);
                uint256 sunflowerReward = blockRewards.mul(9).div(10).mul(pool.allocPoint).div(totalAllocPoint);
                accSunflowerPerShare = accSunflowerPerShare.add(sunflowerReward.mul(1e12).div(lpSupply));
            }
            return user.amount.mul(accSunflowerPerShare).div(1e12).sub(user.rewardDebt);
        }
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.totalAmount;
        if(_pid == 3){
            lpSupply = lpSupply.add(getPccBalanceV1());
        }
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 blockRewards = getBlockRewards(pool.lastRewardBlock, block.number);
        uint256 sunflowerReward = blockRewards.mul(pool.allocPoint).div(totalAllocPoint);
        sunflower.mint(devaddr, sunflowerReward.div(10));
        uint256 userRewards = sunflowerReward.mul(9).div(10);
        sunflower.mint(address(this), userRewards);
        pool.accSunflowerPerShare = pool.accSunflowerPerShare.add(userRewards.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to SunflowerMain for SFR allocation.
    function deposit(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        uint256 userAmount = user.amount;
        if(_pid == 3){
            userAmount = userAmount.add(getAmountV1(msg.sender));
        }
        if (userAmount > 0) {
            uint256 pending = userAmount.mul(pool.accSunflowerPerShare).div(1e12).sub(user.rewardDebt);
            if(pending > 0) {
                safeSunflowerTransfer(msg.sender, pending);
            }
        }
        if(_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            user.amount = user.amount.add(_amount);
            userAmount = userAmount.add(_amount);
            pool.totalAmount = pool.totalAmount.add(_amount);
        }
        user.rewardDebt = userAmount.mul(pool.accSunflowerPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from SunflowerMain.
    function withdraw(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        require(pool.lock == false || pool.lock && sunflower.totalSupply() >= halfPeriod);
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 userAmount = user.amount;
        if(_pid == 3){
            userAmount = userAmount.add(getAmountV1(msg.sender));
        }
        uint256 pending = userAmount.mul(pool.accSunflowerPerShare).div(1e12).sub(user.rewardDebt);
        if(pending > 0) {
            safeSunflowerTransfer(msg.sender, pending);
        }
        if(_amount > 0) {
            user.amount = user.amount.sub(_amount);
            userAmount = userAmount.sub(_amount);
            pool.totalAmount = pool.totalAmount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = userAmount.mul(pool.accSunflowerPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        require(pool.lock == false || pool.lock && sunflower.totalSupply() >= halfPeriod);
        UserInfo storage user = userInfo[_pid][msg.sender];
        pool.lpToken.safeTransfer(address(msg.sender), user.amount);
        emit EmergencyWithdraw(msg.sender, _pid, user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
    }

    // Safe sunflower transfer function, just in case if rounding error causes pool to not have enough SFRs.
    function safeSunflowerTransfer(address _to, uint256 _amount) internal {
        uint256 sunflowerBal = sunflower.balanceOf(address(this));
        if (_amount > sunflowerBal) {
            sunflower.transfer(_to, sunflowerBal);
        } else {
            sunflower.transfer(_to, _amount);
        }
    }

    // Update dev address by the previous dev.
    function dev(address _devaddr) public {
        require(msg.sender == devaddr, "dev: wut?");
        devaddr = _devaddr;
    }
}
