"""Turn a file into plain text for the model. Pure functions (the API runs them in a worker thread with a timeout).

Everything can be read in some honest way:
  text/code/markdown/csv/json/logs, HTML (tags stripped), PDF (pypdf), Word .docx, Excel .xlsx/.xlsm, PowerPoint .pptx,
  OpenDocument (.odt/.ods/.odp), .rtf, .epub, Apple property lists, SQLite databases (schema + sample rows),
  zip/tar archives (a listing plus the text files inside), legacy .doc/.xls/.ppt (best-effort text pulled out of the binary),
  and any other binary (what it is, how big, plus any readable text inside, clearly labelled, never presented as the content).
Images are not handled here: the app sends them straight to vision-capable models.
"""
from __future__ import annotations
import io, json, plistlib, re, sqlite3, tarfile, zipfile
from dataclasses import dataclass
from html.parser import HTMLParser
from pathlib import PurePosixPath
from xml.etree import ElementTree as ET

MAX_BYTES = 25 * 1024 * 1024
MAX_TEXT_CHARS = 600_000
MAX_PDF_PAGES = 400
MAX_ZIP_MEMBER = 50 * 1024 * 1024
MAX_ZIP_TOTAL = 150 * 1024 * 1024
MAX_SHEETS, MAX_ROWS, MAX_COLS = 8, 400, 40

IMAGE_EXT = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic", ".heif", ".bmp", ".tif", ".tiff"}
LEGACY_OFFICE = {".doc": "Word 97-2003", ".xls": "Excel 97-2003", ".ppt": "PowerPoint 97-2003", ".dot": "Word template", ".xlt": "Excel template",
                 ".pps": "PowerPoint show", ".pub": "Publisher", ".wps": "Works"}
EXCEL_EXT = {".xlsx", ".xlsm", ".xltx", ".xltm"}
WORD_EXT = {".docx", ".docm", ".dotx", ".dotm"}
POWERPOINT_EXT = {".pptx", ".pptm", ".potx", ".potm", ".ppsx"}
ODF_EXT = {".odt": "text", ".ods": "sheet", ".odp": "slides", ".odg": "text", ".ott": "text", ".ots": "sheet"}
MAX_ARCHIVE_MEMBERS, MAX_ARCHIVE_TEXT_FILES, MAX_ARCHIVE_FILE, MAX_ARCHIVE_TEXT = 300, 40, 60_000, 300_000


class UnsupportedFile(Exception):
    """The type is not supported (HTTP 415). The message tells the user what to do instead."""


class ExtractionError(Exception):
    """The file is supported but could not be read (HTTP 422)."""


@dataclass
class Extracted:
    name: str
    kind: str                 # text | html | pdf | docx | xlsx | pptx | odf | rtf | epub | sqlite | plist | archive | legacy | binary
    text: str
    chars: int                # length before truncation
    truncated: bool
    warning: str | None = None


def _finish(name: str, kind: str, full: str, warning: str | None = None) -> Extracted:
    full = full.replace("\r\n", "\n").replace("\r", "\n").replace("\x00", "")
    n = len(full)
    trunc = n > MAX_TEXT_CHARS
    if trunc: warning = (warning + " " if warning else "") + f"Only the first {MAX_TEXT_CHARS:,} characters were kept."
    text = full[:MAX_TEXT_CHARS] if trunc else full
    if not text.strip(): warning = (warning + " " if warning else "") + "No text was found in this file."
    return Extracted(name, kind, text, n, trunc, warning)


# ---------------------------------------------------------------- text
def _looks_binary(b: bytes) -> bool:
    head = b[:8192]
    if b"\x00" in head: return True
    if not head: return False
    ctrl = sum(1 for c in head if c < 9 or (13 < c < 32))
    return ctrl / len(head) > 0.10


def decode_text(data: bytes) -> tuple[str, str | None]:
    if data.startswith((b"\xff\xfe", b"\xfe\xff")):
        return data.decode("utf-16", errors="replace"), None
    if data.startswith(b"\xef\xbb\xbf"):
        return data[3:].decode("utf-8", errors="replace"), None
    if _looks_binary(data): raise UnsupportedFile("This looks like a binary file, not text.")
    try: return data.decode("utf-8"), None
    except UnicodeDecodeError: return data.decode("latin-1"), "Decoded as Latin-1 (not valid UTF-8)."


