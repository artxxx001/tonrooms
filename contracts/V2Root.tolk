// Copyright (c) 2026 TonRooms. All rights reserved.
// Source available for verification only.
// Permission is granted to inspect, audit and compile this source to verify
// TonRooms bytecode, and to host or reproduce it for that verification
// provided this notice is retained. No permission is granted to deploy or
// reuse this code in other projects. Third-party dependencies retain their licenses.

import "v2-types"
import "@stdlib/gas-payments"
type RootMessage = Enter | RoomEvent | RegisterPartner | SetPartner | SetPolicy | PublishVersion | SetVersionOpen | TopUp | RecoverEnter
contract V2Root { storage: RootStorage incomingMessages: RootMessage }

fun refsOf(s: RootStorage): CodeRefs {
    return CodeRefs { accountHash: s.accountCode.hash(), accountDepth: s.accountCode.depth(),
        profileHash: s.profileHash, profileDepth: s.profileDepth };
}
fun profileOf(s: RootStorage, wallet: address): address { return profileAt(contract.getAddress(), wallet, refsOf(s)); }
fun accountOf(s: RootStorage, wallet: address): address { return accountAt(contract.getAddress(), wallet, refsOf(s)); }
// Address of a Room of any version ever published (open or not): history is never deleted.
fun roomOf(s: RootStorage, creator: address, seq: uint64, version: uint32): address {
    val v = s.versions.mustGet(version, E_VERSION);
    return addressOf(v.hash, v.depth, roomData(contract.getAddress(), creator, seq));
}

