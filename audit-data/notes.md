# About Project

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

## Findings So Far

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

## Learnings from this Audit

1. It's always better to check the other audits of similar protocol types. As sometimes, there's a lot of hints that can be taken from there.
2. Please, Please take less time on reports. Honestly, I took way too much time on creating the findings report and stuff, more than I took to even search for vulnerabilities. I should definitely work on that.
3. I still feel there are more vulnerabilities that could be found in here, but anyways, next time be more quick and efficient.
