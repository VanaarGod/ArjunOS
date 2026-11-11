import Foundation

/// JavaScript that runs inside web pages. Two scripts:
///  - `observer` is injected into every page; it only TELLS the app that something changed (DOM mutation, scroll, selection).
///  - `extract` is evaluated on demand and returns what the page shows. It never reads form-field values or passwords.
enum PageScripts {
    static let observer = #"""
    (function () {
      if (window.__arjunObserver) return; window.__arjunObserver = true;
      var post = function (t) { try { window.webkit.messageHandlers.arjun.postMessage({ type: t }); } catch (e) {} };
      var mt = null, st = null, ss = null;
      var changed = function () { clearTimeout(mt); mt = setTimeout(function () { post('changed'); }, 700); };
      try { new MutationObserver(changed).observe(document.documentElement, { childList: true, subtree: true, characterData: true }); } catch (e) {}
      window.addEventListener('scroll', function () { clearTimeout(st); st = setTimeout(function () { post('scroll'); }, 350); }, { passive: true });
      document.addEventListener('selectionchange', function () { clearTimeout(ss); ss = setTimeout(function () { post('selection'); }, 400); });
      window.addEventListener('popstate', changed); window.addEventListener('hashchange', changed);
    })();
    """#

    /// Returns a JSON string: { payload: <PagePayload fields>, stats: { textLength, canvases, images, videos, isPdf, truncated } }
    static let extract = #"""
    (function () {
      var T0 = Date.now(), BUDGET_MS = 900;
      var out = { url: location.href, title: document.title || '', status: 'ready', meta: {}, structured: [], prices: [], specs: [], headings: [],
                  tables: [], text: '', visible_text: '', selection: '', links: [], notes: [], source: 'dom' };
      var stats = { textLength: 0, canvases: 0, images: 0, videos: 0, isPdf: false, truncated: false, signIn: false };
      var clip = function (s, n) { s = String(s == null ? '' : s); return s.length > n ? s.slice(0, n) : s; };
      var clean = function (s) { return String(s || '').replace(/[\u00a0\u200b\u200c\u200d\ufeff]/g, ' ').replace(/[ \t\r\f\v]+/g, ' ').replace(/ ?\n ?/g, '\n').replace(/\n{3,}/g, '\n\n').trim(); };
      var over = function () { return Date.now() - T0 > BUDGET_MS; };
      var textOf = function (el) { return (el && (el.innerText || el.textContent)) || ''; };

      stats.isPdf = (document.contentType || '').toLowerCase() === 'application/pdf';
      if (stats.isPdf) { return JSON.stringify({ payload: out, stats: stats }); }

      try { out.lang = document.documentElement.lang || null; } catch (e) {}
      try { var cl = document.querySelector('link[rel="canonical"]'); if (cl && cl.href) out.canonical = cl.href; } catch (e) {}

      // ---- metadata ----
      try {
        var metas = document.querySelectorAll('meta[name], meta[property]'), n = 0;
        for (var i = 0; i < metas.length && n < 40; i++) {
          var k = metas[i].getAttribute('name') || metas[i].getAttribute('property'), v = metas[i].getAttribute('content');
          if (k && v && /^(description|keywords|author|robots|og:|twitter:|product:|article:|price|music:|video:)/i.test(k)) { out.meta[k] = clip(v, 500); n++; }
        }
      } catch (e) {}

      // ---- structured data: JSON-LD, then microdata ----
      try {
        var ld = document.querySelectorAll('script[type="application/ld+json"]');
        for (var j = 0; j < ld.length && out.structured.length < 12; j++) {
          try {
            var raw = ld[j].textContent || ''; if (raw.length > 200000) continue;
            var parsed = JSON.parse(raw), arr = Array.isArray(parsed) ? parsed : [parsed];
            for (var a = 0; a < arr.length && out.structured.length < 12; a++) if (JSON.stringify(arr[a]).length < 30000) out.structured.push(arr[a]);
          } catch (e) {}
        }
        var prop = function (sel) { var el = document.querySelector(sel); return el ? clip((el.getAttribute('content') || el.textContent || '').trim(), 200) : ''; };
        var mp = prop('[itemprop="price"]');
        if (mp && !out.structured.some(function (x) { return JSON.stringify(x).indexOf('"price"') >= 0; })) {
          out.structured.push({ '@type': 'Microdata', name: prop('[itemprop="name"]'), price: mp, priceCurrency: prop('[itemprop="priceCurrency"]'), availability: prop('[itemprop="availability"]') });
        }
      } catch (e) {}

      // ---- visibility ----
      var styleCache = new WeakMap();
      var hiddenEl = function (el) {
        if (el.hidden || el.getAttribute('aria-hidden') === 'true') return true;
        var cs = styleCache.get(el); if (!cs) { cs = getComputedStyle(el); styleCache.set(el, cs); }
        return cs.display === 'none' || cs.visibility === 'hidden' || cs.opacity === '0';
      };

      // ---- sign-in pages: do not read them ----
      try {
        var pw = document.querySelectorAll('input[type="password"]');
        for (var p = 0; p < pw.length; p++) { if (pw[p].offsetParent !== null && !hiddenEl(pw[p])) { stats.signIn = true; break; } }
      } catch (e) {}

      // ---- all visible text, in reading order, through open shadow roots and slots ----
      var BLOCK = { ADDRESS:1, ARTICLE:1, ASIDE:1, BLOCKQUOTE:1, DD:1, DIV:1, DL:1, DT:1, FIELDSET:1, FIGCAPTION:1, FIGURE:1, FOOTER:1, FORM:1, H1:1, H2:1, H3:1, H4:1, H5:1, H6:1,
                    HEADER:1, HR:1, LI:1, MAIN:1, NAV:1, OL:1, P:1, PRE:1, SECTION:1, TABLE:1, TR:1, UL:1, BR:1 };
      var SKIP = { SCRIPT:1, STYLE:1, NOSCRIPT:1, TEMPLATE:1, SVG:1, CANVAS:1, IFRAME:1, OBJECT:1, EMBED:1, HEAD:1, INPUT:1, TEXTAREA:1, SELECT:1, OPTION:1, AUDIO:1, VIDEO:1 };
      var count = 0, buf = [];
      var walk = function (node, depth) {
        if (stats.truncated) return;
        var t = node.nodeType;
        if (t === 3) { var v = node.nodeValue; if (v && /\S/.test(v)) buf.push(v); return; }
        if (t === 11) { for (var c0 = node.firstChild; c0; c0 = c0.nextSibling) walk(c0, depth + 1); return; }
        if (t !== 1) return;
        var tag = node.tagName;
        if (SKIP[tag] || depth > 250) return;
        if ((++count & 127) === 0 && over()) { stats.truncated = true; return; }
        if (hiddenEl(node)) return;
        var blk = !!BLOCK[tag];
        if (blk) buf.push('\n');
        if (tag === 'SLOT') {
          var assigned = node.assignedNodes ? node.assignedNodes({ flatten: true }) : [];
          var list = assigned.length ? assigned : Array.prototype.slice.call(node.childNodes);
          for (var s = 0; s < list.length; s++) walk(list[s], depth + 1);
        } else if (node.shadowRoot) {
          walk(node.shadowRoot, depth + 1);
        } else {
          for (var c = node.firstChild; c; c = c.nextSibling) walk(c, depth + 1);
        }
        if (blk) buf.push('\n');
      };
      var root = document.body || document.documentElement;
      if (root) walk(root, 0);
      out.text = clip(clean(buf.join(' ')), 250000);
      stats.textLength = out.text.length;

      if (stats.signIn && out.text.length < 1500) {
        out.status = 'restricted'; out.status_detail = 'This looks like a sign-in page, so its contents were not shared.'; out.text = ''; stats.textLength = 0;
      } else if (stats.signIn) { out.notes.push('The page contains a sign-in form (its fields were not read).'); }

      if (out.status === 'ready') {
        // ---- what is on screen right now ----
        try {
          var vh = window.innerHeight || 800, vis = [], vlen = 0;
          var tw = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null), tn;
          while ((tn = tw.nextNode()) && vlen < 8000 && !over()) {
            var txt = tn.nodeValue; if (!txt || !/\S/.test(txt)) continue;
            var pe = tn.parentElement; if (!pe || SKIP[pe.tagName]) continue;
            var r = pe.getBoundingClientRect(); if (r.width < 1 || r.height < 1 || r.bottom < 0 || r.top > vh) continue;
            if (hiddenEl(pe)) continue;
            var tx = txt.trim(); vis.push(tx); vlen += tx.length + 1;
          }
          out.visible_text = clip(clean(vis.join('\n')), 8000);
        } catch (e) {}

        out.selection = clip(String((window.getSelection && window.getSelection().toString()) || '').trim(), 8000);

        // ---- headings ----
        try {
          var hs = document.querySelectorAll('h1, h2, h3');
          for (var h = 0; h < hs.length && out.headings.length < 60; h++) {
            var ht = clean(textOf(hs[h])); if (ht && !hiddenEl(hs[h])) out.headings.push(clip(ht, 200));
          }
        } catch (e) {}

        // ---- tables and spec lists ----
        var seenSpec = {}, addSpec = function (nm, val) {
          nm = clip(clean(nm), 120).replace(/[:：]\s*$/, ''); val = clip(clean(val), 300);
          if (!nm || !val || nm.length > 60 || out.specs.length >= 80 || seenSpec[nm + '|' + val]) return;
          seenSpec[nm + '|' + val] = 1; out.specs.push({ name: nm, value: val });
        };
        try {
          var tbs = document.querySelectorAll('table');
          for (var ti = 0; ti < tbs.length && !over(); ti++) {
            var tb = tbs[ti]; if (tb.querySelector('table') || hiddenEl(tb)) continue;
            var rows = tb.querySelectorAll('tr'), grid = [];
            for (var ri = 0; ri < rows.length && grid.length < 40; ri++) {
              var cells = rows[ri].querySelectorAll('th, td'), row = [];
              for (var ci = 0; ci < cells.length && row.length < 12; ci++) row.push(clip(clean(textOf(cells[ci])), 160));
              if (row.some(function (x) { return x; })) grid.push(row);
            }
            if (grid.length >= 2 && grid[0].length >= 2 && out.tables.length < 6) out.tables.push(grid);
            if (grid.length >= 2 && grid.every(function (r) { return r.length === 2; })) grid.forEach(function (r) { addSpec(r[0], r[1]); });
          }
          var dls = document.querySelectorAll('dl');
          for (var di = 0; di < dls.length && !over(); di++) {
            var kids = dls[di].children, key = null;
            for (var ki = 0; ki < kids.length; ki++) {
              if (kids[ki].tagName === 'DT') key = textOf(kids[ki]); else if (kids[ki].tagName === 'DD' && key) { addSpec(key, textOf(kids[ki])); key = null; }
            }
          }
        } catch (e) {}

        // ---- prices ----
        try {
          var CUR = /(?:[$€£¥₹]|\b(?:USD|EUR|GBP|CAD|AUD|INR|JPY|CHF)\b)\s?\d[\d.,\s]*\d|\d[\d.,]*\s?(?:[$€£¥₹]|\b(?:USD|EUR|GBP|CAD|AUD|INR|JPY|CHF)\b)/;
          var pend = document.querySelectorAll('[itemprop="price"], [class*="price" i], [id*="price" i], [data-testid*="price" i], [data-price], .a-offscreen'), seenP = {};
          for (var pi = 0; pi < pend.length && out.prices.length < 20 && !over(); pi++) {
            var pel = pend[pi], ptxt = clean(pel.getAttribute('content') || pel.getAttribute('data-price') || pel.textContent);
            if (!ptxt || ptxt.length > 60) continue;
            var pm = ptxt.match(CUR); if (!pm || seenP[pm[0]]) continue;
            seenP[pm[0]] = 1;
            var lab = pel.getAttribute('aria-label') || (typeof pel.className === 'string' ? pel.className : '') || '';
            out.prices.push({ text: clip(pm[0].trim(), 80), label: clip(lab.replace(/\s+/g, ' ').trim(), 100) });
          }
          if (!out.prices.length) {
            var g = /(?:[$€£¥₹]\s?\d[\d.,]*\d|\d[\d.,]*\d\s?(?:USD|EUR|GBP))/g, m2, guard = 0, src = out.visible_text || out.text;
            while ((m2 = g.exec(src)) && out.prices.length < 8 && guard++ < 50) {
              if (seenP[m2[0]]) continue; seenP[m2[0]] = 1;
              out.prices.push({ text: m2[0], label: clip(src.slice(Math.max(0, m2.index - 40), m2.index).replace(/\s+/g, ' ').trim(), 100) });
            }
          }
        } catch (e) {}

        // ---- links ----
        try {
          var as = document.querySelectorAll('a[href]'), seenL = {};
          for (var li = 0; li < as.length && out.links.length < 60 && !over(); li++) {
            var an = as[li], href = an.href || ''; if (!/^https?:/i.test(href) || seenL[href]) continue;
            var lt = clean(textOf(an) || an.getAttribute('aria-label') || ''); if (!lt || lt.length > 120 || hiddenEl(an)) continue;
            seenL[href] = 1; out.links.push({ text: clip(lt, 120), href: clip(href, 500) });
          }
        } catch (e) {}
      }

      // ---- things we cannot read ----
      try {
        var ifr = document.querySelectorAll('iframe'), blocked = 0;
        for (var fi = 0; fi < ifr.length; fi++) { try { if (!ifr[fi].contentDocument) blocked++; } catch (e) { blocked++; } }
        if (blocked) out.notes.push(blocked + ' embedded frame(s) from other sites could not be read.');
      } catch (e) {}
      stats.canvases = document.querySelectorAll('canvas').length; stats.images = document.images ? document.images.length : 0; stats.videos = document.querySelectorAll('video').length;
      if (stats.truncated) out.notes.push('The page is very large; only part of it was read.');
      var de = document.documentElement, sh = Math.max(1, (de.scrollHeight || 1) - (window.innerHeight || 0));
      out.scroll = { percent: Math.max(0, Math.min(100, Math.round(100 * (window.scrollY || de.scrollTop || 0) / sh))) };
      if (document.readyState !== 'complete') out.status = out.status === 'ready' ? 'loading' : out.status;
      return JSON.stringify({ payload: out, stats: stats });
    })();
    """#
}
