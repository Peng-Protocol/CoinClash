// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

// File Version: 0.0.2 (24/11/2025)
// Changelog:
// - 24/11/2025: Added Swap function

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

contract MockUniPair {
    address public token0;
    address public token1;
    address public factory;
    
    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;
    
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to);
    event Sync(uint112 reserve0, uint112 reserve1);

    constructor() {
        factory = msg.sender;
    }

    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, "Only factory");
        token0 = _token0;
        token1 = _token1;
    }

    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    // Simplified mint - called after transferring tokens to pair
    function mint(address to) external returns (uint256 liquidity) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        uint256 balance0 = token0 == address(0) ? address(this).balance : IERC20(token0).balanceOf(address(this));
        uint256 balance1 = token1 == address(0) ? address(this).balance : IERC20(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - uint256(_reserve0);
        uint256 amount1 = balance1 - uint256(_reserve1);

        if (totalSupply == 0) {
            liquidity = sqrt(amount0 * amount1);
        } else {
            liquidity = min((amount0 * totalSupply) / _reserve0, (amount1 * totalSupply) / _reserve1);
        }

        require(liquidity > 0, "Insufficient liquidity minted");
        totalSupply += liquidity;
        balanceOf[to] += liquidity;

        _update(balance0, balance1);
        emit Mint(msg.sender, amount0, amount1);
    }

    // Simplified burn for testing
    function burn(address to) external returns (uint256 amount0, uint256 amount1) {
        uint256 balance0 = token0 == address(0) ? address(this).balance : IERC20(token0).balanceOf(address(this));
        uint256 balance1 = token1 == address(0) ? address(this).balance : IERC20(token1).balanceOf(address(this));
        uint256 liquidity = balanceOf[address(this)];

        amount0 = (liquidity * balance0) / totalSupply;
        amount1 = (liquidity * balance1) / totalSupply;
        require(amount0 > 0 && amount1 > 0, "Insufficient liquidity burned");

        balanceOf[address(this)] = 0;
        totalSupply -= liquidity;

        if (token0 == address(0)) {
            payable(to).transfer(amount0);
        } else {
            IERC20(token0).transfer(to, amount0);
        }
        
        if (token1 == address(0)) {
            payable(to).transfer(amount1);
        } else {
            IERC20(token1).transfer(to, amount1);
        }

        balance0 = token0 == address(0) ? address(this).balance : IERC20(token0).balanceOf(address(this));
        balance1 = token1 == address(0) ? address(this).balance : IERC20(token1).balanceOf(address(this));

        _update(balance0, balance1);
        emit Burn(msg.sender, amount0, amount1, to);
    }

    // Helper function to add initial liquidity for testing
    function addInitialLiquidity(uint256 amount0, uint256 amount1) external payable {
        require(totalSupply == 0, "Liquidity already exists");
        
        if (token0 == address(0)) {
            require(msg.value >= amount0, "Insufficient ETH");
        } else {
            IERC20(token0).transferFrom(msg.sender, address(this), amount0);
        }
        
        if (token1 == address(0)) {
            require(msg.value >= amount1, "Insufficient ETH");
        } else {
            IERC20(token1).transferFrom(msg.sender, address(this), amount1);
        }
        
        uint256 liquidity = sqrt(amount0 * amount1);
        totalSupply = liquidity;
        balanceOf[msg.sender] = liquidity;
        
        _update(amount0, amount1);
        emit Mint(msg.sender, amount0, amount1);
    }

    function _update(uint256 balance0, uint256 balance1) private {
        require(balance0 <= type(uint112).max && balance1 <= type(uint112).max, "Overflow");
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = uint32(block.timestamp);
        emit Sync(reserve0, reserve1);
    }

    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    function min(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x < y ? x : y;
    }
    
    // 0.0.2 : Added Swap function
    
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external {
        require(amount0Out > 0 || amount1Out > 0, "MockPair: Insufficient output amount");
        
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        require(amount0Out < _reserve0 && amount1Out < _reserve1, "MockPair: Insufficient liquidity");

        uint balance0;
        uint balance1;
        { // scope for _token{0,1}, avoids stack too deep errors
        address _token0 = token0;
        address _token1 = token1;
        require(to != _token0 && to != _token1, "MockPair: INVALID_TO");
        
        if (amount0Out > 0) {
             if (_token0 == address(0)) payable(to).transfer(amount0Out);
             else IERC20(_token0).transfer(to, amount0Out);
        }
        if (amount1Out > 0) {
             if (_token1 == address(0)) payable(to).transfer(amount1Out);
             else IERC20(_token1).transfer(to, amount1Out);
        }
        
        balance0 = _token0 == address(0) ? address(this).balance : IERC20(_token0).balanceOf(address(this));
        balance1 = _token1 == address(0) ? address(this).balance : IERC20(_token1).balanceOf(address(this));
        }
        
        _update(balance0, balance1);
        // Note: Sync/emit Swap event if needed, but not strictly required for this crash
    }

    receive() external payable {}
}