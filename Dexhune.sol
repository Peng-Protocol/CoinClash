// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2026
pragma solidity ^0.8.2;

/**
 * @title Dexhune (DXH)
 * @dev A fork of Link Gold (LAU) with the innate reward mechanism removed.
 * It maintains the "Cell" data structure to allow an external Fee Claimer
 * to distribute rewards efficiently to holders "cell by cell".
 */
 // 0.0.2: Added manual gap closing by fetching addresses from highest cell to fill empty entries in earlier ones. 
 
 interface TokenRegistry {
    function initializeBalances(address token, address[] memory userAddresses) external;
}

contract Dexhune {
    // --- ERC20 State ---
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;
    address public tokenRegistry;
    
    // --- Cell System State (Maintained for External Fee Claimer) ---
    mapping(uint256 => address[100]) private cells;
    mapping(address => uint256) private addressToCell;
    uint256 public cellHeight;
    uint256 private constant CELL_SIZE = 100;

    // --- Metadata ---
    string private constant NAME = "Dexhune";
    string private constant SYMBOL = "DXH";
    uint8 private constant DECIMALS = 18;

    address public owner;

    // --- Events ---
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event TokenRegistryCallFailed(address indexed user, address indexed token);
    event TokenRegistrySet(address indexed tokenRegistry);
    event GapClosed(uint256 indexed cellIndex, uint256 slotsFilled);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
        // Mint Fixed Supply: 1,000,000 DXH
        _totalSupply = 1_000_000 * 10**uint256(DECIMALS);
        
        // Assign to deployer
        _balances[msg.sender] = _totalSupply;
        
        // Initialize Cell 0 with deployer
        cells[0][0] = msg.sender;
        addressToCell[msg.sender] = 0;
        cellHeight = 0;

        emit Transfer(address(0), msg.sender, _totalSupply);
        emit OwnershipTransferred(address(0), msg.sender);
    }
    
    // Management Functions ---
    function setTokenRegistry(address _tokenRegistry) external onlyOwner {
        require(_tokenRegistry != address(0), "Invalid registry address");
        tokenRegistry = _tokenRegistry;
        emit TokenRegistrySet(_tokenRegistry);
    }

    // --- ERC20 Standard Functions ---

    function name() external pure returns (string memory) { return NAME; }
    function symbol() external pure returns (string memory) { return SYMBOL; }
    function decimals() external pure returns (uint8) { return DECIMALS; }
    function totalSupply() external view returns (uint256) { return _totalSupply; }
    function balanceOf(address account) external view returns (uint256) { return _balances[account]; }

    function transfer(address to, uint256 amount) external returns (bool success) {
        _transferWithRegistry(msg.sender, to, amount);
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) external returns (bool success) {
        uint256 allowed = _allowances[from][msg.sender];
        require(allowed >= amount, "Insufficient allowance");
        unchecked { _allowances[from][msg.sender] = allowed - amount; }
        _transfer(from, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool success) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function allowance(address owner_, address spender) external view returns (uint256) {
        return _allowances[owner_][spender];
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "New owner is zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // --- Cell System & Internal Logic ---
    
    function _transferWithRegistry(address from, address to, uint256 amount) private {
        require(from != address(0), "Transfer from zero address");
        require(to != address(0), "Transfer to zero address");
        require(_balances[from] >= amount, "Insufficient balance");

        unchecked {
            _balances[from] -= amount;
            _balances[to] += amount;
        }

        _updateCells(from, _balances[from]);
        _updateCells(to, _balances[to]);

        if (tokenRegistry != address(0)) {
            address[] memory users = new address[](2);
            users[0] = from;
            users[1] = to;
            try TokenRegistry(tokenRegistry).initializeBalances(address(this), users) {} catch {
                emit TokenRegistryCallFailed(from, address(this));
            }
        }

        emit Transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) private {
        require(from != address(0), "Transfer from zero");
        require(to != address(0), "Transfer to zero");
        require(_balances[from] >= amount, "Insufficient balance");

        unchecked {
            _balances[from] -= amount;
            _balances[to] += amount;
        }

        // Update cells for external tracking (Moved from LAU logic)
        _updateCells(from, _balances[from]);
        _updateCells(to, _balances[to]);

        emit Transfer(from, to, amount);
    }

    /**
     * @dev Manages the "Cell" list. When a user's balance becomes 0, they are removed.
     * When a user's balance becomes non-zero, they are added to the list.
     * This keeps the holder list compact for the Fee Claimer.
     */
    function _updateCells(address account, uint256 newBalance) private {
        // Check if account is already tracked (in a cell)
        bool isInCell = addressToCell[account] != 0 || cells[0][0] == account;

        // CASE 1: Balance became 0 -> Remove from cell
        if (newBalance == 0 && isInCell) {
            uint256 cellIndex = addressToCell[account];
            uint256 indexInCell;
            
            // Find position in cell
            for (uint256 i = 0; i < CELL_SIZE; i++) {
                if (cells[cellIndex][i] == account) {
                    indexInCell = i;
                    break;
                }
            }

            // Find last occupant in this cell to swap-and-pop
            uint256 lastIndex = CELL_SIZE - 1;
            while (lastIndex > 0 && cells[cellIndex][lastIndex] == address(0)) {
                lastIndex--;
            }

            // Move the last occupant to the empty spot (unless it was the last spot)
            if (lastIndex != indexInCell && cells[cellIndex][lastIndex] != address(0)) {
                cells[cellIndex][indexInCell] = cells[cellIndex][lastIndex];
                addressToCell[cells[cellIndex][lastIndex]] = cellIndex;
            }

            // Delete the old slot
            cells[cellIndex][lastIndex] = address(0);
            delete addressToCell[account];

            // If the cell is now completely empty and it was the last cell, shrink height
            if (lastIndex == 0 && cellIndex == cellHeight) {
                while (cellHeight > 0) {
                    bool isEmpty = true;
                    for (uint256 i = 0; i < CELL_SIZE; i++) {
                        if (cells[cellHeight][i] != address(0)) {
                            isEmpty = false;
                            break;
                        }
                    }
                    if (!isEmpty) break;
                    cellHeight--;
                }
            }
        
        // CASE 2: Balance became > 0 -> Add to cell
        } else if (newBalance > 0 && !isInCell) {
            // If current top cell is full, increment height
            if (cells[cellHeight][CELL_SIZE - 1] != address(0)) {
                cellHeight++;
            }
            
            // Find first empty slot in the current top cell
            uint256 indexInCell;
            for (uint256 i = 0; i < CELL_SIZE; i++) {
                if (cells[cellHeight][i] == address(0)) {
                    indexInCell = i;
                    break;
                }
            }
            
            cells[cellHeight][indexInCell] = account;
            addressToCell[account] = cellHeight;
        }
    }
    
    // --- Gap Closing Logic (External Automation) ---

    /**
     * @dev Selects a pseudo-random cell (excluding the highest) and attempts to close gaps.
     * Designed for external bots/keepers. Degrades gracefully if no work is needed.
     */
    function closeRandomGap() external {
        if (cellHeight == 0) return;

        // Psuedo-random selection based on block properties
        // We mod by cellHeight because we cannot target the highest cell itself
        uint256 randomCellIndex = uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao))) % cellHeight;
        
        // Attempt to close gaps in the selected cell
        closeGap(randomCellIndex);
    }

    /**
     * @dev Scans a specific cell for empty slots and fills them with addresses 
     * popped from the very top of the list (cellHeight).
     * @param cellIndex The index of the cell to defragment.
     * Note: if the highest cell has insufficient addresses to fill gaps, the system uses whatever number of addresses it can pull, requires calling again till the cell is full. 
     */
    function closeGap(uint256 cellIndex) public {
        // Can only close gaps in cells strictly below the current height
        require(cellIndex < cellHeight, "Cannot target highest cell");

        uint256 gapsFilled = 0;

        for (uint256 i = 0; i < CELL_SIZE; i++) {
            // Optimization: If we've shrunk the top down to this level, stop immediately
            if (cellHeight <= cellIndex) break;

            // Found an empty slot?
            if (cells[cellIndex][i] == address(0)) {
                
                // Pull the last active user from the top of the stack
                address movedUser = _pullFromTop(cellIndex);

                // If no user could be pulled (or we hit the limit), stop
                if (movedUser == address(0)) break;

                // Move user to the gap
                cells[cellIndex][i] = movedUser;
                addressToCell[movedUser] = cellIndex;
                gapsFilled++;
            }
        }

        if (gapsFilled > 0) {
            emit GapClosed(cellIndex, gapsFilled);
        }
    }

    /**
     * @dev Helper to find and remove the last address from the highest cell.
     * Handles shrinking `cellHeight` automatically.
     * @param limitIndex The absolute floor index we cannot pull from (the cell we are fixing).
     */
    function _pullFromTop(uint256 limitIndex) private returns (address) {
        while (cellHeight > limitIndex) {
            // Search the current top cell from back to front
            for (int256 i = int256(CELL_SIZE) - 1; i >= 0; i--) {
                address candidate = cells[cellHeight][uint256(i)];
                
                if (candidate != address(0)) {
                    // Clear the old slot
                    cells[cellHeight][uint256(i)] = address(0);
                    return candidate;
                }
            }

            // If the loop finishes, this cell is empty. Shrink height and try the next one down.
            // We only shrink if we remain above the limitIndex.
            if (cellHeight - 1 > limitIndex) {
                cellHeight--;
            } else {
                // We cannot go lower without touching the target cell
                // Just decrement to reflect it is empty, but return 0 to stop the process
                cellHeight--;
                return address(0);
            }
        }
        return address(0);
    }

    // --- View Functions for External Fee Claimer ---

    function getCell(uint256 cellIndex) external view returns (address[100] memory) {
        return cells[cellIndex];
    }

    function getAddressCell(address account) external view returns (uint256) {
        return addressToCell[account];
    }

    // Helper to get non-zero balances in a cell for easier calculation
    function getCellBalances(uint256 cellIndex) external view returns (address[] memory addresses, uint256[] memory balances) {
        address[] memory tempAddresses = new address[](CELL_SIZE);
        uint256[] memory tempBalances = new uint256[](CELL_SIZE);
        uint256 count = 0;

        for (uint256 i = 0; i < CELL_SIZE; i++) {
            address account = cells[cellIndex][i];
            if (account == address(0)) continue;
            uint256 bal = _balances[account];
            if (bal == 0) continue; // Should not happen given logic, but safety check

            tempAddresses[count] = account;
            tempBalances[count] = bal;
            count++;
        }

        addresses = new address[](count);
        balances = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            addresses[i] = tempAddresses[i];
            balances[i] = tempBalances[i];
        }
    }
}