# TonRooms

**Create rooms, join battles, and win GRAM.**

[Open TonRooms](https://tonrooms.app) · [Telegram bot & support](https://t.me/tonroomsbot) · [Русский](README.ru.md)

TonRooms is a platform for GRAM battles between players. Create a room or join an existing one, place the same stake as the other participants, and wait for the room to fill. A smart contract selects the winner and sends the prize to their wallet.

The participants, draw result, and payments are recorded on the blockchain. This repository contains the contract sources so that anyone can inspect how the game works.

## How a battle works

1. Connect a personal, non-custodial wallet through TON Connect.
2. Create a room with a name, stake, and capacity of 2–10 players, or join an open room.
3. Each wallet takes one place and pays the same stake. When the room fills, entries close and the draw starts automatically.
4. The winner receives the bank minus the service fee. The room history links to the payment on the blockchain.

Private rooms are accessed by invitation link and do not appear in the public active-room list. Their contracts and transactions remain public.

Before a room fills, a participant can leave and request their stake back. The creator can cancel the room when no other participants remain. Once the room is full, the participant list is fixed for the draw.

## How the winner is selected

The RNG — random number generator — runs inside the room's smart contract. The website displays its result.

The draw uses blockchain randomness from **two different blocks**:

- When the final stake is accepted, the contract saves the current random seed and records the block in which the room filled.
- Winner selection is allowed only in a later block. The contract initializes fresh randomness for that transaction and mixes in the saved seed.
- The resulting random value selects one position in the fixed participant list.

The blockchain's initial seed is derived from the block's random data and the room contract's address. The contract also mixes in the transaction's **logical time** — its position in the network's transaction ordering, not the time shown on a player's device.

At the point when entries close, the random data of the later draw block is not yet available to players. A player cannot calculate the outcome in advance from the room's public state or send a command that sets the seed or names a winner. Each participating wallet has one place in the draw; affiliate status, previous results, and the order in which the website displays players give no extra places or weighting.

The selection is implemented in [V2Room](contracts/V2Room.tolk) and [V2RoomB](contracts/V2RoomB.tolk). The underlying blockchain functions are described in the [TON documentation](https://docs.ton.org/contracts/techniques/random).

## Stakes, prizes, and fees

The service fee is charged on the winner's **profit**, excluding the winner's own stake. For example, with three players staking 10 GRAM each and a 10% fee:

| Item | Amount |
| --- | ---: |
| Total bank | 30 GRAM |
| Profit before the service fee | 20 GRAM |
| Service fee | 2 GRAM |
| Winner receives | **28 GRAM** |

The transaction preview shows the stake and the technical payment for contract execution and storage. The wallet separately shows its network fee.

Stakes are held by the room contract. The published room code has no administrator command to take players' stakes, appoint a winner, or cancel a room on their behalf. Room terms are fixed when the room is created. The owner can manage settings for new rooms and publish new room versions; that does not replace the code of an existing room.

## Affiliate Program

Register a wallet as an affiliate, receive your referral link, and share it with players. Registration costs **1 GRAM once**, plus the technical payment shown before confirmation. The registration fee is non-refundable. If manual approval is enabled, the application is paid on submission and becomes active after approval.

A player is linked to you after their first successful stake with your valid invitation, provided they do not already have an affiliate. This also works for wallets that previously played without an invitation. The confirmed link cannot be switched or reset. Earlier games are not recalculated.

You earn when your referred players take part in completed battles, whether they create a room or join someone else's. Rewards come from the project's service fee, with no additional deduction from the player's stake or prize.

With a 10% technical-fund allocation, 90% of the service fee remains. That amount is divided by the number of players, and your affiliate percentage applies to each referred player's share. For the battle in the example above, a **20% affiliate rate** earns **0.12 GRAM per referred player**: `2 × 90% ÷ 3 × 20%`.

Your dashboard shows your rate, linked wallets, earnings history, and available withdrawal balance. Earnings are credited to your on-chain account; withdrawals are authorized by your wallet. Individual affiliate rates can be discussed through [Telegram support](https://t.me/tonroomsbot).

## Contracts you can check

**Mainnet Root:** [`EQAvlB0dp7oDSJJGjs4hyO2kinO6VaYYzKDlzxD9NdYhRgfe`](https://tonviewer.com/EQAvlB0dp7oDSJJGjs4hyO2kinO6VaYYzKDlzxD9NdYhRgfe)

The five contract types were compiled with **Tolk 1.4.2**. Their code hashes have verified source records at [verifier.ton.org](https://verifier.ton.org/EQAvlB0dp7oDSJJGjs4hyO2kinO6VaYYzKDlzxD9NdYhRgfe), checked on 14 October 2026.

| Contract | Purpose |
| --- | --- |
| [Root](contracts/V2Root.tolk) | Room versions, admission rules, and program settings |
| [Room](contracts/V2Room.tolk) / [RoomB](contracts/V2RoomB.tolk) | Stakes, participant list, draw, refunds, and prize payment |
| [Profile](contracts/V2Profile.tolk) | A player's room operations and confirmed affiliate link |
| [Account](contracts/V2Account.tolk) | Wallet-controlled account for affiliate, investor, and project income |

[Verified code hashes and source checksums](verified-contracts.json) identify the exact sources published here. Verification links the sources to compiled code; results and payments can be checked separately in the blockchain history.

Source is available for inspection and verification under the [source notice](LICENSE.txt).
