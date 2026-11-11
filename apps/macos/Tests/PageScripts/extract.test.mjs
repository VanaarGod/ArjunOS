import test from 'node:test';
import assert from 'node:assert/strict';
import { EXTRACT, OBSERVER, page, run, PRODUCT } from './harness.mjs';

test('reads text, metadata, canonical link, headings and links from a product page', () => {
  const { p } = run(page(PRODUCT));
  assert.equal(p.title, 'MacBook Pro 14 | Example Shop'); assert.equal(p.lang, 'en'); assert.equal(p.canonical, 'https://shop.example.com/macbook-pro-14');
  assert.equal(p.meta['description'], 'Pro laptop with M3'); assert.equal(p.meta['og:site_name'], 'Example Shop'); assert.equal(p.meta['viewport'], undefined);
  assert.match(p.text, /MacBook Pro 14-inch/); assert.match(p.text, /Ships in 2 days/); assert.match(p.text, /Customers love the battery/);
  assert.match(p.text, /Return policy/);                                    // footer text is page content too ("what is the return policy?")
  assert.deepEqual(p.headings.slice(0, 3), ['MacBook Pro 14-inch', 'Tech specs', 'Reviews']);
  assert.ok(p.links.some((l) => l.text === 'Return policy' && l.href === 'https://shop.example.com/returns'));
});

test('structured data, prices and specs come out as data, not just text', () => {
  const { p } = run(page(PRODUCT));
  assert.equal(p.structured[0]['@type'], 'Product'); assert.equal(p.structured[0].offers.price, '1599.00');
  const prices = p.prices.map((x) => x.text); assert.ok(prices.includes('$1,599.00') && prices.includes('$1,799.00'), JSON.stringify(prices));
  const spec = Object.fromEntries(p.specs.map((s) => [s.name, s.value]));
  assert.equal(spec['Chip'], 'Apple M3'); assert.equal(spec['Battery'], 'Up to 22 hours'); assert.equal(spec['Weight'], '1.55 kg');
  assert.equal(p.tables.length, 1); assert.deepEqual(p.tables[0][0], ['Chip', 'Apple M3']);
});

test('never includes scripts, styles, hidden elements or form-field values', () => {
  const { p } = run(page(PRODUCT));
  for (const bad of ['SCRIPT-BODY-MUST-NOT-APPEAR', 'color:red', 'HIDDEN-DISPLAY-NONE', 'HIDDEN-ARIA', 'HIDDEN-ATTR', 'USER-TYPED-VALUE', 'TEXTAREA-VALUE'])
    assert.ok(!p.text.includes(bad) && !p.visible_text.includes(bad), bad + ' leaked');
});

test('"on screen" text excludes what is scrolled out of view', () => {
  const { p } = run(page(PRODUCT));
  assert.match(p.visible_text, /MacBook Pro 14-inch/); assert.ok(!p.visible_text.includes('Customers love the battery'));
});

test('the user\'s selection is captured', () => {
  const w = page(PRODUCT); const el = w.document.querySelector('p'); const r = w.document.createRange(); r.selectNodeContents(el); w.getSelection().addRange(r);
  assert.match(run(w).p.selection, /Ships in 2 days/);
});

test('shadow DOM and slotted content are read', () => {
  const w = page('<body><my-card><span slot="t">SLOTTED-TITLE</span></my-card></body>');
  const host = w.document.querySelector('my-card'); const sr = host.attachShadow({ mode: 'open' });
  sr.innerHTML = '<div>SHADOW-HEADING</div><slot name="t"></slot>';
  const { p } = run(w); assert.match(p.text, /SHADOW-HEADING/); assert.match(p.text, /SLOTTED-TITLE/); assert.equal((p.text.match(/SLOTTED-TITLE/g) || []).length, 1);
});

test('a sign-in page is withheld, but a content page with a login box is not', () => {
  const login = run(page('<body><h1>Sign in</h1><form><input type="email" value="me@x.com"><input type="password" value="hunter2"></form></body>'));
  assert.equal(login.p.status, 'restricted'); assert.equal(login.p.text, ''); assert.ok(login.s.signIn); assert.ok(!JSON.stringify(login.p).includes('hunter2'));
  const long = '<p>' + 'Useful article sentence. '.repeat(120) + '</p>';
  const content = run(page('<body><form><input type="password"></form>' + long + '</body>'));
  assert.equal(content.p.status, 'ready'); assert.match(content.p.text, /Useful article/); assert.ok(content.p.notes.some((n) => /sign-in form/.test(n)));
});

