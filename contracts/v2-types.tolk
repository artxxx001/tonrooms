// Copyright (c) 2026 TonRooms. All rights reserved.
// Source available for verification only.
// Permission is granted to inspect, audit and compile this source to verify
// TonRooms bytecode, and to host or reproduce it for that verification
// provided this notice is retained. No permission is granted to deploy or
// reuse this code in other projects. Third-party dependencies retain their licenses.

// TonRooms v6-next. Protocol v6. Admission deadlines do not expire rooms.
import "@stdlib/gas-payments"

const PROFILE_MIN = 30000000      // kept on Profile (AT_MOST): rent reserve, paid once and topped up by entries
const ACCOUNT_MIN = 20000000      // kept on Account: rent reserve
const EXCESS_MIN = 1000000        // overpayment above this is returned at once
const DEFAULT_BPS = 65535         // "use the partner rate of the Room terms"
const MAX_CREATED = 5
const MIN_CAPACITY = 2
const MAX_CAPACITY = 10
const RENT_HORIZON = 94608000     // 3 years of Room rent prepaid by the creator, unused part returned
const ROOM_CELLS = 240             // largest open Room (9 of 10 seats): 80 cells measured, reports/gas-profile.json
const ROOM_BITS = 120000           // 39352 bits measured (bits are free at the snapshot tariff)
const DRAW_SELF_HOPS = 3          // self re-sends of Draw while still in the fill block

// Gas units: measured maxima in reports/gas-profile.json plus ~10%; priced with on-chain tariff getters.
const JOIN_GAS = 26000            // Room entry (measured max 17416)
const FILL_GAS = 6000             // extra of the filling entry: DRAWING state and the Draw send (measured +4952)
const SETTLE_GAS_BASE = 35000     // Draw transaction without per-seat work
const SETTLE_GAS_SEAT = 14000      // per seat, worst case: a distinct partner credit per seat (N=10: 106225 measured, 117000 quoted)
const CREDIT_GAS = 12000           // measured 3587
const NOTE_GAS = 26000            // Accepted: Root relay + Profile handler (measured 6665 + 4021)
const CLOSE_GAS = 50000           // Closed: Root relay + Profile handler + Room CloseAck/destroy (measured 6761 + 5633 + 4198)
const ACK_GAS = 20000              // part of CLOSE_GAS executed by the Room on CloseAck

const E_AUTH = 401
const E_STATE = 402
const E_VALUE = 403
const E_LIMIT = 404
const E_POLICY = 405
const E_FULL = 410
const E_SEATED = 411
const E_VERSION = 412
const E_PENDING = 413
const E_DEADLINE = 414
const ENTRY_TTL = 600
const RECEIPT_KEEP = 2000000

const PHASE_OPEN = 0
const PHASE_DRAWING = 1
const PHASE_CLOSING = 2

const EVENT_ACCEPTED = 1
const EVENT_CLOSED = 2
const EVENT_FAILED = 3

struct PolicyAddrs { investor: address? techFund: address }
struct Policy {
    paused: bool
    feePercent: uint8
    techBps: uint16
    partnerBps: uint16
    partnersEnabled: bool
    manualApproval: bool
    investorBps: uint16
    betMin: coins
    betMax: coins
    seatMargin: coins
    surplusToWinner: bool  // unspent technical quote: false = tech fund, true = winner
    addrs: Cell<PolicyAddrs>
}
// Hash/depth of the permanent-record codes, enough to derive their addresses.
struct CodeRefs { accountHash: uint256 accountDepth: uint16 profileHash: uint256 profileDepth: uint16 }
// Room terms, snapshotted at creation.
struct Terms {
    feePercent: uint8 techBps: uint16 partnerBps: uint16 partnersEnabled: bool investorBps: uint16
    seatMargin: coins surplusToWinner: bool owner: address name: cell addrs: Cell<PolicyAddrs> refs: Cell<CodeRefs>
}
struct VersionInfo { hash: uint256 depth: uint16 open: bool }
// latest = the version used for new rooms; versions keeps every published version forever.
struct RootStorage {
    owner: address policy: Cell<Policy> accountCode: cell profileHash: uint256 profileDepth: uint16
    latest: uint32 roomCode: cell versions: map<uint32, VersionInfo>
}

struct ProfileState {
    bound: bool referrer: address?
    tentative: address?                     // candidate of pending entry; ignored once a real affiliate is bound
    nextSeq: uint64 nextOp: uint64          // nextOp is assigned as Enter.queryId, unique per Profile
    slots: map<uint64, bool>
    pending: Cell<Enter>?                 // exactly one unconfirmed entry; constant storage
}
struct ProfileStorage { root: address wallet: address accountHash: uint256 accountDepth: uint16 state: Cell<ProfileState>? }