class _Strip(HTMLParser):
    SKIP, BLOCK = {"script", "style", "noscript", "template", "svg"}, {"p", "div", "br", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "section", "article", "table", "ul", "ol", "pre", "blockquote"}
    def __init__(self): super().__init__(convert_charrefs=True); self.out, self.skip = [], 0
    def handle_starttag(self, tag, attrs):
        if tag in self.SKIP: self.skip += 1
        elif tag in self.BLOCK: self.out.append("\n")
    def handle_endtag(self, tag):
        if tag in self.SKIP: self.skip = max(0, self.skip - 1)
        elif tag in self.BLOCK: self.out.append("\n")
    def handle_data(self, d):
        if not self.skip: self.out.append(d)


def html_to_text(src: str) -> str:
    p = _Strip(); p.feed(src); p.close()
    return re.sub(r"\n{3,}", "\n\n", re.sub(r"[ \t]+", " ", "".join(p.out))).strip()


# ---------------------------------------------------------------- zip-based office formats
def _open_zip(data: bytes) -> zipfile.ZipFile:
    try: z = zipfile.ZipFile(io.BytesIO(data))
    except zipfile.BadZipFile as e: raise ExtractionError("The file is damaged or not a valid Office document.") from e
    infos = z.infolist()
    if len(infos) > 5000 or sum(i.file_size for i in infos) > MAX_ZIP_TOTAL or any(i.file_size > MAX_ZIP_MEMBER for i in infos):
        raise ExtractionError("The document is too large when unpacked (refused to protect against zip bombs).")
    return z


def _xml(z: zipfile.ZipFile, name: str) -> ET.Element:
    raw = z.read(name)
    if b"<!DOCTYPE" in raw[:4096] or b"<!ENTITY" in raw[:65536]:      # no legitimate Office part needs a DTD
        raise ExtractionError("The document contains an XML DTD and was refused.")
    try: return ET.fromstring(raw)
    except ET.ParseError as e: raise ExtractionError("The document's XML is damaged.") from e


W = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"
S = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"


def _docx_par(p: ET.Element) -> str:
    out = []
    for el in p.iter():
        if el.tag == W + "t" and el.text: out.append(el.text)
        elif el.tag == W + "tab": out.append("\t")
        elif el.tag in (W + "br", W + "cr"): out.append("\n")
    text = "".join(out)
    style = p.find(f"{W}pPr/{W}pStyle")
    if style is not None and text.strip():
        m = re.match(r"(?i)heading\s*(\d)", style.get(W + "val", ""))
        if m: return "#" * min(int(m.group(1)), 6) + " " + text
    return text


def extract_docx(data: bytes) -> str:
    z = _open_zip(data)
    if "word/document.xml" not in z.namelist(): raise ExtractionError("This is not a Word document (word/document.xml is missing).")
    body = _xml(z, "word/document.xml").find(W + "body")
    if body is None: return ""
    lines = []
    for el in body:
        if el.tag == W + "p": lines.append(_docx_par(el))
        elif el.tag == W + "tbl":
            for tr in el.iter(W + "tr"):
                lines.append(" | ".join(" ".join(_docx_par(p) for p in tc.iter(W + "p")).strip() for tc in tr.findall(W + "tc")))
            lines.append("")
    return "\n".join(lines)


def _col_index(ref: str) -> int:
    n = 0
    for ch in re.match(r"[A-Za-z]+", ref).group(0).upper(): n = n * 26 + ord(ch) - 64
    return n - 1


