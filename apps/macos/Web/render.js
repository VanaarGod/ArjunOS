/* Markdown + math renderer for assistant messages. Model output is UNTRUSTED:
 *  - raw HTML is escaped (never executed), remote images are never loaded, only http(s)/mailto links survive
 *  - only real ~~double tilde~~ is strikethrough (a single ~ is common in "~$600" and must not strike text)
 *  - math ($..$, $$..$$, \(..\), \[..\], \begin{align}..) is typeset by KaTeX with trust:false
 */
(function () {
  'use strict';
  var ESC = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
  function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return ESC[c]; }); }
  var SAFE_LINK = /^(https?:\/\/|mailto:)/i;
  var ENVS = 'equation\\*?|align\\*?|aligned|alignat\\*?|gather\\*?|gathered|multline\\*?|cases|array|[pbBvV]?matrix|split|eqnarray\\*?';

  // ---------- math extensions (code spans / blocks and escaped \$ are handled natively by marked) ----------
  var BLOCK_MATH = new RegExp('^(?:\\$\\$([\\s\\S]+?)\\$\\$|\\\\\\[([\\s\\S]+?)\\\\\\]|(\\\\begin\\{(' + ENVS + ')\\}[\\s\\S]+?\\\\end\\{\\4\\}))[ \\t]*(?:\\n|$)');
  var BLOCK_START = new RegExp('(^|\\n)(?:\\$\\$|\\\\\\[|\\\\begin\\{(?:' + ENVS + ')\\})');
  var INLINE_START = /(?<!\\)(?:\$|\\\(|\\\[)/;
  var INLINE_DISPLAY = /^(?:\$\$([\s\S]+?)\$\$|\\\[([\s\S]+?)\\\])/;
  var INLINE_PAREN = /^\\\(([\s\S]+?)\\\)/;
  // pandoc-style single dollar: no space inside the delimiters and the closing $ is not followed by a digit,
  // so prices like "$1,200 ... $600" are NOT math.
  var INLINE_DOLLAR = /^\$(?![\s$])((?:\\.|[^$\\\n])+?)(?<![\s\\])\$(?![\d$])/;

  function mathToken(type, raw, tex, display) { return { type: type, raw: raw, tex: String(tex).trim(), display: display }; }
  function mathHtml(t) { return '<span class="math" data-display="' + (t.display ? 1 : 0) + '" data-tex="' + esc(t.tex) + '">' + esc(t.tex) + '</span>'; }

  var extensions = [
    { name: 'mathBlock', level: 'block',
      start: function (src) { var m = BLOCK_START.exec(src); return m ? m.index + m[1].length : undefined; },
      tokenizer: function (src) {
        var m = BLOCK_MATH.exec(src); if (!m) return undefined;
        var tex = m[1] != null ? m[1] : (m[2] != null ? m[2] : m[3]);
        return mathToken('mathBlock', m[0].replace(/\n$/, ''), tex, true);
      },
      renderer: mathHtml },
    { name: 'mathInline', level: 'inline',
      start: function (src) { var m = INLINE_START.exec(src); return m ? m.index : undefined; },
      tokenizer: function (src) {
        var m = INLINE_DISPLAY.exec(src);
        if (m) return mathToken('mathInline', m[0], m[1] != null ? m[1] : m[2], true);
        m = INLINE_PAREN.exec(src);
        if (m) return mathToken('mathInline', m[0], m[1], false);
        m = INLINE_DOLLAR.exec(src);
        if (m && !/^[\d\s.,]+$/.test(m[1])) return mathToken('mathInline', m[0], m[1], false);
        return undefined;
      },
      renderer: mathHtml }
  ];

  marked.use({
    gfm: true, breaks: false, extensions: extensions,
    tokenizer: {
      // strikethrough only for ~~double~~; returning undefined (not false) disables marked's single-tilde rule
      del: function (src) {
        var m = /^~~(?=\S)([\s\S]*?\S)~~/.exec(src);
        if (!m) return undefined;
        return { type: 'del', raw: m[0], text: m[1], tokens: this.lexer.inlineTokens(m[1]) };
      }
    },
    renderer: {
      html: function (tok) { return esc(tok.text != null ? tok.text : tok.raw); },       // raw HTML shown as text, never executed
      image: function (tok) {                                                           // never fetch remote images (data-exfiltration channel)
        var label = esc(tok.text || 'image');
        if (tok.href && /^https?:\/\//i.test(tok.href)) return '<a href="' + esc(tok.href) + '" rel="noopener noreferrer">Image: ' + label + '</a>';
        return '<span class="blocked-image">[image: ' + label + ']</span>';
      },
      link: function (tok) {
        var inner = this.parser.parseInline(tok.tokens);
        if (!tok.href || !SAFE_LINK.test(tok.href)) return inner;                       // javascript:, data:, file:, relative -> plain text
        return '<a href="' + esc(tok.href) + '"' + (tok.title ? ' title="' + esc(tok.title) + '"' : '') + ' rel="noopener noreferrer">' + inner + '</a>';
      },
      code: function (tok) {
        var lang = String(tok.lang || '').split(/\s+/)[0].replace(/[^A-Za-z0-9_+#.-]/g, '');
        return '<div class="code"><div class="code-bar"><span>' + esc(lang || 'text') + '</span><button class="copy" type="button">Copy</button></div><pre><code>' + esc(tok.text) + '</code></pre></div>';
      },
      table: function (tok) {                                                           // wide tables scroll instead of breaking the layout
        var head = '', body = '', i, j, c;
        for (j = 0; j < tok.header.length; j++) { c = tok.header[j]; head += this.tablecell(c); }
        head = this.tablerow({ text: head });
        for (i = 0; i < tok.rows.length; i++) { var row = ''; for (j = 0; j < tok.rows[i].length; j++) row += this.tablecell(tok.rows[i][j]); body += this.tablerow({ text: row }); }
        return '<div class="table-wrap"><table><thead>' + head + '</thead><tbody>' + body + '</tbody></table></div>';
      }
    }
  });

  // ---------- rendering ----------
  var root = document.getElementById('root');
  var mathCache = new Map();
  function typeset(el) {
    var tex = el.getAttribute('data-tex') || '', display = el.getAttribute('data-display') === '1', key = (display ? 'D:' : 'I:') + tex;
    if (mathCache.has(key)) { el.innerHTML = mathCache.get(key); return; }
    try {
      katex.render(tex, el, { displayMode: display, throwOnError: false, strict: 'ignore', trust: false, maxExpand: 1000, maxSize: 30 });
      if (mathCache.size > 600) mathCache.clear();
      mathCache.set(key, el.innerHTML);
    } catch (e) { el.textContent = tex; el.classList.add('math-error'); }
  }

  var lastHeight = -1;
  function reportHeight() {
    var h = Math.ceil(root.getBoundingClientRect().height) + 2;
    if (h !== lastHeight) { lastHeight = h; post('height', h); }
  }
  function post(name, value) {
    try { window.webkit.messageHandlers[name].postMessage(value); } catch (e) { /* not in WKWebView (tests) */ }
  }

  window.render = function (markdown) {
    var html;
    try { html = marked.parse(String(markdown || ''), { async: false }); }
    catch (e) { html = '<p>' + esc(String(markdown || '')) + '</p>'; }                // never show a blank bubble
    root.innerHTML = html;
    var spans = root.querySelectorAll('.math');
    for (var i = 0; i < spans.length; i++) typeset(spans[i]);
    reportHeight();
  };

  root.addEventListener('click', function (e) {
    var b = e.target.closest && e.target.closest('button.copy');
    if (!b) return;
    var code = b.closest('.code').querySelector('pre code');
    post('copy', code ? code.textContent : '');
    b.textContent = 'Copied'; setTimeout(function () { b.textContent = 'Copy'; }, 1200);
  });

  if (window.ResizeObserver) new ResizeObserver(reportHeight).observe(root);
  window.addEventListener('load', reportHeight);
})();
