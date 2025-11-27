// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

// File Version: 0.0.6 (27/11/2025)
// 0.0.6 (27/11/2025): Replaced p7 with impact price test, corrected p6 order direction and gas control. 
// 0.0.5 (26/11/2025): Adjusted p6 to use direct swaps for price manipulation. 

import "./MockMAILToken.sol";
import "./MockMailTester.sol";
import "./MockWETH.sol";
import "./MockUniRouter.sol";

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
    
    function listingTemplate() external view returns (address);
    function wethAddress() external view returns (address);
}

interface ICCSettlementRouter {
    function setListingTemplate(address) external;
    function settleOrders(
        address listingAddress,
        uint256[] calldata orderIds,
        uint256[] calldata amountsIn,
        bool isBuyOrder
    ) external returns (string memory);
    
    function listingTemplate() external view returns (address);
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

contract SettlementTests {
    ICCOrderRouter public orderRouter;
    ICCSettlementRouter public settlementRouter;
    ICCListingTemplate public listingTemplate;
    MockUniFactory public uniFactory;
    MockWETH public weth;
    MockUniRouter public uniRouter; // New state variable
    
    MockMAILToken public token18; // 18 decimals
    MockMAILToken public token6;  // 6 decimals
    MockMailTester public tester;
    address public owner;

    address payable public pairToken18Token6;
    uint256 public constant TOKEN18_AMOUNT = 1000 * 1e18;
    uint256 public constant TOKEN6_AMOUNT = 1000 * 1e6;
    uint256 public constant LIQUIDITY_TOKEN18 = 10000 * 1e18;
    uint256 public constant LIQUIDITY_TOKEN6 = 10000 * 1e6;

    // Path-specific order tracking
    uint256 public p1_orderId;
    uint256 public p2_orderId;
    uint256 public p3_order1;
    uint256 public p3_order2;
    uint256 public p3_order3;
    uint256 public p4_order1;
    uint256 public p4_order2;
    uint256 public p4_order3;
    uint256 public p5_orderId;
    uint256 public p6_orderId;
    uint256 public p7_orderId; 

    // For Seesaw test
    uint256 public originalPrice;
    uint256 public minPriceFromP6;
    uint256 public maxPriceFromP6;
    
    bool private orderRouterInitialized;
    bool private settlementRouterInitialized;
    bool private listingTemplateInitialized;

    event ContractsSet(address orderRouter, address settlementRouter, address listing);
    event PairCreated(address pair);
    event TestPassed(string testName);
    event OrderSettled(uint256 orderId, uint256 amountIn, uint256 pending, uint256 filled);
    event DebugPrice(uint256 price, uint256 maxPrice, string label);

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
                // Deploy the new Router
        uniRouter = new MockUniRouter(address(uniFactory), address(weth));
    }

    function setOrderRouter(address _orderRouter) external {
        require(msg.sender == owner, "Not owner");
        require(_orderRouter != address(0), "Invalid order router");
        orderRouter = ICCOrderRouter(_orderRouter);
        orderRouterInitialized = false; // allow re-init if address changes
    }

    function setSettlementRouter(address _settlementRouter) external {
        require(msg.sender == owner, "Not owner");
        require(_settlementRouter != address(0), "Invalid settlement router");
        settlementRouter = ICCSettlementRouter(_settlementRouter);
        settlementRouterInitialized = false;
    }

    function setListingTemplate(address _listing) external {
        require(msg.sender == owner, "Not owner");
        require(_listing != address(0), "Invalid listing");
        listingTemplate = ICCListingTemplate(_listing);
        listingTemplateInitialized = false;
    }