def extract_xlsx(data: bytes) -> str:
    z = _open_zip(data); names = set(z.namelist())
    if "xl/workbook.xml" not in names: raise ExtractionError("This is not an Excel workbook (xl/workbook.xml is missing).")
    shared: list[str] = []
    if "xl/sharedStrings.xml" in names:
        for si in _xml(z, "xl/sharedStrings.xml").iter(S + "si"): shared.append("".join(t.text or "" for t in si.iter(S + "t")))
    sheet_files = sorted((n for n in names if re.fullmatch(r"xl/worksheets/sheet\d+\.xml", n)), key=lambda n: int(re.findall(r"\d+", n)[0]))
    wb_names = [s.get("name", "") for s in _xml(z, "xl/workbook.xml").iter(S + "sheet")]
    out = []
    for idx, fn in enumerate(sheet_files[:MAX_SHEETS]):
        title = wb_names[idx] if idx < len(wb_names) and len(wb_names) == len(sheet_files) else f"Sheet {idx + 1}"
        out.append(f"=== {title} ===")
        rows = 0
        for row in _xml(z, fn).iter(S + "row"):
            if rows >= MAX_ROWS: out.append(f"[… more rows not shown (limit {MAX_ROWS})]"); break
            cells: dict[int, str] = {}
            for c in row.findall(S + "c"):
                t, v = c.get("t"), c.find(S + "v")
                if t == "inlineStr": val = "".join(x.text or "" for x in c.iter(S + "t"))
                elif v is None or v.text is None: continue
                elif t == "s":
                    try: val = shared[int(v.text)]
                    except (ValueError, IndexError): val = ""
                elif t == "b": val = "TRUE" if v.text == "1" else "FALSE"
                else: val = v.text
                col = _col_index(c.get("r", "A1"))
                if col < MAX_COLS: cells[col] = val
            if cells:
                out.append(" | ".join(cells.get(i, "") for i in range(max(cells) + 1))); rows += 1
        out.append("")
    if len(sheet_files) > MAX_SHEETS: out.append(f"[… {len(sheet_files) - MAX_SHEETS} more sheets not shown]")
    return "\n".join(out)


# ---------------------------------------------------------------- pdf
def extract_pdf(data: bytes) -> tuple[str, str | None]:
    import importlib, importlib.util, sys
    importlib.invalidate_caches()                          # so a package installed while the app is running is picked up
    try: from pypdf import PdfReader
    except ImportError as e:
        installed = importlib.util.find_spec("pypdf") is not None
        why = (f"pypdf is installed but failed to load ({e})" if installed else "pypdf isn't installed in the Python the app is using")
        raise ExtractionError(f"PDF support isn't available: {why}. Python: {sys.executable}. "
                              f"Run scripts/setup.sh, or: \"{sys.executable}\" -m pip install pypdf") from e
    try:
        reader = PdfReader(io.BytesIO(data), strict=False)
        if reader.is_encrypted and not reader.decrypt(""): raise ExtractionError("This PDF is password-protected.")
        pages, skipped, total = [], 0, len(reader.pages)
        for i, page in enumerate(reader.pages[:MAX_PDF_PAGES], 1):
            try: t = (page.extract_text() or "").strip()
            except Exception: t = ""; skipped += 1
            if t: pages.append(f"--- Page {i} ---\n{t}")
    except ExtractionError: raise
    except Exception as e: raise ExtractionError(f"Couldn't read this PDF ({type(e).__name__}).") from e
    warn = []
    if total > MAX_PDF_PAGES: warn.append(f"Only the first {MAX_PDF_PAGES} of {total} pages were read.")
    if skipped: warn.append(f"{skipped} page(s) couldn't be read.")
    if not pages: warn.append("No selectable text (this may be a scanned PDF; OCR isn't built in).")
    return "\n\n".join(pages), (" ".join(warn) or None)


# ---------------------------------------------------------------- PowerPoint
P = "{http://schemas.openxmlformats.org/presentationml/2006/main}"
A = "{http://schemas.openxmlformats.org/drawingml/2006/main}"
RELNS = "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}"
PKGREL = "{http://schemas.openxmlformats.org/package/2006/relationships}"


def _a_par(p: ET.Element) -> str:
    out = []
    for el in p.iter():
        if el.tag == A + "t" and el.text: out.append(el.text)
        elif el.tag == A + "br": out.append("\n")
    return "".join(out).strip()


