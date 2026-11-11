"""DuckDuckGo web search (no API key) + the rules deciding WHEN to search.

Privacy: only a short, redacted QUERY is sent (never the conversation). Host is pinned, https only, no redirects,
offline mode refuses, and every search is shown to the user by the caller. Results are untrusted data.
NOTE: parses DuckDuckGo's public HTML results page; if DDG changes its markup or rate-limits, this raises a clear
SearchError rather than returning fabricated results.
"""
from __future__ import annotations
import datetime, html, re
from dataclasses import dataclass
from html.parser import HTMLParser
from urllib.parse import parse_qs, urlsplit
import httpx
from ..security.netguard import NetPolicy, validate_endpoint, EndpointRejected, _resolve
from ..security.redact import redact_text
from ..security.untrusted import wrap_untrusted

DDG_HOST = "html.duckduckgo.com"
DDG_URL = f"https://{DDG_HOST}/html/"
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) JarvisOS/0.1"
MAX_QUERY_CHARS = 200


class SearchError(Exception):
    """User-presentable failure (offline, blocked, rate-limited, unparseable)."""


@dataclass(frozen=True)
class SearchResult:
    title: str
    url: str
    snippet: str


def _clean(text: str, limit: int) -> str:
    t = re.sub(r"\s+", " ", html.unescape(text or "")).strip()
    return t if len(t) <= limit else t[: limit - 1].rstrip() + "…"


def sanitize_query(q: str) -> str:
    q = redact_text(re.sub(r"\s+", " ", q or "")).strip()
    if not q: raise SearchError("empty search query")
    return q[:MAX_QUERY_CHARS]


def _decode_href(href: str) -> str | None:
    """DDG wraps targets as //duckduckgo.com/l/?uddg=<url>. Returns the real http(s) URL, or None (ads/garbage)."""
    if href.startswith("//"): href = "https:" + href
    try: p = urlsplit(href)
    except ValueError: return None
    if p.netloc.endswith("duckduckgo.com"):
        if p.path.startswith("/l/"):
            target = (parse_qs(p.query).get("uddg") or [""])[0]
            href = target
            try: p = urlsplit(href)
            except ValueError: return None
        else:
            return None                                   # y.js ad redirects etc.
    return href if p.scheme in ("http", "https") and p.netloc else None


class _DDGParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.results: list[dict] = []
        self._cap: str | None = None                      # "title" | "snippet"
        self._buf: list[str] = []
        self.no_results = False

    def handle_starttag(self, tag, attrs):
        a = dict(attrs); cls = (a.get("class") or "").split()
        if tag == "a" and "result__a" in cls:
            self.results.append({"url": _decode_href(a.get("href") or ""), "title": "", "snippet": ""})
            self._cap, self._buf = "title", []
        elif tag in ("a", "td", "div") and "result__snippet" in cls and self.results:
            self._cap, self._buf = "snippet", []
        elif "no-results" in cls:
            self.no_results = True

    def handle_endtag(self, tag):
        if self._cap and tag in ("a", "td", "div"):
            self.results[-1][self._cap] = "".join(self._buf)
            self._cap = None

    def handle_data(self, data):
        if self._cap: self._buf.append(data)
        elif "No results" in data: self.no_results = True


def parse_ddg_html(page: str, limit: int = 5) -> list[SearchResult]:
    p = _DDGParser(); p.feed(page); p.close()
    out, seen = [], set()
    for r in p.results:
        if not r["url"] or r["url"] in seen or not r["title"].strip(): continue
        seen.add(r["url"])
        out.append(SearchResult(_clean(r["title"], 200), r["url"], _clean(r["snippet"], 400)))
        if len(out) >= limit: break
    if not out and not p.no_results and "result" not in page.lower():
        raise SearchError("DuckDuckGo returned a page this app couldn't read (the format may have changed, or it is rate-limiting automated requests).")
    return out


