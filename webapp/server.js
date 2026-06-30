// ============================================================
// Trading Bot Web Server — Local Only
// ============================================================
// Flow per user:
//   1. Enter API Key + Secret → Generate Kite login URL
//   2. OAuth callback → Exchange token → Store in session
//   3. Dashboard: Profile loaded, config form shown
//   4. Start Bot → In-process trading engine connects Kite WS
//   5. SSE streams live ticks/candles/signals to browser
//   6. Stop Bot → Disconnect WS, clear state
// ============================================================
require('dotenv').config();
const express = require('express');
const session = require('express-session');
const crypto = require('crypto');
const axios = require('axios');
const WebSocket = require('ws');
const path = require('path');
const fs = require('fs');
const { spawn } = require('child_process');

const app = express();
const PORT = process.env.PORT || 8080;

// ── Session with secure defaults ──
const sessionSecret = process.env.SESSION_SECRET || crypto.randomBytes(32).toString('hex');
app.use(session({
    secret: sessionSecret,
    resave: false,
    saveUninitialized: false,
    cookie: { secure: false, httpOnly: true, maxAge: 12 * 60 * 60 * 1000 }
}));
app.use(express.json());
app.use(express.urlencoded({ extended: true }));
app.use(express.static(path.join(__dirname, 'public')));

const KITE_BASE_URL = 'https://api.kite.trade';

// ── Local token persistence (accesstoken.json) ──
const TOKEN_FILE = path.join(__dirname, '..', 'accesstoken.json');

function saveTokenToFile(userId, userName, apiKey, accessToken) {
    const data = {
        user_id: userId,
        user_name: userName || userId,
        api_key: apiKey,
        access_token: accessToken,
        saved_at: new Date().toISOString()
    };
    fs.writeFileSync(TOKEN_FILE, JSON.stringify(data, null, 2));
    console.log(`Token saved to ${TOKEN_FILE}`);
}

function loadTokenFromFile() {
    try {
        if (!fs.existsSync(TOKEN_FILE)) return null;
        const data = JSON.parse(fs.readFileSync(TOKEN_FILE, 'utf8'));
        if (!data.access_token || !data.api_key) return null;
        return data;
    } catch { return null; }
}

async function isTokenValid(apiKey, accessToken) {
    try {
        const r = await axios.get(`${KITE_BASE_URL}/user/profile`, {
            headers: { 'X-Kite-Version': '3', 'Authorization': `token ${apiKey}:${accessToken}` }
        });
        return r.data.status === 'success' ? r.data.data : null;
    } catch { return null; }
}

// ══════════════════════════════════════════════════════════════
// Per-user bot instances: userId → TradingBot
// ══════════════════════════════════════════════════════════════
const activeBots = new Map();
// Per-user SSE clients: userId → Set<res>
const sseClients = new Map();

function sha256(data) {
    return crypto.createHash('sha256').update(data).digest('hex');
}

function sanitizeId(userId) {
    return userId.replace(/[^a-zA-Z0-9-]/g, '-').substring(0, 50);
}

function kiteHeaders(apiKey, accessToken) {
    return { 'X-Kite-Version': '3', 'Authorization': `token ${apiKey}:${accessToken}` };
}

// ── Broadcast SSE to all clients of a user ──
function broadcastSSE(userId, event, data) {
    const clients = sseClients.get(userId);
    if (!clients) return;
    const payload = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
    for (const res of clients) {
        try { res.write(payload); } catch { clients.delete(res); }
    }
}

// ── Trade history file persistence ──
const TRADES_DIR = path.join(__dirname, 'data');
function tradesFilePath(userId) {
    return path.join(TRADES_DIR, `trades-${sanitizeId(userId)}.json`);
}
function loadTradesFromFile(userId) {
    try {
        const fp = tradesFilePath(userId);
        if (fs.existsSync(fp)) return JSON.parse(fs.readFileSync(fp, 'utf8'));
    } catch {}
    return [];
}
function saveTradeToFile(userId, trade) {
    try {
        if (!fs.existsSync(TRADES_DIR)) fs.mkdirSync(TRADES_DIR, { recursive: true });
        const fp = tradesFilePath(userId);
        const trades = loadTradesFromFile(userId);
        trade.id = trades.length + 1;
        trades.push(trade);
        fs.writeFileSync(fp, JSON.stringify(trades, null, 2));
    } catch (e) { console.error('Failed to save trade:', e.message); }
}

// ══════════════════════════════════════════════════════════════
// KITE BINARY TICK PARSER (mirrors KiteData.psm1)
// ══════════════════════════════════════════════════════════════
function readInt16BE(buf, pos) { return (buf[pos] << 8) | buf[pos + 1]; }
function readInt32BE(buf, pos) {
    return ((buf[pos] << 24) | (buf[pos + 1] << 16) | (buf[pos + 2] << 8) | buf[pos + 3]) >>> 0;
}
function toSigned32(v) { return v > 0x7FFFFFFF ? v - 0x100000000 : v; }

function parseTicks(data) {
    if (data.length < 4) return [];
    const count = readInt16BE(data, 0);
    const ticks = [];
    let off = 2;
    for (let i = 0; i < count; i++) {
        if (off + 2 > data.length) break;
        const size = readInt16BE(data, off); off += 2;
        if (off + size > data.length) break;
        const token = readInt32BE(data, off);
        const tick = { instrumentToken: token };
        if (size >= 8)  tick.lastPrice = toSigned32(readInt32BE(data, off + 4)) / 100;
        if (size >= 44) {
            tick.dayHigh  = toSigned32(readInt32BE(data, off + 8))  / 100;
            tick.dayLow   = toSigned32(readInt32BE(data, off + 12)) / 100;
            tick.dayClose = toSigned32(readInt32BE(data, off + 16)) / 100;
            tick.dayOpen  = toSigned32(readInt32BE(data, off + 20)) / 100;
            tick.volume   = readInt32BE(data, off + 28);
        }
        if (size >= 184) tick.openInterest = readInt32BE(data, off + 44);
        ticks.push(tick); off += size;
    }
    return ticks;
}

