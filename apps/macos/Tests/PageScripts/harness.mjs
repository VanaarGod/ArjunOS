// Runs the REAL extraction script (pulled out of PageScripts.swift) against HTML pages in jsdom.
// jsdom has no layout engine, so geometry is stubbed: every element is "on screen" unless it is marked data-offscreen.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { JSDOM } from 'jsdom';

const swift = fs.readFileSync(new URL('../../Sources/JarvisOS/Browser/PageScripts.swift', import.meta.url), 'utf8');
const grab = (name) => {
  const m = swift.match(new RegExp('static let ' + name + ' = #"""\\n([\\s\\S]*?)\\n\\s*"""#'));
  assert.ok(m, 'could not find script ' + name);
  return m[1];
};
export const EXTRACT = grab('extract'), OBSERVER = grab('observer');

export function page(html, { url = 'https://shop.example.com/p/1', contentType = 'text/html' } = {}) {
  const dom = new JSDOM(html, { url, runScripts: 'outside-only', pretendToBeVisual: true, contentType });
  const w = dom.window;
  w.Element.prototype.getBoundingClientRect = function () {
    const off = this.closest && this.closest('[data-offscreen]');
    return off ? { top: 5000, bottom: 5100, left: 0, right: 100, width: 100, height: 100 } : { top: 10, bottom: 40, left: 0, right: 300, width: 300, height: 30 };
  };
  Object.defineProperty(w.HTMLElement.prototype, 'offsetParent', { get() { return this.parentNode; } });
  Object.defineProperty(w, 'innerHeight', { value: 800 });
  Object.defineProperty(w.document, 'readyState', { value: 'complete', configurable: true });        // a page that has finished loading
  return w;
}
export const run = (w) => { const r = JSON.parse(w.eval(EXTRACT)); return { p: r.payload, s: r.stats }; };

export const PRODUCT = `<!doctype html><html lang="en"><head><title>MacBook Pro 14 | Example Shop</title>
<link rel="canonical" href="https://shop.example.com/macbook-pro-14">
<meta name="description" content="Pro laptop with M3"><meta property="og:site_name" content="Example Shop"><meta name="viewport" content="width=device-width">
<script type="application/ld+json">{"@context":"https://schema.org","@type":"Product","name":"MacBook Pro 14","offers":{"@type":"Offer","price":"1599.00","priceCurrency":"USD"}}</script>
<script>window.secret = "SCRIPT-BODY-MUST-NOT-APPEAR"</script><style>.x{color:red}</style></head>
<body><header><nav><a href="/">Home</a><a href="/laptops">Laptops</a></nav></header>
<main><h1>MacBook Pro 14-inch</h1><h2>Tech specs</h2>
<div class="product-price"><span class="price-now">$1,599.00</span> <span class="price-was">$1,799.00</span></div>
<p>Ships in 2 days. Free returns within 14 days.</p>
<table><tr><th>Chip</th><td>Apple M3</td></tr><tr><th>Memory</th><td>16 GB</td></tr><tr><th>Battery</th><td>Up to 22 hours</td></tr></table>
<dl><dt>Weight</dt><dd>1.55 kg</dd></dl>
<div style="display:none">HIDDEN-DISPLAY-NONE</div><div aria-hidden="true">HIDDEN-ARIA</div><div hidden>HIDDEN-ATTR</div>
<input type="text" value="USER-TYPED-VALUE"><textarea>TEXTAREA-VALUE</textarea>
<section data-offscreen><h3>Reviews</h3><p>Customers love the battery.</p></section></main>
<footer><a href="/returns">Return policy</a></footer></body></html>`;

