// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

// File Version: 0.0.3 (22/11/2025)
// Changelog Summary:
// - 22/11/2025: Added setWETH call and interface. 

import "./MockMAILToken.sol";
import "./MockMailTester.sol";
import "./MockUniFactory.sol";
import "./MockUniPair.sol";
import "./MockWETH.sol";

// Inline interfaces to avoid import bloat
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
    function createSellOrder(
        address startToken,
        address endToken,
        address recipientAddress,
        uint256 inputAmount,
        uint256 maxPrice,
        uint256 minPrice
    ) external payable;
    function clearSingleOrder(uint256 orderIdentifier, bool isBuyOrder) external;
    function clearOrders(uint256 maxIterations) external;
    function setWETH(address) external; 
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
    function getSellOrder(uint256 orderId) external view returns (
        address[] memory addresses,
        uint256[] memory prices,
        uint256[] memory amounts,
        uint8 status
    );
    function pendingBuyOrdersView() external view returns (uint256[] memory);
    function pendingSellOrdersView() external view returns (uint256[] memory);
    function makerPendingOrdersView(address maker) external view returns (uint256[] memory);
    function transferOwnership(address) external;
}

interface VERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

contract OrderTests {
    ICCOrderRouter public orderRouter;
    ICCListingTemplate public listingTemplate;
    MockUniFactory public uniFactory;
    MockWETH public weth;
    
    MockMAILToken public token18; // 18 decimals
    MockMAILToken public token6;  // 6 decimals
    MockMailTester public tester;
    address public owner;

    // CHANGELOG 21/11/2025 - Pair variables changed to address payable
    // Required because MockUniPair has a payable receive() fallback
    address payable public pairWETHToken18;
    address payable public pairWETHToken6;
    address payable public pairToken18Token6;

    uint256 public constant TEST_AMOUNT = 0.1 ether;
    uint256 public constant TOKEN18_AMOUNT = 100 * 1e18;
    uint256 public constant TOKEN6_AMOUNT = 100 * 1e6;
    uint256 public constant LIQUIDITY_ETH = 1 ether;
    uint256 public constant LIQUIDITY_TOKEN18 = 1000 * 1e18;
    uint256 public constant LIQUIDITY_TOKEN6 = 1000 * 1e6;

    // Test state tracking
    uint256 public p1BuyOrderId;
    uint256 public p1SellOrderId;
    uint256 public p2BuyOrderId;
    uint256 public p2SellOrderId;

    event CCContractsSet(address router, address listing, address factory);
    event UniMocksDeployed(address factory, address weth);
    event PairsCreated(address wethToken18, address wethToken6, address token18Token6);
    event TestPassed(string testName);
    event TestFailed(string testName, string reason);

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

    // Deploy Uniswap mocks
    function deployUniMocks() external {
        require(msg.sender == owner, "Not owner");
        
        weth = new MockWETH();
        uniFactory = new MockUniFactory(address(weth));
        
        emit UniMocksDeployed(address(uniFactory), address(weth));
    }

    // External setup for pre-deployed CoinClash contracts
    function setCCContracts(
        address _router,
        address _listing
    ) external {
        require(msg.sender == owner, "Not owner");
        require(_router != address(0), "Invalid router");
        require(_listing != address(0), "Invalid listing");

        orderRouter = ICCOrderRouter(_router);
        listingTemplate = ICCListingTemplate(_listing);

        emit CCContractsSet(_router, _listing, address(uniFactory));
    }

    // Initialize contracts and create liquidity pairs
    function initializeContracts() external payable {
    require(msg.sender == owner, "Not owner");
    require(address(listingTemplate) != address(0), "Contracts not set");
    require(address(uniFactory) != address(0), "Uni mocks not deployed");
    require(msg.value >= LIQUIDITY_ETH * 2, "Insufficient ETH for liquidity");

    // Set up router in listing template
    listingTemplate.addRouter(address(orderRouter));
    
    // Set listing template in router
    orderRouter.setListingTemplate(address(listingTemplate));

    // FIX: Inject the MockWETH address into the Router so it finds the correct pair
    orderRouter.setWETH(address(weth)); 
    
    // Set Uniswap factory and router
    listingTemplate.setUniswapV2Factory(address(uniFactory));
    listingTemplate.setUniswapV2Router(address(uniFactory));
    
    // Create pairs and add liquidity
    _createPairsWithLiquidity();
}

    function _createPairsWithLiquidity() internal {
        // WETH ↔ Token18 (18 decimals)
        pairWETHToken18 = payable(uniFactory.createPair(address(weth), address(token18)));
        weth.deposit{value: LIQUIDITY_ETH}();
        weth.transfer(pairWETHToken18, LIQUIDITY_ETH);
        token18.transfer(pairWETHToken18, LIQUIDITY_TOKEN18);
        MockUniPair(pairWETHToken18).mint(address(this));

        // WETH ↔ Token6 (6 decimals) – fixed token0 → token6
        pairWETHToken6 = payable(uniFactory.createPair(address(weth), address(token6)));
        weth.deposit{value: LIQUIDITY_ETH}();
        weth.transfer(pairWETHToken6, LIQUIDITY_ETH);
        token6.transfer(pairWETHToken6, LIQUIDITY_TOKEN6);
        MockUniPair(pairWETHToken6).mint(address(this));

        // Token18 ↔ Token6
        pairToken18Token6 = payable(uniFactory.createPair(address(token18), address(token6)));
        token18.transfer(pairToken18Token6, LIQUIDITY_TOKEN18);
        token6.transfer(pairToken18Token6, LIQUIDITY_TOKEN6);
        MockUniPair(pairToken18Token6).mint(address(this));

        emit PairsCreated(pairWETHToken18, pairWETHToken6, pairToken18Token6);
    }

    // Return ownership of contracts
    function returnOwnership() external {
        require(msg.sender == owner, "Not owner");
        require(address(listingTemplate) != address(0), "Contracts not set");
        
        listingTemplate.transferOwnership(msg.sender);
    }

    function initiateTester() public payable {
        require(msg.sender == owner, "Not owner");
        require(msg.value == 1 ether, "Send 1 ETH");
        
        tester = new MockMailTester(address(this));
        
        // Fund tester with ETH
        (bool success,) = address(tester).call{value: 1 ether}("");
        require(success, "Fund failed");

        // Mint tokens to tester
        token18.mint(address(tester), TOKEN18_AMOUNT);
        token6.mint(address(tester), TOKEN6_AMOUNT);
    }

    function _approveToken18(address spender, uint256 amount) internal {
        tester.proxyCall(
            address(token18),
            abi.encodeWithSignature("approve(address,uint256)", spender, amount)
        );
    }

    function _approveToken6(address spender, uint256 amount) internal {
        tester.proxyCall(
            address(token6),
            abi.encodeWithSignature("approve(address,uint256)", spender, amount)
        );
    }

    // ============ P1: Token-to-Token Orders (18 decimals to 6 decimals) ============

    function p1_1TestBuyTokenBtoA() public {
        // Buy order: Give token6 (6 decimals), receive token18 (18 decimals)
        // This tests normalization from 6 decimals
        
        _approveToken6(address(orderRouter), TOKEN6_AMOUNT);
        
        uint256 orderIdBefore = listingTemplate.getNextOrderId();
        uint256 inputAmount = 10 * 1e6; // 10 token6
        uint256 maxPrice = 2e18;  // Max 2:1 ratio
        uint256 minPrice = 1e17;  // Min 0.1:1 ratio
        
        tester.proxyCall(
            address(orderRouter),
            abi.encodeWithSignature(
                "createBuyOrder(address,address,address,uint256,uint256,uint256)",
                address(token6),   // startToken (what we pay with)
                address(token18),  // endToken (what we receive)
                address(tester),   // recipient
                inputAmount,
                maxPrice,
                minPrice
            )
        );
        
        p1BuyOrderId = orderIdBefore;
        
        // Verify order details
        (address[] memory addrs, uint256[] memory prices, uint256[] memory amounts, uint8 status) 
            = listingTemplate.getBuyOrder(p1BuyOrderId);
        
        assert(addrs[0] == address(tester)); // maker
        assert(addrs[1] == address(tester)); // recipient
        assert(addrs[2] == address(token6)); // startToken
        assert(addrs[3] == address(token18)); // endToken
        
        assert(prices[0] == maxPrice);
        assert(prices[1] == minPrice);
        
        // Check normalized amount (6 decimals -> 18 decimals)
        uint256 expectedNormalized = inputAmount * 1e12; // 10 * 1e6 * 1e12 = 10 * 1e18
        assert(amounts[0] == expectedNormalized); // pending
        assert(amounts[1] == 0); // filled
        assert(amounts[2] == 0); // amountSent
        
        assert(status == 1); // pending
        
        // Verify order is in pending lists
        uint256[] memory pendingBuys = listingTemplate.pendingBuyOrdersView();
        bool found = false;
        for (uint i = 0; i < pendingBuys.length; i++) {
            if (pendingBuys[i] == p1BuyOrderId) {
                found = true;
                break;
            }
        }
        assert(found);
    }

    function p1_2TestSellTokenAtoB() public {
        // Sell order: Give token18 (18 decimals), receive token6 (6 decimals)
        // This tests normalization from 18 decimals
        
        _approveToken18(address(orderRouter), TOKEN18_AMOUNT);
        
        uint256 orderIdBefore = listingTemplate.getNextOrderId();
        uint256 inputAmount = 10 * 1e18; // 10 token18
        uint256 maxPrice = 2e18;
        uint256 minPrice = 1e17;
        
        tester.proxyCall(
            address(orderRouter),
            abi.encodeWithSignature(
                "createSellOrder(address,address,address,uint256,uint256,uint256)",
                address(token18),  // startToken (what we sell)
                address(token6),   // endToken (what we receive)
                address(tester),   // recipient
                inputAmount,
                maxPrice,
                minPrice
            )
        );
        
        p1SellOrderId = orderIdBefore;
        
        // Verify order details
        (address[] memory addrs, uint256[] memory prices, uint256[] memory amounts, uint8 status) 
            = listingTemplate.getSellOrder(p1SellOrderId);
        
        assert(addrs[0] == address(tester));
        assert(addrs[2] == address(token18)); // startToken
        assert(addrs[3] == address(token6));  // endToken
        
        assert(amounts[0] == inputAmount); // Already 18 decimals, no normalization needed
        assert(amounts[1] == 0);
        assert(amounts[2] == 0);
        assert(status == 1);
    }

    function p1_3TestCancelTokenBuyOrder() public {
        // Get initial balance
        uint256 balanceBefore = VERC20(address(token6)).balanceOf(address(tester));
        
        // Cancel order
        tester.proxyCall(
            address(orderRouter),
            abi.encodeWithSignature("clearSingleOrder(uint256,bool)", p1BuyOrderId, true)
        );
        
        // Verify order status updated
        (,, uint256[] memory amounts, uint8 status) = listingTemplate.getBuyOrder(p1BuyOrderId);
        assert(status == 0); // cancelled
        
        // Verify refund received (denormalized back to 6 decimals)
        uint256 balanceAfter = VERC20(address(token6)).balanceOf(address(tester));
        assert(balanceAfter > balanceBefore); // Should receive refund
        
        // Verify order removed from pending list
        uint256[] memory pendingBuys = listingTemplate.pendingBuyOrdersView();
        for (uint i = 0; i < pendingBuys.length; i++) {
            assert(pendingBuys[i] != p1BuyOrderId);
        }
    }

    function p1_4TestCancelTokenSellOrder() public {
        uint256 balanceBefore = VERC20(address(token18)).balanceOf(address(tester));
        
        tester.proxyCall(
            address(orderRouter),
            abi.encodeWithSignature("clearSingleOrder(uint256,bool)", p1SellOrderId, false)
        );
        
        (,, uint256[] memory amounts, uint8 status) = listingTemplate.getSellOrder(p1SellOrderId);
        assert(status == 0);
        
        uint256 balanceAfter = VERC20(address(token18)).balanceOf(address(tester));
        assert(balanceAfter > balanceBefore);
    }

    // ============ P2: ETH-to-Token Orders (using WETH pairs) ============

    function p2_1TestBuyTokenAtoETH() public {
        // Buy order: Give ETH, receive token18
        
        uint256 orderIdBefore = listingTemplate.getNextOrderId();
        uint256 maxPrice = 2e18;
        uint256 minPrice = 1e17;
        
        tester.proxyCall{value: TEST_AMOUNT}(
            address(orderRouter),
            abi.encodeWithSignature(
                "createBuyOrder(address,address,address,uint256,uint256,uint256)",
                address(0),        // startToken (ETH)
                address(token18),  // endToken
                address(tester),
                TEST_AMOUNT,
                maxPrice,
                minPrice
            )
        );
        
        p2BuyOrderId = orderIdBefore;
        
        (address[] memory addrs, uint256[] memory prices, uint256[] memory amounts, uint8 status) 
            = listingTemplate.getBuyOrder(p2BuyOrderId);
        
        assert(addrs[2] == address(0)); // startToken is ETH
        assert(addrs[3] == address(token18));
        assert(amounts[0] == TEST_AMOUNT); // ETH is 18 decimals, no normalization
        assert(status == 1);
    }

    function p2_2TestSellTokenBtoETH() public {
        // Sell order: Give token6, receive ETH
        
        _approveToken6(address(orderRouter), TOKEN6_AMOUNT);
        
        uint256 orderIdBefore = listingTemplate.getNextOrderId();
        uint256 inputAmount = 10 * 1e6;
        uint256 maxPrice = 2e18;
        uint256 minPrice = 1e17;
        
        tester.proxyCall(
            address(orderRouter),
            abi.encodeWithSignature(
                "createSellOrder(address,address,address,uint256,uint256,uint256)",
                address(token6),   // startToken
                address(0),        // endToken (ETH)
                address(tester),
                inputAmount,
                maxPrice,
                minPrice
            )
        );
        
        p2SellOrderId = orderIdBefore;
        
        (address[] memory addrs,, uint256[] memory amounts, uint8 status) 
            = listingTemplate.getSellOrder(p2SellOrderId);
        
        assert(addrs[2] == address(token6));
        assert(addrs[3] == address(0)); // endToken is ETH
        
        // Check normalized amount
        uint256 expectedNormalized = inputAmount * 1e12;
        assert(amounts[0] == expectedNormalized);
        assert(status == 1);
    }

    function p2_3TestCancelETHBuyOrder() public {
        uint256 balanceBefore = address(tester).balance;
        
        tester.proxyCall(
            address(orderRouter),
            abi.encodeWithSignature("clearSingleOrder(uint256,bool)", p2BuyOrderId, true)
        );
        
        (,,, uint8 status) = listingTemplate.getBuyOrder(p2BuyOrderId);
        assert(status == 0);
        
        uint256 balanceAfter = address(tester).balance;
        assert(balanceAfter > balanceBefore); // Should receive ETH refund
    }

    function p2_4TestCancelETHSellOrder() public {
        uint256 balanceBefore = VERC20(address(token6)).balanceOf(address(tester));
        
        tester.proxyCall(
            address(orderRouter),
            abi.encodeWithSignature("clearSingleOrder(uint256,bool)", p2SellOrderId, false)
        );
        
        (,,, uint8 status) = listingTemplate.getSellOrder(p2SellOrderId);
        assert(status == 0);
        
        uint256 balanceAfter = VERC20(address(token6)).balanceOf(address(tester));
        assert(balanceAfter > balanceBefore);
    }

    // ============ SAD PATH TESTS ============

    function s1_TestCreateOrderSameTokens() public {
        // Attempt to create order with same start and end token
        _approveToken18(address(orderRouter), TOKEN18_AMOUNT);
        
        try tester.proxyCall(
            address(orderRouter),
            abi.encodeWithSignature(
                "createBuyOrder(address,address,address,uint256,uint256,uint256)",
                address(token18),
                address(token18), // Same token
                address(tester),
                10 * 1e18,
                2e18,
                1e17
            )
        ) {
            revert("Did not revert");
        } catch {}
    }

    function s2_TestCreateOrderBothNative() public {
        // Attempt to create order with both tokens as native ETH
        try tester.proxyCall{value: TEST_AMOUNT}(
            address(orderRouter),
            abi.encodeWithSignature(
                "createBuyOrder(address,address,address,uint256,uint256,uint256)",
                address(0),
                address(0), // Both native
                address(tester),
                TEST_AMOUNT,
                2e18,
                1e17
            )
        ) {
            revert("Did not revert");
        } catch {}
    }

    function s3_TestCreateOrderZeroAmount() public {
        // Attempt to create order with zero amount
        try tester.proxyCall(
            address(orderRouter),
            abi.encodeWithSignature(
                "createBuyOrder(address,address,address,uint256,uint256,uint256)",
                address(token18),
                address(token6),
                address(tester),
                0, // Zero amount
                2e18,
                1e17
            )
        ) {
            revert("Did not revert");
        } catch {}
    }

    function s4_TestCreateOrderIncorrectETHAmount() public {
        // Send wrong ETH amount
        try tester.proxyCall{value: TEST_AMOUNT}(
            address(orderRouter),
            abi.encodeWithSignature(
                "createBuyOrder(address,address,address,uint256,uint256,uint256)",
                address(0),
                address(token18),
                address(tester),
                TEST_AMOUNT * 2, // Requesting more than sent
                2e18,
                1e17
            )
        ) {
            revert("Did not revert");
        } catch {}
    }

    function s5_TestCancelOrderNotMaker() public {
        // Create an order from this contract
        token18.approve(address(orderRouter), TOKEN18_AMOUNT);
        
        orderRouter.createBuyOrder(
            address(token18),
            address(token6),
            address(this),
            10 * 1e18,
            2e18,
            1e17
        );
        
        uint256 orderId = listingTemplate.getNextOrderId() - 1;
        
        // Try to cancel from tester (not maker)
        try tester.proxyCall(
            address(orderRouter),
            abi.encodeWithSignature("clearSingleOrder(uint256,bool)", orderId, true)
        ) {
            revert("Did not revert");
        } catch {}
    }

    function s6_TestCreateOrderNonexistentPair() public {
        // Deploy new token without creating Uniswap pair
        MockMAILToken newToken = new MockMAILToken();
        newToken.setDetails("New Token", "NEW", 18);
        newToken.mint(address(tester), 100 * 1e18);
        
        tester.proxyCall(
            address(newToken),
            abi.encodeWithSignature("approve(address,uint256)", address(orderRouter), type(uint256).max)
        );
        
        // Attempt to create order with non-existent pair
        try tester.proxyCall(
            address(orderRouter),
            abi.encodeWithSignature(
                "createBuyOrder(address,address,address,uint256,uint256,uint256)",
                address(newToken),
                address(token18),
                address(tester),
                10 * 1e18,
                2e18,
                1e17
            )
        ) {
            revert("Did not revert");
        } catch {}
    }

    function s7_TestClearOrdersMultiple() public {
        // Create multiple orders
        _approveToken18(address(orderRouter), TOKEN18_AMOUNT);
        _approveToken6(address(orderRouter), TOKEN6_AMOUNT);
        
        for (uint i = 0; i < 3; i++) {
            tester.proxyCall(
                address(orderRouter),
                abi.encodeWithSignature(
                    "createBuyOrder(address,address,address,uint256,uint256,uint256)",
                    address(token18),
                    address(token6),
                    address(tester),
                    1 * 1e18,
                    2e18,
                    1e17
                )
            );
        }
        
        // Clear all orders at once
        tester.proxyCall(
            address(orderRouter),
            abi.encodeWithSignature("clearOrders(uint256)", 10)
        );
        
        // Verify all orders cleared
        uint256[] memory pendingOrders = listingTemplate.makerPendingOrdersView(address(tester));
        assert(pendingOrders.length == 0);
    }
}