test('prices fall back to the page text when there are no price elements', () => {
  const { p } = run(page('<body><p>Special offer: only $49.99 this week, was $79.00.</p></body>'));
  assert.ok(p.prices.map((x) => x.text).includes('$49.99'));
});

test('microdata price is reported when there is no JSON-LD', () => {
  const { p } = run(page('<body><span itemprop="name">Widget</span><meta itemprop="price" content="12.50"><meta itemprop="priceCurrency" content="EUR"></body>'));
  assert.equal(p.structured[0].price, '12.50'); assert.equal(p.structured[0].priceCurrency, 'EUR');
});

test('stats report what is hard to read (canvas, images, video) so the app can fall back to OCR', () => {
  const { s, p } = run(page('<body><canvas></canvas><canvas></canvas><img src="a.png"><video></video><p>hi</p></body>'));
  assert.equal(s.canvases, 2); assert.equal(s.images, 1); assert.equal(s.videos, 1); assert.equal(s.textLength, p.text.length);
});

test('cross-origin or unreadable frames are reported honestly', () => {
  const w = page('<body><p>Main text</p><iframe src="https://other.example.net/x"></iframe></body>');
  Object.defineProperty(w.HTMLIFrameElement.prototype, 'contentDocument', { get() { return null; } });     // what a browser returns for another origin
  assert.ok(run(w).p.notes.some((n) => /frame/.test(n)));
});

test('a PDF is flagged for the app to read with PDFKit instead', () => {
  const w = page('<body></body>'); Object.defineProperty(w.document, 'contentType', { value: 'application/pdf' });
  assert.equal(run(w).s.isPdf, true);
});

test('malformed JSON-LD and huge pages do not break extraction', () => {
  const html = '<head><script type="application/ld+json">{not json</script></head><body>' + '<div>word word word</div>'.repeat(20000) + '</body>';
  const t0 = Date.now(); const { p } = run(page(html));
  assert.ok(p.text.length > 1000 && p.structured.length === 0 && Date.now() - t0 < 5000);
});

test('an empty page yields empty text rather than an error', () => {
  const { p, s } = run(page('<body></body>')); assert.equal(p.text, ''); assert.equal(s.textLength, 0); assert.equal(p.status, 'ready');
});

test('the scroll position is reported as a percentage', () => {
  const w = page('<body><p>x</p></body>'); Object.defineProperty(w.document.documentElement, 'scrollHeight', { value: 2000 }); w.scrollY = 600;
  Object.defineProperty(w, 'scrollY', { value: 600 });
  const pct = run(w).p.scroll.percent; assert.ok(pct > 40 && pct < 60, String(pct));
});

test('the observer script reports changes, scroll and selection to the app and is idempotent', () => {
  const w = page('<body><div id="a">x</div></body>'); const sent = [];
  w.webkit = { messageHandlers: { arjun: { postMessage: (m) => sent.push(m.type) } } };
  w.eval(OBSERVER); w.eval(OBSERVER);                                          // injected twice: must not double-report
  w.document.getElementById('a').textContent = 'changed';
  return new Promise((resolve) => setTimeout(() => {
    assert.deepEqual(sent, ['changed']); resolve();
  }, 1000));
});

test('a page that is still loading is flagged so the answer can say so', () => {
  const w = page('<body><p>Partial</p></body>'); Object.defineProperty(w.document, 'readyState', { value: 'interactive', configurable: true });
  assert.equal(run(w).p.status, 'loading');
});

test('scripts, styles and noscript fallbacks inside the body are never read as page text', () => {
  const { p } = run(page('<body><p>Real content</p><script>var token="BODY-SCRIPT-TEXT"</script><style>.a{content:"BODY-STYLE-TEXT"}</style><noscript>NOSCRIPT-TEXT</noscript><template><p>TEMPLATE-TEXT</p></template></body>'));
  assert.match(p.text, /Real content/);
  for (const bad of ['BODY-SCRIPT-TEXT', 'BODY-STYLE-TEXT', 'NOSCRIPT-TEXT', 'TEMPLATE-TEXT']) assert.ok(!p.text.includes(bad), bad);
});