fun onInternalMessage(in: InMessage) {
    if (in.body.isEmpty()) { return; }
    val msg = lazy RootMessage.fromSlice(in.body);
    var s = RootStorage.fromCell(contract.getData());
    // Every request pays for itself; Root never spends its own balance on users.
    val prior = contract.getOriginalBalance() - in.valueCoins;
    match (msg) {
        Enter => {
            var e = msg;
            assert (blockchain.now() <= e.deadline) throw E_DEADLINE;
            if (e.stamped) {
                assert (e.partner != null && in.senderAddress == accountOf(s, e.partner!)) throw E_AUTH;
            } else {
                assert (e.partner == null && in.senderAddress == profileOf(s, e.wallet)) throw E_AUTH;
            }
            val p = s.policy.load();
            assert (!p.paused) throw E_POLICY;
            // Admission is the policy snapshot point. A disabled program cannot
            // acquire a new player, including a join to a previously open Room.
            // Existing bindings and already forwarded entries keep their terms.
            if (!p.partnersEnabled && e.first) {
                e.partner = null; e.stamped = false; e.registered = false;
                e.eligible = false; e.bps = 0;
            }
            reserveExact(prior);
            if (e.join != null) {
                assert (e.create == null) throw E_STATE;
                val j = e.join!.load();
                // Only NEW entries depend on the version being open.
                assert (s.versions.mustGet(j.version, E_VERSION).open) throw E_VERSION;
                createMessage({ dest: roomOf(s, j.creator, j.seq, j.version), value: 0, bounce: BounceMode.RichBounce, body: e })
                    .send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
                return;
            }
            assert (e.create != null) throw E_STATE;
            val q = e.create!.load();
            assert (q.version == s.latest) throw E_VERSION;
            assert (q.name.beginParse().remainingRefsCount() == 0 && q.name.beginParse().remainingBitsCount() > 0 && q.name.beginParse().remainingBitsCount() <= 640) throw E_POLICY;
            assert (q.bet >= p.betMin && q.bet <= p.betMax && q.capacity >= MIN_CAPACITY && q.capacity <= MAX_CAPACITY) throw E_POLICY;
            var partner: address? = null; var bps: uint16 = 0;
            if (e.stamped && e.registered) { partner = e.partner; bps = e.eligible ? e.bps : 0; }
            val terms = Terms { feePercent: p.feePercent, techBps: p.techBps, partnerBps: p.partnerBps,
                partnersEnabled: p.partnersEnabled, investorBps: p.investorBps, seatMargin: p.seatMargin,
                surplusToWinner: p.surplusToWinner, owner: s.owner, name: q.name, addrs: p.addrs, refs: refsOf(s).toCell() };
            createMessage({ dest: { stateInit: { code: s.roomCode, data: roomData(contract.getAddress(), e.wallet, q.seq) } },
                value: 0, bounce: BounceMode.RichBounce,
                body: RoomInit { queryId: e.queryId, deadline: e.deadline, wallet: e.wallet, first: e.first, partner, bps, version: s.latest,
                    params: e.create!, terms: terms.toCell(), creatorProfile: profileOf(s, e.wallet) } })
                .send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
        }
        RoomEvent => {
            // Authentic only if the sender is the Room derived from a published version.
            assert (in.senderAddress == roomOf(s, msg.creator, msg.seq, msg.version)) throw E_AUTH;
            if (msg.kind == EVENT_ACCEPTED) {
                createMessage({ dest: profileOf(s, msg.wallet), value: 0, bounce: BounceMode.RichBounce,
                    body: Accepted { queryId: msg.queryId, wallet: msg.wallet, partner: msg.partner, room: in.senderAddress } })
                    .send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
                return;
            }
            if (msg.kind == EVENT_FAILED) {
                createMessage({ dest: profileOf(s, msg.wallet), value: 0, bounce: BounceMode.RichBounce,
                    body: EntryAbsent { queryId: msg.queryId, wallet: msg.wallet } })
                    .send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
                return;
            }
            assert (msg.kind == EVENT_CLOSED) throw E_STATE;
            createMessage({ dest: profileOf(s, msg.creator), value: 0, bounce: BounceMode.RichBounce,
                body: Closed { seq: msg.seq, room: in.senderAddress, wallet: msg.creator } })
                .send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
        }
        RecoverEnter => {
            val e = msg.original.load();
            assert (in.senderAddress == profileOf(s, e.wallet) && blockchain.now() > e.deadline) throw E_AUTH;
            var creator = e.wallet; var seq: uint64 = 0; var version: uint32 = 0;
            if (e.create != null) { val q = e.create!.load(); seq = q.seq; version = q.version; }
            else { val q = e.join!.load(); creator = q.creator; seq = q.seq; version = q.version; }
            val v = s.versions.mustGet(version, E_VERSION);
            assert (msg.roomCode.hash() == v.hash && msg.roomCode.depth() == v.depth) throw E_VERSION;
            reserveExact(prior);
            createMessage({ dest: { stateInit: { code: msg.roomCode, data: roomData(contract.getAddress(), creator, seq) } },
                value: 0, bounce: BounceMode.RichBounce, body: ProbeEntry { original: msg.original, excessTo: msg.excessTo } })
                .send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
            return;
        }
        RegisterPartner => {
            val p = s.policy.load(); val a = p.addrs.load();
            assert (msg.expectedManualApproval == p.manualApproval) throw E_POLICY;
            assert (p.partnersEnabled) throw E_POLICY;
            assert (in.valueCoins >= 1000000000 + ACCOUNT_MIN + 3 * noteValue()) throw E_VALUE;
            var investorAmount: coins = 0;
            if (a.investor != null) { investorAmount = 1000000000 * p.investorBps / 10000; }
            reserveExact(prior);
            val r = refsOf(s);
            createMessage({ dest: { stateInit: { code: s.accountCode,
                    data: accountData(contract.getAddress(), in.senderAddress, r.profileHash, r.profileDepth) } },
                value: 0, bounce: BounceMode.RichBounce,
                body: PartnerInit { queryId: msg.queryId, wallet: in.senderAddress, approved: !p.manualApproval, owner: s.owner,
                    ownerAmount: 1000000000 - investorAmount, investor: a.investor, investorAmount } })
                .send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
        }
        SetPartner => {
            assert (in.senderAddress == s.owner && (msg.customBps <= 10000 || msg.customBps == DEFAULT_BPS)) throw E_AUTH;
            reserveExact(prior);
            createMessage({ dest: accountOf(s, msg.wallet), value: 0, bounce: BounceMode.NoBounce,
                body: PartnerPolicy { approved: msg.approved, enabled: msg.enabled, customBps: msg.customBps, excessTo: s.owner } })
                .send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
        }
        SetPolicy => {
            assert (in.senderAddress == s.owner) throw E_AUTH;
            validatePolicy(msg.policy.load()); s.policy = msg.policy;
            contract.setData(s.toCell());
        }
        PublishVersion => {
            // A published number is never reassigned to other code.
            assert (in.senderAddress == s.owner && msg.version > s.latest) throw E_VERSION;
            s.versions.set(msg.version, VersionInfo { hash: msg.code.hash(), depth: msg.code.depth(), open: true });
            s.latest = msg.version; s.roomCode = msg.code;
            contract.setData(s.toCell());
        }
        SetVersionOpen => {
            assert (in.senderAddress == s.owner && (msg.open || msg.version != s.latest)) throw E_VERSION;
            var v = s.versions.mustGet(msg.version, E_VERSION); v.open = msg.open;
            s.versions.set(msg.version, v);
            contract.setData(s.toCell());
        }
        TopUp => { }
    }
}

