import test from 'node:test';
import assert from 'node:assert/strict';
import { NYSE_HOLIDAYS, NYSE_EARLY_CLOSES, sessionState, feedFresh, marketGate, MARKET_DEFAULTS } from '../lib/market.mjs';

// New York is UTC-4 (EDT) until 2026-11-01, UTC-5 (EST) after.
const at = iso => Math.floor(Date.parse(iso) / 1000);

test('calendar: NYSE 2026-2027 full-day holidays and 13:00 early closes (nyse.com/markets/hours-calendars, read 2026-10-01)', () => {
  assert.deepEqual(NYSE_HOLIDAYS.filter(d => d.startsWith('2026')), ['2026-01-01', '2026-01-19', '2026-02-16', '2026-04-03', '2026-05-25', '2026-06-19', '2026-07-03', '2026-09-07', '2026-11-26', '2026-12-25']);
  assert.deepEqual(NYSE_HOLIDAYS.filter(d => d.startsWith('2027')), ['2027-01-01', '2027-01-18', '2027-02-15', '2027-03-26', '2027-05-31', '2027-06-18', '2027-07-05', '2027-09-06', '2027-11-25', '2027-12-24']);
  assert.deepEqual(NYSE_EARLY_CLOSES, ['2026-11-27', '2026-12-24', '2027-11-26']);
});

test('24/5 session: open mid-week, closed from Friday 17:00 ET to Sunday 18:00 ET', () => {
  assert.equal(sessionState(at('2026-10-01T15:00:00Z')).open, true, 'Thu 11:00 ET');
  assert.equal(sessionState(at('2026-10-02T20:59:00Z')).open, true, 'Fri 16:59 ET');
  const friAfter = sessionState(at('2026-10-02T21:00:00Z'));
  assert.equal(friAfter.open, false, 'Fri 17:00 ET: weekend close');
  assert.match(friAfter.reason, /weekend/);
  assert.equal(sessionState(at('2026-10-03T16:00:00Z')).open, false, 'Saturday noon ET');
  assert.equal(sessionState(at('2026-10-04T21:59:00Z')).open, false, 'Sun 17:59 ET');
  assert.equal(sessionState(at('2026-10-04T22:00:00Z')).open, true, 'Sun 18:00 ET opens Monday\'s session');
  assert.equal(sessionState(at('2026-10-05T23:30:00Z')).open, true, 'Mon 19:30 ET overnight');
});

test('holidays: closed all day, and the evening session that belongs to the holiday is closed too', () => {
  // Good Friday 2026-04-03: closed Thu 17:00 ET -> Sun 18:00 ET.
  assert.equal(sessionState(at('2026-04-02T20:59:00Z')).open, true, 'Thu 16:59 ET before Good Friday');
  const thuEve = sessionState(at('2026-04-02T21:00:00Z'));
  assert.equal(thuEve.open, false, 'Thu 17:00 ET: next session is the holiday');
  assert.match(thuEve.reason, /holiday 2026-04-03/);
  assert.equal(sessionState(at('2026-04-03T15:00:00Z')).open, false, 'Good Friday 11:00 ET');
  // Thanksgiving Thu 2026-11-26 (EST): Wed 17:00 ET closed, reopens Thu 18:00 ET for Friday.
  assert.equal(sessionState(at('2026-11-25T22:00:00Z')).open, false, 'Wed 17:00 ET before Thanksgiving');
  assert.equal(sessionState(at('2026-11-26T17:00:00Z')).open, false, 'Thanksgiving noon');
  assert.equal(sessionState(at('2026-11-26T23:00:00Z')).open, true, 'Thu 18:00 ET: Friday session');
  // Monday holiday (MLK 2027-01-18): the Sunday-evening open is skipped.
  assert.equal(sessionState(at('2027-01-17T23:30:00Z')).open, false, 'Sun 18:30 ET before MLK');
  assert.equal(sessionState(at('2027-01-18T23:30:00Z')).open, true, 'Mon 18:30 ET: Tuesday session');
});

test('regular mode: 09:30-16:00 ET only, 13:00 on early-close days', () => {
  const r = { mode: 'regular' };
  assert.equal(sessionState(at('2026-10-01T13:29:00Z'), r).open, false, '09:29 ET');
  assert.equal(sessionState(at('2026-10-01T13:30:00Z'), r).open, true, '09:30 ET');
  assert.equal(sessionState(at('2026-10-01T20:00:00Z'), r).open, false, '16:00 ET');
  assert.equal(sessionState(at('2026-11-27T17:59:00Z'), r).open, true, 'Black Friday 12:59 ET');
  assert.equal(sessionState(at('2026-11-27T18:00:00Z'), r).open, false, 'Black Friday 13:00 ET early close');
});

test('outside the built-in calendar the session fails closed', () => {
  const s = sessionState(at('2028-03-01T15:00:00Z'));
  assert.equal(s.open, false);
  assert.match(s.reason, /calendar/);
  assert.equal(s.calendarExpired, true);
});

test('feedFresh: Chainlink heartbeat (24h) + margin', () => {
  const now = at('2026-10-01T15:00:00Z');
  assert.equal(feedFresh(now - 86_400 - 1_799, now).fresh, true);
  assert.equal(feedFresh(now - 86_400 - 1_801, now).fresh, false);
  assert.equal(feedFresh(now + 5, now).fresh, true, 'RH clock slightly ahead');
  assert.equal(feedFresh(0, now).fresh, false);
});

test('marketGate: Friday after close, Saturday and a holiday all block; open + fresh passes; open + frozen feed alerts', () => {
  const fri = at('2026-10-02T21:30:00Z');
  const friCl = fri - 30 * 60;
  let g = marketGate({ nowSec: fri, sourceUpdatedAt: friCl });
  assert.equal(g.ok, false, 'Friday 17:30 ET: price only 30 min old, still closed');
  assert.equal(g.closed, true);
  assert.equal(g.alert, false, 'a routine close is not an incident');
  g = marketGate({ nowSec: at('2026-10-03T16:00:00Z'), sourceUpdatedAt: friCl });
  assert.equal(g.ok, false, 'Saturday');
  g = marketGate({ nowSec: at('2026-04-03T15:00:00Z'), sourceUpdatedAt: at('2026-04-02T20:00:00Z') });
  assert.equal(g.ok, false, 'Good Friday');
  assert.match(g.reason, /holiday/);
  g = marketGate({ nowSec: at('2026-10-01T15:00:00Z'), sourceUpdatedAt: at('2026-10-01T14:00:00Z') });
  assert.equal(g.ok, true);
  g = marketGate({ nowSec: at('2026-10-01T15:00:00Z'), sourceUpdatedAt: at('2026-09-30T12:00:00Z') });
  assert.equal(g.ok, false, '27h-old feed in an open session');
  assert.equal(g.closed, false);
  assert.equal(g.alert, true, 'frozen feed while the session is open is abnormal');
  assert.match(g.reason, /older than/);
  assert.equal(MARKET_DEFAULTS.heartbeatSec, 86_400);
});