def _shape_lines(el: ET.Element, lines: list, title: list) -> None:
    for ch in el:
        if ch.tag == P + "sp":
            ph = ch.find(f"{P}nvSpPr/{P}nvPr/{P}ph")
            is_title = ph is not None and ph.get("type") in ("title", "ctrTitle")
            paras = [t for t in (_a_par(p) for p in ch.iter(A + "p")) if t]
            if is_title and paras and not title: title.append(" ".join(paras))
            else: lines += paras
        elif ch.tag == P + "graphicFrame":
            for tr in ch.iter(A + "tr"):
                cells = [" ".join(t for t in (_a_par(p) for p in tc.iter(A + "p")) if t) for tc in tr.findall(A + "tc")]
                if any(cells): lines.append(" | ".join(cells))
        elif ch.tag == P + "grpSp": _shape_lines(ch, lines, title)
        elif ch.tag == P + "pic":
            d = ch.find(f"{P}nvPicPr/{P}cNvPr")
            if d is not None and d.get("descr"): lines.append(f"[Picture: {d.get('descr')[:200]}]")


def _rels(z: zipfile.ZipFile, name: str) -> dict:
    if name not in z.namelist(): return {}
    return {r.get("Id"): r.get("Target", "") for r in _xml(z, name).iter(PKGREL + "Relationship")}


def extract_pptx(data: bytes) -> tuple[str, str | None]:
    z = _open_zip(data); names = set(z.namelist())
    if "ppt/presentation.xml" not in names: raise ExtractionError("This is not a PowerPoint file (ppt/presentation.xml is missing).")
    order: list[str] = []
    rels = _rels(z, "ppt/_rels/presentation.xml.rels")
    for sid in _xml(z, "ppt/presentation.xml").iter(P + "sldId"):
        target = rels.get(sid.get(RELNS + "id"), "")
        if target: order.append("ppt/" + target.lstrip("/").removeprefix("ppt/"))
    order = [n for n in order if n in names] or sorted((n for n in names if re.fullmatch(r"ppt/slides/slide\d+\.xml", n)), key=lambda n: int(re.findall(r"\d+", n)[-1]))
    out = []
    for i, fn in enumerate(order, 1):
        root = _xml(z, fn); tree = root.find(f"{P}cSld/{P}spTree"); lines, title = [], []
        if tree is not None: _shape_lines(tree, lines, title)
        out.append(f"--- Slide {i}" + (f": {title[0]}" if title else "") + " ---")
        out += lines
        srels = _rels(z, f"ppt/slides/_rels/{fn.rsplit('/', 1)[-1]}.rels")
        for t in srels.values():
            if "notesSlide" in t:
                notes_name = "ppt/notesSlides/" + t.rsplit("/", 1)[-1]
                if notes_name in names:
                    notes = [x for x in (_a_par(p) for p in _xml(z, notes_name).iter(A + "p")) if x and not x.isdigit()]
                    if notes: out.append("Speaker notes: " + " ".join(notes))
        out.append("")
    extras = [f"{n} {label}" for n, label in ((sum(1 for x in names if x.startswith("ppt/media/")), "image(s)"), (sum(1 for x in names if re.fullmatch(r"ppt/charts/chart\d+\.xml", x)), "chart(s)")) if n]
    warn = ("Also contains " + " and ".join(extras) + ", which were not read as text.") if extras else None
    return "\n".join(out), warn


# ---------------------------------------------------------------- OpenDocument, RTF, EPUB, plist, SQLite
def _odf_text(el: ET.Element, ns: dict) -> str:
    out = [el.text or ""]
    for ch in el:
        t = ch.tag
        if t == ns["text"] + "s": out.append(" " * min(int(ch.get(ns["text"] + "c", "1") or 1), 40))
        elif t == ns["text"] + "tab": out.append("\t")
        elif t == ns["text"] + "line-break": out.append("\n")
        else: out.append(_odf_text(ch, ns))
        out.append(ch.tail or "")
    return "".join(out)


