// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

// File Version: 0.0.8 (03/12/2025)
// - (03/12): Added token6 deposit before compensation test. 
// Streamlined version with external MockDeployer to reduce init code size
// LiquidTests calls create functions on MockDeployer which returns addresses

interface ICCLiquidRouter {
    function setListingAddress(address _listingAddress) external;
    function settleBuyLiquid(uint256 step) external;
    function setLiquidityAddress(address _liquidityAddress) external;
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
    function routerAddressesView() external view returns (address[] memory);
}

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
    function transfer(address, uint256) external returns (bool);
}

interface IMockDeployer {
    function setLiquidTests(address _liquidTests) external;
    function createMocks() external returns (address token18, address token6);
    function createUniMocks() external returns (address weth, address factory, address router, address pair);
    function createTester() external payable returns (address tester);
    function mintToken18(address to, uint256 amount) external;
    function mintToken6(address to, uint256 amount) external;
}

interface IMockTester {
    function proxyCall(address target, bytes memory data) external payable returns (bytes memory);
}

contract LiquidTests {
    ICCOrderRouter public orderRouter;
    ICCSettlementRouter public settlementRouter;
    ICCLiquidRouter public liquidRouter;
    ICCLiquidityRouter public liquidityRouter;
    ICCListingTemplate public listingTemplate;
    ICCLiquidityTemplate public liquidityTemplate;
    
    IMockDeployer public mockDeployer;
    
    // Mock addresses (retrieved from deployer)
    address public token18;
    address public token6;
    address public weth;
    address public uniFactory;
    address public uniRouter;
    address public pairToken18Token6;
    address public tester;
    
    address public owner;

    // Slot tracking
    uint256 public mainSlot;
    uint256 public orderId;
    
    event TestPassed(string testName);
    event DebugLog(string label, uint256 value);

    constructor() {
        owner = msg.sender;
    }

    receive() external payable {}

    function setMockDeployer(address _mockDeployer) external {
        require(msg.sender == owner, "Not owner");
        require(_mockDeployer != address(0), "Invalid address");
        mockDeployer = IMockDeployer(_mockDeployer);
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

    function setLiquidityAddress(address _liquidity) external {
        require(msg.sender == owner, "Not owner");
        liquidityTemplate = ICCLiquidityTemplate(_liquidity);
    }

    function deployMocks() external {
        require(msg.sender == owner, "Not owner");
        require(address(mockDeployer) != address(0), "MockDeployer not set");
        require(token18 == address(0), "Already deployed");
        
        (address _token18, address _token6) = mockDeployer.createMocks();
        token18 = _token18;
        token6 = _token6;
    }

    function deployUniMocks() external {
        require(msg.sender == owner, "Not owner");
        require(address(mockDeployer) != address(0), "MockDeployer not set");
        require(weth == address(0), "Already deployed");
        require(token18 != address(0), "Deploy mocks first");
        
        (address _weth, address _factory, address _router, address _pair) = mockDeployer.createUniMocks();
        weth = _weth;
        uniFactory = _factory;
        uniRouter = _router;
        pairToken18Token6 = _pair;
    }

    function initiateTester() external payable {
        require(msg.sender == owner, "Not owner");
        require(address(mockDeployer) != address(0), "MockDeployer not set");
        require(msg.value >= 2 ether, "Send 2 ETH");
        require(tester == address(0), "Already deployed");
        
        address _tester = mockDeployer.createTester{value: 2 ether}();
        tester = _tester;
    }

    function initializeContracts() external {
        require(msg.sender == owner, "Not owner");
        require(uniFactory != address(0), "Deploy uni mocks first");

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
        if (!settlementRouterAdded) listingTemplate.addRouter(address(settlementRouter));
        if (!liquidRouterAdded) listingTemplate.addRouter(address(liquidRouter));

        // Add routers to liquidity template
        address[] memory liquidityRouters = liquidityTemplate.routerAddressesView();
        bool liquidRouterInLiquidity = false;
        bool liquidityRouterInLiquidity = false;
        
        for (uint i = 0; i < liquidityRouters.length; i++) {
            if (liquidityRouters[i] == address(liquidRouter)) liquidRouterInLiquidity = true;
            if (liquidityRouters[i] == address(liquidityRouter)) liquidityRouterInLiquidity = true;
        }
        
        if (!liquidRouterInLiquidity) liquidityTemplate.addRouter(address(liquidRouter));
        if (!liquidityRouterInLiquidity) liquidityTemplate.addRouter(address(liquidityRouter));

        // Configure routers
        (bool success, bytes memory data) = address(orderRouter).staticcall(abi.encodeWithSignature("listingTemplate()"));
        if (success && abi.decode(data, (address)) == address(0)) {
            orderRouter.setListingTemplate(address(listingTemplate));
        }

        (success, data) = address(orderRouter).staticcall(abi.encodeWithSignature("wethAddress()"));
        if (success && abi.decode(data, (address)) == address(0)) {
            orderRouter.setWETH(weth);
        }

        (success, data) = address(settlementRouter).staticcall(abi.encodeWithSignature("listingTemplate()"));
        if (success && abi.decode(data, (address)) == address(0)) {
            settlementRouter.setListingTemplate(address(listingTemplate));
        }

        (success, data) = address(liquidRouter).staticcall(abi.encodeWithSignature("listingAddressView()"));
        if (success && abi.decode(data, (address)) == address(0)) {
            liquidRouter.setListingAddress(address(listingTemplate));
        }
        
        (success, data) = address(liquidRouter).staticcall(abi.encodeWithSignature("liquidityAddressView()"));
        if (success && abi.decode(data, (address)) == address(0)) {
            liquidRouter.setLiquidityAddress(address(liquidityTemplate));
        }

        if (listingTemplate.uniswapV2Factory() == address(0)) {
            listingTemplate.setUniswapV2Factory(uniFactory);
        }

        if (listingTemplate.uniswapV2Router() == address(0)) {
            listingTemplate.setUniswapV2Router(uniRouter);
        }
    }

    // ============ STREAMLINED TEST FLOW ============

    // Test 1: Initial deposit
    function test1_InitialDeposit() public {
        uint256 depositAmount = 1000 * 1e18;
        mockDeployer.mintToken18(address(this), depositAmount);
        IERC20Min(token18).approve(address(liquidityRouter), depositAmount);
        
        liquidityRouter.depositToken(
            address(liquidityTemplate),
            token18,
            address(this),
            depositAmount
        );
        
        uint256[] memory slots = liquidityTemplate.userSlotIndicesView(token18, address(this));
        mainSlot = slots[slots.length - 1];
        
        (,address depositor,,uint256 allocation,,) = liquidityTemplate.getSlotView(token18, mainSlot);
        
        assert(depositor == address(this));
        assert(allocation > 0);
        
        emit TestPassed("test1_InitialDeposit");
    }

    // Test 2: Partial withdrawal
    function test2_PartialWithdrawal() public {
        (,,,uint256 allocationBefore,,) = liquidityTemplate.getSlotView(token18, mainSlot);
        uint256 withdrawAmount = allocationBefore / 3; // Withdraw 33%
        
        liquidityRouter.withdraw(
            address(liquidityTemplate),
            address(listingTemplate),
            token18,
            address(0),
            withdrawAmount,
            0,
            mainSlot
        );
        
        (,,,uint256 allocationAfter,,) = liquidityTemplate.getSlotView(token18, mainSlot);
        
        assert(allocationAfter == allocationBefore - withdrawAmount);
        
        emit TestPassed("test2_PartialWithdrawal");
    }

    // Test 3: Partial withdrawal with compensation
    function test3_WithdrawalWithCompensation() public {
        // Deposit token6 for compensation - need enough for withdrawal
        uint256 deposit6 = 2000 * 1e6; // Increased to ensure sufficient liquidity
        mockDeployer.mintToken6(address(this), deposit6);
        IERC20Min(token6).approve(address(liquidityRouter), deposit6);
        liquidityRouter.depositToken(address(liquidityTemplate), token6, address(this), deposit6);
        
        (,,,uint256 allocation18,,) = liquidityTemplate.getSlotView(token18, mainSlot);
        
        // Check available liquidity in both tokens
        uint256 liquid18 = liquidityTemplate.liquidityAmounts(token18);
        uint256 liquid6 = liquidityTemplate.liquidityAmounts(token6);
        
        emit DebugLog("allocation18", allocation18);
        emit DebugLog("liquid18", liquid18);
        emit DebugLog("liquid6", liquid6);
        
        // Calculate safe compensation amount
        uint256 price = listingTemplate.prices(token18, token6);
        uint256 primaryAmount = allocation18 / 5; // Withdraw 20% in token18 (reduced from 25%)
        
        // Compensation: equivalent to 5% of allocation in token6 (reduced from 10%)
        uint256 compensationAmount = (allocation18 / 20 * price) / 1e18;
        
        // Ensure we don't over-withdraw from either token
        uint256 compensationInPrimary = (compensationAmount * 1e18) / price;
        require(primaryAmount + compensationInPrimary <= allocation18, "Over-withdrawal from allocation");
        require(primaryAmount <= liquid18, "Insufficient token18 liquidity");
        require(compensationAmount <= liquid6, "Insufficient token6 liquidity");
        
        emit DebugLog("primaryAmount", primaryAmount);
        emit DebugLog("compensationAmount", compensationAmount);
        emit DebugLog("compensationInPrimary", compensationInPrimary);
        
        uint256 token6BalBefore = IERC20Min(token6).balanceOf(address(this));
        
        liquidityRouter.withdraw(
            address(liquidityTemplate),
            address(listingTemplate),
            token18,
            token6,
            primaryAmount,
            compensationAmount,
            mainSlot
        );
        
        uint256 token6BalAfter = IERC20Min(token6).balanceOf(address(this));
        assert(token6BalAfter > token6BalBefore);
        
        emit TestPassed("test3_WithdrawalWithCompensation");
    }

    // Test 4: Full withdrawal of remaining allocation
    function test4_FullWithdrawal() public {
        (,,,uint256 allocation,,) = liquidityTemplate.getSlotView(token18, mainSlot);
        
        liquidityRouter.withdraw(
            address(liquidityTemplate),
            address(listingTemplate),
            token18,
            address(0),
            allocation,
            0,
            mainSlot
        );
        
        (,,,uint256 allocationAfter,,) = liquidityTemplate.getSlotView(token18, mainSlot);
        assert(allocationAfter == 0);
        
        emit TestPassed("test4_FullWithdrawal");
    }

    // Test 5: Deposit for liquid settlement
    function test5_DepositForSettlement() public {
        uint256 deposit18 = 2000 * 1e18;
        uint256 deposit6 = 2000 * 1e6;
        
        mockDeployer.mintToken18(address(this), deposit18);
        IERC20Min(token18).approve(address(liquidityRouter), deposit18);
        liquidityRouter.depositToken(address(liquidityTemplate), token18, address(this), deposit18);
        
        mockDeployer.mintToken6(address(this), deposit6);
        IERC20Min(token6).approve(address(liquidityRouter), deposit6);
        liquidityRouter.depositToken(address(liquidityTemplate), token6, address(this), deposit6);
        
        emit TestPassed("test5_DepositForSettlement");
    }

    // Test 6: Create order and partial settlement via settlement router
    function test6_CreateAndPartialSettle() public {
        // Approve tester's token6
        IMockTester(tester).proxyCall(
            token6,
            abi.encodeWithSignature("approve(address,uint256)", address(orderRouter), 1000 * 1e6)
        );
        
        uint256 orderIdBefore = listingTemplate.getNextOrderId();
        
        // Create buy order
        IMockTester(tester).proxyCall(
            address(orderRouter),
            abi.encodeWithSignature(
                "createBuyOrder(address,address,address,uint256,uint256,uint256)",
                token6,
                token18,
                tester,
                100 * 1e6,
                10e18,
                1e16
            )
        );
        orderId = orderIdBefore;
        
        // Partial settle via settlement router (50%)
        (,, uint256[] memory amountsBefore,) = listingTemplate.getBuyOrder(orderId);
        
        IERC20Min(token18).approve(address(settlementRouter), type(uint256).max);
        
        uint256[] memory orderIds = new uint256[](1);
        orderIds[0] = orderId;
        
        uint256[] memory amountsIn = new uint256[](1);
        amountsIn[0] = amountsBefore[0] / 2;
        
        settlementRouter.settleOrders(address(listingTemplate), orderIds, amountsIn, true);
        
        (,, uint256[] memory amountsAfter, uint8 status) = listingTemplate.getBuyOrder(orderId);
        
        assert(status == 2); // Partial
        assert(amountsAfter[0] > 0); // Still has pending
        
        emit TestPassed("test6_CreateAndPartialSettle");
    }

    // Test 7: Complete settlement via liquid router
    function test7_LiquidSettlement() public {
        (uint256 feesBefore,,) = liquidityTemplate.liquidityDetailsView(token6);
        
        IMockTester(tester).proxyCall(
            address(liquidRouter),
            abi.encodeWithSignature("settleBuyLiquid(uint256)", 0)
        );
        
        (,, uint256[] memory amountsAfter, uint8 statusAfter) = listingTemplate.getBuyOrder(orderId);
        (uint256 feesAfter,,) = liquidityTemplate.liquidityDetailsView(token6);
        
        assert(amountsAfter[0] == 0); // Pending = 0
        assert(statusAfter == 3); // Filled
        assert(feesAfter > feesBefore); // Fees generated
        
        emit TestPassed("test7_LiquidSettlement");
    }

    // Test 8: Collect fees
    function test8_CollectFees() public {
        uint256[] memory slots6 = liquidityTemplate.userSlotIndicesView(token6, address(this));
        uint256 claimSlot = slots6[slots6.length - 1];
        
        uint256 balBefore = IERC20Min(token6).balanceOf(address(this));
        (uint256 feesBefore,,) = liquidityTemplate.liquidityDetailsView(token6);
        
        liquidityRouter.claimFees(
            address(liquidityTemplate),
            token6,
            claimSlot
        );
        
        uint256 balAfter = IERC20Min(token6).balanceOf(address(this));
        (uint256 feesAfter,,) = liquidityTemplate.liquidityDetailsView(token6);
        
        assert(balAfter > balBefore); // Received fees
        assert(feesAfter < feesBefore); // Fees decreased
        
        emit TestPassed("test8_CollectFees");
    }

    // Test 9: Transfer ownership before final withdrawal
    function test9_TransferOwnership() public {
        uint256[] memory slots6 = liquidityTemplate.userSlotIndicesView(token6, address(this));
        uint256 transferSlot = slots6[slots6.length - 1];
        
        (,address depositorBefore,,,, ) = liquidityTemplate.getSlotView(token6, transferSlot);
        assert(depositorBefore == address(this));
        
        liquidityRouter.changeDepositor(
            address(liquidityTemplate),
            token6,
            transferSlot,
            tester
        );
        
        (,address depositorAfter,,,, ) = liquidityTemplate.getSlotView(token6, transferSlot);
        assert(depositorAfter == tester);
        
        emit TestPassed("test9_TransferOwnership");
    }

    // Test 10: Final withdrawal by new owner (tester)
    function test10_FinalWithdrawalByNewOwner() public {
        uint256[] memory slots6 = liquidityTemplate.userSlotIndicesView(token6, tester);
        uint256 withdrawSlot = slots6[slots6.length - 1];
        
        (,,,uint256 allocation,,) = liquidityTemplate.getSlotView(token6, withdrawSlot);
        
        if (allocation > 0) {
            uint256 testerBalBefore = IERC20Min(token6).balanceOf(tester);
            
            IMockTester(tester).proxyCall(
                address(liquidityRouter),
                abi.encodeWithSignature(
                    "withdraw(address,address,address,address,uint256,uint256,uint256)",
                    address(liquidityTemplate),
                    address(listingTemplate),
                    token6,
                    address(0),
                    allocation,
                    0,
                    withdrawSlot
                )
            );
            
            (,,,uint256 allocationAfter,,) = liquidityTemplate.getSlotView(token6, withdrawSlot);
            uint256 testerBalAfter = IERC20Min(token6).balanceOf(tester);
            
            assert(allocationAfter == 0);
            assert(testerBalAfter > testerBalBefore);
        }
        
        emit TestPassed("test10_FinalWithdrawalByNewOwner");
    }

    // ============ PATH L3: PRICE IMPACT REJECTION ============

    // Test 11: Deposit heavy liquidity for impact test
    function test11_DepositHeavyLiquidity() public {
        uint256 deposit18 = 8000 * 1e18;
        uint256 deposit6 = 8000 * 1e6;
        
        mockDeployer.mintToken18(address(this), deposit18);
        IERC20Min(token18).approve(address(liquidityRouter), deposit18);
        liquidityRouter.depositToken(address(liquidityTemplate), token18, address(this), deposit18);
        
        mockDeployer.mintToken6(address(this), deposit6);
        IERC20Min(token6).approve(address(liquidityRouter), deposit6);
        liquidityRouter.depositToken(address(liquidityTemplate), token6, address(this), deposit6);
        
        emit TestPassed("test11_DepositHeavyLiquidity");
    }

    // Test 12: Create high impact order that should be rejected
    function test12_CreateHighImpactOrder() public {
        // Mint large amount for tester
        mockDeployer.mintToken6(tester, 5000 * 1e6);
        
        IMockTester(tester).proxyCall(
            token6,
            abi.encodeWithSignature("approve(address,uint256)", address(orderRouter), 5000 * 1e6)
        );
        
        uint256 currentPrice = listingTemplate.prices(token6, token18);
        uint256 minPrice = (currentPrice * 90) / 100;
        uint256 maxPrice = (currentPrice * 110) / 100;
        
        uint256 orderIdBefore = listingTemplate.getNextOrderId();
        
        // Create massive order that will cause >10% price impact
        IMockTester(tester).proxyCall(
            address(orderRouter),
            abi.encodeWithSignature(
                "createBuyOrder(address,address,address,uint256,uint256,uint256)",
                token6,
                token18,
                tester,
                3000 * 1e6, // Massive amount
                maxPrice,
                minPrice
            )
        );
        
        uint256 impactOrderId = orderIdBefore;
        
        // Try to settle - should fail due to impact
        IMockTester(tester).proxyCall(
            address(liquidRouter),
            abi.encodeWithSignature("settleBuyLiquid(uint256)", 0)
        );
        
        (,,, uint8 status) = listingTemplate.getBuyOrder(impactOrderId);
        assert(status == 1); // Should remain pending due to impact rejection
        
        emit TestPassed("test12_CreateHighImpactOrder");
    }
}
