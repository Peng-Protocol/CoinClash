// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

// File Version: 0.0.4 (01/12/2025)
// 0.0.3 (01/12/2025): Adjusted expectations of d2_4, withdrawal degrades gracefully. 
// 0.0.3 (01/12/2025): (How could you forget the star of the show?) Added liquid router interface, setter, and setup. 
// 0.0.2 (30/11/2025): Comprehensive liquidity router tests including deposits, withdrawals, 
//                     compensation withdrawals, fee claims, ownership transfers, and settlement integration
// 0.0.1 (30/11/2025): Initial liquid router test suite based on SettlementTests.sol

import "./MockMAILToken.sol";
import "./MockMailTester.sol";
import "./MockWETH.sol";
import "./MockUniRouter.sol";

interface ICCLiquidRouter {
    function setListingAddress(address _listingAddress) external;
    function settleBuyLiquid(uint256 step) external;
    function settleSellLiquid(uint256 step) external;
}

interface ICCOrderRouter {
    function setListingTemplate(address) external;
    function createBuyOrder(
        address startToken,
        address endToken,
        address recipientAddress,
        uint256 inputAmount,
        uint256 maxPrice,
        uint256 minPrice
    ) external payable;
    function setWETH(address) external;
}

interface ICCSettlementRouter {
    function setListingTemplate(address) external;
    function settleOrders(
        address listingAddress,
        uint256[] calldata orderIds,
        uint256[] calldata amountsIn,
        bool isBuyOrder
    ) external returns (string memory);
}

interface ICCLiquidityRouter {
    function depositToken(address liquidityAddress, address token, address depositor, uint256 amount) external;
    function depositNativeToken(address liquidityAddress, address depositor, uint256 amount) external payable;
    function withdraw(address liquidityAddress, address listingAddress, address token, address compensationToken, uint256 outputAmount, uint256 compensationAmount, uint256 index) external;
    function claimFees(address liquidityAddress, address token, uint256 liquidityIndex) external;
    function changeDepositor(address liquidityAddress, address token, uint256 slotIndex, address newDepositor) external;
}

interface ICCListingTemplate {
    function setUniswapV2Factory(address) external;
    function setUniswapV2Router(address) external;
    function addRouter(address) external;
    function getNextOrderId() external view returns (uint256);
    function getBuyOrder(uint256 orderId) external view returns (
        address[] memory addresses,
        uint256[] memory prices,
        uint256[] memory amounts,
        uint8 status
    );
    function prices(address tokenA, address tokenB) external view returns (uint256);
    function transferOwnership(address) external;
    function routerAddressesView() external view returns (address[] memory);
    function uniswapV2Factory() external view returns (address);
    function uniswapV2Router() external view returns (address);
}

interface ICCLiquidityTemplate {
    function addRouter(address) external;
    function liquidityAmounts(address token) external view returns (uint256);
    function liquidityDetailsView(address token) external view returns (uint256 liquid, uint256 fees, uint256 feesAcc);
    function userSlotIndicesView(address token, address user) external view returns (uint256[] memory);
    function getSlotView(address token, uint256 index) external view returns (
        address token_,
        address depositor,
        address recipient,
        uint256 allocation,
        uint256 dFeesAcc,
        uint256 timestamp
    );
    function getActiveSlots(address token) external view returns (uint256[] memory);
}

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function mint(address to) external returns (uint256 liquidity);
}