// ══════════════════════════════════════════════════════════════
// HEIKIN-ASHI + CANDLE BUILDING
// ══════════════════════════════════════════════════════════════
function convertToHA(raw, prevHA) {
    const c = (raw.open + raw.high + raw.low + raw.close) / 4;
    const o = prevHA ? (prevHA.open + prevHA.close) / 2 : (raw.open + raw.close) / 2;
    const h = Math.max(raw.high, o, c);
    const l = Math.min(raw.low, o, c);
    return { open: o, high: h, low: l, close: c };
}

// ── Index & Symbol Configs (mirror KiteData.psm1) ──
const INDEX_CONFIGS = {
    NIFTY:      { tradingsymbol: 'NIFTY 50',          token: 256265, spotKey: 'NSE:NIFTY 50',          kw: 'NIFTY',      lot: 75, exchange: 'NFO', optExchange: 'NFO' },
    BANKNIFTY:  { tradingsymbol: 'NIFTY BANK',        token: 260105, spotKey: 'NSE:NIFTY BANK',        kw: 'BANKNIFTY',  lot: 15, exchange: 'NFO', optExchange: 'NFO' },
    FINNIFTY:   { tradingsymbol: 'NIFTY FIN SERVICE', token: 257801, spotKey: 'NSE:NIFTY FIN SERVICE', kw: 'FINNIFTY',   lot: 40, exchange: 'NFO', optExchange: 'NFO' },
    MIDCPNIFTY: { tradingsymbol: 'NIFTY MID SELECT',  token: 288009, spotKey: 'NSE:NIFTY MID SELECT',  kw: 'MIDCPNIFTY', lot: 75, exchange: 'NFO', optExchange: 'NFO' },
    SENSEX:     { tradingsymbol: 'SENSEX',             token: 265,    spotKey: 'BSE:SENSEX',             kw: 'SENSEX',     lot: 20, exchange: 'BFO', optExchange: 'BFO' },
};

const SYMBOL_PRESETS = {
    NIFTY: 256265, NIFTY50: 256265, BANKNIFTY: 260105, FINNIFTY: 257801, MIDCPNIFTY: 288009, SENSEX: 265,
    RELIANCE: 738561, TCS: 2953217, INFY: 408065, HDFCBANK: 341249, ICICIBANK: 1270529, SBIN: 779521,
    TATAMOTORS: 884737, ITC: 424961, WIPRO: 969473, BHARTIARTL: 2714625,
};

function getIntervalSeconds(tf) {
    const m = { '5second':5,'15second':15,'30second':30,'minute':60,'2minute':120,'3minute':180,'4minute':240,'5minute':300,'10minute':600,'15minute':900,'30minute':1800,'60minute':3600 };
    return m[tf] || 60;
}

function getTimeBucket(intSec) {
    const n = new Date();
    // Use IST (UTC+5:30)
    const utcMs = n.getTime() + n.getTimezoneOffset() * 60000;
    const ist = new Date(utcMs + 5.5 * 3600000);
    const total = ist.getHours() * 3600 + ist.getMinutes() * 60 + ist.getSeconds();
    const b = Math.floor(total / intSec) * intSec;
    const hh = String(Math.floor(b / 3600)).padStart(2, '0');
    const mm = String(Math.floor((b % 3600) / 60)).padStart(2, '0');
    const ss = String(b % 60).padStart(2, '0');
    return `${ist.getFullYear()}-${String(ist.getMonth()+1).padStart(2,'0')}-${String(ist.getDate()).padStart(2,'0')} ${hh}:${mm}:${ss}`;
}

function nowIST() {
    const n = new Date();
    return new Date(n.getTime() + n.getTimezoneOffset() * 60000 + 5.5 * 3600000);
}

