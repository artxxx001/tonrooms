// Copyright (c) 2026 TonRooms. All rights reserved.
// Source available for verification only.
// Permission is granted to inspect, audit and compile this source to verify
// TonRooms bytecode, and to host or reproduce it for that verification
// provided this notice is retained. No permission is granted to deploy or
// reuse this code in other projects. Third-party dependencies retain their licenses.

import "v2-types"
type AccountMessage = PartnerInit | PartnerPolicy | Enter | Credit | Withdraw | TopUp
contract V2Account { storage: AccountStorage incomingMessages: AccountMessage }

fun freshAccount(): AccountState {
    return AccountState { paid: false, approved: false, enabled: false, customBps: DEFAULT_BPS, credited: 0, withdrawn: 0 };
}
fun accountOf(s: AccountStorage, wallet: address): address {
    return addressOf(contract.getCode().hash(), contract.getCode().depth(), accountData(s.root, wallet, s.profileHash, s.profileDepth));
}
fun profileOf(s: AccountStorage, wallet: address): address {
    val code = contract.getCode();
    return addressOf(s.profileHash, s.profileDepth, profileData(s.root, wallet, code.hash(), code.depth()));
}
fun sendCredit(to: address, amount: coins, role: int) {
    createMessage({ dest: to, value: amount + creditGasFee(), bounce: BounceMode.NoBounce, body: Credit { role, amount } })
        .send(SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
}
fun save(mutate s: AccountStorage, st: AccountState) { s.state = st.toCell(); contract.setData(s.toCell()); createExternalLogMessage({dest: createAddressNone(), body: AccountSnapshot { storage: s.toCell() }}).send(SEND_MODE_REGULAR); }

// The balance above ACCOUNT_MIN is withdrawable by `wallet`. `credited` is raw inflow from any sender:
// recognised income is defined by authentic Room settlement messages (verified off-chain).
fun onInternalMessage(in: InMessage) {
    if (in.body.isEmpty()) { return; }
    val msg = lazy AccountMessage.fromSlice(in.body);
    var s = AccountStorage.fromCell(contract.getData());
    var st = s.state == null ? freshAccount() : s.state!.load();
    val prior = max(0, contract.getOriginalBalance() - in.valueCoins);
    match (msg) {
        PartnerInit => {
            assert (in.senderAddress == s.root && msg.wallet == s.wallet) throw E_AUTH;
            if (st.paid) {
                reserveExact(prior);
                createMessage({ dest: s.wallet, value: 0, bounce: BounceMode.NoBounce, body: comment("TonRooms.app: already registered") })
                    .send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
                return;
            }
            st.paid = true; st.approved = msg.approved; st.enabled = true;
            if (msg.ownerAmount > 0) { sendCredit(accountOf(s, msg.owner), msg.ownerAmount, 3); }
            if (msg.investor != null && msg.investorAmount > 0) { sendCredit(accountOf(s, msg.investor!), msg.investorAmount, 2); }
            save(mutate s, st);
            reserveExact(max(prior, ACCOUNT_MIN));
            createMessage({ dest: s.wallet, value: 0, bounce: BounceMode.NoBounce, body: comment("TonRooms.app: registration excess") })
                .send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
            return;
        }
        PartnerPolicy => {
            assert (in.senderAddress == s.root) throw E_AUTH;
            st.approved = msg.approved; st.enabled = msg.enabled; st.customBps = msg.customBps;
            save(mutate s, st);
            reserveExact(max(prior, ACCOUNT_MIN));
            createMessage({ dest: msg.excessTo, value: 0, bounce: BounceMode.NoBounce })
                .send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
            return;
        }
        Enter => {
            var e = msg;
            assert (!e.stamped && e.partner != null && e.partner! == s.wallet) throw E_AUTH;
            assert (in.senderAddress == profileOf(s, e.wallet)) throw E_AUTH;
            // New bindings require an approved, enabled partner. Existing Profile bindings remain immutable.
            e.stamped = true;
            e.registered = st.paid && st.approved && st.enabled;
            e.eligible = st.paid && st.approved && st.enabled;
            e.bps = e.eligible ? st.customBps : 0;
            reserveExact(prior);
            createMessage({ dest: s.root, value: 0, bounce: BounceMode.RichBounce, body: e })
                .send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
            return;
        }
        Credit => {
            st.credited += min(msg.amount, in.valueCoins);
        }
        Withdraw => {
            assert (in.senderAddress == s.wallet) throw E_AUTH;
            val available = contract.getOriginalBalance() - in.valueCoins - ACCOUNT_MIN;
            assert (available > 0) throw E_VALUE;
            st.withdrawn += available;
            save(mutate s, st);
            reserveExact(ACCOUNT_MIN);
            createMessage({ dest: s.wallet, value: 0, bounce: BounceMode.NoBounce, body: comment("TonRooms.app: income") })
                .send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
            return;
        }
        TopUp => { }
    }
    save(mutate s, st);
}

// A forwarded entry bounced at Root: return it to the player's Profile.
fun onBouncedMessage(in: InMessageBounced) {
    val rich = RichBounceBody.fromSlice(in.bouncedBody);
    if (rich.originalBody.beginParse().preloadUint(32) != 0x7e570203) { return; }
    val e = Enter.fromCell(rich.originalBody);
    val s = AccountStorage.fromCell(contract.getData());
    reserveExact(max(0, contract.getOriginalBalance() - in.valueCoins));
    createMessage({ dest: profileOf(s, e.wallet), value: 0, bounce: BounceMode.NoBounce, body: EnterFailed { original: rich.originalBody } })
        .send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
}
get fun get_account(): (bool, bool, bool, int, int, int) {
    val s = AccountStorage.fromCell(contract.getData());
    if (s.state == null) { return (false, false, false, DEFAULT_BPS, 0, 0); }
    val st = s.state!.load();
    return (st.paid, st.approved, st.enabled, st.customBps, st.credited, st.withdrawn);
}
