// Copyright (c) 2026 TonRooms. All rights reserved.
// Source available for verification only.
// Permission is granted to inspect, audit and compile this source to verify
// TonRooms bytecode, and to host or reproduce it for that verification
// provided this notice is retained. No permission is granted to deploy or
// reuse this code in other projects. Third-party dependencies retain their licenses.

import "v2-types"
type ProfileMessage = CreateRoom | JoinRoom | Accepted | EnterFailed | InitFailed | Closed | Withdraw | QueryBinding | TopUp | RecoverEntry | EntryAbsent
contract V2Profile { storage: ProfileStorage incomingMessages: ProfileMessage }
fun freshState(): ProfileState {
    return ProfileState { bound: false, referrer: null, tentative: null, nextSeq: 0, nextOp: 0, slots: createEmptyMap(), pending: null };
}
fun mapCount(m: map<uint64, bool>): int {
    var n = 0; var it = m.findFirst(); while (it.isFound) { n += 1; it = m.iterateNext(it); } return n;
}
fun myAccount(s: ProfileStorage, wallet: address): address {
    val code = contract.getCode();
    return addressOf(s.accountHash, s.accountDepth, accountData(s.root, wallet, code.hash(), code.depth()));
}
fun keepProfileMin() { reserveGramsOnBalance(PROFILE_MIN, RESERVE_MODE_AT_MOST | RESERVE_MODE_BOUNCE_ON_ACTION_FAIL); }
fun forwardEnter(s: ProfileStorage, e: Enter) {
    var dest = s.root;
    if (e.partner != null) { dest = myAccount(s, e.partner!); }
    keepProfileMin();
    createMessage({ dest, value: 0, bounce: BounceMode.RichBounce, body: e })
        .send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
}
fun refundWallet(s: ProfileStorage, text: string) {
    keepProfileMin();
    createMessage({ dest: s.wallet, value: 0, bounce: BounceMode.NoBounce, body: comment(text) })
        .send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
}
fun save(mutate s: ProfileStorage, st: ProfileState) { s.state = st.toCell(); contract.setData(s.toCell()); createExternalLogMessage({dest: createAddressNone(), body: ProfileSnapshot { storage: s.toCell() }}).send(SEND_MODE_REGULAR); }
fun failPending(mutate st: ProfileState, queryId: uint64) {
    if (st.pending == null) { return; }
    val p = st.pending!.load();
    if (p.queryId != queryId) { return; }
    if (p.create != null) { st.slots.delete(p.create!.load().seq); }
    st.pending = null; st.tentative = null;
}
fun candidateOf(s: ProfileStorage, st: ProfileState, candidate: address?): address? {
    if (st.bound) { return st.referrer; }
    if (candidate != null && candidate! == s.wallet) { return null; }
    return candidate;
}
fun onInternalMessage(in: InMessage) {
    if (in.body.isEmpty()) { return; }
    val msg = lazy ProfileMessage.fromSlice(in.body);
    var s = ProfileStorage.fromCell(contract.getData());
    var st = s.state == null ? freshState() : s.state!.load();
    match (msg) {
        CreateRoom => {
            assert (in.senderAddress == s.wallet) throw E_AUTH;
            assert (st.pending == null) throw E_PENDING;
            assert (mapCount(st.slots) < MAX_CREATED) throw E_LIMIT;
            assert (msg.capacity >= MIN_CAPACITY && msg.capacity <= MAX_CAPACITY && msg.bet > 0) throw E_POLICY;
            assert (in.valueCoins >= msg.bet + entryRouteBudget() + max(0, PROFILE_MIN - (contract.getOriginalBalance() - in.valueCoins))) throw E_VALUE;
            st.nextOp += 1; st.nextSeq += 1;
            val partner = candidateOf(s, st, msg.candidate);
            val e = Enter { queryId: st.nextOp, deadline: blockchain.now() + ENTRY_TTL, wallet: s.wallet, first: !st.bound, partner,
                stamped: false, registered: false, eligible: false, bps: 0, join: null,
                create: CreateParams { seq: st.nextSeq, version: msg.version, bet: msg.bet, capacity: msg.capacity, isPrivate: msg.isPrivate, name: msg.name }.toCell() };
            st.slots.set(st.nextSeq, true); st.pending = e.toCell(); st.tentative = partner;
            save(mutate s, st); forwardEnter(s, e); return;
        }
        JoinRoom => {
            assert (in.senderAddress == s.wallet) throw E_AUTH;
            assert (st.pending == null) throw E_PENDING;
            assert (in.valueCoins >= entryRouteBudget() + max(0, PROFILE_MIN - (contract.getOriginalBalance() - in.valueCoins))) throw E_VALUE;
            st.nextOp += 1;
            val partner = candidateOf(s, st, msg.candidate);
            val e = Enter { queryId: st.nextOp, deadline: blockchain.now() + ENTRY_TTL, wallet: s.wallet, first: !st.bound, partner,
                stamped: false, registered: false, eligible: false, bps: 0,
                join: JoinTarget { creator: msg.creator, seq: msg.seq, version: msg.version }.toCell(), create: null };
            st.pending = e.toCell(); st.tentative = partner;
            save(mutate s, st); forwardEnter(s, e); return;
        }
        Accepted => {
            assert (in.senderAddress == s.root && msg.wallet == s.wallet) throw E_AUTH;
            if (st.pending != null && st.pending!.load().queryId == msg.queryId) {
                // Only an accepted stake with a real affiliate finalizes attribution.
                // Ordinary play leaves the profile open to a future invitation.
                // The matching receipt guard above also prevents a delayed older
                // acceptance from clearing/replacing a newer pending operation.
                if (!st.bound && msg.partner != null) { st.bound = true; st.referrer = msg.partner; }
                st.pending = null; st.tentative = null;
            }
            // Duplicate receipts receive ACK without altering another pending operation.
            assert (msg.queryId <= st.nextOp) throw E_STATE;
            save(mutate s, st);
            createMessage({ dest: msg.room, value: 0, bounce: BounceMode.NoBounce, body: ReceiptAck { queryId: msg.queryId, wallet: s.wallet } })
                .send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
            return;
        }
        EntryAbsent => {
            assert (in.senderAddress == s.root && msg.wallet == s.wallet) throw E_AUTH;
            failPending(mutate st, msg.queryId);
            save(mutate s, st); refundWallet(s, "TonRooms.app: recovery excess"); return;
        }
        RecoverEntry => {
            // Caller pays. The requested entry is taken from stored state, not from caller input.
            assert (st.pending != null) throw E_STATE;
            assert (blockchain.now() > st.pending!.load().deadline) throw E_DEADLINE;
            assert (in.valueCoins >= recoveryBudget()) throw E_VALUE;
            createMessage({ dest: s.root, value: 0, bounce: BounceMode.RichBounce,
                body: RecoverEnter { original: st.pending!, roomCode: msg.roomCode, excessTo: in.senderAddress } })
                .send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
            return;
        }
        EnterFailed => {
            val e = Enter.fromCell(msg.original);
            assert (e.wallet == s.wallet && (in.senderAddress == s.root
                || (e.partner != null && in.senderAddress == myAccount(s, e.partner!)))) throw E_AUTH;
            failPending(mutate st, e.queryId);
            save(mutate s, st); refundWallet(s, "TonRooms.app: entry refund"); return;
        }
        InitFailed => {
            assert (in.senderAddress == s.root) throw E_AUTH;
            failPending(mutate st, msg.queryId);
            save(mutate s, st); refundWallet(s, "TonRooms.app: entry refund"); return;
        }
        Closed => {
            assert (in.senderAddress == s.root && msg.wallet == s.wallet) throw E_AUTH;
            st.slots.delete(msg.seq); save(mutate s, st);
            createMessage({ dest: msg.room, value: 0, bounce: BounceMode.RichBounce, body: CloseAck { seq: msg.seq } })
                .send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
            return;
        }
        Withdraw => {
            assert (in.senderAddress == s.wallet) throw E_AUTH;
            refundWallet(s, "TonRooms.app: profile balance"); return;
        }
        QueryBinding => {
            createMessage({ dest: in.senderAddress, value: 0, bounce: BounceMode.NoBounce,
                body: BindingInfo { queryId: msg.queryId, wallet: s.wallet, bound: st.bound, referrer: st.referrer,
                    tentative: st.tentative, firstOpen: st.pending == null ? 0 : 1 } })
                .send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS);
            return;
        }
        TopUp => { }
    }
    save(mutate s, st);
}
fun onBouncedMessage(in: InMessageBounced) {
    val rich = RichBounceBody.fromSlice(in.bouncedBody);
    if (rich.originalBody.beginParse().preloadUint(32) != 0x7e570203) { return; }
    var e = Enter.fromCell(rich.originalBody);
    var s = ProfileStorage.fromCell(contract.getData());
    if (s.state == null || e.wallet != s.wallet) { return; }
    var st = s.state!.load();
    if (e.partner != null && in.senderAddress == myAccount(s, e.partner!) && rich.bouncedByPhase == 0 && rich.exitCode == -1
        && st.pending != null && st.pending!.load().queryId == e.queryId && blockchain.now() <= e.deadline) {
        e.partner = null; st.tentative = null; st.pending = e.toCell();
        save(mutate s, st); forwardEnter(s, e); return;
    }
    if (in.senderAddress != s.root && (e.partner == null || in.senderAddress != myAccount(s, e.partner!))) { return; }
    failPending(mutate st, e.queryId);
    save(mutate s, st); refundWallet(s, "TonRooms.app: entry refund");
}
get fun get_profile(): (bool, address?, int, int, address?, int) {
    val s = ProfileStorage.fromCell(contract.getData());
    if (s.state == null) { return (false, null, 0, 0, null, 0); }
    val st = s.state!.load();
    return (st.bound, st.referrer, mapCount(st.slots), st.pending == null ? 0 : 1, st.tentative, st.nextSeq);
}
get fun get_pending(): Cell<Enter>? { val s = ProfileStorage.fromCell(contract.getData()); return s.state == null ? null : s.state!.load().pending; }
get fun get_slot(seq: int): bool { val s = ProfileStorage.fromCell(contract.getData()); return s.state != null && s.state!.load().slots.exists(seq); }
get fun get_entry_route_budget(): int { return entryRouteBudget(); }
get fun get_recovery_budget(): int { return recoveryBudget(); }