// ── Fetch option chain instruments from Kite ──
async function fetchOptions(optExchange, underlying, optType, headers) {
    const r = await axios.get(`${KITE_BASE_URL}/instruments/${optExchange}`, { headers, responseType: 'text' });
    const lines = r.data.split('\n').slice(1).filter(l => l.length > 10);
    const opts = [];
    for (const line of lines) {
        const c = line.split(',');
        if (c.length < 12) continue;
        const name = c[3].replace(/"/g, '').trim();
        const type = c[9].replace(/"/g, '').trim();
        if (name === underlying && type === optType) {
            opts.push({ token: +c[0], symbol: c[2].replace(/"/g,'').trim(), expiry: c[5].replace(/"/g,'').trim(), strike: +c[6], lotSize: +c[8], type });
        }
    }
    const today = new Date().toISOString().split('T')[0];
    const expiries = [...new Set(opts.map(o => o.expiry))].sort();
    const nearest = expiries.find(e => e >= today);
    if (!nearest) return null;
    const filtered = opts.filter(o => o.expiry === nearest);
    return { options: filtered, strikes: [...new Set(filtered.map(o => o.strike))].sort((a,b) => a-b), expiry: nearest };
}

function getATMOption(spot, options, strikes, offset = 0) {
    const s = [...strikes].sort((a,b) => a-b);
    const atm = s.reduce((p, c) => Math.abs(c-spot) < Math.abs(p-spot) ? c : p);
    let idx = s.indexOf(atm) + offset;
    idx = Math.max(0, Math.min(idx, s.length - 1));
    return options.find(o => o.strike === s[idx]);
}

async function placeOrder(headers, type, p) {
    const body = new URLSearchParams({
        tradingsymbol: p.tradingsymbol, exchange: p.exchange, transaction_type: type,
        order_type: p.orderType || 'MARKET', quantity: String(p.quantity), product: p.product || 'NRML', validity: 'DAY'
    });
    if (p.marketProtection > 0) body.append('market_protection', String(p.marketProtection));
    if (p.tag) body.append('tag', p.tag);
    const r = await axios.post(`${KITE_BASE_URL}/orders/${p.variety || 'regular'}`, body.toString(), {
        headers: { ...headers, 'Content-Type': 'application/x-www-form-urlencoded' }
    });
    return r.data;
}

// ══════════════════════════════════════════════════════════════
// TRADING BOT ENGINE — One instance per user
// Mirrors Long-Short-Combined.ps1 logic exactly
// ══════════════════════════════════════════════════════════════
class TradingBot {
    constructor(userId, config, apiKey, accessToken) {
        this.userId = userId;
        this.config = config;
        this.apiKey = apiKey;
        this.accessToken = accessToken;
        this.headers = kiteHeaders(apiKey, accessToken);

        this.intSec = getIntervalSeconds(config.timeFrame);
        this.completedCandles = [];
        this.activeCandle = null;
        this.previousHA = null;
        this.tickCount = 0;

        this.direction = '';   // 'LONG' | 'SHORT' | ''
        this.entryPrice = 0;
        this.entryTime = '';
        this.optSymbol = '';
        this.optToken = 0;
        this.optStrike = 0;
        this.optEntryLTP = 0;
        this.optQty = 0;
        this.optType = '';

        this.signals = [];
        this.trades = [];
        this.totalPnL = 0;
        this.status = 'initializing';
        this.ws = null;
        this.logs = [];
        this._busy = false;
        this._reconnectTimer = null;

        this.ceData = null;
        this.peData = null;
        this.indexConfig = null;
        this.instrumentToken = 0;
        this.symbolLabel = '';
        this.quantity = 0;
        this.nearestExpiry = '';
    }

    log(msg, level = 'info') {
        const ts = nowIST().toISOString().replace('T', ' ').substring(0, 23);
        const entry = { ts, level, msg };
        this.logs.push(entry);
        if (this.logs.length > 1000) this.logs = this.logs.slice(-500);
        console.log(`[${this.userId}] ${msg}`);
        broadcastSSE(this.userId, 'log', entry);
    }

    async init() {
        const idxKey = this.config.indexChoosen.toUpperCase().replace('FINNIFTY', 'FINNIFTY');
        const map = { NIFTY: 'NIFTY', BANKNIFTY: 'BANKNIFTY', FINNIFTY: 'FINNIFTY', FINNIFTY: 'FINNIFTY', MIDCPNIFTY: 'MIDCPNIFTY', SENSEX: 'SENSEX' };
        const key = map[idxKey] || 'NIFTY';
        this.indexConfig = INDEX_CONFIGS[key];
        if (!this.indexConfig) throw new Error(`Unknown index: ${this.config.indexChoosen}`);

        this.quantity = this.indexConfig.lot * (this.config.noOfLots || 1);

        const sym = (this.config.tradingSymbol || 'NIFTY').toUpperCase();
        const token = this.config.instrumentToken > 0 ? this.config.instrumentToken : (SYMBOL_PRESETS[sym] || this.indexConfig.token);
        this.instrumentToken = token;
        this.symbolLabel = sym;

        this.log(`Fetching CE+PE instruments for ${this.indexConfig.kw}...`);
        const [ce, pe] = await Promise.all([
            fetchOptions(this.indexConfig.optExchange, this.indexConfig.kw, 'CE', this.headers),
            fetchOptions(this.indexConfig.optExchange, this.indexConfig.kw, 'PE', this.headers),
        ]);
        if (!ce || !pe) throw new Error('Failed to fetch option instruments');
        this.ceData = ce; this.peData = pe;
        this.nearestExpiry = ce.expiry;
        this.log(`Expiry: ${ce.expiry} | CE: ${ce.strikes.length} | PE: ${pe.strikes.length} | Lot: ${this.indexConfig.lot} | Qty: ${this.quantity}`);
        this.status = 'initialized';
    }

    async start() {
        await this.init();
        this._connectWS();
        this.status = 'running';
        this.log('Bot started — listening for ticks');
        broadcastSSE(this.userId, 'status', this.getSnapshot());
    }

    _connectWS() {
        const uri = `wss://ws.kite.trade?api_key=${this.apiKey}&access_token=${this.accessToken}`;
        this.ws = new WebSocket(uri, { headers: { 'X-Kite-Version': '3' } });

        this.ws.on('open', () => {
            this.log('WebSocket connected');
            const mode = this.config.fullMode ? 'full' : 'quote';
            this.ws.send(JSON.stringify({ a: 'subscribe', v: [this.instrumentToken] }));
            this.ws.send(JSON.stringify({ a: 'mode', v: [mode, [this.instrumentToken]] }));
            this.log(`Subscribed ${this.instrumentToken} (${mode})`);
        });

        this.ws.on('message', (data) => {
            if (typeof data === 'string') {
                try { const m = JSON.parse(data); if (m.type === 'error') this.log(`WS error: ${m.data}`, 'error'); } catch {}
                return;
            }
            const buf = Buffer.from(data);
            if (buf.length > 2) {
                for (const tick of parseTicks(buf)) {
                    if (tick.lastPrice > 0) this._onTick(tick);
                }
            }
        });

        this.ws.on('close', () => {
            this.log('WebSocket disconnected');
            if (this.status === 'running') {
                this._reconnectTimer = setTimeout(() => this._connectWS(), 5000);
            }
        });

        this.ws.on('error', (e) => this.log(`WS error: ${e.message}`, 'error'));
    }

    _onTick(tick) {
        this.tickCount++;
        const bucket = getTimeBucket(this.intSec);

        if (!this.activeCandle || this.activeCandle.bucket !== bucket) {
            if (this.activeCandle) {
                const ha = convertToHA(this.activeCandle, this.previousHA);
                this.previousHA = { ...ha };
                const completed = {
                    bucket: this.activeCandle.bucket,
                    open: +ha.open.toFixed(2), high: +ha.high.toFixed(2),
                    low: +ha.low.toFixed(2), close: +ha.close.toFixed(2),
                    volume: this.activeCandle.volume, ticks: this.activeCandle.tickCount
                };
                this.completedCandles.push(completed);
                broadcastSSE(this.userId, 'candle', completed);
            }
            this.activeCandle = {
                bucket, open: tick.lastPrice, high: tick.lastPrice, low: tick.lastPrice, close: tick.lastPrice,
                volume: 0, prevVol: tick.volume || 0,
                dayOpen: tick.dayOpen || 0, dayHigh: tick.dayHigh || 0, dayLow: tick.dayLow || 0, dayClose: tick.dayClose || 0,
                tickCount: 1
            };
        } else {
            const ac = this.activeCandle;
            ac.high = Math.max(ac.high, tick.lastPrice);
            ac.low  = Math.min(ac.low, tick.lastPrice);
            ac.close = tick.lastPrice;
            ac.tickCount++;
            if (tick.dayHigh > 0) ac.dayHigh = tick.dayHigh;
            if (tick.dayLow > 0) ac.dayLow = tick.dayLow;
            if (tick.volume > ac.prevVol && ac.prevVol > 0) ac.volume += tick.volume - ac.prevVol;
            ac.prevVol = tick.volume || 0;
        }

        // Broadcast live tick + active HA every 10 ticks (throttle)
        if (this.tickCount % 10 === 0 || this.tickCount < 5) {
            const liveHA = this.activeCandle ? convertToHA(this.activeCandle, this.previousHA) : null;
            broadcastSSE(this.userId, 'tick', {
                ltp: tick.lastPrice, volume: tick.volume, oi: tick.openInterest,
                dayO: tick.dayOpen, dayH: tick.dayHigh, dayL: tick.dayLow, dayC: tick.dayClose,
                tickCount: this.tickCount,
                liveHA: liveHA ? { o: +liveHA.open.toFixed(2), h: +liveHA.high.toFixed(2), l: +liveHA.low.toFixed(2), c: +liveHA.close.toFixed(2) } : null,
                bucket: this.activeCandle?.bucket,
                direction: this.direction,
                entryPrice: this.entryPrice,
                optSymbol: this.optSymbol,
                totalPnL: +this.totalPnL.toFixed(2)
            });
        }

        this._checkSignal(tick.lastPrice);
    }

    async _checkSignal(ltp) {
        if (this.completedCandles.length < 1 || !this.activeCandle || this._busy) return;
        const prev = this.completedCandles[this.completedCandles.length - 1];
        const liveHA = convertToHA(this.activeCandle, this.previousHA);

        const ist = nowIST();
        const [sH, sM, sS] = (this.config.startTime || '09:16:01').split(':').map(Number);
        const [eH, eM, eS] = (this.config.stopTime || '15:30:00').split(':').map(Number);
        const nowSec = ist.getHours() * 3600 + ist.getMinutes() * 60 + ist.getSeconds();
        const startSec = sH * 3600 + sM * 60 + (sS || 0);
        const stopSec = eH * 3600 + eM * 60 + (eS || 0);

        if (nowSec < startSec || nowSec > stopSec) {
            if (nowSec >= stopSec && this.direction) {
                this.log('STOP TIME — Force exiting position');
                await this._exit(ltp);
            }
            return;
        }

        // LONG ENTRY
        if (!this.direction && liveHA.close > prev.high) {
            this.log(`*** LONG ENTRY *** LTP: ${ltp} | HA Close: ${liveHA.close.toFixed(2)} > Prev High: ${prev.high}`);
            await this._enter('LONG', ltp);
            return;
        }
        // SHORT ENTRY
        if (!this.direction && liveHA.close < prev.low) {
            this.log(`*** SHORT ENTRY *** LTP: ${ltp} | HA Close: ${liveHA.close.toFixed(2)} < Prev Low: ${prev.low}`);
            await this._enter('SHORT', ltp);
            return;
        }
        // LONG EXIT
        if (this.direction === 'LONG' && liveHA.close < prev.low) {
            this.log(`*** LONG EXIT *** LTP: ${ltp} | HA Close: ${liveHA.close.toFixed(2)} < Prev Low: ${prev.low}`);
            await this._exit(ltp);
            return;
        }
        // SHORT EXIT
        if (this.direction === 'SHORT' && liveHA.close > prev.high) {
            this.log(`*** SHORT EXIT *** LTP: ${ltp} | HA Close: ${liveHA.close.toFixed(2)} > Prev High: ${prev.high}`);
            await this._exit(ltp);
        }
    }

    async _enter(dir, spot) {
        if (this._busy) return;
        this._busy = true;
        try {
            const optType = dir === 'LONG' ? 'CE' : 'PE';
            const data = dir === 'LONG' ? this.ceData : this.peData;
            const offset = dir === 'LONG' ? -(this.config.atmOffset || 0) : (this.config.atmOffset || 0);
            const atm = getATMOption(spot, data.options, data.strikes, offset);
            if (!atm) { this.log(`No ATM ${optType} found`, 'error'); return; }

            let qty = this.quantity;
            // If amountToTrade specified, calculate lots from LTP
            if (this.config.amountToTrade > 0) {
                try {
                    const ek = encodeURIComponent(`${this.indexConfig.exchange}:${atm.symbol}`);
                    const qr = await axios.get(`${KITE_BASE_URL}/quote/ltp?i=${ek}`, { headers: this.headers });
                    for (const p of Object.values(qr.data.data)) {
                        if (p.last_price > 0) {
                            const lots = Math.max(1, Math.floor(this.config.amountToTrade / (p.last_price * this.indexConfig.lot)));
                            qty = lots * this.indexConfig.lot;
                            this.optEntryLTP = p.last_price;
                        }
                    }
                } catch {}
            }

            this.log(`${optType} BUY | Strike: ${atm.strike} | Symbol: ${atm.symbol} | Qty: ${qty}`);
            const result = await placeOrder(this.headers, 'BUY', {
                tradingsymbol: atm.symbol, quantity: qty,
                orderType: this.config.orderType || 'MARKET', product: this.config.product || 'NRML',
                exchange: this.indexConfig.exchange, variety: this.config.variety || 'regular',
                marketProtection: this.config.marketProtection || 2, tag: `${optType}-ENTRY`
            });

            if (result?.status === 'success') {
                this.direction = dir; this.entryPrice = spot; this.entryTime = nowIST().toISOString();
                this.optSymbol = atm.symbol; this.optToken = atm.token; this.optStrike = atm.strike;
                this.optQty = qty; this.optType = optType;

                // Fetch actual option buy price if not already fetched
                if (!this.optEntryLTP || this.optEntryLTP === 0) {
                    try {
                        const ek = encodeURIComponent(`${this.indexConfig.exchange}:${atm.symbol}`);
                        const qr = await axios.get(`${KITE_BASE_URL}/quote/ltp?i=${ek}`, { headers: this.headers });
                        for (const p of Object.values(qr.data.data)) {
                            if (p.last_price > 0) this.optEntryLTP = p.last_price;
                        }
                    } catch {}
                }

                this.signals.push({ type: 'ENTRY', dir, spot, symbol: atm.symbol, strike: atm.strike, qty, optPrice: this.optEntryLTP, time: this.entryTime });
                broadcastSSE(this.userId, 'signal', this.signals[this.signals.length - 1]);
                broadcastSSE(this.userId, 'status', this.getSnapshot());
                this.log(`Position OPEN: ${dir} ${atm.symbol} Strike:${atm.strike} Qty:${qty} @ Spot:${spot} | Option BUY: ₹${this.optEntryLTP}`);
            } else {
                this.log(`Order failed: ${JSON.stringify(result)}`, 'error');
            }
        } catch (e) {
            this.log(`Entry error: ${e.message}`, 'error');
        } finally { this._busy = false; }
    }

    async _exit(ltp) {
        if (this._busy || !this.direction) return;
        this._busy = true;
        try {
            if (this.config.exitTrade === 'no') {
                this.log('ExitTrade=no — signal only, not closing');
                const pnl = this.direction === 'LONG' ? ltp - this.entryPrice : this.entryPrice - ltp;
                this.signals.push({ type: 'EXIT_SIGNAL', dir: this.direction, spot: ltp, pnl: +pnl.toFixed(2), time: nowIST().toISOString() });
                this.direction = '';
                return;
            }

            // Cancel stop losses first
            try {
                const ordResp = await axios.get(`${KITE_BASE_URL}/orders`, { headers: this.headers });
                const slOrders = (ordResp.data.data || []).filter(o =>
                    o.order_type === 'SL' && o.status === 'TRIGGER PENDING' && o.tradingsymbol === this.optSymbol
                );
                for (const sl of slOrders) {
                    try { await axios.delete(`${KITE_BASE_URL}/orders/regular/${sl.order_id}`, { headers: this.headers }); } catch {}
                }
            } catch {}

            this.log(`${this.optType} SELL | ${this.optSymbol} | Qty: ${this.optQty}`);
            await placeOrder(this.headers, 'SELL', {
                tradingsymbol: this.optSymbol, quantity: this.optQty,
                orderType: this.config.orderType || 'MARKET', product: this.config.product || 'NRML',
                exchange: this.indexConfig.exchange, variety: this.config.variety || 'regular',
                marketProtection: this.config.marketProtection || 2, tag: `${this.optType}-EXIT`
            });

            // Fetch option exit price (sell price)
            let optExitLTP = 0;
            try {
                const ek = encodeURIComponent(`${this.indexConfig.exchange}:${this.optSymbol}`);
                const qr = await axios.get(`${KITE_BASE_URL}/quote/ltp?i=${ek}`, { headers: this.headers });
                for (const p of Object.values(qr.data.data)) {
                    if (p.last_price > 0) optExitLTP = p.last_price;
                }
            } catch {}

            // P&L based on spot price movement (strategy signal)
            const pnl = this.direction === 'LONG' ? ltp - this.entryPrice : this.entryPrice - ltp;
            const pctPnL = this.entryPrice > 0 ? (pnl / this.entryPrice) * 100 : 0;
            this.totalPnL += pnl;

            // Option P&L (actual premium difference)
            const optBuy = this.optEntryLTP || 0;
            const optSell = optExitLTP || 0;
            const optPnL = (optSell - optBuy) * this.optQty;
            const optPnLPct = optBuy > 0 ? ((optSell - optBuy) / optBuy) * 100 : 0;

            this.signals.push({ type: 'EXIT', dir: this.direction, spot: ltp, symbol: this.optSymbol, pnl: +pnl.toFixed(2), totalPnL: +this.totalPnL.toFixed(2), optBuy, optSell, time: nowIST().toISOString() });
            broadcastSSE(this.userId, 'signal', this.signals[this.signals.length - 1]);

            // Record completed trade with option prices
            const trade = {
                id: this.trades.length + 1,
                direction: this.direction,
                symbol: this.optSymbol,
                strike: this.optStrike,
                qty: this.optQty,
                entryTime: this.entryTime,
                exitTime: nowIST().toISOString(),
                entrySpot: +this.entryPrice.toFixed(2),
                exitSpot: +ltp.toFixed(2),
                optBuyPrice: +optBuy.toFixed(2),
                optSellPrice: +optSell.toFixed(2),
                optPnL: +optPnL.toFixed(2),
                optPnLPct: +optPnLPct.toFixed(2),
                spotPnL: +pnl.toFixed(2),
                spotPnLPct: +pctPnL.toFixed(2),
                totalPnL: +this.totalPnL.toFixed(2)
            };
            this.trades.push(trade);
            saveTradeToFile(this.userId, trade);
            broadcastSSE(this.userId, 'trade', trade);

            this.log(`CLOSED | ${this.optSymbol} | Buy:₹${optBuy} Sell:₹${optSell} | Opt P&L: ₹${optPnL.toFixed(2)} (${optPnLPct.toFixed(2)}%) | Spot P&L: ${pnl.toFixed(2)} | Total: ${this.totalPnL.toFixed(2)}`);

            this.direction = ''; this.entryPrice = 0; this.entryTime = '';
            this.optSymbol = ''; this.optToken = 0; this.optStrike = 0; this.optEntryLTP = 0; this.optQty = 0; this.optType = '';
            broadcastSSE(this.userId, 'status', this.getSnapshot());
        } catch (e) {
            this.log(`Exit error: ${e.message}`, 'error');
        } finally { this._busy = false; }
    }

    getSnapshot() {
        const liveHA = this.activeCandle ? convertToHA(this.activeCandle, this.previousHA) : null;
        return {
            status: this.status, tickCount: this.tickCount,
            direction: this.direction, entryPrice: this.entryPrice, entryTime: this.entryTime,
            optSymbol: this.optSymbol, optStrike: this.optStrike, optType: this.optType, optQty: this.optQty,
            totalPnL: +this.totalPnL.toFixed(2),
            signals: this.signals.slice(-30),
            trades: this.trades,
            completedCandles: this.completedCandles.slice(-(this.config.candlesToShow || 15)),
            activeCandle: this.activeCandle,
            liveHA: liveHA ? { open: +liveHA.open.toFixed(2), high: +liveHA.high.toFixed(2), low: +liveHA.low.toFixed(2), close: +liveHA.close.toFixed(2) } : null,
            nearestExpiry: this.nearestExpiry, symbolLabel: this.symbolLabel, instrumentToken: this.instrumentToken,
            config: this.config, logs: this.logs.slice(-100)
        };
    }

    stop() {
        this.status = 'stopped';
        if (this._reconnectTimer) { clearTimeout(this._reconnectTimer); this._reconnectTimer = null; }
        if (this.ws) { try { this.ws.close(); } catch {} this.ws = null; }
        this.log('Bot stopped');
        broadcastSSE(this.userId, 'status', this.getSnapshot());
    }
}

// ══════════════════════════════════════════════════════════════
// ROUTES
// ══════════════════════════════════════════════════════════════

app.get('/', async (req, res) => {
    if (req.session.accessToken && req.session.userId) return res.redirect('/dashboard');
    // Try to restore from saved token file
    const saved = loadTokenFromFile();
    if (saved) {
        const profile = await isTokenValid(saved.api_key, saved.access_token);
        if (profile) {
            req.session.accessToken = saved.access_token;
            req.session.apiKey = saved.api_key;
            req.session.userId = saved.user_id || profile.user_id;
            console.log(`Auto-login from accesstoken.json: ${profile.user_name || saved.user_id}`);
            return res.redirect('/dashboard');
        }
    }
    res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

// Token status check (called by login page)
app.get('/api/token-status', async (req, res) => {
    const saved = loadTokenFromFile();
    if (!saved) return res.json({ valid: false, reason: 'No saved token' });
    const profile = await isTokenValid(saved.api_key, saved.access_token);
    if (profile) {
        return res.json({ valid: true, user: profile.user_name || saved.user_id, userId: profile.user_id || saved.user_id, savedAt: saved.saved_at });
    }
    return res.json({ valid: false, reason: 'Token expired' });
});

// Step 1: Accept API Key + Secret → Generate login URL
app.post('/api/login', (req, res) => {
    const { apiKey, apiSecret } = req.body;
    if (!apiKey || !apiSecret) return res.status(400).json({ error: 'API Key and Secret required' });
    req.session.apiKey = apiKey;
    req.session.apiSecret = apiSecret;
    res.json({ loginUrl: `https://kite.zerodha.com/connect/login?api_key=${encodeURIComponent(apiKey)}&v=3` });
});

// Step 2a: Manual token submission (user pastes request_token from redirect URL)
app.post('/api/set-token', async (req, res) => {
    let { requestToken, apiKey: bodyKey, apiSecret: bodySecret } = req.body;
    const apiKey = req.session.apiKey || bodyKey;
    const apiSecret = req.session.apiSecret || bodySecret;
    if (!requestToken || !apiKey || !apiSecret) return res.status(400).json({ error: 'Missing request token or credentials. Please start over.' });
    // Store in session in case they weren't there
    req.session.apiKey = apiKey;
    req.session.apiSecret = apiSecret;
    // Extract request_token from full URL if user pasted the entire redirect URL
    try { const u = new URL(requestToken); const t = u.searchParams.get('request_token'); if (t) requestToken = t; } catch (_) {}

    try {
        const checksum = sha256(apiKey + requestToken + apiSecret);
        const form = new URLSearchParams({ api_key: apiKey, request_token: requestToken, checksum });
        const r = await axios.post(`${KITE_BASE_URL}/session/token`, form.toString(), {
            headers: { 'X-Kite-Version': '3', 'Content-Type': 'application/x-www-form-urlencoded' }
        });
        if (r.data.status !== 'success') return res.json({ error: 'Token exchange failed' });

        const accessToken = r.data.data.access_token;
        const userId = r.data.data.user_id;
        const userName = r.data.data.user_name || userId;
        req.session.accessToken = accessToken;
        req.session.userId = userId;
        delete req.session.apiSecret;

        saveTokenToFile(userId, userName, apiKey, accessToken);
        console.log(`User ${userId} authenticated via manual token`);
        res.json({ success: true, userId });
    } catch (e) {
        console.error('Token exchange error:', e.response?.data || e.message);
        res.json({ error: e.response?.data?.message || 'Token exchange failed. Token may be expired.' });
    }
});

// Step 2: OAuth callback
app.get('/callback', async (req, res) => {
    const { request_token } = req.query;
    const { apiKey, apiSecret } = req.session;
    if (!request_token || !apiKey || !apiSecret) return res.redirect('/?error=missing_credentials');

    try {
        const checksum = sha256(apiKey + request_token + apiSecret);
        const form = new URLSearchParams({ api_key: apiKey, request_token, checksum });
        const r = await axios.post(`${KITE_BASE_URL}/session/token`, form.toString(), {
            headers: { 'X-Kite-Version': '3', 'Content-Type': 'application/x-www-form-urlencoded' }
        });
        if (r.data.status !== 'success') return res.redirect('/?error=login_failed');

        const accessToken = r.data.data.access_token;
        const userId = r.data.data.user_id;
        const userName = r.data.data.user_name || userId;
        req.session.accessToken = accessToken;
        req.session.userId = userId;
        delete req.session.apiSecret;

        saveTokenToFile(userId, userName, apiKey, accessToken);
        console.log(`User ${userId} authenticated`);
        res.redirect('/dashboard');
    } catch (e) {
        console.error('Auth error:', e.response?.data || e.message);
        res.redirect('/?error=auth_failed');
    }
});

app.get('/dashboard', async (req, res) => {
    // Try session first
    if (req.session.accessToken) return res.sendFile(path.join(__dirname, 'public', 'dashboard.html'));
    // Fallback: restore from saved token file
    const saved = loadTokenFromFile();
    if (saved) {
        const profile = await isTokenValid(saved.api_key, saved.access_token);
        if (profile) {
            req.session.accessToken = saved.access_token;
            req.session.apiKey = saved.api_key;
            req.session.userId = saved.user_id || profile.user_id;
            return res.sendFile(path.join(__dirname, 'public', 'dashboard.html'));
        }
    }
    res.redirect('/');
});

// Profile
app.get('/api/profile', async (req, res) => {
    if (!req.session.accessToken) return res.status(401).json({ error: 'Not logged in' });
    try {
        const r = await axios.get(`${KITE_BASE_URL}/user/profile`, { headers: kiteHeaders(req.session.apiKey, req.session.accessToken) });
        res.json(r.data.data);
    } catch (e) { res.status(500).json({ error: e.response?.data?.message || e.message }); }
});

// Positions
app.get('/api/positions', async (req, res) => {
    if (!req.session.accessToken) return res.status(401).json({ error: 'Not logged in' });
    try {
        const r = await axios.get(`${KITE_BASE_URL}/portfolio/positions`, { headers: kiteHeaders(req.session.apiKey, req.session.accessToken) });
        res.json(r.data.data);
    } catch (e) { res.status(500).json({ error: e.response?.data?.message || e.message }); }
});

// Orders
app.get('/api/orders', async (req, res) => {
    if (!req.session.accessToken) return res.status(401).json({ error: 'Not logged in' });
    try {
        const r = await axios.get(`${KITE_BASE_URL}/orders`, { headers: kiteHeaders(req.session.apiKey, req.session.accessToken) });
        res.json(r.data.data);
    } catch (e) { res.status(500).json({ error: e.response?.data?.message || e.message }); }
});

// ── SSE: Real-time stream per user ──
app.get('/api/stream', (req, res) => {
    if (!req.session.userId) return res.status(401).end();
    const uid = req.session.userId;

    res.writeHead(200, {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache',
        Connection: 'keep-alive',
        'X-Accel-Buffering': 'no'
    });
    res.write(':ok\n\n');

    if (!sseClients.has(uid)) sseClients.set(uid, new Set());
    sseClients.get(uid).add(res);

    // Send current state if bot is running
    const bot = activeBots.get(uid);
    if (bot) res.write(`event: status\ndata: ${JSON.stringify(bot.getSnapshot())}\n\n`);

    req.on('close', () => {
        const set = sseClients.get(uid);
        if (set) { set.delete(res); if (set.size === 0) sseClients.delete(uid); }
    });
});

// ── Start bot ──
// ── Per-user PS1 process tracking ──
const activeProcesses = new Map(); // userId → { proc, status }

app.post('/api/bot/start', async (req, res) => {
    if (!req.session.accessToken || !req.session.userId) return res.status(401).json({ error: 'Not logged in' });
    const uid = req.session.userId;

    // Stop existing process
    if (activeProcesses.has(uid)) {
        const prev = activeProcesses.get(uid);
        if (prev.proc && !prev.proc.killed) prev.proc.kill('SIGTERM');
        activeProcesses.delete(uid);
    }

    // Also stop in-process bot if any
    if (activeBots.has(uid)) { activeBots.get(uid).stop(); activeBots.delete(uid); }

    const config = req.body;

    // Write config to input.json
    const inputJsonPath = path.join(__dirname, '..', 'input.json');
    const inputData = {
        API_Key: req.session.apiKey,
        API_Secret: '',
        TradingSymbol: config.tradingSymbol || 'Nifty',
        InstrumentToken: config.instrumentToken || 0,
        TimeFrame: config.timeFrame || '30second',
        CandlesToShow: config.candlesToShow || 10,
        FullMode: config.fullMode === true || config.fullMode === 'true',
        IndexChoosen: config.indexChoosen || 'Nifty',
        NoOfLotsPurchaseAtaTime: config.noOfLots || 1,
        AmountToTrade: config.amountToTrade || 0,
        Product: config.product || 'NRML',
        StartTime: config.startTime || '09:16:01',
        StopTime: config.stopTime || '15:30:00',
        Order_type: config.orderType || 'MARKET',
        ModeOfTrading: config.modeOfTrading || 'Option_Buyer',
        ATMOffset: config.atmOffset || 1,
        Variety: config.variety || 'regular',
        MarketProtection: config.marketProtection || 2,
        ExitTrade: config.exitTrade || 'yes',
        SLCandlesLookback: config.slCandlesLookback || 1,
        SLTriggerOffset: config.slTriggerOffset || 0.5
    };

    // Read existing input.json to preserve API_Secret
    try {
        const existing = JSON.parse(fs.readFileSync(inputJsonPath, 'utf8'));
        if (existing.API_Secret) inputData.API_Secret = existing.API_Secret;
    } catch {}

    fs.writeFileSync(inputJsonPath, JSON.stringify(inputData, null, 4));
    console.log(`Config saved to input.json for user ${uid}`);

    // Spawn Long-Short-Combined.ps1
    const scriptPath = path.join(__dirname, '..', 'Long-Short-Combined.ps1');
    const proc = spawn('pwsh', ['-NoProfile', '-File', scriptPath, '-AccessToken', req.session.accessToken], {
        cwd: path.join(__dirname, '..'),
        env: { ...process.env },
        stdio: ['ignore', 'pipe', 'pipe']
    });

    const entry = { proc, status: 'running', startTime: new Date().toISOString(), logs: [] };
    activeProcesses.set(uid, entry);

    const logLine = (msg, level = 'info') => {
        const ts = new Date().toISOString().replace('T', ' ').substring(0, 23);
        const logEntry = { ts, level, msg: msg.trim() };
        entry.logs.push(logEntry);
        if (entry.logs.length > 500) entry.logs = entry.logs.slice(-300);
        broadcastSSE(uid, 'log', logEntry);
    };

    proc.stdout.on('data', (data) => {
        const raw = data.toString().replace(/\x1b\[[0-9;]*[A-Za-z]/g, '').replace(/\x1b\[\?[0-9;]*[A-Za-z]/g, '');
        const lines = raw.split('\n').filter(l => l.trim());
        for (const line of lines) logLine(line);
    });

    proc.stderr.on('data', (data) => {
        const raw = data.toString().replace(/\x1b\[[0-9;]*[A-Za-z]/g, '').replace(/\x1b\[\?[0-9;]*[A-Za-z]/g, '');
        const lines = raw.split('\n').filter(l => l.trim());
        for (const line of lines) logLine(line, 'error');
    });

    proc.on('close', (code) => {
        entry.status = 'stopped';
        logLine(`Process exited with code ${code}`, code === 0 ? 'info' : 'error');
        broadcastSSE(uid, 'status', { status: 'stopped' });
    });

    broadcastSSE(uid, 'status', { status: 'running' });
    broadcastSSE(uid, 'log', { ts: new Date().toISOString().replace('T', ' ').substring(0, 23), level: 'info', msg: 'Long-Short-Combined.ps1 started' });

    res.json({ success: true, message: 'Script started' });
});

// ── Stop bot ──
app.post('/api/bot/stop', (req, res) => {
    if (!req.session.userId) return res.status(401).json({ error: 'Not logged in' });
    const uid = req.session.userId;

    // Kill PS1 process
    const entry = activeProcesses.get(uid);
    if (entry && entry.proc && !entry.proc.killed) {
        entry.proc.kill('SIGTERM');
        entry.status = 'stopped';
    }
    activeProcesses.delete(uid);

    // Also stop in-process bot if any
    const bot = activeBots.get(uid);
    if (bot) { bot.stop(); activeBots.delete(uid); }

    res.json({ success: true });
});

// ── Bot state (poll fallback) ──
app.get('/api/bot/state', (req, res) => {
    if (!req.session.userId) return res.status(401).json({ error: 'Not logged in' });
    const entry = activeProcesses.get(req.session.userId);
    const bot = activeBots.get(req.session.userId);
    if (entry && entry.status === 'running') {
        return res.json({ status: 'running', logs: entry.logs.slice(-100) });
    }
    res.json(bot ? bot.getSnapshot() : { status: 'idle' });
});

// ── Trade history (persisted) ──
app.get('/api/bot/trades', (req, res) => {
    if (!req.session.userId) return res.status(401).json({ error: 'Not logged in' });
    const trades = loadTradesFromFile(req.session.userId);
    res.json(trades);
});

// ── Logout ──
app.get('/api/logout', (req, res) => {
    const uid = req.session.userId;
    if (uid && activeBots.has(uid)) { activeBots.get(uid).stop(); activeBots.delete(uid); }
    req.session.destroy();
    res.redirect('/');
});

app.get('/api/health', (req, res) => {
    res.json({ status: 'ok', users: activeBots.size, uptime: process.uptime() });
});

app.listen(PORT, () => {
    console.log(`Trading Bot server on port ${PORT} — local mode`);
});
