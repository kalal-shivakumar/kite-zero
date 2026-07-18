// ============================================================
// Daily P&L validation
// ------------------------------------------------------------
// 1. Unit-tests the BUY/SELL order-pairing P&L math (same logic
//    as server.js computeRealizedFromOrders) across several days.
// 2. Validates the "last N days" slice logic.
// 3. Seeds webapp/data/daily-pnl-<userId>.json with multi-day
//    sample data so the dashboard chart can be visually verified.
//
// Run:  node webapp/test-daily-pnl.js
//       node webapp/test-daily-pnl.js --no-seed   (tests only)
// ============================================================
const fs = require('fs');
const path = require('path');

// ── Mirror of server.js computeRealizedFromOrders (F&O only: NFO/BFO) ──
function computeRealizedFromOrders(orders) {
    const FNO = new Set(['NFO', 'BFO']);
    const completed = (orders || []).filter(o => o.status === 'COMPLETE' && FNO.has(o.exchange));
    const buys  = completed.filter(o => o.transaction_type === 'BUY').sort((a, b) => new Date(a.order_timestamp) - new Date(b.order_timestamp));
    const sells = completed.filter(o => o.transaction_type === 'SELL').sort((a, b) => new Date(a.order_timestamp) - new Date(b.order_timestamp));
    const used = new Set();
    let pnl = 0, trades = 0, wins = 0, losses = 0;
    for (const buy of buys) {
        const sell = sells.find(s => s.tradingsymbol === buy.tradingsymbol && !used.has(s.order_id) && new Date(s.order_timestamp) >= new Date(buy.order_timestamp));
        if (!sell) continue;
        used.add(sell.order_id);
        const p = (+sell.average_price - +buy.average_price) * (+buy.quantity);
        pnl += p; trades++;
        if (p > 0) wins++; else if (p < 0) losses++;
    }
    return { pnl: +pnl.toFixed(2), trades, wins, losses };
}

let pass = 0, fail = 0;
function assert(name, cond, extra) {
    if (cond) { pass++; console.log('  \u2713', name); }
    else { fail++; console.log('  \u2717', name, extra != null ? '\u2192 ' + JSON.stringify(extra) : ''); }
}
function ord(sym, side, price, qty, ts, status = 'COMPLETE', exchange = 'NFO') {
    return { tradingsymbol: sym, transaction_type: side, average_price: price, quantity: qty, order_timestamp: ts, exchange, order_id: `${sym}-${side}-${ts}-${Math.random().toString(36).slice(2, 7)}`, status };
}

console.log('\n=== computeRealizedFromOrders unit tests ===');

// Test 1 — one profitable round trip
(() => {
    const o = [ord('NIFTY24800CE', 'BUY', 100, 75, '2026-07-06 09:20:00'), ord('NIFTY24800CE', 'SELL', 120, 75, '2026-07-06 10:00:00')];
    const r = computeRealizedFromOrders(o);
    assert('profitable pair pnl = +1500', r.pnl === 1500, r);
    assert('profitable pair trades = 1, wins = 1', r.trades === 1 && r.wins === 1 && r.losses === 0, r);
})();

// Test 2 — one losing round trip
(() => {
    const o = [ord('BANKNIFTY51000PE', 'BUY', 200, 15, '2026-07-07 09:30:00'), ord('BANKNIFTY51000PE', 'SELL', 150, 15, '2026-07-07 11:00:00')];
    const r = computeRealizedFromOrders(o);
    assert('losing pair pnl = -750', r.pnl === -750, r);
    assert('losing pair losses = 1', r.losses === 1 && r.wins === 0, r);
})();

// Test 3 — multiple pairs in a day net out
(() => {
    const o = [
        ord('A', 'BUY', 100, 50, '2026-07-08 09:20:00'), ord('A', 'SELL', 110, 50, '2026-07-08 09:40:00'), // +500
        ord('B', 'BUY', 80, 100, '2026-07-08 10:20:00'), ord('B', 'SELL', 70, 100, '2026-07-08 10:40:00'),  // -1000
    ];
    const r = computeRealizedFromOrders(o);
    assert('two pairs net pnl = -500', r.pnl === -500, r);
    assert('two pairs trades = 2 (1 win, 1 loss)', r.trades === 2 && r.wins === 1 && r.losses === 1, r);
})();

// Test 4 — unpaired BUY (still-open position) is ignored
(() => {
    const o = [ord('OPEN', 'BUY', 100, 75, '2026-07-09 09:20:00')];
    const r = computeRealizedFromOrders(o);
    assert('open position ignored (trades = 0)', r.trades === 0 && r.pnl === 0, r);
})();

// Test 5 — SELL earlier than BUY must NOT pair
(() => {
    const o = [ord('X', 'SELL', 120, 75, '2026-07-10 09:10:00'), ord('X', 'BUY', 100, 75, '2026-07-10 09:20:00')];
    const r = computeRealizedFromOrders(o);
    assert('sell-before-buy not paired (trades = 0)', r.trades === 0, r);
})();