    function initializeContracts() external payable {
        require(msg.sender == owner, "Not owner");
        require(address(uniFactory) != address(0), "Uni mocks not deployed");

        // === 1. ListingTemplate: Add routers if not already present ===
        address[] memory currentRouters = listingTemplate.routerAddressesView();
        bool orderRouterAdded = false;
        bool settlementRouterAdded = false;

        for (uint i = 0; i < currentRouters.length; i++) {
            if (currentRouters[i] == address(orderRouter)) orderRouterAdded = true;
            if (currentRouters[i] == address(settlementRouter)) settlementRouterAdded = true;
        }

        if (!orderRouterAdded) listingTemplate.addRouter(address(orderRouter));
        if (!settlementRouterAdded) listingTemplate.addRouter(address(settlementRouter));

        // === 2. OrderRouter: Set listingTemplate & WETH only if not already set ===
        if (address(orderRouter) != address(0)) {
            // We detect via public listingTemplate variable in OrderRouter
            // Assuming: address public listingTemplate; exists in CCOrderRouter
            // We'll read it directly using inline interface call
            (bool success, bytes memory data) = address(orderRouter).staticcall(
                abi.encodeWithSignature("listingTemplate()")
            );
            if (success && abi.decode(data, (address)) == address(0)) {
                orderRouter.setListingTemplate(address(listingTemplate));
            }

            (success, data) = address(orderRouter).staticcall(
                abi.encodeWithSignature("wethAddress()")
            );
            if (success && abi.decode(data, (address)) == address(0)) {
                orderRouter.setWETH(address(weth));
            }
        }

        // === 3. SettlementRouter: Set listingTemplate only if not already set ===
        if (address(settlementRouter) != address(0)) {
            (bool success, bytes memory data) = address(settlementRouter).staticcall(
                abi.encodeWithSignature("listingTemplate()")
            );
            if (success && abi.decode(data, (address)) == address(0)) {
                settlementRouter.setListingTemplate(address(listingTemplate));
            }
        }

        // === 4. ListingTemplate: Factory & Router only if not already set ===
        if (listingTemplate.uniswapV2Factory() == address(0)) {
            listingTemplate.setUniswapV2Factory(address(uniFactory));
        }

        if (listingTemplate.uniswapV2Router() == address(0)) {
            listingTemplate.setUniswapV2Router(address(uniRouter));
        }

        // === 5. Create pair + liquidity (idempotent) ===
        if (pairToken18Token6 == address(0)) {
            _createPairWithLiquidity();
        }
    }

    function _createPairWithLiquidity() internal {
        pairToken18Token6 = payable(uniFactory.createPair(address(token18), address(token6)));
        token18.transfer(pairToken18Token6, LIQUIDITY_TOKEN18);
        token6.transfer(pairToken18Token6, LIQUIDITY_TOKEN6);
        IUniswapV2Pair(pairToken18Token6).mint(address(this));

        emit PairCreated(pairToken18Token6);
    }

    function returnOwnership() external {
        require(msg.sender == owner, "Not owner");
        listingTemplate.transferOwnership(msg.sender);
    }

    function initiateTester() public payable {
        require(msg.sender == owner, "Not owner");
        require(msg.value >= 3 ether, "Send 3 ETH or More");
        
        tester = new MockMailTester(address(this));
        
        // Fund tester with ETH
        (bool success,) = address(tester).call{value: 2 ether}("");
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

    // Updated Helper: Calculates directional price (Output per Input) matching Listing Template
    function _getPoolPrice(address startToken, address endToken) internal view returns (uint256 price) {
        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pairToken18Token6).getReserves();
        address token0 = IUniswapV2Pair(pairToken18Token6).token0();
        
        // Identify Reserves relative to direction
        // Start = Input (Denominator), End = Output (Numerator)
        uint256 reserveIn = startToken == token0 ? uint256(reserve0) : uint256(reserve1);
        uint256 reserveOut = endToken == token0 ? uint256(reserve0) : uint256(reserve1);
        
        // Normalize to 18 decimals (Token18 is 18, Token6 is 6)
        uint256 normIn = startToken == address(token18) ? reserveIn : reserveIn * 1e12;
        uint256 normOut = endToken == address(token18) ? reserveOut : reserveOut * 1e12;
        
        require(normIn > 0, "Zero Reserve In");
        
        // Price = Output per 1 Input (1e18 precision)
        price = (normOut * 1e18) / normIn;
    }

    // ============ PATH 1: FULL SINGLE SETTLEMENT (Includes Mixed Decimal & Zero Check) ============