struct AccountState { paid: bool approved: bool enabled: bool customBps: uint16 credited: coins withdrawn: coins }
struct AccountStorage { root: address wallet: address profileHash: uint256 profileDepth: uint16 state: Cell<AccountState>? }

struct Receipt { queryId: uint64 partner: address? }
struct Seat { partner: address? bps: uint16 deposit: coins }
struct DrawState { fillBlockLt: uint64 entropy: uint256 hops: uint8 techCover: coins }
struct RoomState {
    phase: uint2 bet: coins capacity: uint8 isPrivate: bool count: uint8 version: uint32 createdAt: uint32
    buffer: coins creatorProfile: address terms: Cell<Terms> seats: map<address, Seat> draw: Cell<DrawState>?
    receipts: map<address, Receipt> receiptCount: uint8 creatorClosed: bool
}
struct RoomStorage { root: address creator: address seq: uint64 state: Cell<RoomState>? }

struct CreateParams { seq: uint64 version: uint32 bet: coins capacity: uint8 isPrivate: bool name: cell }
struct JoinTarget { creator: address seq: uint64 version: uint32 }

struct (0x7e570201) CreateRoom { queryId: uint64 version: uint32 bet: coins capacity: uint8 isPrivate: bool candidate: address? name: cell }
struct (0x7e570202) JoinRoom { queryId: uint64 creator: address seq: uint64 version: uint32 candidate: address? }
// Exactly one of join/create is set. A partner Account stamps registered/eligible/bps.
struct (0x7e570203) Enter {
    queryId: uint64 deadline: uint32 wallet: address first: bool partner: address?
    stamped: bool registered: bool eligible: bool bps: uint16 join: Cell<JoinTarget>? create: Cell<CreateParams>?
}
struct (0x7e570204) RoomInit {
    queryId: uint64 deadline: uint32 wallet: address first: bool partner: address? bps: uint16 version: uint32
    params: Cell<CreateParams> terms: Cell<Terms> creatorProfile: address
}
struct (0x7e570205) RoomEvent { kind: uint8 queryId: uint64 wallet: address partner: address? creator: address seq: uint64 version: uint32 }
struct (0x7e570206) Accepted { queryId: uint64 wallet: address partner: address? room: address }
struct (0x7e570207) Closed { seq: uint64 room: address wallet: address }
struct (0x7e570208) EnterFailed { original: cell }
struct (0x7e570209) InitFailed { queryId: uint64 seq: uint64 first: bool }
struct (0x7e57020a) Leave { }
struct (0x7e57020b) CloseAck { seq: uint64 }
struct (0x7e57020c) RetryClose { }
struct (0x7e57020d) Draw { }
struct (0x7e57020e) Credit { role: uint8 amount: coins }
struct (0x7e57020f) Withdraw { }
struct (0x7e570210) RegisterPartner { queryId: uint64 expectedManualApproval: bool }
// Two coins fields of real size (< 2^64 nanoGRAM) keep this under 1023 bits.
@overflow1023_policy("suppress")
struct (0x7e570211) PartnerInit { queryId: uint64 wallet: address approved: bool owner: address ownerAmount: coins investor: address? investorAmount: coins }
struct (0x7e570212) SetPartner { wallet: address approved: bool enabled: bool customBps: uint16 }
struct (0x7e570213) PartnerPolicy { approved: bool enabled: bool customBps: uint16 excessTo: address }
struct (0x7e570214) SetPolicy { policy: Cell<Policy> }
struct (0x7e570215) PublishVersion { version: uint32 code: cell }
struct (0x7e570216) SetVersionOpen { version: uint32 open: bool }
struct (0x7e570217) QueryBinding { queryId: uint64 }
struct (0x7e570218) BindingInfo { queryId: uint64 wallet: address bound: bool referrer: address? tentative: address? firstOpen: uint16 }
struct (0x7e570219) TopUp { }
struct (0x7e57021a) RecoverEntry { roomCode: cell }
struct (0x7e57021b) RecoverEnter { original: Cell<Enter> roomCode: cell excessTo: address }
struct (0x7e57021c) ProbeEntry { original: Cell<Enter> excessTo: address }
struct (0x7e57021d) EntryAbsent { queryId: uint64 wallet: address }
struct (0x7e57021e) ReceiptAck { queryId: uint64 wallet: address }
struct (0x7e57021f) RetryReceipt { wallet: address }