// Test 6 — non-COMPLETE orders excluded
(() => {
    const o = [ord('R', 'BUY', 100, 75, '2026-07-13 09:20:00', 'REJECTED'), ord('R', 'SELL', 130, 75, '2026-07-13 10:20:00', 'CANCELLED')];
    const r = computeRealizedFromOrders(o);
    assert('rejected/cancelled excluded (trades = 0)', r.trades === 0, r);
})();

// Test 7 — non-F&O (NSE equity) excluded, only F&O counted
(() => {
    const o = [
        ord('RELIANCE', 'BUY', 2900, 10, '2026-07-14 09:20:00', 'COMPLETE', 'NSE'),  // equity — must be ignored
        ord('RELIANCE', 'SELL', 3000, 10, '2026-07-14 10:20:00', 'COMPLETE', 'NSE'), // +1000 equity, ignored
        ord('NIFTY24800CE', 'BUY', 100, 75, '2026-07-14 09:30:00', 'COMPLETE', 'NFO'),
        ord('NIFTY24800CE', 'SELL', 110, 75, '2026-07-14 10:30:00', 'COMPLETE', 'NFO'), // +750 F&O
    ];
    const r = computeRealizedFromOrders(o);
    assert('equity excluded, only F&O pnl = +750', r.pnl === 750 && r.trades === 1, r);
})();

// Test 8 — BSE F&O (BFO) is included
(() => {
    const o = [ord('SENSEX80000CE', 'BUY', 200, 20, '2026-07-15 09:20:00', 'COMPLETE', 'BFO'), ord('SENSEX80000CE', 'SELL', 250, 20, '2026-07-15 10:20:00', 'COMPLETE', 'BFO')];
    const r = computeRealizedFromOrders(o);
    assert('BFO (BSE F&O) included pnl = +1000', r.pnl === 1000 && r.trades === 1, r);
})();

// ── "Last N days" slice logic (same as endpoint) ──
console.log('\n=== last-N-days slice tests ===');
function lastNDays(history, days) {
    const keys = Object.keys(history).filter(k => /^\d{4}-\d{2}-\d{2}$/.test(k)).sort();
    return keys.slice(-days).map(k => ({ date: k, ...history[k] }));
}
(() => {
    const h = {
        '2026-07-01': { pnl: 100 }, '2026-07-02': { pnl: -50 }, '2026-07-03': { pnl: 200 },
        '2026-07-06': { pnl: -300 }, '2026-07-07': { pnl: 75 }, 'garbage': { pnl: 9 },
    };
    const r5 = lastNDays(h, 5);
    assert('slice returns 5 valid days (garbage filtered)', r5.length === 5, r5.map(x => x.date));
    assert('slice is chronological', r5[0].date === '2026-07-01' && r5[4].date === '2026-07-07', r5.map(x => x.date));
    const r3 = lastNDays(h, 3);
    assert('last 3 days = 03,06,07', r3.map(x => x.date).join(',') === '2026-07-03,2026-07-06,2026-07-07', r3.map(x => x.date));
})();

console.log(`\n=== RESULT: ${pass} passed, ${fail} failed ===`);

// ── Seed multi-day history file for visual verification ──
if (!process.argv.includes('--no-seed')) {
    const tokFile = path.join(__dirname, '..', 'accesstoken.json');
    let userId = 'DEMO';
    try { userId = JSON.parse(fs.readFileSync(tokFile, 'utf8')).user_id || userId; } catch {}
    const sanitize = id => id.replace(/[^a-zA-Z0-9-]/g, '-').substring(0, 50);
    const dataDir = path.join(__dirname, 'data');
    const seedFile = path.join(dataDir, `daily-pnl-${sanitize(userId)}.json`);

    // Build the last 12 trading days (skip Sat/Sun) with varied sample P&L
    const samples = [4200, -1800, 6100, 900, -3400, 5200, -650, 3100, 2750, -2200, 7400, 1500];
    const history = {};
    const d = new Date();
    let i = 0;
    while (Object.keys(history).length < samples.length) {
        const dow = d.getDay();
        if (dow !== 0 && dow !== 6) {
            const key = d.toISOString().substring(0, 10);
            const pnl = samples[i++];
            const trades = 2 + (i % 4);
            history[key] = { pnl, trades, wins: pnl >= 0 ? trades : Math.max(0, trades - 2), losses: pnl < 0 ? trades : 0, updated: new Date().toISOString() };
        }
        d.setDate(d.getDate() - 1);
    }

    if (!fs.existsSync(dataDir)) fs.mkdirSync(dataDir, { recursive: true });
    fs.writeFileSync(seedFile, JSON.stringify(history, null, 2));
    console.log(`\nSeeded ${Object.keys(history).length} days into ${seedFile}`);
    console.log('Sample (chronological):');
    for (const k of Object.keys(history).sort()) {
        const v = history[k];
        console.log(`  ${k}  ${v.pnl >= 0 ? '+' : ''}${v.pnl}  (${v.trades} trades)`);
    }
    console.log('\nRefresh the dashboard \u2192 Daily P&L card to verify the bars.');
}

process.exit(fail > 0 ? 1 : 0);