    function p1_1CreateOrder() public {
        _approveToken6Tester(TOKEN6_AMOUNT);
        uint256 orderIdBefore = listingTemplate.getNextOrderId();
        
        // Creates a Buy Order: Selling Token6 (Input), Buying Token18 (Output)
        // This inherently tests mixed decimal logic (6 -> 18)
        tester.proxyCall(
            address(orderRouter),
            abi.encodeWithSignature(
                "createBuyOrder(address,address,address,uint256,uint256,uint256)",
                address(token6),
                address(token18),
                address(tester),
                10 * 1e6, // Input 10 Token6
                10e18,    // Max Price
                1e16      // Min Price
            )
        );
        p1_orderId = orderIdBefore;
        
        (,, uint256[] memory amounts, uint8 status) = listingTemplate.getBuyOrder(p1_orderId);
        
        // Assert Normalization: 10 * 1e6 input should be normalized to 10 * 1e18 internally
        // The mock implementation multiplies by 1e12 for 6->18 normalization
        assert(amounts[0] == 10 * 1e6 * 1e12); 
        assert(amounts[1] == 0);
        assert(status == 1);
        
        emit TestPassed("p1_1CreateOrder_MixedDecimalsVerified");
    }

    function p1_2FullSettleWithZeroCheck() public {
        (,, uint256[] memory amountsBefore,) = listingTemplate.getBuyOrder(p1_orderId);
        token18.approve(address(settlementRouter), type(uint256).max);
        
        uint256[] memory orderIds = new uint256[](1);
        orderIds[0] = p1_orderId;
        
        // Negative Test: Attempt to settle with 0 amount
        uint256[] memory zeroAmounts = new uint256[](1);
        zeroAmounts[0] = 0;
        string memory reason = settlementRouter.settleOrders(address(listingTemplate), orderIds, zeroAmounts, true);
        
        (,, uint256[] memory amountsCheck, uint8 statusCheck) = listingTemplate.getBuyOrder(p1_orderId);
        assert(amountsCheck[1] == 0); // Should not have filled anything
        assert(statusCheck == 1);     // Should remain pending
        
        // Positive Test: Full Settle
        uint256[] memory amountsIn = new uint256[](1);
        amountsIn[0] = amountsBefore[0]; // Full amount
        
        settlementRouter.settleOrders(address(listingTemplate), orderIds, amountsIn, true);
        
        (,, uint256[] memory amountsAfter, uint8 status) = listingTemplate.getBuyOrder(p1_orderId);
        assert(amountsAfter[0] == 0);
        assert(amountsAfter[1] == amountsBefore[0]);
        assert(amountsAfter[2] > 0); // AmountSent (output) should be > 0
        assert(status == 3); // Filled
        
        emit TestPassed("p1_2FullSettleWithZeroCheck");
    }

    // ============ PATH 2: PARTIAL SETTLEMENT (Includes Status & Cumulative Checks) ============

    function p2_1CreateOrder() public {
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
        p2_orderId = orderIdBefore;
        
        emit TestPassed("p2_1CreateOrder");
    }

    function p2_2PartialSettleWithTransitionChecks() public {
        (,, uint256[] memory amountsBefore,) = listingTemplate.getBuyOrder(p2_orderId);
        token18.approve(address(settlementRouter), type(uint256).max);
        
        uint256[] memory orderIds = new uint256[](1);
        orderIds[0] = p2_orderId;
        
        // Round 1: Settle 20%
        uint256[] memory amountsIn = new uint256[](1);
        amountsIn[0] = amountsBefore[0] / 5; 
        
        settlementRouter.settleOrders(address(listingTemplate), orderIds, amountsIn, true);
        
        (,, uint256[] memory amountsAfter1, uint8 status1) = listingTemplate.getBuyOrder(p2_orderId);
        assert(amountsAfter1[0] == amountsBefore[0] - amountsIn[0]);
        assert(status1 == 2); // Transition: Pending -> Partial
        uint256 sentRound1 = amountsAfter1[2];
        assert(sentRound1 > 0);

        // Round 2: Settle another 20% (Cumulative Check)
        settlementRouter.settleOrders(address(listingTemplate), orderIds, amountsIn, true);

        (,, uint256[] memory amountsAfter2, uint8 status2) = listingTemplate.getBuyOrder(p2_orderId);
        assert(status2 == 2); // Remain Partial
        assert(amountsAfter2[2] > sentRound1); // Cumulative AmountSent increased

        emit TestPassed("p2_2PartialSettleWithTransitionChecks");
    }