contract LiquidTests {
    ICCOrderRouter public orderRouter;
    ICCSettlementRouter public settlementRouter; // Standard Settlement
    ICCLiquidRouter public liquidRouter; // Liquid Settlement
    ICCLiquidityRouter public liquidityRouter;
    ICCListingTemplate public listingTemplate;
    ICCLiquidityTemplate public liquidityTemplate;
    MockUniFactory public uniFactory;
    MockWETH public weth;
    MockUniRouter public uniRouter;
    
    MockMAILToken public token18;
    MockMAILToken public token6;
    MockMailTester public tester;
    address public owner;

    address payable public pairToken18Token6;
    uint256 public constant TOKEN18_AMOUNT = 1000 * 1e18;
    uint256 public constant TOKEN6_AMOUNT = 1000 * 1e6;
    uint256 public constant LIQUIDITY_TOKEN18 = 10000 * 1e18;
    uint256 public constant LIQUIDITY_TOKEN6 = 10000 * 1e6;

    // Order tracking
    uint256 public l1_orderId;
    uint256 public l2_orderId;
    uint256 public l3_orderId;

    // Slot tracking for deposits
    uint256 public d1_slotIndex;
    uint256 public d2_slotIndex;
    uint256 public d3_testerSlot;
    uint256 public d3_contractSlot;
    
    event TestPassed(string testName);
    event DebugLiquidity(address token, uint256 liquid, uint256 fees, string label);
    event DebugSlot(uint256 slotIndex, address depositor, uint256 allocation, string label);

    constructor() {
        owner = msg.sender;
        _deployMocks();
    }

    receive() external payable {}

    function _deployMocks() internal {
        token18 = new MockMAILToken();
        token18.setDetails("Token 18", "TK18", 18);
        
        token6 = new MockMAILToken();
        token6.setDetails("Token 6", "TK6", 6);
    }

    function deployUniMocks() external {
        require(msg.sender == owner, "Not owner");
        weth = new MockWETH();
        uniFactory = new MockUniFactory(address(weth));
        uniRouter = new MockUniRouter(address(uniFactory), address(weth));
    }

    function setOrderRouter(address _orderRouter) external {
        require(msg.sender == owner, "Not owner");
        orderRouter = ICCOrderRouter(_orderRouter);
    }

    function setSettlementRouter(address _settlementRouter) external {
        require(msg.sender == owner, "Not owner");
        settlementRouter = ICCSettlementRouter(_settlementRouter);
    }

    function setLiquidRouter(address _liquidRouter) external {
        require(msg.sender == owner, "Not owner");
        require(_liquidRouter != address(0), "Invalid liquid router");
        liquidRouter = ICCLiquidRouter(_liquidRouter);
    }

    function setLiquidityRouter(address _liquidityRouter) external {
        require(msg.sender == owner, "Not owner");
        liquidityRouter = ICCLiquidityRouter(_liquidityRouter);
    }

    function setListingTemplate(address _listing) external {
        require(msg.sender == owner, "Not owner");
        listingTemplate = ICCListingTemplate(_listing);
    }

    function setLiquidityTemplate(address _liquidity) external {
        require(msg.sender == owner, "Not owner");
        liquidityTemplate = ICCLiquidityTemplate(_liquidity);
    }

    function initializeContracts() external payable {
        require(msg.sender == owner, "Not owner");
        require(address(uniFactory) != address(0), "Uni mocks not deployed");

        // Add routers to listing template
        address[] memory currentRouters = listingTemplate.routerAddressesView();
        bool orderRouterAdded = false;
        bool settlementRouterAdded = false;
        bool liquidRouterAdded = false;

        for (uint i = 0; i < currentRouters.length; i++) {
            if (currentRouters[i] == address(orderRouter)) orderRouterAdded = true;
            if (currentRouters[i] == address(settlementRouter)) settlementRouterAdded = true;
            if (currentRouters[i] == address(liquidRouter)) liquidRouterAdded = true;
        }

        if (!orderRouterAdded) listingTemplate.addRouter(address(orderRouter));
        if (!settlementRouterAdded && address(settlementRouter) != address(0)) {
            listingTemplate.addRouter(address(settlementRouter));
        }
        if (!liquidRouterAdded && address(liquidRouter) != address(0)) {
            listingTemplate.addRouter(address(liquidRouter));
        }

        // Add routers to liquidity template
        liquidityTemplate.addRouter(address(liquidRouter));
        liquidityTemplate.addRouter(address(liquidityRouter));

        // Set listing template for order router
        (bool success, bytes memory data) = address(orderRouter).staticcall(abi.encodeWithSignature("listingTemplate()"));
        if (success && abi.decode(data, (address)) == address(0)) {
            orderRouter.setListingTemplate(address(listingTemplate));
        }

        // Set WETH for order router
        (success, data) = address(orderRouter).staticcall(abi.encodeWithSignature("wethAddress()"));
        if (success && abi.decode(data, (address)) == address(0)) {
            orderRouter.setWETH(address(weth));
        }

        // Set listing template for settlement router
        (success, data) = address(settlementRouter).staticcall(abi.encodeWithSignature("listingTemplate()"));
        if (success && abi.decode(data, (address)) == address(0)) {
            settlementRouter.setListingTemplate(address(listingTemplate));
        }

        // Initialize Liquid Router - This fixes the "Listing not set" error
        if (address(liquidRouter) != address(0)) {
            liquidRouter.setListingAddress(address(listingTemplate));
        }

        // Set factory and router
        if (listingTemplate.uniswapV2Factory() == address(0)) {
            listingTemplate.setUniswapV2Factory(address(uniFactory));
        }

        if (listingTemplate.uniswapV2Router() == address(0)) {
            listingTemplate.setUniswapV2Router(address(uniRouter));
        }

        // Create pair with liquidity
        if (pairToken18Token6 == address(0)) {
            _createPairWithLiquidity();
        }
    }

    function _createPairWithLiquidity() internal {
        pairToken18Token6 = payable(uniFactory.createPair(address(token18), address(token6)));
        token18.transfer(pairToken18Token6, LIQUIDITY_TOKEN18);
        token6.transfer(pairToken18Token6, LIQUIDITY_TOKEN6);
        IUniswapV2Pair(pairToken18Token6).mint(address(this));
    }

    function returnOwnership() external {
        require(msg.sender == owner, "Not owner");
        listingTemplate.transferOwnership(msg.sender);
    }

    function initiateTester() public payable {
        require(msg.sender == owner, "Not owner");
        require(msg.value >= 3 ether, "Send 3 ETH or More");
        
        tester = new MockMailTester(address(this));
        
        (bool success,) = address(tester).call{value: 2 ether}("");
        require(success, "ETH transfer failed");
        
        token18.mint(address(tester), TOKEN18_AMOUNT);
        token6.mint(address(tester), TOKEN6_AMOUNT);
    }

    // ============ HELPER FUNCTIONS ============

    function _approveToken6Tester(uint256 amount) internal {
        tester.proxyCall(
            address(token6),
            abi.encodeWithSignature("approve(address,uint256)", address(orderRouter), amount)
        );
    }

    function _getPoolPrice(address startToken, address endToken) internal view returns (uint256 price) {
        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pairToken18Token6).getReserves();
        address token0 = IUniswapV2Pair(pairToken18Token6).token0();
        
        uint256 reserveIn = startToken == token0 ? uint256(reserve0) : uint256(reserve1);
        uint256 reserveOut = endToken == token0 ? uint256(reserve0) : uint256(reserve1);
        
        uint256 normIn = startToken == address(token18) ? reserveIn : reserveIn * 1e12;
        uint256 normOut = endToken == address(token18) ? reserveOut : reserveOut * 1e12;
        
        require(normIn > 0, "Zero Reserve In");
        price = (normOut * 1e18) / normIn;
    }

    function _logLiquidity(address token, string memory label) internal {
        (uint256 liquid, uint256 fees,) = liquidityTemplate.liquidityDetailsView(token);
        emit DebugLiquidity(token, liquid, fees, label);
    }

    function _logSlot(address token, uint256 slotIndex, string memory label) internal {
        (,address depositor,,uint256 allocation,,) = liquidityTemplate.getSlotView(token, slotIndex);
        emit DebugSlot(slotIndex, depositor, allocation, label);
    }

    // ============ PATH D1: BASIC DEPOSIT & SLOT CREATION ============

    function d1_1DepositToken18() public {
        uint256 depositAmount = 1000 * 1e18;
        token18.mint(address(this), depositAmount);
        token18.approve(address(liquidityRouter), depositAmount);
        
        uint256[] memory slotsBefore = liquidityTemplate.getActiveSlots(address(token18));
        
        liquidityRouter.depositToken(
            address(liquidityTemplate),
            address(token18),
            address(this),
            depositAmount
        );
        
        uint256[] memory slotsAfter = liquidityTemplate.getActiveSlots(address(token18));
        assert(slotsAfter.length == slotsBefore.length + 1);
        
        d1_slotIndex = slotsAfter[slotsAfter.length - 1];
        (,address depositor,,uint256 allocation,,) = liquidityTemplate.getSlotView(address(token18), d1_slotIndex);
        
        assert(depositor == address(this));
        assert(allocation > 0);
        
        _logSlot(address(token18), d1_slotIndex, "After Token18 Deposit");
        emit TestPassed("d1_1DepositToken18");
    }

    function d1_2ZeroDepositMustFail() public {
        // Test that zero deposit reverts
        token18.mint(address(this), 100 * 1e18);
        token18.approve(address(liquidityRouter), 100 * 1e18);
        
        bool failed = false;
        try liquidityRouter.depositToken(
            address(liquidityTemplate),
            address(token18),
            address(this),
            0
        ) {
            // Should not reach here
            assert(false);
        } catch {
            failed = true;
        }
        
        assert(failed);
        emit TestPassed("d1_2ZeroDepositMustFail");
    }

    // ============ PATH D2: WITHDRAWAL & SLOT CLEARING ============

    function d2_1DepositForWithdrawal() public {
        uint256 depositAmount = 500 * 1e6;
        token6.mint(address(this), depositAmount);
        token6.approve(address(liquidityRouter), depositAmount);
        
        liquidityRouter.depositToken(
            address(liquidityTemplate),
            address(token6),
            address(this),
            depositAmount
        );
        
        uint256[] memory slots = liquidityTemplate.userSlotIndicesView(address(token6), address(this));
        d2_slotIndex = slots[slots.length - 1];
        
        _logSlot(address(token6), d2_slotIndex, "Before Withdrawal");
        emit TestPassed("d2_1DepositForWithdrawal");
    }

    function d2_2PartialWithdrawal() public {
        (,,,uint256 allocationBefore,,) = liquidityTemplate.getSlotView(address(token6), d2_slotIndex);
        uint256 withdrawAmount = allocationBefore / 2; // Withdraw 50%
        
        liquidityRouter.withdraw(
            address(liquidityTemplate),
            address(listingTemplate),
            address(token6),
            address(0), // No compensation
            withdrawAmount,
            0,
            d2_slotIndex
        );
        
        (,address depositor,,uint256 allocationAfter,,) = liquidityTemplate.getSlotView(address(token6), d2_slotIndex);
        
        assert(depositor == address(this)); // Slot still exists
        assert(allocationAfter == allocationBefore - withdrawAmount);
        
        _logSlot(address(token6), d2_slotIndex, "After Partial Withdrawal");
        emit TestPassed("d2_2PartialWithdrawal");
    }

    function d2_3FullWithdrawalClearsSlot() public {
        (,,,uint256 allocation,,) = liquidityTemplate.getSlotView(address(token6), d2_slotIndex);
        
        liquidityRouter.withdraw(
            address(liquidityTemplate),
            address(listingTemplate),
            address(token6),
            address(0),
            allocation,
            0,
            d2_slotIndex
        );
        
        (,address depositor,,uint256 allocationAfter,,) = liquidityTemplate.getSlotView(address(token6), d2_slotIndex);
        
        assert(allocationAfter == 0);
        
        _logSlot(address(token6), d2_slotIndex, "After Full Withdrawal");
        emit TestPassed("d2_3FullWithdrawalClearsSlot");
    }

    function d2_4ZeroWithdrawalMustFail() public {
        // Create new deposit for this test
        uint256 depositAmount = 100 * 1e6;
        token6.mint(address(this), depositAmount);
        token6.approve(address(liquidityRouter), depositAmount);
        
        liquidityRouter.depositToken(
            address(liquidityTemplate),
            address(token6),
            address(this),
            depositAmount
        );
        
        uint256[] memory slots = liquidityTemplate.userSlotIndicesView(address(token6), address(this));
        uint256 testSlot = slots[slots.length - 1];
        
        // Capture balance before zero withdrawal attempt
        uint256 preBalance = token6.balanceOf(address(this));
        (,,,uint256 preAllocation,,) = liquidityTemplate.getSlotView(address(token6), testSlot);
        
        // Attempt zero withdrawal - should degrade gracefully
        liquidityRouter.withdraw(
            address(liquidityTemplate),
            address(listingTemplate),
            address(token6),
            address(0),
            0, // Zero withdrawal
            0,
            testSlot
        );
        
        // Verify nothing changed
        uint256 postBalance = token6.balanceOf(address(this));
        (,,,uint256 postAllocation,,) = liquidityTemplate.getSlotView(address(token6), testSlot);
        
        assert(postBalance == preBalance); // Balance unchanged
        assert(postAllocation == preAllocation); // Allocation unchanged
        
        emit TestPassed("d2_4ZeroWithdrawalMustFail");
    }

    // ============ PATH D3: MULTI-USER DEPOSITS ============

    function d3_1TesterDeposit() public {
        uint256 depositAmount = 300 * 1e18;
        
        tester.proxyCall(
            address(token18),
            abi.encodeWithSignature("approve(address,uint256)", address(liquidityRouter), depositAmount)
        );
        
        tester.proxyCall(
            address(liquidityRouter),
            abi.encodeWithSignature(
                "depositToken(address,address,address,uint256)",
                address(liquidityTemplate),
                address(token18),
                address(tester),
                depositAmount
            )
        );
        
        uint256[] memory slots = liquidityTemplate.userSlotIndicesView(address(token18), address(tester));
        d3_testerSlot = slots[slots.length - 1];
        
        (,address depositor,,,, ) = liquidityTemplate.getSlotView(address(token18), d3_testerSlot);
        assert(depositor == address(tester));
        
        emit TestPassed("d3_1TesterDeposit");
    }

    function d3_2ContractDeposit() public {
        uint256 depositAmount = 400 * 1e18;
        token18.mint(address(this), depositAmount);
        token18.approve(address(liquidityRouter), depositAmount);
        
        liquidityRouter.depositToken(
            address(liquidityTemplate),
            address(token18),
            address(this),
            depositAmount
        );
        
        uint256[] memory slots = liquidityTemplate.userSlotIndicesView(address(token18), address(this));
        d3_contractSlot = slots[slots.length - 1];
        
        emit TestPassed("d3_2ContractDeposit");
    }

    function d3_3VerifyIndependentSlots() public {
        (,address testerDep,,uint256 testerAlloc,,) = liquidityTemplate.getSlotView(address(token18), d3_testerSlot);
        (,address contractDep,,uint256 contractAlloc,,) = liquidityTemplate.getSlotView(address(token18), d3_contractSlot);
        
        assert(testerDep == address(tester));
        assert(contractDep == address(this));
        assert(testerAlloc > 0);
        assert(contractAlloc > 0);
        assert(d3_testerSlot != d3_contractSlot);
        
        emit TestPassed("d3_3VerifyIndependentSlots");
    }

    // ============ PATH D4: WITHDRAWAL WITH COMPENSATION ============

    function d4_1SetupForCompensation() public {
        // Deposit both tokens for compensation test
        uint256 deposit18 = 200 * 1e18;
        uint256 deposit6 = 200 * 1e6;
        
        token18.mint(address(this), deposit18);
        token18.approve(address(liquidityRouter), deposit18);
        liquidityRouter.depositToken(address(liquidityTemplate), address(token18), address(this), deposit18);
        
        token6.mint(address(this), deposit6);
        token6.approve(address(liquidityRouter), deposit6);
        liquidityRouter.depositToken(address(liquidityTemplate), address(token6), address(this), deposit6);
        
        emit TestPassed("d4_1SetupForCompensation");
    }

    function d4_2WithdrawWithCompensation() public {
        uint256[] memory slots18 = liquidityTemplate.userSlotIndicesView(address(token18), address(this));
        uint256 slot18 = slots18[slots18.length - 1];
        
        (,,,uint256 allocation18,,) = liquidityTemplate.getSlotView(address(token18), slot18);
        
        uint256 primaryAmount = allocation18 / 2;
        uint256 compensationAmount = 50 * 1e6; // Compensate with token6
        
        uint256 token6BalBefore = token6.balanceOf(address(this));
        
        liquidityRouter.withdraw(
            address(liquidityTemplate),
            address(listingTemplate),
            address(token18),
            address(token6), // Compensation token
            primaryAmount,
            compensationAmount,
            slot18
        );
        
        uint256 token6BalAfter = token6.balanceOf(address(this));
        
        // Should have received compensation in token6
        assert(token6BalAfter > token6BalBefore);
        
        emit TestPassed("d4_2WithdrawWithCompensation");
    }

    // ============ PATH D5: FEE CLAIMING ============

    function d5_1CreateOrderAndSettle() public {
        // First deposit liquidity for settlement
        uint256 deposit18 = 2000 * 1e18;
        uint256 deposit6 = 2000 * 1e6;
        
        token18.mint(address(this), deposit18);
        token18.approve(address(liquidityRouter), deposit18);
        liquidityRouter.depositToken(address(liquidityTemplate), address(token18), address(this), deposit18);
        
        token6.mint(address(this), deposit6);
        token6.approve(address(liquidityRouter), deposit6);
        liquidityRouter.depositToken(address(liquidityTemplate), address(token6), address(this), deposit6);
        
        // Create order via tester
        _approveToken6Tester(TOKEN6_AMOUNT);
        uint256 orderIdBefore = listingTemplate.getNextOrderId();
        
        tester.proxyCall(
            address(orderRouter),
            abi.encodeWithSignature(
                "createBuyOrder(address,address,address,uint256,uint256,uint256)",
                address(token6),
                address(token18),
                address(tester),
                50 * 1e6,
                10e18,
                1e16
            )
        );
        l1_orderId = orderIdBefore;
        
        emit TestPassed("d5_1CreateOrderAndSettle");
    }

    function d5_2SettleViaLiquidRouter() public {
        (uint256 feesBefore,,) = liquidityTemplate.liquidityDetailsView(address(token6));
        
        // Settle via liquid router (generates fees)
        tester.proxyCall(
            address(liquidRouter),
            abi.encodeWithSignature("settleBuyLiquid(uint256)", 0)
        );
        
        (uint256 feesAfter,,) = liquidityTemplate.liquidityDetailsView(address(token6));
        
        assert(feesAfter > feesBefore);
        
        _logLiquidity(address(token6), "After Liquid Settlement");
        emit TestPassed("d5_2SettleViaLiquidRouter");
    }

    function d5_3ClaimFees() public {
        uint256[] memory slots6 = liquidityTemplate.userSlotIndicesView(address(token6), address(this));
        uint256 claimSlot = slots6[slots6.length - 1];
        
        uint256 balBefore = token6.balanceOf(address(this));
        (uint256 feesBefore,,) = liquidityTemplate.liquidityDetailsView(address(token6));
        
        liquidityRouter.claimFees(
            address(liquidityTemplate),
            address(token6),
            claimSlot
        );
        
        uint256 balAfter = token6.balanceOf(address(this));
        (uint256 feesAfter,,) = liquidityTemplate.liquidityDetailsView(address(token6));
        
        assert(balAfter > balBefore); // Received fees
        assert(feesAfter < feesBefore); // Fees decreased
        
        emit TestPassed("d5_3ClaimFees");
    }

    // ============ PATH D6: OWNERSHIP TRANSFER ============

    function d6_1DepositForTransfer() public {
        uint256 depositAmount = 150 * 1e18;
        token18.mint(address(this), depositAmount);
        token18.approve(address(liquidityRouter), depositAmount);
        
        liquidityRouter.depositToken(
            address(liquidityTemplate),
            address(token18),
            address(this),
            depositAmount
        );
        
        emit TestPassed("d6_1DepositForTransfer");
    }

    function d6_2TransferOwnership() public {
        uint256[] memory slots = liquidityTemplate.userSlotIndicesView(address(token18), address(this));
        uint256 transferSlot = slots[slots.length - 1];
        
        (,address depositorBefore,,,, ) = liquidityTemplate.getSlotView(address(token18), transferSlot);
        assert(depositorBefore == address(this));
        
        liquidityRouter.changeDepositor(
            address(liquidityTemplate),
            address(token18),
            transferSlot,
            address(tester)
        );
        
        (,address depositorAfter,,,, ) = liquidityTemplate.getSlotView(address(token18), transferSlot);
        assert(depositorAfter == address(tester));
        
        // Verify old owner no longer has this slot
        uint256[] memory newSlots = liquidityTemplate.userSlotIndicesView(address(token18), address(this));
        bool found = false;
        for (uint i = 0; i < newSlots.length; i++) {
            if (newSlots[i] == transferSlot) found = true;
        }
        assert(!found);
        
        emit TestPassed("d6_2TransferOwnership");
    }

    // ============ PATH L1: LIQUID SETTLEMENT FULL ============

    function l1_1CreateOrderForLiquidSettlement() public {
        // Ensure liquidity exists
        uint256 deposit18 = 500 * 1e18;
        uint256 deposit6 = 500 * 1e6;
        
        token18.mint(address(this), deposit18);
        token18.approve(address(liquidityRouter), deposit18);
        liquidityRouter.depositToken(address(liquidityTemplate), address(token18), address(this), deposit18);
        
        token6.mint(address(this), deposit6);
        token6.approve(address(liquidityRouter), deposit6);
        liquidityRouter.depositToken(address(liquidityTemplate), address(token6), address(this), deposit6);
        
        _approveToken6Tester(TOKEN6_AMOUNT);
        uint256 orderIdBefore = listingTemplate.getNextOrderId();
        
        tester.proxyCall(
            address(orderRouter),
            abi.encodeWithSignature(
                "createBuyOrder(address,address,address,uint256,uint256,uint256)",
                address(token6),
                address(token18),
                address(tester),
                30 * 1e6,
                10e18,
                1e16
            )
        );
        l2_orderId = orderIdBefore;
        
        emit TestPassed("l1_1CreateOrderForLiquidSettlement");
    }

    function l1_2FullLiquidSettle() public {
        (,, uint256[] memory amountsBefore, uint8 statusBefore) = listingTemplate.getBuyOrder(l2_orderId);
        
        tester.proxyCall(
            address(liquidRouter),
            abi.encodeWithSignature("settleBuyLiquid(uint256)", 0)
        );
        
        (,, uint256[] memory amountsAfter, uint8 statusAfter) = listingTemplate.getBuyOrder(l2_orderId);
        
        assert(amountsAfter[0] == 0); // Pending = 0
        assert(amountsAfter[1] == amountsBefore[0]); // Filled = original pending
        assert(statusAfter == 3); // Filled
        
        emit TestPassed("l1_2FullLiquidSettle");
    }

    // ============ PATH L2: LIQUID SETTLEMENT WITH PARTIAL PRE-SETTLEMENT ============

    function l2_1CreateLargeOrder() public {
        _approveToken6Tester(TOKEN6_AMOUNT * 2);
        token6.mint(address(tester), 500 * 1e6);
        
        uint256 orderIdBefore = listingTemplate.getNextOrderId();
        
        tester.proxyCall(
            address(orderRouter),
            abi.encodeWithSignature(
                "createBuyOrder(address,address,address,uint256,uint256,uint256)",
                address(token6),
                address(token18),
                address(tester),
                200 * 1e6,
                10e18,
                1e16
            )
        );
        l3_orderId = orderIdBefore;
        
        emit TestPassed("l2_1CreateLargeOrder");
    }

    function l2_2PartialSettleViaSettlementRouter() public {
        (,, uint256[] memory amountsBefore,) = listingTemplate.getBuyOrder(l3_orderId);
        
        // Partially settle using settlement router (50%)
        token18.approve(address(settlementRouter), type(uint256).max);
        
        uint256[] memory orderIds = new uint256[](1);
        orderIds[0] = l3_orderId;
        
        uint256[] memory amountsIn = new uint256[](1);
        amountsIn[0] = amountsBefore[0] / 2;
        
        settlementRouter.settleOrders(address(listingTemplate), orderIds, amountsIn, true);
        
        (,, uint256[] memory amountsAfter, uint8 status) = listingTemplate.getBuyOrder(l3_orderId);
        
        assert(status == 2); // Partial
        assert(amountsAfter[0] > 0); // Still has pending
        assert(amountsAfter[1] > 0); // Has filled
        
        emit TestPassed("l2_2PartialSettleViaSettlementRouter");
    }

    function l2_3CompleteLiquidSettle() public {
        (,, uint256[] memory amountsBefore, uint8 statusBefore) = listingTemplate.getBuyOrder(l3_orderId);
        assert(statusBefore == 2); // Should be partial
        
        // Complete settlement via liquid router
        tester.proxyCall(
            address(liquidRouter),
            abi.encodeWithSignature("settleBuyLiquid(uint256)", 0)
        );
        
        (,, uint256[] memory amountsAfter, uint8 statusAfter) = listingTemplate.getBuyOrder(l3_orderId);
        
        assert(amountsAfter[0] == 0); // Pending = 0
        assert(statusAfter == 3); // Filled
        
        emit TestPassed("l2_3CompleteLiquidSettle");
    }

    // ============ PATH L3: PRICE IMPACT REJECTION ============

    function l3_1DepositHeavyLiquidity() public {
        // Heavy deposits to allow large order creation
        uint256 deposit18 = 8000 * 1e18;
        uint256 deposit6 = 8000 * 1e6;
        
        token18.mint(address(this), deposit18);
        token18.approve(address(liquidityRouter), deposit18);
        liquidityRouter.depositToken(address(liquidityTemplate), address(token18), address(this), deposit18);
        
        token6.mint(address(this), deposit6);
        token6.approve(address(liquidityRouter), deposit6);
        liquidityRouter.depositToken(address(liquidityTemplate), address(token6), address(this), deposit6);
        
        emit TestPassed("l3_1DepositHeavyLiquidity");
    }

    function l3_2CreateHighImpactOrder() public {
        _approveToken6Tester(TOKEN6_AMOUNT * 10);
        token6.mint(address(tester), 5000 * 1e6);
        
        uint256 currentPrice = _getPoolPrice(address(token6), address(token18));
        uint256 minPrice = (currentPrice * 90) / 100;
        uint256 maxPrice = (currentPrice * 110) / 100;
        
        uint256 orderIdBefore = listingTemplate.getNextOrderId();
        
        // Create massive order that will cause >10% price impact
        tester.proxyCall(
            address(orderRouter),
            abi.encodeWithSignature(
                "createBuyOrder(address,address,address,uint256,uint256,uint256)",
                address(token6),
                address(token18),
                address(tester),
                3000 * 1e6, // Massive amount
                maxPrice,
                minPrice
            )
        );
        
        uint256 impactOrderId = orderIdBefore;
        
        // Try to settle - should fail due to impact
        tester.proxyCall(
            address(liquidRouter),
            abi.encodeWithSignature("settleBuyLiquid(uint256)", 0)
        );
        
        (,,, uint8 status) = listingTemplate.getBuyOrder(impactOrderId);
        assert(status == 1); // Should remain pending due to impact rejection
        
        emit TestPassed("l3_2CreateHighImpactOrder");
    }
}