def extract_odf(data: bytes) -> str:
    z = _open_zip(data)
    if "content.xml" not in z.namelist(): raise ExtractionError("This is not an OpenDocument file (content.xml is missing).")
    ns = {"text": "{urn:oasis:names:tc:opendocument:xmlns:text:1.0}", "table": "{urn:oasis:names:tc:opendocument:xmlns:table:1.0}",
          "draw": "{urn:oasis:names:tc:opendocument:xmlns:drawing:1.0}", "office": "{urn:oasis:names:tc:opendocument:xmlns:office:1.0}"}
    lines: list[str] = []
    state = {"slide": 0}
    def walk(el: ET.Element) -> None:
        for ch in el:
            t = ch.tag
            if t == ns["text"] + "h": txt = _odf_text(ch, ns).strip(); lines.append(("#" * min(int(ch.get(ns["text"] + "outline-level", "1") or 1), 6) + " " + txt) if txt else "")
            elif t == ns["text"] + "p": lines.append(_odf_text(ch, ns).strip())
            elif t == ns["table"] + "table":
                lines.append(f"=== {ch.get(ns['table'] + 'name', 'Table')} ===")
                rows = 0
                for row in ch.iter(ns["table"] + "table-row"):
                    if rows >= MAX_ROWS: lines.append(f"[… more rows not shown (limit {MAX_ROWS})]"); break
                    cells = [" ".join(x for x in (_odf_text(p, ns).strip() for p in c.iter(ns["text"] + "p")) if x) for c in row.findall(ns["table"] + "table-cell")][:MAX_COLS]
                    while cells and not cells[-1]: cells.pop()
                    if cells: lines.append(" | ".join(cells)); rows += 1
                lines.append("")
            elif t == ns["draw"] + "page": state["slide"] += 1; lines.append(f"--- Slide {state['slide']} ---"); walk(ch)
            else: walk(ch)
    body = _xml(z, "content.xml").find(ns["office"] + "body")
    if body is not None: walk(body)
    return re.sub(r"\n{3,}", "\n\n", "\n".join(lines))


_RTF_SKIP = {"fonttbl", "colortbl", "stylesheet", "info", "pict", "header", "footer", "headerl", "headerr", "footerl", "footerr", "object", "themedata",
             "colorschememapping", "datastore", "latentstyles", "listtable", "listoverridetable", "rsidtbl", "generator", "xmlnstbl", "fldinst"}


def rtf_to_text(src: str) -> str:
    out, stack, i, n, skip_depth, uc = [], [], 0, len(src), None, 1
    while i < n:
        c = src[i]
        if c == "{":
            stack.append(uc); i += 1
            if skip_depth is None:
                m = re.match(r"(?:\\\*)?\\([a-zA-Z]+)", src[i:i + 40])
                if src[i:i + 2] == "\\*" or (m and m.group(1) in _RTF_SKIP): skip_depth = len(stack)
        elif c == "}":
            if skip_depth is not None and len(stack) == skip_depth: skip_depth = None
            if stack: uc = stack.pop()
            i += 1
        elif c == "\\":
            i += 1
            if i >= n: break
            if src[i] in "\\{}": 
                if skip_depth is None: out.append(src[i])
                i += 1
            elif src[i] == "'":
                if skip_depth is None:
                    try: out.append(bytes([int(src[i + 1:i + 3], 16)]).decode("cp1252", errors="replace"))
                    except ValueError: pass
                i += 3
            elif src[i] in "\n\r": i += 1
            else:
                m = re.match(r"([a-zA-Z]+)(-?\d+)? ?", src[i:])
                if not m: i += 1; continue
                word, num = m.group(1), m.group(2); i += m.end()
                if skip_depth is not None: continue
                if word in ("par", "line", "sect", "page"): out.append("\n")
                elif word == "tab": out.append("\t")
                elif word == "u" and num is not None:
                    v = int(num); out.append(chr(v + 65536 if v < 0 else v)); i += uc if i < n and src[i] != "\\" else 0
                elif word == "uc" and num is not None: uc = int(num)
                elif word in ("emdash", "endash"): out.append("-")
                elif word in ("lquote", "rquote"): out.append("'")
                elif word in ("ldblquote", "rdblquote"): out.append('"')
        else:
            if skip_depth is None and c not in "\r\n": out.append(c)
            i += 1
    return re.sub(r"\n{3,}", "\n\n", re.sub(r"[ \t]+\n", "\n", "".join(out))).strip()