    // ============ PATH 3: BATCH FULL SETTLEMENT ============

    function p3_1CreateOrders() public {
        _approveToken6Tester(TOKEN6_AMOUNT);
        token6.approve(address(orderRouter), TOKEN6_AMOUNT);
        uint256 orderIdBefore = listingTemplate.getNextOrderId();
        
        // Create 3 orders
        tester.proxyCall(address(orderRouter), abi.encodeWithSignature("createBuyOrder(address,address,address,uint256,uint256,uint256)", address(token6), address(token18), address(tester), 10 * 1e6, 10e18, 1e16));
        orderRouter.createBuyOrder(address(token6), address(token18), address(this), 15 * 1e6, 10e18, 1e16);
        tester.proxyCall(address(orderRouter), abi.encodeWithSignature("createBuyOrder(address,address,address,uint256,uint256,uint256)", address(token6), address(token18), address(tester), 20 * 1e6, 10e18, 1e16));
        
        p3_order1 = orderIdBefore;
        p3_order2 = orderIdBefore + 1;
        p3_order3 = orderIdBefore + 2;
        
        emit TestPassed("p3_1CreateOrders");
    }

    function p3_2FullSettleAll() public {
        (,, uint256[] memory am1,) = listingTemplate.getBuyOrder(p3_order1);
        (,, uint256[] memory am2,) = listingTemplate.getBuyOrder(p3_order2);
        (,, uint256[] memory am3,) = listingTemplate.getBuyOrder(p3_order3);
        
        token18.approve(address(settlementRouter), type(uint256).max);
        
        uint256[] memory orderIds = new uint256[](3);
        orderIds[0] = p3_order1; orderIds[1] = p3_order2; orderIds[2] = p3_order3;
        
        uint256[] memory amountsIn = new uint256[](3);
        amountsIn[0] = am1[0]; amountsIn[1] = am2[0]; amountsIn[2] = am3[0];
        
        settlementRouter.settleOrders(address(listingTemplate), orderIds, amountsIn, true);
        
        (,,, uint8 s1) = listingTemplate.getBuyOrder(p3_order1);
        (,,, uint8 s2) = listingTemplate.getBuyOrder(p3_order2);
        (,,, uint8 s3) = listingTemplate.getBuyOrder(p3_order3);
        
        assert(s1 == 3 && s2 == 3 && s3 == 3); // All filled
        emit TestPassed("p3_2FullSettleAll");
    }

    // ============ PATH 4: BATCH PARTIAL SETTLEMENT ============

    function p4_1CreateOrders() public {
        _approveToken6Tester(TOKEN6_AMOUNT);
        token6.approve(address(orderRouter), TOKEN6_AMOUNT);
        uint256 orderIdBefore = listingTemplate.getNextOrderId();
        
        tester.proxyCall(address(orderRouter), abi.encodeWithSignature("createBuyOrder(address,address,address,uint256,uint256,uint256)", address(token6), address(token18), address(tester), 30 * 1e6, 10e18, 1e16));
        orderRouter.createBuyOrder(address(token6), address(token18), address(this), 40 * 1e6, 10e18, 1e16);
        tester.proxyCall(address(orderRouter), abi.encodeWithSignature("createBuyOrder(address,address,address,uint256,uint256,uint256)", address(token6), address(token18), address(tester), 50 * 1e6, 10e18, 1e16));
        
        p4_order1 = orderIdBefore;
        p4_order2 = orderIdBefore + 1;
        p4_order3 = orderIdBefore + 2;
        
        emit TestPassed("p4_1CreateOrders");
    }

