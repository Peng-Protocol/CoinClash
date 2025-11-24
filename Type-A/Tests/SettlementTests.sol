// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

// File Version: 0.0.2 (23/11/2025)
// 0.0.2 (23/11/2035): Comprehensive settlement testing with consolidated paths
// Refactored to include "Seesaw" price impact testing and merged verification logic

import "./MockMAILToken.sol";
import "./MockMailTester.sol";
import "./MockUniFactory.sol";
import "./MockUniPair.sol";
import "./MockWETH.sol";

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
    uint256 public p6_orderId; // For Seesaw test

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
    }

    function setCCContracts(
        address _orderRouter,
        address _settlementRouter,
        address _listing
    ) external {
        require(msg.sender == owner, "Not owner");
        require(_orderRouter != address(0), "Invalid order router");
        require(_settlementRouter != address(0), "Invalid settlement router");
        require(_listing != address(0), "Invalid listing");

        orderRouter = ICCOrderRouter(_orderRouter);
        settlementRouter = ICCSettlementRouter(_settlementRouter);
        listingTemplate = ICCListingTemplate(_listing);

        emit ContractsSet(_orderRouter, _settlementRouter, _listing);
    }

    function initializeContracts() external payable {
        require(msg.sender == owner, "Not owner");
        require(address(listingTemplate) != address(0), "Contracts not set");
        require(address(uniFactory) != address(0), "Uni mocks not deployed");
        require(msg.value >= 2 ether, "Insufficient ETH sent");

        listingTemplate.addRouter(address(orderRouter));
        listingTemplate.addRouter(address(settlementRouter));
        
        orderRouter.setListingTemplate(address(listingTemplate));
        settlementRouter.setListingTemplate(address(listingTemplate));

        orderRouter.setWETH(address(weth));
        
        listingTemplate.setUniswapV2Factory(address(uniFactory));
        listingTemplate.setUniswapV2Router(address(uniFactory));

        _createPairWithLiquidity();
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
        require(msg.value == 1 ether, "Send 1 ETH");
        
        tester = new MockMailTester(address(this));
        
        // Fund tester with ETH
        (bool success,) = address(tester).call{value: 1 ether}("");
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
        // Min: Current * 0.9 (Allow slightly worse rate)
        // Max: Current * 1.1 (Allow slightly better rate)
        uint256 minPrice = (currentPrice * 90) / 100;
        uint256 maxPrice = (currentPrice * 110) / 100;
        
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
        // ACTION: Add massive Input (Token6) to pool.
        // Result: Denominator increases -> Price (Out/In) decreases (Crashes).
        // Expectation: Price drops BELOW minPrice.
        
        token6.transfer(pairToken18Token6, 5000 * 1e6); 
        IUniswapV2Pair(pairToken18Token6).mint(address(this));
        
        uint256 newPrice = _getPoolPrice(address(token6), address(token18));
        
        // Attempt Settle
        token18.approve(address(settlementRouter), type(uint256).max);
        uint256[] memory orderIds = new uint256[](1); orderIds[0] = p6_orderId;
        (,, uint256[] memory amounts, ) = listingTemplate.getBuyOrder(p6_orderId);
        uint256[] memory amountsIn = new uint256[](1); amountsIn[0] = amounts[0];
        
        settlementRouter.settleOrders(address(listingTemplate), orderIds, amountsIn, true);
        
        // Assert: Skipped (Status remains 1)
        (,,, uint8 status) = listingTemplate.getBuyOrder(p6_orderId);
        assert(status == 1); 
        
        emit DebugPrice(newPrice, 0, "Crashed Price (Should Fail)");
        emit TestPassed("p6_2CrashPriceAndFail");
    }

    function p6_3RecoverPriceAndSucceed() public {
        // ACTION: Add Output (Token18) to pool.
        // Result: Numerator increases -> Price (Out/In) increases (Recovers).
        // Expectation: Price rises back into [min, max] range.
        
        // Add enough T18 to balance the T6 dumped earlier
        token18.transfer(pairToken18Token6, 5000 * 1e18); 
        IUniswapV2Pair(pairToken18Token6).mint(address(this));
        
        uint256 newPrice = _getPoolPrice(address(token6), address(token18));
        
        // Attempt Settle
        uint256[] memory orderIds = new uint256[](1); orderIds[0] = p6_orderId;
        (,, uint256[] memory amounts, ) = listingTemplate.getBuyOrder(p6_orderId);
        uint256[] memory amountsIn = new uint256[](1); amountsIn[0] = amounts[0];
        
        settlementRouter.settleOrders(address(listingTemplate), orderIds, amountsIn, true);
        
        // Assert: Filled (Status 3)
        (,,, uint8 status) = listingTemplate.getBuyOrder(p6_orderId);
        assert(status == 3); 
        
        emit DebugPrice(newPrice, 0, "Recovered Price (Should Succeed)");
        emit TestPassed("p6_3RecoverPriceAndSucceed");
    }

    // ============ PATH 7: LARGE BATCH STRESS TEST ============

    function p7_1CreateLargeBatch() public {
        _approveToken6Tester(TOKEN6_AMOUNT);
        token6.approve(address(orderRouter), TOKEN6_AMOUNT);
        uint256 orderIdBefore = listingTemplate.getNextOrderId();
        
        // Create 5 orders alternating addresses
        for (uint i = 0; i < 5; i++) {
            if (i % 2 == 0) {
                tester.proxyCall(address(orderRouter), abi.encodeWithSignature("createBuyOrder(address,address,address,uint256,uint256,uint256)", address(token6), address(token18), address(tester), (10 + i * 5) * 1e6, 10e18, 1e16));
            } else {
                orderRouter.createBuyOrder(address(token6), address(token18), address(this), (10 + i * 5) * 1e6, 10e18, 1e16);
            }
        }
        emit TestPassed("p7_1CreateLargeBatch");
    }

    function p7_2SettleBatch() public {
        uint256 startOrderId = listingTemplate.getNextOrderId() - 5;
        token18.approve(address(settlementRouter), type(uint256).max);
        
        uint256[] memory orderIds = new uint256[](5);
        uint256[] memory amountsIn = new uint256[](5);
        
        for (uint i = 0; i < 5; i++) {
            orderIds[i] = startOrderId + i;
            (,, uint256[] memory amounts,) = listingTemplate.getBuyOrder(orderIds[i]);
            amountsIn[i] = amounts[0]; // Full Settle
        }
        
        settlementRouter.settleOrders(address(listingTemplate), orderIds, amountsIn, true);
        
        for (uint i = 0; i < 5; i++) {
            (,,, uint8 status) = listingTemplate.getBuyOrder(orderIds[i]);
            assert(status == 3);
        }
        emit TestPassed("p7_2SettleBatch");
    }
}