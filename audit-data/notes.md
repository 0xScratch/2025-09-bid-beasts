## About Project

This smart contract implements a basic auction-based NFT marketplace for the BidBeasts ERC721 token. It enables NFT owners to list their tokens for auction, accept bids from participants, and settle auctions with a platform fee mechanism.

## Notes

- Honestly, I don't see any mention of 3-days duration of the auction in the whole contract. The only duration mentioned is the extension duration of 15 minutes. and yeah, I am indeed right there.
- This `AuctionSettled` event is clearly at the wrong place. It should be emitted after the auction is successfully settled, not when a bid is placed.
- I have been going round and round in this marketplace contract. I don't find any upfront vulnerability in `_executeSale` and `_payout` functions. But I guess, they should definitely need to be tested out.
- There's a thing in my mind related to this `_payout` function. Like we know that it eventually provides the payout to the previous bidder, no matter if the call failed or not. I mean, if the call even failed then the amount will be added to the `failedCredits` mapping. But what if the call don't fail but actually takes a lot of gas to execute? I mean, what if the previous bidder is a contract and the fallback function of that contract is doing some heavy computation which takes a lot of gas to execute? Well, it won't fail still but the next bidder might have to think twice before placing a bid because they might have to pay a lot of gas for the previous bidder's payout. So, this is something that I think should be considered.
- Damn, the above statement do came to be true!!!

- Alright, Now I have reached to the point where finding more vulnerability is getting really hard. Gotta seek some new approaches, some of them revolving in my mind are:
  - Try to research some vulnerabilities, hacks, etc. related to auction-based/NFTs-related contracts. (Actually, make this the priority move)
  - Try various tests, i.e. fuzzing and stateful fuzzing. However, I am really skeptical of them working out, but still, I gotta try them.
  - Try digging into your own `Smart Contract Vulnerabilities` repo. Recheck the most of the vulnerabilities there and see whether one of them fits or not.