def extract_epub(data: bytes) -> str:
    z = _open_zip(data); names = z.namelist(); order: list[str] = []
    try:
        opf = _xml(z, "META-INF/container.xml").find(".//{*}rootfile").get("full-path")
        base = opf.rsplit("/", 1)[0] + "/" if "/" in opf else ""
        root = _xml(z, opf); manifest = {i.get("id"): i.get("href") for i in root.iter("{*}item")}
        order = [base + manifest[r.get("idref")] for r in root.iter("{*}itemref") if r.get("idref") in manifest]
    except Exception: order = []
    order = [n for n in order if n in names] or sorted(n for n in names if n.lower().endswith((".xhtml", ".html", ".htm")))
    parts = []
    for k, n in enumerate(order[:200], 1):
        t = html_to_text(z.read(n).decode("utf-8", errors="replace"))
        if t: parts.append(f"--- Section {k} ---\n{t}")
    return "\n\n".join(parts)


def extract_plist(data: bytes) -> str:
    try: obj = plistlib.loads(data)
    except Exception as e: raise ExtractionError("This property list could not be read.") from e
    def clean(x):
        if isinstance(x, bytes): return f"<{len(x)} bytes>"
        if isinstance(x, dict): return {str(k): clean(v) for k, v in x.items()}
        if isinstance(x, (list, tuple)): return [clean(v) for v in x]
        return x
    return json.dumps(clean(obj), indent=2, default=str, ensure_ascii=False)