// Representation hash of StateInit{code, data} computed from the code hash and depth only
// (d1 = 2 refs, d2 = 1 for 5 data bits "00110" + completion tag), so retired code needs no storage.
fun stateInitHash(codeHash: uint256, codeDepth: int, data: cell): uint256 {
    return beginCell().storeUint(0x020134, 24).storeUint(codeDepth, 16).storeUint(data.depth(), 16)
        .storeUint(codeHash, 256).storeUint(data.hash(), 256).endCell().beginParse().bitsHash();
}
fun addressOf(codeHash: uint256, codeDepth: int, data: cell): address {
    return address.fromWorkchainAndHash(0, stateInitHash(codeHash, codeDepth, data));
}
fun profileData(root: address, wallet: address, accountHash: uint256, accountDepth: int): cell {
    return ProfileStorage { root, wallet, accountHash, accountDepth, state: null }.toCell();
}
fun accountData(root: address, wallet: address, profileHash: uint256, profileDepth: int): cell {
    return AccountStorage { root, wallet, profileHash, profileDepth, state: null }.toCell();
}
fun roomData(root: address, creator: address, seq: uint64): cell {
    return RoomStorage { root, creator, seq, state: null }.toCell();
}
fun profileAt(root: address, wallet: address, r: CodeRefs): address {
    return addressOf(r.profileHash, r.profileDepth, profileData(root, wallet, r.accountHash, r.accountDepth));
}
fun accountAt(root: address, wallet: address, r: CodeRefs): address {
    return addressOf(r.accountHash, r.accountDepth, accountData(root, wallet, r.profileHash, r.profileDepth));
}

fun reserveExact(amount: coins) {
    reserveGramsOnBalance(amount, RESERVE_MODE_EXACT_AMOUNT | RESERVE_MODE_BOUNCE_ON_ACTION_FAIL);
}
fun comment(text: string): cell { return beginCell().storeUint(0, 32).storeString(text).endCell(); }
fun payPlain(to: address, amount: coins, text: string) {
    createMessage({ dest: to, value: amount, bounce: BounceMode.NoBounce, body: comment(text) })
        .send(SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
}

fun noteFwd(): coins { return calculateForwardFee(0, 1200, 3); }
fun creditGasFee(): coins { return calculateGasFee(0, CREDIT_GAS); }
// Value of the Accepted notice of a first stake (Room -> Root -> Profile).
fun noteValue(): coins { return calculateGasFee(0, NOTE_GAS) + 3 * noteFwd(); }
// Value carried by the Closed notice (Room -> Root -> Profile -> CloseAck -> Room).
fun closeNoteValue(): coins { return calculateGasFee(0, CLOSE_GAS - ACK_GAS) + 3 * noteFwd(); }
// What the Room keeps after closing until CloseAck: its own ack gas and the destroy message.
fun ackKeep(): coins { return calculateGasFee(0, ACK_GAS) + noteFwd(); }
fun closeCost(): coins { return closeNoteValue() + ackKeep(); }
fun joinCost(): coins { return calculateGasFee(0, JOIN_GAS); }
fun rentQuote(seconds: int): coins { return calculateStorageFee(0, seconds, ROOM_BITS, ROOM_CELLS); }
// Creator-paid buffer of an open Room: prepaid rent horizon plus the closing protocol.
fun roomBuffer(): coins { return rentQuote(RENT_HORIZON) + closeCost(); }
// Budget of the draw: the filling entry's extra gas, the Draw self message, the draw transaction, N+5 messages, credits.
fun settleCost(n: int): coins {
    return calculateGasFee(0, FILL_GAS) + calculateGasFee(0, SETTLE_GAS_BASE + n * SETTLE_GAS_SEAT) + noteFwd()
        + (n + 5) * noteFwd() + (n + 2) * creditGasFee();
}
// The same for every seat: own entry gas, an equal share of the draw budget, the margin.
fun seatPrice(n: int, margin: coins): coins {
    return joinCost() + (settleCost(n) + n - 1) / n + margin;
}
fun validatePolicy(p: Policy) {
    assert (p.feePercent >= 1 && p.feePercent <= 10 && p.techBps <= 2000 && p.partnerBps <= 10000
        && p.investorBps <= 10000 && p.betMin > 0 && p.betMax >= p.betMin && p.seatMargin <= 50000000) throw E_POLICY;
    val a = p.addrs.load();
    assert (a.investor != null || p.investorBps == 0) throw E_POLICY;
}

// Forwarding and bounce headroom, repriced from the current network config.
fun entryRouteBudget(): coins { return calculateGasFee(0, 70000) + 6 * calculateForwardFee(0, 4000, 25); }
fun recoveryBudget(): coins { return calculateGasFee(0, 100000) + 6 * calculateForwardFee(0, 16000, 260); }

struct (0x7e57f201) ProfileSnapshot { storage: Cell<ProfileStorage> }
struct (0x7e57f202) AccountSnapshot { storage: Cell<AccountStorage> }
struct (0x7e57f203) RoomSnapshot { storage: Cell<RoomStorage> }
struct (0x7e57f204) RoomSettled { winner: address amount: coins storage: Cell<RoomStorage> }