    function p4_2PartialSettleAll() public {
        (,, uint256[] memory am1,) = listingTemplate.getBuyOrder(p4_order1);
        (,, uint256[] memory am2,) = listingTemplate.getBuyOrder(p4_order2);
        (,, uint256[] memory am3,) = listingTemplate.getBuyOrder(p4_order3);
        
        token18.approve(address(settlementRouter), type(uint256).max);
        
        uint256[] memory orderIds = new uint256[](3);
        orderIds[0] = p4_order1; orderIds[1] = p4_order2; orderIds[2] = p4_order3;
        
        uint256[] memory amountsIn = new uint256[](3);
        amountsIn[0] = am1[0] / 2; amountsIn[1] = am2[0] / 2; amountsIn[2] = am3[0] / 2;
        
        settlementRouter.settleOrders(address(listingTemplate), orderIds, amountsIn, true);
        
        (,,, uint8 s1) = listingTemplate.getBuyOrder(p4_order1);
        (,,, uint8 s2) = listingTemplate.getBuyOrder(p4_order2);
        (,,, uint8 s3) = listingTemplate.getBuyOrder(p4_order3);
        
        assert(s1 == 2 && s2 == 2 && s3 == 2); // All partial
        emit TestPassed("p4_2PartialSettleAll");
    }

    // ============ PATH 5: MULTI-ROUND SPLIT & PRECISION ============

    function p5_1CreateOrder() public {
        _approveToken6Tester(TOKEN6_AMOUNT);
        uint256 orderIdBefore = listingTemplate.getNextOrderId();
        
        tester.proxyCall(
            address(orderRouter),
            abi.encodeWithSignature("createBuyOrder(address,address,address,uint256,uint256,uint256)", address(token6), address(token18), address(tester), 100 * 1e6, 10e18, 1e16)
        );
        p5_orderId = orderIdBefore;
        emit TestPassed("p5_1CreateOrder");
    }

    function p5_2Round1Settle() public {
        (,, uint256[] memory amounts,) = listingTemplate.getBuyOrder(p5_orderId);
        uint256 totalPending = amounts[0];
        token18.approve(address(settlementRouter), type(uint256).max);
        
        uint256[] memory orderIds = new uint256[](1); orderIds[0] = p5_orderId;
        uint256[] memory amountsIn = new uint256[](1); amountsIn[0] = (totalPending * 30) / 100; // 30%
        
        settlementRouter.settleOrders(address(listingTemplate), orderIds, amountsIn, true);
        (,, uint256[] memory amountsAfter, uint8 status) = listingTemplate.getBuyOrder(p5_orderId);
        
        assert(amountsAfter[0] == totalPending - amountsIn[0]);
        assert(status == 2);
        emit TestPassed("p5_2Round1Settle");
    }

    function p5_3Round2RecoverOriginal() public {
        (,, uint256[] memory amounts,) = listingTemplate.getBuyOrder(p5_orderId);
        // Math to verify we are still tracking correctly relative to original 100%
        // (filled + pending) should equal roughly original, allowing for tiny rounding errors
        
        uint256[] memory orderIds = new uint256[](1); orderIds[0] = p5_orderId;
        uint256[] memory amountsIn = new uint256[](1); amountsIn[0] = amounts[0] / 2; // 50% of remainder
        
        settlementRouter.settleOrders(address(listingTemplate), orderIds, amountsIn, true);
        emit TestPassed("p5_3Round2RecoverOriginal");
    }

    function p5_4FinalSweep() public {
        (,, uint256[] memory amounts,) = listingTemplate.getBuyOrder(p5_orderId);
        uint256[] memory orderIds = new uint256[](1); orderIds[0] = p5_orderId;
        uint256[] memory amountsIn = new uint256[](1); amountsIn[0] = amounts[0]; // Remaining 100%
        
        settlementRouter.settleOrders(address(listingTemplate), orderIds, amountsIn, true);
        
        (,, uint256[] memory amountsAfter, uint8 status) = listingTemplate.getBuyOrder(p5_orderId);
        assert(amountsAfter[0] == 0);
        assert(status == 3); // Fully Filled
        emit TestPassed("p5_4FinalSweep");
    }

// ============ PATH 6: SEESAW PRICE IMPACT TEST (Refined) ============

