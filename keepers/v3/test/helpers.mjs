import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
export const tmp = () => mkdtempSync(join(tmpdir(), 'keeper-test-'));
export const quietLogger = { lines: [], info(m) { this.lines.push(m); }, warn(m) { this.lines.push(m); }, error(m) { this.lines.push(m); } };
export const clock = (start = 1_000_000) => { let t = start; const f = () => t; f.advance = ms => { t += ms; }; return f; };
