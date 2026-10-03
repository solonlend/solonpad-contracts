// Event source of the oracle keeper. Two paths feed the same onLogs callback; neither carries state the keeper
// relies on (a log only means "re-read now"):
//   - WebSocket eth_subscribe("logs") on RH, reconnecting with backoff (1s, 2s, ... 60s); a ping that gets no
//     pong within pingMs terminates the socket so a half-open connection cannot hang the keeper.
//   - HTTP catch-up: eth_getLogs from the last block seen to head (chunked), on start, after every (re)connect
//     and every catchUpMs. Without a WS URL this is the only path (polling). Checked 2026-10-01: the public RH RPC
//     has no WebSocket (wss://rpc.mainnet.chain.robinhood.com/ws -> HTTP 404, /rpc and / -> HTTP 400).
import { backoffMs } from './decide.mjs';

export class LogWatcher {
  constructor({ http, wsUrl = null, WebSocketImpl = null, addresses, topics, onLogs, onConnect = () => {}, logger, maxRange = 50_000, initialLookback = 2_000, catchUpMs = 300_000, pingMs = 30_000, stableMs = 60_000, timers = { setTimeout, clearTimeout, setInterval, clearInterval } }) {
    Object.assign(this, { http, wsUrl, WebSocketImpl, addresses, topics, onLogs, onConnect, logger, maxRange, initialLookback, catchUpMs, pingMs, stableMs, timers });
    this.lastBlock = null; // highest block fully scanned over HTTP
    this.attempt = 0;
    this.ws = null;
    this.stopped = false;
    this.stats = { wsLogs: 0, catchUpLogs: 0, reconnects: 0, catchUps: 0 };
    this.catchingUp = null;
  }

  filter(fromBlock, toBlock) {
    return { address: this.addresses, topics: [this.topics], fromBlock, toBlock };
  }

  /// Scan (lastBlock, head]; single-flight. Returns the number of logs delivered.
  async catchUp() {
    if (this.catchingUp) return this.catchingUp;
    this.catchingUp = (async () => {
      const head = await this.http.getBlockNumber();
      let from = this.lastBlock == null ? Math.max(0, head - this.initialLookback) : this.lastBlock + 1;
      let n = 0;
      while (from <= head) {
        const to = Math.min(head, from + this.maxRange - 1);
        const logs = await this.http.getLogs(this.filter(from, to));
        this.lastBlock = to; // advance only after the range was read
        if (logs.length) { n += logs.length; await this.onLogs(logs, 'catchup'); }
        from = to + 1;
      }
      if (this.lastBlock == null || this.lastBlock < head) this.lastBlock = head;
      this.stats.catchUps++;
      this.stats.catchUpLogs += n;
      return n;
    })();
    try { return await this.catchingUp; } finally { this.catchingUp = null; }
  }

  async start() {
    await this.catchUp();
    this.catchTimer = this.timers.setInterval(() => this.catchUp().catch(e => this.logger?.warn(`catch-up failed: ${e?.message}`)), this.catchUpMs);
    if (this.wsUrl && this.WebSocketImpl) this.connect();
  }

  connect() {
    if (this.stopped) return;
    const ws = new this.WebSocketImpl(this.wsUrl);
    this.ws = ws;
    let alive = true;
    let openedAt = null;
    const id = 1;
    ws.on('open', () => {
      openedAt = Date.now();
      ws.send(JSON.stringify({ jsonrpc: '2.0', id, method: 'eth_subscribe', params: ['logs', { address: this.addresses, topics: [this.topics] }] }));
      this.pingTimer = this.timers.setInterval(() => {
        if (!alive) { this.logger?.warn('ws: no pong, terminating'); ws.terminate?.(); return; }
        alive = false;
        try { ws.ping?.(); } catch {}
      }, this.pingMs);
      // Anything emitted while we were away is picked up over HTTP.
      Promise.resolve(this.onConnect()).then(() => this.catchUp()).catch(e => this.logger?.warn(`catch-up after connect failed: ${e?.message}`));
    });
    ws.on('pong', () => { alive = true; });
    ws.on('message', raw => {
      alive = true;
      let m;
      try { m = JSON.parse(String(raw)); } catch { return; }
      if (m.id === id && m.error) { this.logger?.warn(`ws subscribe error: ${JSON.stringify(m.error).slice(0, 160)}`); ws.close?.(); return; }
      if (m.method === 'eth_subscription' && m.params?.result) {
        this.stats.wsLogs++;
        Promise.resolve(this.onLogs([m.params.result], 'ws')).catch(e => this.logger?.warn(`onLogs failed: ${e?.message}`));
      }
    });
    ws.on('error', e => this.logger?.warn(`ws error: ${e?.message}`));
    ws.on('close', () => {
      if (this.pingTimer) this.timers.clearInterval(this.pingTimer);
      if (this.stopped) return;
      if (openedAt && Date.now() - openedAt >= this.stableMs) this.attempt = 0;
      const delay = backoffMs(this.attempt++);
      this.stats.reconnects++;
      this.logger?.warn(`ws closed; reconnect in ${delay} ms`);
      this.reconnectTimer = this.timers.setTimeout(() => this.connect(), delay);
    });
  }

  stop() {
    this.stopped = true;
    for (const [t, clear] of [[this.catchTimer, 'clearInterval'], [this.pingTimer, 'clearInterval'], [this.reconnectTimer, 'clearTimeout']]) if (t) this.timers[clear](t);
    try { this.ws?.close?.(); } catch {}
  }
}