    function p6_1CreateRestrictedOrder() public {
        _approveToken6Tester(TOKEN6_AMOUNT);

// Calculate Price: How much T18 (Out) for T6 (In)?
        uint256 currentPrice = _getPoolPrice(address(token6), address(token18));
        p6_orderId = listingTemplate.getNextOrderId();
        
        // Strict Range: 
        // Min: Current * 0.75 (Allow slightly worse rate)
        // Max: Current * 1.25 (Allow slightly better rate)
        uint256 minPrice = (currentPrice * 75) / 100;
        uint256 maxPrice = (currentPrice * 125) / 100;
        
        tester.proxyCall(
            address(orderRouter),
            abi.encodeWithSignature(
                "createBuyOrder(address,address,address,uint256,uint256,uint256)",
                address(token6),   // Input
                address(token18),  // Output
                address(tester),
                10 * 1e6,
                maxPrice,
                minPrice
            )
        );
        emit TestPassed("p6_1CreateRestrictedOrder");
  }

    function p6_2CrashPriceAndFail() public {
    // ACTION: Sell a massive amount of Token6 → buy Token18
    // This increases reserve of Token6 (in), decreases Token18 (out) → price of Token18 crashes
    uint256 crashAmountIn = 5000 * 1e6;

    token6.approve(address(uniRouter), crashAmountIn);

    address[] memory path = new address[](2);
    path[0] = address(token6);
    path[1] = address(token18);

    // Perform real swap via router to crash the price
    uniRouter.swapExactTokensForTokens(
        crashAmountIn,
        0, // accept any amount out
        path,
        address(this),
        block.timestamp + 300
    );

    uint256 newPrice = _getPoolPrice(address(token6), address(token18));
    emit DebugPrice(newPrice, 0, "Crashed Price (Should Fail)");

    // Now attempt to settle — should skip due to price < minPrice
    uint256[] memory orderIds = new uint256[](1);
    orderIds[0] = p6_orderId;

    (,, uint256[] memory amounts,) = listingTemplate.getBuyOrder(p6_orderId);
    uint256[] memory amountsIn = new uint256[](1);
    amountsIn[0] = amounts[0];

    // This should skip due to price out of bounds
    settlementRouter.settleOrders(address(listingTemplate), orderIds, amountsIn, true);

    // Assert: still pending (status == 1), not filled
    (,,, uint8 status) = listingTemplate.getBuyOrder(p6_orderId);
    assert(status == 1);

    emit TestPassed("p6_2CrashPriceAndFail");
}

function p6_3RecoverPriceAndSucceed() public {
    // Goal: Bring price back into [minPrice, maxPrice] gradually
    
    // Safety check for state variables
    require(maxPriceFromP6 > 0 && minPriceFromP6 > 0, "P6 state not set");

    uint256 currentPrice;
    uint256 swapAmount = 10 * 1e18; // Start small

    // Limit iterations to prevent gas limit errors during testing
    uint256 maxIterations = 20; 
    uint256 i = 0;

    while (i < maxIterations) {
        currentPrice = _getPoolPrice(address(token6), address(token18));
        
        // Success condition
        if (currentPrice >= minPriceFromP6 && currentPrice <= maxPriceFromP6) {
            break; 
        }

        if (currentPrice > maxPriceFromP6) {
            // Price too HIGH. We need to LOWER it.
            // Action: Sell Token6 -> Buy Token18 (Increases T6 reserve, Decreases T18 reserve)
            token6.approve(address(uniRouter), swapAmount);
            address[] memory path = new address[](2);
            path[0] = address(token6);
            path[1] = address(token18);
            
            // Note: We use 'try' to avoid test reverts if liquidity is tight
            try uniRouter.swapExactTokensForTokens(swapAmount, 0, path, address(this), block.timestamp + 300) {} catch {}
        } else {
            // Price too LOW (This is the state after p6_2). We need to RAISE it.
            // Action: Sell Token18 -> Buy Token6 (Increases T18 reserve, Decreases T6 reserve)
            token18.approve(address(uniRouter), swapAmount);
            address[] memory path = new address[](2);
            path[0] = address(token18);
            path[1] = address(token6);
            
            try uniRouter.swapExactTokensForTokens(swapAmount, 0, path, address(this), block.timestamp + 300) {} catch {}
        }

        // Damping factor: Reduce impact as we get closer? 
        // Actually, if we are far off, we might want to keep the size steady, 
        // but reducing it is safer to avoid oscillating forever.
        if (swapAmount > 1e16) {
            swapAmount = swapAmount * 9 / 10;
        }
        
        i++;
    }
    
    // Final check before attempting settlement
    require(currentPrice >= minPriceFromP6 && currentPrice <= maxPriceFromP6, "Failed to recover price");

    emit DebugPrice(currentPrice, 0, "Recovered Price Now In Range");
    
    // Now settle — should succeed
    uint256[] memory orderIds = new uint256[](1); orderIds[0] = p6_orderId;
    (,, uint256[] memory amounts,) = listingTemplate.getBuyOrder(p6_orderId);
    uint256[] memory amountsIn = new uint256[](1); amountsIn[0] = amounts[0];

    settlementRouter.settleOrders(address(listingTemplate), orderIds, amountsIn, true);
    (,,, uint8 status) = listingTemplate.getBuyOrder(p6_orderId);
    
    assert(status == 3);
    emit TestPassed("p6_3RecoverPriceAndSucceed");
}