def extract_sqlite(data: bytes) -> str:
    con = sqlite3.connect(":memory:")
    try:
        con.deserialize(data)
        tables = [r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' ORDER BY name")]
        out = [f"SQLite database with {len(tables)} table(s)/view(s)."]
        for t in tables[:25]:
            q = '"' + t.replace('"', '""') + '"'
            cols = [r[1] + (" " + r[2] if r[2] else "") for r in con.execute(f"PRAGMA table_info({q})")]
            try: count = con.execute(f"SELECT COUNT(*) FROM {q}").fetchone()[0]
            except sqlite3.Error: count = "?"
            out.append(f"\n=== {t}  ({count} rows) ===\ncolumns: " + ", ".join(cols))
            try:
                for row in con.execute(f"SELECT * FROM {q} LIMIT 5"):
                    out.append(" | ".join(f"<blob {len(v)} bytes>" if isinstance(v, bytes) else str(v)[:80] for v in row))
            except sqlite3.Error: pass
        if len(tables) > 25: out.append(f"\n[… {len(tables) - 25} more tables not shown]")
        return "\n".join(out)
    except sqlite3.Error as e: raise ExtractionError("This SQLite database could not be opened.") from e
    finally: con.close()


# ---------------------------------------------------------------- archives and unknown binaries
def _plain(b: bytes) -> str | None:
    if _looks_binary(b): return None
    try: return b.decode("utf-8")
    except UnicodeDecodeError: return None


def extract_archive(data: bytes, ext: str) -> tuple[str, str | None]:
    """A listing, plus the text files inside (never extracted to disk, never executed)."""
    listing: list[str] = []; texts: list[str] = []; total = 0; more = 0
    def consider(name: str, size: int, read) -> None:
        nonlocal total, more
        listing.append(f"{size:>12,}  {name}")
        if len(texts) >= MAX_ARCHIVE_TEXT_FILES or total >= MAX_ARCHIVE_TEXT or size == 0 or size > MAX_ARCHIVE_FILE: return
        low = name.lower()
        if low.endswith(("/", ".png", ".jpg", ".jpeg", ".gif", ".webp", ".pdf", ".zip", ".gz", ".mp3", ".mp4", ".mov", ".woff", ".woff2", ".ttf", ".class", ".pyc", ".o", ".so", ".dylib")): return
        try: t = _plain(read())
        except Exception: t = None
        if t and t.strip(): texts.append(f'=== {name} ===\n{t[:MAX_ARCHIVE_FILE]}'); total += len(t)
    kind = "archive"
    if data[:4] == b"PK\x03\x04" or ext in (".zip", ".jar", ".apk", ".pages", ".numbers", ".key"):
        z = _open_zip(data)
        infos = [i for i in z.infolist() if not i.is_dir()]
        for i in infos[:MAX_ARCHIVE_MEMBERS]: consider(i.filename, i.file_size, lambda i=i: z.read(i))
        more = len(infos) - MAX_ARCHIVE_MEMBERS
        if ext in (".pages", ".numbers", ".key"): kind = "iwork"
    else:
        try: tf = tarfile.open(fileobj=io.BytesIO(data), mode="r:*")
        except (tarfile.TarError, EOFError, OSError) as e: raise UnsupportedFile("This archive format can't be opened here. Unpack it and mention the files inside.") from e
        members = [m for m in tf.getmembers() if m.isfile()]
        if sum(m.size for m in members) > MAX_ZIP_TOTAL: raise ExtractionError("The archive is too large when unpacked (refused to protect against archive bombs).")
        for m in members[:MAX_ARCHIVE_MEMBERS]: consider(m.name, m.size, lambda m=m: tf.extractfile(m).read(MAX_ARCHIVE_FILE + 1))
        more = len(members) - MAX_ARCHIVE_MEMBERS
    head = f"Archive with {len(listing) + max(more, 0)} file(s). Listing (size in bytes, name):\n" + "\n".join(listing)
    if more > 0: head += f"\n[… {more} more files not listed]"
    warn = None
    if kind == "iwork": warn = "Apple iWork files keep their text in a private format, so only the file list is shown. Export to PDF, PPTX, DOCX or XLSX for the full content."
    return head + ("\n\nText files inside:\n\n" + "\n\n".join(texts) if texts else ""), warn


def readable_strings(data: bytes, limit: int = 120_000, min_len: int = 6) -> str:
    """Runs of readable text (ASCII and UTF-16) found anywhere in a binary file. Approximate by nature."""
    runs: list[str] = []
    for m in re.finditer(rb"[\x20-\x7e\t]{%d,}" % min_len, data): runs.append(m.group().decode("ascii"))
    for m in re.finditer(rb"(?:[\x20-\x7e]\x00){%d,}" % min_len, data): runs.append(m.group().decode("utf-16-le", errors="ignore"))
    seen, out, total = set(), [], 0
    for r in runs:
        r = r.strip()
        if len(r) < min_len or r in seen or not re.search(r"[A-Za-z]{3}", r): continue
        seen.add(r); out.append(r); total += len(r) + 1
        if total > limit: break
    return "\n".join(out)


_MAGIC = [(b"\x7fELF", "a Linux/Unix program"), (b"MZ", "a Windows program"), (b"\xcf\xfa\xed\xfe", "a macOS program"), (b"\xca\xfe\xba\xbe", "a macOS/Java program"),
          (b"ID3", "an MP3 audio file"), (b"fLaC", "a FLAC audio file"), (b"OggS", "an Ogg media file"), (b"RIFF", "a RIFF media file (WAV/AVI)"),
          (b"\x1a\x45\xdf\xa3", "a Matroska/WebM video"), (b"\x00\x00\x00\x18ftyp", "an MP4/MOV video"), (b"\x00\x00\x00\x20ftyp", "an MP4/MOV video"),
          (b"\x1f\x8b", "a gzip-compressed file"), (b"7z\xbc\xaf", "a 7-Zip archive"), (b"Rar!", "a RAR archive"), (b"BZh", "a bzip2-compressed file"),
          (b"\xfd7zXZ", "an xz-compressed file"), (b"wOFF", "a web font"), (b"wOF2", "a web font"), (b"\x00\x01\x00\x00", "a font"), (b"OTTO", "an OpenType font"),
          (b"\xd0\xcf\x11\xe0", "an old-style Microsoft Office/OLE file"), (b"SQLite format 3\x00", "a SQLite database"), (b"bplist00", "an Apple binary property list")]


def describe_binary(name: str, data: bytes) -> Extracted:
    """For files with no readable content: say honestly what it is and how big, plus a sample of any readable text inside."""
    kind = next((d for sig, d in _MAGIC if data.startswith(sig)), None) or "a binary file"
    sample = readable_strings(data[:2_000_000], limit=3000)
    text = f"{name}: {kind}, {len(data):,} bytes. The contents are not text, so only these details can be given."
    warn = "Binary file: its contents could not be read as text."
    if sample: text += "\n\nReadable text found inside (a sample, not the file's real content):\n" + sample; warn = "Binary file: only a sample of readable text was found inside; this is not the full content."
    return _finish(name, "binary", text, warn)


# ---------------------------------------------------------------- entry point
def extract(name: str, data: bytes) -> Extracted:
    if len(data) > MAX_BYTES: raise UnsupportedFile(f"File is larger than the {MAX_BYTES // 2**20} MB limit.")
    name = re.sub(r"[\x00-\x1f]", "", name or "file")[:255] or "file"
    ext = PurePosixPath(name.lower()).suffix
    if ext in IMAGE_EXT: raise UnsupportedFile("Images are sent directly to a vision-capable model, not extracted as text.")
    if data[:5] == b"%PDF-" or ext == ".pdf":
        text, warn = extract_pdf(data); return _finish(name, "pdf", text, warn)
    is_zip = data[:4] == b"PK\x03\x04"
    names: list[str] = []
    if is_zip:
        try: names = zipfile.ZipFile(io.BytesIO(data)).namelist()
        except zipfile.BadZipFile: names = []
    if ext in WORD_EXT or (is_zip and "word/document.xml" in names): return _finish(name, "docx", extract_docx(data))
    if ext in EXCEL_EXT or (is_zip and "xl/workbook.xml" in names): return _finish(name, "xlsx", extract_xlsx(data))
    if ext in POWERPOINT_EXT or (is_zip and "ppt/presentation.xml" in names):
        text, warn = extract_pptx(data); return _finish(name, "pptx", text, warn)
    if ext in ODF_EXT or (is_zip and "content.xml" in names and "mimetype" in names and b"opendocument" in zipfile.ZipFile(io.BytesIO(data)).read("mimetype")):
        return _finish(name, "odf", extract_odf(data))
    if ext == ".epub" or (is_zip and "META-INF/container.xml" in names and "mimetype" in names and b"epub" in zipfile.ZipFile(io.BytesIO(data)).read("mimetype")):
        return _finish(name, "epub", extract_epub(data))
    if data[:16] == b"SQLite format 3\x00" or ext in (".sqlite", ".sqlite3", ".db"):
        if data[:16] == b"SQLite format 3\x00": return _finish(name, "sqlite", extract_sqlite(data))
    if data[:8] == b"bplist00" or (ext == ".plist" and data.lstrip()[:5] != b"<?xml") or (data.lstrip()[:5] == b"<?xml" and b"<plist" in data[:600]):
        return _finish(name, "plist", extract_plist(data))
    if data[:5] == b"{\\rtf" or ext == ".rtf": return _finish(name, "rtf", rtf_to_text(data.decode("latin-1")))
    if is_zip or ext in (".tar", ".tgz", ".gz", ".bz2", ".xz", ".jar", ".apk", ".pages", ".numbers", ".key") or data[:2] == b"\x1f\x8b" or data[:3] == b"BZh" or data[:6] == b"\xfd7zXZ\x00" or data[257:262] == b"ustar":
        try:
            text, warn = extract_archive(data, ext); return _finish(name, "archive", text, warn)
        except UnsupportedFile:
            if data[:2] == b"\x1f\x8b":                                       # a single gzip file (not a tarball): read what is inside
                import gzip
                try: inner = gzip.decompress(data)[:MAX_BYTES]; return extract(name[:-3] if name.lower().endswith(".gz") else name + ".out", inner)
                except Exception: pass
            return describe_binary(name, data)
    if ext in LEGACY_OFFICE or data[:4] == b"\xd0\xcf\x11\xe0":
        text = readable_strings(data)
        label = LEGACY_OFFICE.get(ext, "old-style Office")
        return _finish(name, "legacy", text, f"This is a {label} file, an old binary format. The text below was pulled out of it and may be incomplete or out of order. "
                                              "For exact content, save it as .docx / .xlsx / .pptx and attach that.")
    try:
        text, warn = decode_text(data)
    except UnsupportedFile:
        return describe_binary(name, data)
    if ext in (".html", ".htm", ".xhtml"): return _finish(name, "html", html_to_text(text), warn)
    return _finish(name, "text", text, warn)