// Bounced flags cannot be forged, so a bounce is always a reply to a message Root itself sent:
// the refund route never depends on the (mutable) set of open versions.
fun onBouncedMessage(in: InMessageBounced) {
    val rich = RichBounceBody.fromSlice(in.bouncedBody);
    val op = rich.originalBody.beginParse().preloadUint(32);
    val s = RootStorage.fromCell(contract.getData());
    reserveExact(contract.getOriginalBalance() - in.valueCoins);
    if (op == 0x7e570203) {
        val e = Enter.fromCell(rich.originalBody);
        createMessage({ dest: profileOf(s, e.wallet), value: 0, bounce: BounceMode.NoBounce, body: EnterFailed { original: rich.originalBody } })
            .send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
        return;
    }
    if (op == 0x7e570204) {
        val init = RoomInit.fromCell(rich.originalBody);
        createMessage({ dest: profileOf(s, init.wallet), value: 0, bounce: BounceMode.NoBounce,
            body: InitFailed { queryId: init.queryId, seq: init.params.load().seq, first: init.first } })
            .send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
        return;
    }
    // A notice the Profile could not process, or a failed partner deployment: the value goes to the wallet.
    var wallet: address? = null;
    if (op == 0x7e570206) { wallet = Accepted.fromCell(rich.originalBody).wallet; }
    if (op == 0x7e570207) { wallet = Closed.fromCell(rich.originalBody).wallet; }
    if (op == 0x7e570211) { wallet = PartnerInit.fromCell(rich.originalBody).wallet; }
    if (wallet != null) {
        createMessage({ dest: wallet!, value: 0, bounce: BounceMode.NoBounce, body: comment("TonRooms.app: undelivered notice") })
            .send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
    }
}
get fun get_policy(): cell { return RootStorage.fromCell(contract.getData()).policy; }
get fun get_room_version(): int { return RootStorage.fromCell(contract.getData()).latest; }
get fun get_version(version: int): (int, int, bool) {
    val v = RootStorage.fromCell(contract.getData()).versions.mustGet(version, E_VERSION);
    return (v.hash, v.depth, v.open);
}
get fun get_profile_address(wallet: address): address { return profileOf(RootStorage.fromCell(contract.getData()), wallet); }
get fun get_account_address(wallet: address): address { return accountOf(RootStorage.fromCell(contract.getData()), wallet); }
get fun get_room_address(creator: address, seq: int, version: int): address {
    return roomOf(RootStorage.fromCell(contract.getData()), creator, seq, version);
}
get fun get_code_refs(): cell { return refsOf(RootStorage.fromCell(contract.getData())).toCell(); }

get fun get_storage(): RootStorage { return RootStorage.fromCell(contract.getData()); }
get fun get_create_quote(capacity: int): (int, int, int) { assert (capacity >= 2 && capacity <= 10) throw E_POLICY; val p = RootStorage.fromCell(contract.getData()).policy.load(); return (seatPrice(capacity, p.seatMargin) + noteValue() + entryRouteBudget(), roomBuffer(), PROFILE_MIN); }

get fun get_rent_quote(seconds: int): int { assert (seconds >= 0 && seconds <= 3153600000) throw E_VALUE; return rentQuote(seconds); }

get fun get_root_rent_quote(seconds: int): int { assert (seconds >= 0 && seconds <= 3153600000) throw E_VALUE; return calculateStorageFee(0, seconds, 300000, 600); }

// The fee remains 1 GRAM; execution follows live network tariffs.
get fun get_registration_quote(): (int, int, int) { return (1000000000, ACCOUNT_MIN, 3 * noteValue() + entryRouteBudget()); }
