// Prints the REAL extraction result for the sample product page as JSON (used by the Python cross-language test).
import { page, run, PRODUCT } from './harness.mjs';
const { p, s } = run(page(PRODUCT));
p.tab_id = 'tab-1'; p.captured_at = '2026-11-02T12:00:00Z';
console.log(JSON.stringify({ payload: p, stats: s }));