- There's a serious issue with the 15 minutes time duration. Earlier I thought it's just a minor issue, but it came out to be something big. So far, it's theoretical in my head, but test it the next time you jump in here.
- Here's how it might look like:
  - Nft gets listed, auctionEnd = 0
  - Someone places a bid, auctionEnd = block.timestamp + 15 minutes
  - But if no one places a bid for the next 15 minutes, then auctionEnd will be less than block.timestamp, and the bidder can easily call `settleAuction` and get the NFT for almost a minimum price.
  - The thing is, this auction just provides a maximum of 29 minutes and 59 seconds of bidding window (supposing that two bids took places one after another, with a gap of 1 second, well, that's due the logic in lines 159 to 166). So, if no one places a bid in that 29 minutes and 59 seconds, then the last bidder can easily call `settleAuction` and get the NFT for a very low price.
  - Moreover, let's say, 1 hour has passed, and no one noticed such loophole, and someone placed a bid after that 1 hour, then we do get an event emitted, saying that auction has extended. But in reality, that last bidder can easily call `settleAuction` the next second because according to the logic, `listing.auctionEnd + S_AUCTION_EXTENSION_DURATION` will be less than `block.timestamp`. As that's `listing.auctionEnd` was updated 1 hour before.
  - Overall, seller is at a big loss here, and the last bidder can easily get the NFT for a very low price.

## Findings So Far:

1. **`BidBeasts_NFT_ERC721.sol`**:
    - First is that `burn` function in the `BidBeasts_NFT_ERC721.sol` contract, anyone can call the burn function
    - In that same contract, there's a reentrance chance in `mint()` function. However, I am not able to exploit it so far, but there's a chance of it. Still, it's better to be safe than sorry.
        - It's really not exploitable in the current state, but yeah, like I said, there's no issue in shifting `currentTokenId++` before the `_safeMint` call. Can act as an informational note.
2. **`BidBeastsNFTMarketPlace.sol`**:
    - The `BidBeasts` contract instance could be declared as `immutable` to save gas.
    - `AuctionSettled` event is emitted in the wrong place. It should be emitted after the auction is successfully settled, not when a bid is placed.
    - Then there's a slight inconsistency in the auction duration. The contract mentions a 3-day auction duration, but the code only shows an extension duration of 15 minutes. This could lead to confusion about how long auctions actually last.
    - On line 156, the contract calculates `requiredAmount = (previousBidAmount / 100) * (100 + S_MIN_BID_INCREMENT_PERCENTAGE);`. This calculation could lead to rounding errors due to integer division in Solidity. A better approach would be to use multiplication before division to maintain precision, like this: `requiredAmount = (previousBidAmount * (100 + S_MIN_BID_INCREMENT_PERCENTAGE)) / 100;`.
    - The `withdrawAllFailedCredits` function allows anyone to withdraw funds on behalf of any user by specifying the `_receiver` address. This is a critical security flaw as it enables unauthorized access to users' funds. The function should be modified to allow only the caller to withdraw their own failed credits, i.e., it should use `msg.sender` instead of accepting an address parameter.
    - Check the 4th and 5th points in the "Notes" section. Another issue.
    - Hmm, somehow my doubt related to `transferFrom` thing used for NFT transfer in `executeSale` was right. It leads to an issue where if the NFT is transferred to a contract that doesn't implement the `onERC721Received` function, the NFT will be locked in that contract forever. This is because `transferFrom` does not check if the recipient can handle ERC721 tokens, unlike `safeTransferFrom`. This could lead to loss of NFTs if users are not careful about where they transfer their tokens.

## Learnings from this Audit:

1. It's always better to check the other audits of similar protocol types. As sometimes, there's a lot of hints that can be taken from there.
2. Please, Please take less time on reports. Honestly, I took way too much time on creating the findings report and stuff, more than I took to even search for vulnerabilities. I should definitely work on that.
3. I still feel there are more vulnerabilities that could be found in here, but anyways, next time be more quick and efficient.

## Mistakes I made in this audit:

1. The [2nd finding](./findings.md/#missing-enforcement-of-the-3-days-auction-duration-allows-early-settlement-undermining-bidding-fairness-and-seller-revenue) was downgraded by the judge due to a dumb mistake of mine. I kind of mixed up the two vulnerabilities, one being the 3-days auction duration (documentation mismatch) and the other being the unintended early settlement due to the 15-minutes extension logic at line 164. The worse thing is, I do had this in mind but tried to be more smart and thought both should be clubbed together. But yeah, I was wrong. Gotta be more careful next time.

## Appeals

Greetings Sir, I just checked out your comment about listing my finding as an "edge case" of `M-04. Reentrancy During Buy-Now Purchase`, and I read the vulnerability details mentioned in the preliminary report. But, sorry to say, I completely disagree with that. Here's why (tbh, there's a lot to unpack here, so please bear with me):

1. **M-04 looks like a reentrancy attempt, but it's not really an attack**:

    - In `M-04`'s PoC, they show this:
      
      ```solidity
        receive() external payable {
          // Called when receiving bid refund
          if (attackCount < 1) {
              attackCount++;
              // Try to manipulate state during refund
      @>      // At this point, listing.listed is false but bids[tokenId] still exists
              // This could cause unexpected behavior or DoS
              market.placeBid{value: msg.value}(targetTokenId);
          }
        }
      ```
    
    - But here's the thing: they (and others, mostly) missed that `placeBid` has the `isListed(tokenId)` modifier, which reverts if `listing.listed = false`. The refund goes to `failedTransferCredits`.

    - Plus, running their PoC fails and `vm.expectRevert()` doesn't revert as expected.

    - Here's a better PoC (similar to `M-04`):

      ```solidity
      function test_ReentrancyInBuyNow() public {
        // Setup
        MaliciousBidder attacker = new MaliciousBidder(address(market)); // MaliciousBidder contract as in M-04
        vm.deal(address(attacker), 10 ether);
        console.log("Attacker's address:", address(attacker));

        address legitimateBuyer = makeAddr("LegitimateBuyer");
        vm.deal(legitimateBuyer, 10 ether);
        console.log("Legitimate buyer's address:", legitimateBuyer);

        _mintNFT();
        _listNFT();
        
        // 1. Attacker places initial bid
        attacker.placeBid{value: 2 ether}(TOKEN_ID);
        
        // 2. Legitimate user tries to buy-now
        vm.prank(legitimateBuyer);
        // vm.expectRevert(); /// @audit Commenting this out as it never reverts anyway, unlike in M-04
        market.placeBid{value: BUY_NOW_PRICE}(TOKEN_ID);
        
        address currentOwner = nft.ownerOf(TOKEN_ID);
        console.log("Current owner of the NFT:", currentOwner);

        console.log("failed transfer credit's amount of attacker:", market.failedTransferCredits(address(attacker)));
      }
      ```
    
    - Logs:
    
      ```log
      Attacker's address: 0xF62849F9A0B5Bf2913b396098F7c7019b51A820a
      Legitimate buyer's address: 0x5E5e2E4395CDa9E269F9FB2Ce27Db5A340A6E91f
      Current owner of the NFT: 0x5E5e2E4395CDa9E269F9FB2Ce27Db5A340A6E91f
      failed transfer credit's amount of attacker: 2000000000000000000
      ```
    
    - See? The legitimate buyer gets the NFT, and the attacker achieves nothing. So, this is not an attack at all.

    - Other reports call it "potential reentrancy" but don't prove impact. Here's a quick list:
      - [#62](https://codehawks.cyfrin.io/c/2025-09-bid-beasts/s/62): Ties to `H-01` withdrawal bug; reentrancy alone isn't enough. And somehow, the auditor seems aware of it.
      - [#89](https://codehawks.cyfrin.io/c/2025-09-bid-beasts/s/89): Reenters `placeBid` — fails as expected
      - [#118](https://codehawks.cyfrin.io/c/2025-09-bid-beasts/s/118): Reenters `unlistNFT` — blocked by modifiers (`isListed` and `isSeller`); unclear gain even if get passed
      - And so on... Honestly, at this point I don't really want to check them all, but I believe you got my point.
    
    - So, based on my understanding, `M-04` isn't a true security issue — maybe **Informational** or **Low** at best. And if this "reentrancy attempt" counts, why not flag the mint function in BidBeasts_NFT_ERC721? (I didn't submit it, and you know why.) 

        ```solidity
            function mint(address to) public onlyOwner returns (uint256) {
            uint256 _tokenId = CurrenTokenID;
        @>  _safeMint(to, _tokenId); // _safeMint, a open window through `onERC721Received`
            emit BidBeastsMinted(to, _tokenId);
        @>  CurrenTokenID++; // state updates later on
            return _tokenId;
        }
        ```

2. **Why `Economic DoS` finding is different from `reentrancy`, and better?**:

    - Crediting auditors for spotting the ETH transfer is fair, but attaching my finding to it undermines what I reported.

    - My finding doesn't involve state manipulation or reentrancy; it demonstrates an economic DoS or gas griefing with a clear PoC.

    - Suggested fixes for reentrancy don't address my attack vector, so the real risk could be overlooked.

    - Please also reconsider the severity of my Economic DoS — it may be **High**.

Sorry for the long write-up, but I felt a bit of injustice at first and wanted to explain properly. If I'm off base, it'll be a good learning chance anyway.