class DuckDuckGoSearch:
    def __init__(self, *, offline: bool = False, transport: httpx.AsyncBaseTransport | None = None, resolver=_resolve,
                 timeout: float = 8.0):
        self.offline, self.transport, self.resolver, self.timeout = offline, transport, resolver, timeout

    async def search(self, query: str, *, max_results: int = 5) -> list[SearchResult]:
        q = sanitize_query(query)
        policy = NetPolicy(allow_remote=True, offline_mode=self.offline, allowlist=frozenset({DDG_HOST}))
        try:
            validate_endpoint(DDG_URL, policy, resolver=self.resolver)
        except EndpointRejected as e:
            raise SearchError("Web search is unavailable: " + str(e)) from e
        try:
            async with httpx.AsyncClient(follow_redirects=False, timeout=self.timeout, transport=self.transport,
                                         headers={"User-Agent": UA, "Accept-Language": "en-US,en;q=0.9"}) as c:
                r = await c.get(DDG_URL, params={"q": q})
        except httpx.TimeoutException as e:
            raise SearchError("Web search timed out.") from e
        except httpx.HTTPError as e:
            raise SearchError(f"Couldn't reach DuckDuckGo ({type(e).__name__}).") from e
        if r.status_code != 200:
            raise SearchError(f"DuckDuckGo returned HTTP {r.status_code}" + (" (it may be rate-limiting automated requests)" if r.status_code in (202, 429, 403) else "") + ".")
        return parse_ddg_html(r.text, max_results)


def format_results(query: str, results: list[SearchResult]) -> str:
    """Prompt-ready, fenced as untrusted data, numbered so the model can cite [1], [2]."""
    if not results: body = "No results found."
    else: body = "\n".join(f"[{i}] {r.title}\n    {r.url}\n    {r.snippet}" for i, r in enumerate(results, 1))
    return wrap_untrusted("web_search", f"Web search results for: {query}\n{body}")


# ---------------------------------------------------------------- when to search
@dataclass(frozen=True)
class SearchDecision:
    search: bool
    query: str = ""
    reason: str | None = None          # "keyword" | "auto"


# explicit request, as a DIRECTIVE ("search for X", "please search the web", "look up X", "google X") — not "binary search"
_EXPLICIT = re.compile(
    r"(?:^|[.!?]\s+|\b(?:please|pls|can you|could you|would you|go|and|then|just)\s+)"
    r"(?:search(?:\s+(?:the\s+)?(?:web|internet|online|net))?(?:\s+(?:for|up|about|on))?|look\s*up|google|duckduckgo|ddg)\b"
    r"|\bweb\s+search\b|\bsearch\s+(?:the\s+)?(?:web|internet|online)\b|\bsearch\s+(?:for|up)\b|\bsearch:",
    re.I)
_TIME_SENSITIVE = re.compile(
    r"\b(latest|newest|most recent|current(?:ly)?|today(?:'s)?|tonight|right now|this (?:week|month|year|weekend)|yesterday|"
    r"breaking|news|headlines|weather|forecast|stock price|share price|exchange rate|who won|final score|release date)\b", re.I)
_LEAD_STRIP = re.compile(
    r"^(?:(?:please|pls|can you|could you|would you|go|and|then|just)\s+)*"
    r"(?:search(?:\s+(?:the\s+)?(?:web|internet|online|net))?(?:\s+(?:for|up|about|on))?\s*:?|look\s*up|google|duckduckgo|ddg)\s*", re.I)


def derive_query(prompt: str) -> str:
    text = re.sub(r"\s+", " ", prompt).strip()
    m = _EXPLICIT.search(text)
    if m:
        text = text[m.start():].lstrip(". !?")               # drop anything before the directive
        text = _LEAD_STRIP.sub("", text, count=1) or text
    text = re.sub(r"\b(and\s+)?(tell|show|give|summari[sz]e)\s+me\b.*$", "", text, flags=re.I).strip(" ,.;")
    return (text or prompt.strip())[:MAX_QUERY_CHARS]


def decide(prompt: str, mode: str, *, year: int | None = None) -> SearchDecision:
    """mode: off | keyword | auto. Pure function (testable)."""
    if mode == "off" or not prompt.strip(): return SearchDecision(False)
    if _EXPLICIT.search(prompt): return SearchDecision(True, derive_query(prompt), "keyword")
    if mode == "auto":
        y = year or datetime.date.today().year
        if _TIME_SENSITIVE.search(prompt) or any(int(m) >= y - 1 for m in re.findall(r"\b(20[2-9]\d)\b", prompt)):
            return SearchDecision(True, derive_query(prompt), "auto")
    return SearchDecision(False)