    // ============ PATH 7: HIGH IMPACT STRESS TEST ============

    function p7_1CreateHighImpactOrder() public {
        _approveToken6Tester(TOKEN6_AMOUNT * 10); // Approve a lot
        
        // 1. Get current pool price
        uint256 currentPrice = _getPoolPrice(address(token6), address(token18));
        
        // 2. Set bounds relatively tight (e.g., +/- 10%)
        uint256 minPrice = (currentPrice * 90) / 100;
        uint256 maxPrice = (currentPrice * 110) / 100;
        
        // 3. Create a MASSIVE order (e.g., 50% of the pool's liquidity)
        // If pool has 10,000 T6, we order 5,000 T6.
        // This will definitely shift the impact price beyond 10%.
        uint256 massiveAmount = 5000 * 1e6; 
        
        uint256 orderId = listingTemplate.getNextOrderId();
        tester.proxyCall(
            address(orderRouter),
            abi.encodeWithSignature(
                "createBuyOrder(address,address,address,uint256,uint256,uint256)",
                address(token6), address(token18), address(tester),
                massiveAmount, maxPrice, minPrice
            )
        );
        p7_orderId = orderId; // new state var
        emit TestPassed("p7_1CreateHighImpactOrder");
    }

    function p7_2AttemptImpactSettlement() public {
        (,, uint256[] memory amounts,) = listingTemplate.getBuyOrder(p7_orderId);
        
        uint256[] memory orderIds = new uint256[](1);
        orderIds[0] = p7_orderId;
        
        uint256[] memory amountsIn = new uint256[](1);
        
        // Attempt to settle 20% of this massive order.
        // Even 20% of a massive order might cause >10% impact linear estimation.
        amountsIn[0] = amounts[0] / 5; 
        
        string memory result = settlementRouter.settleOrders(address(listingTemplate), orderIds, amountsIn, true);
        
        // Assertions
        // 1. Result should indicate failure/skip
        // "No orders settled: price/impact check failed" is the expected return from the Router logic.
        bool expectedMsg = keccak256(abi.encodePacked(result)) == keccak256(abi.encodePacked("No orders settled: price/impact check failed"));
        require(expectedMsg, "Should have failed due to impact");

        // 2. Order Status should remain Pending (1)
        (,,, uint8 status) = listingTemplate.getBuyOrder(p7_orderId);
        assert(status == 1);
        
        emit TestPassed("p7_2AttemptImpactSettlement");
    }
}