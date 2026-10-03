// US equity market gate shared by every keeper that anchors to, or trades at, the Chainlink stock price
// (review r12 M1: the Arc oracle keeps a frozen Friday-close price Live for up to maxSourceAge = 26h, so an
// automated keeper must not act on it). A keeper may act only when BOTH hold:
//   1. the session is open by the built-in NYSE calendar (weekends, full-day holidays, the evening session that
//      belongs to a holiday, and anything outside the table are closed — fail closed), and
//   2. the feed's updatedAt is no older than the Chainlink heartbeat + a margin (a frozen feed in an "open"
//      session is treated as closed and alerted: the calendar or the feed is wrong).
//
// Sources (read 2026-10-01):
//   - Holidays / early closes: NYSE "Holidays & Trading Hours", https://www.nyse.com/markets/hours-calendars
//   - Session: Chainlink us_equities_24/5 market hours, "18:00 ET Sunday to 17:00 ET Friday", not on US market
//     holidays (docs.chain.link, Selecting data feeds); RH stock feeds: threshold 0.5%, heartbeat 86400 s
//     (Chainlink feeds-robinhood-mainnet.json, see docs/ORACLE-PUSH-r8.md).
// Pre/post-market (design choice): RH stock tokens and their Chainlink feeds run 24/5, so the default '24/5' mode
// treats the overnight / pre / post sessions as open (the price there is live, not frozen). 'regular' restricts
// to 09:30-16:00 ET (13:00 on early-close days) for operators who want only the primary session. Early-close days
// keep the 24/5 close at 17:00 ET (NYSE: late trading sessions still close at 17:00 on those days).
// The table ends with 2027: from 2028-01-01 every gate is closed until it is extended (calendarExpired).

export const NYSE_HOLIDAYS = Object.freeze([
  '2026-01-01', '2026-01-19', '2026-02-16', '2026-04-03', '2026-05-25', '2026-06-19', '2026-07-03', '2026-09-07', '2026-11-26', '2026-12-25',
  '2027-01-01', '2027-01-18', '2027-02-15', '2027-03-26', '2027-05-31', '2027-06-18', '2027-07-05', '2027-09-06', '2027-11-25', '2027-12-24',
]);
export const NYSE_EARLY_CLOSES = Object.freeze(['2026-11-27', '2026-12-24', '2027-11-26']);
export const CALENDAR_FIRST = '2026-01-01';
export const CALENDAR_LAST = '2027-12-31';

export const MARKET_DEFAULTS = Object.freeze({
  mode: '24/5',
  heartbeatSec: 86_400, // Chainlink RH stock feeds
  heartbeatMarginSec: 1_800,
  holidays: NYSE_HOLIDAYS,
  earlyCloses: NYSE_EARLY_CLOSES,
});

const NY = new Intl.DateTimeFormat('en-US', { timeZone: 'America/New_York', weekday: 'short', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' });
const DOW = { Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 };

export function nyTime(nowSec) {
  const parts = Object.fromEntries(NY.formatToParts(new Date(nowSec * 1000)).map(p => [p.type, p.value]));
  return { dow: DOW[parts.weekday], minute: Number(parts.hour) * 60 + Number(parts.minute), date: `${parts.year}-${parts.month}-${parts.day}` };
}

// Calendar-date arithmetic on YYYY-MM-DD (UTC noon avoids DST edges).
const nextDate = date => new Date(Date.parse(`${date}T12:00:00Z`) + 86_400_000).toISOString().slice(0, 10);
const dowOf = date => new Date(Date.parse(`${date}T12:00:00Z`)).getUTCDay();

/// Is the session open at nowSec? Returns { open, reason, tradingDate, calendarExpired }.
/// 24/5: from 17:00 ET a moment belongs to the NEXT date's session (Sunday 18:00 opens Monday's), so the evening
/// before a holiday is closed and the holiday evening reopens for the following trading day.
export function sessionState(nowSec, params = {}) {
  const p = { ...MARKET_DEFAULTS, ...params };
  const t = nyTime(nowSec);
  if (t.date < CALENDAR_FIRST || t.date > CALENDAR_LAST) {
    return { open: false, reason: `outside the built-in NYSE calendar (${CALENDAR_FIRST}..${CALENDAR_LAST}): extend lib/market.mjs`, calendarExpired: true };
  }
  const holidays = new Set(p.holidays);
  if (p.mode === 'regular') {
    if (t.dow === 0 || t.dow === 6) return { open: false, reason: 'weekend' };
    if (holidays.has(t.date)) return { open: false, reason: `NYSE holiday ${t.date}` };
    const close = p.earlyCloses.includes(t.date) ? 13 * 60 : 16 * 60;
    if (t.minute < 9 * 60 + 30 || t.minute >= close) return { open: false, reason: `outside regular hours (09:30-${close / 60}:00 ET)` };
    return { open: true, reason: 'regular session', tradingDate: t.date };
  }
  if (p.mode !== '24/5') throw new Error(`market mode ${p.mode} (24/5 | regular)`);
  const tradingDate = t.minute >= 17 * 60 ? nextDate(t.date) : t.date;
  const tdow = dowOf(tradingDate);
  if (tdow === 0 || tdow === 6) return { open: false, reason: 'weekend (Fri 17:00 ET - Sun 18:00 ET)' };
  if (t.dow === 0 && t.minute < 18 * 60) return { open: false, reason: 'weekend (opens Sun 18:00 ET)' };
  if (holidays.has(tradingDate)) return { open: false, reason: `NYSE holiday ${tradingDate}` };
  return { open: true, reason: '24/5 session', tradingDate };
}

/// Chainlink updatedAt no older than heartbeat + margin (a timestamp slightly ahead of us counts as fresh).
export function feedFresh(sourceUpdatedAt, nowSec, params = {}) {
  const p = { ...MARKET_DEFAULTS, ...params };
  const updated = Number(sourceUpdatedAt ?? 0);
  const age = updated > 0 ? Math.max(0, nowSec - updated) : Infinity;
  const limit = p.heartbeatSec + p.heartbeatMarginSec;
  return { fresh: age <= limit, ageSec: age, limitSec: limit };
}

/// Combined gate. { ok, closed, alert, reason }: closed = routine session close (observe only, no incident);
/// alert = abnormal (open session but frozen feed, or the calendar ran out).
export function marketGate({ nowSec, sourceUpdatedAt, params = {} }) {
  const s = sessionState(nowSec, params);
  if (!s.open) return { ok: false, closed: true, alert: Boolean(s.calendarExpired), reason: `market closed: ${s.reason}` };
  const f = feedFresh(sourceUpdatedAt, nowSec, params);
  if (!f.fresh) {
    const h = Number.isFinite(f.ageSec) ? (f.ageSec / 3600).toFixed(1) : 'inf';
    return { ok: false, closed: false, alert: true, reason: `Chainlink update ${h}h old, older than heartbeat + margin (${f.limitSec / 3600}h) in an open session` };
  }
  return { ok: true, closed: false, alert: false, reason: s.reason };
}
