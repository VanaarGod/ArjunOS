import io, zipfile
import pytest
from jarvis_bridge.files import extract as ex
from jarvis_bridge.files.extract import extract, UnsupportedFile, ExtractionError
from officegen import make_pdf, make_docx, make_xlsx

# ---------------- text ----------------
def test_plain_text_and_code_roundtrip():
    r = extract("notes.md", "# Title\n\nSome **text** ünïcode ✓\n".encode()); assert r.kind == "text" and "ünïcode ✓" in r.text and not r.truncated and r.warning is None
    r = extract("main.swift", b"let x = 1\nprint(x)\n"); assert r.text.startswith("let x")
    assert extract("data.csv", b"a,b\n1,2\n").text == "a,b\n1,2\n" and extract("c.json", b'{"a": [1, 2]}').text == '{"a": [1, 2]}'

def test_encodings_utf16_bom_latin1_and_crlf():
    assert extract("u16.txt", "héllo wörld".encode("utf-16")).text == "héllo wörld"
    assert extract("bom.txt", b"\xef\xbb\xbfhello").text == "hello"
    r = extract("old.txt", "café".encode("latin-1")); assert r.text == "café" and "Latin-1" in r.warning
    assert extract("w.txt", b"a\r\nb\rc").text == "a\nb\nc"

@pytest.mark.parametrize("data", [bytes(range(256)) * 40, b"\x00\x01\x02binary", b"ELF\x00\x00\x00" * 100])
def test_binary_files_are_described_honestly_not_turned_into_garbage(data):
    r = extract("thing.dat", data)
    assert r.kind == "binary" and "contents are not text" in r.text and f"{len(data):,} bytes" in r.text and "Binary file" in r.warning

def test_html_is_reduced_to_text_without_scripts_or_styles():
    html = b"<html><head><style>p{color:red}</style><script>alert('x')</script></head><body><h1>Title</h1><p>Hello &amp; welcome</p><ul><li>a</li><li>b</li></ul></body></html>"
    r = extract("page.html", html); assert r.kind == "html" and "alert" not in r.text and "color:red" not in r.text
    assert "Title" in r.text and "Hello & welcome" in r.text and "a\n" in r.text

def test_long_text_is_truncated_and_says_so():
    r = extract("big.txt", b"x" * (ex.MAX_TEXT_CHARS + 500)); assert r.truncated and len(r.text) == ex.MAX_TEXT_CHARS and r.chars == ex.MAX_TEXT_CHARS + 500 and "first" in r.warning

def test_empty_file_warns():
    assert "No text" in extract("empty.txt", b"").warning

def test_size_limit_and_path_like_names():
    with pytest.raises(UnsupportedFile, match="larger"): extract("x.txt", b"a" * (ex.MAX_BYTES + 1))
    assert extract("../../etc/passwd\n.txt", b"hi").name == "../../etc/passwd.txt"        # only used as a label; never opened as a path

# ---------------- every other type is read in some honest way ----------------
def test_legacy_office_files_give_best_effort_text_with_a_clear_warning():
    doc = b"\xd0\xcf\x11\xe0" + bytes(200) + "Quarterly budget summary".encode("utf-16-le") + bytes(50) + b"Approved by the finance committee" + bytes(30)
    for name in ("a.doc", "a.xls", "a.ppt"):
        r = extract(name, doc)
        assert r.kind == "legacy" and "Quarterly budget summary" in r.text and "Approved by the finance committee" in r.text and "old binary format" in r.warning

def test_programs_and_media_say_what_they_are():
    r = extract("tool", b"\x7fELF" + bytes(300)); assert r.kind == "binary" and "Linux/Unix program" in r.text
    r = extract("song.mp3", b"ID3" + bytes(300)); assert "MP3 audio" in r.text

def test_images_are_redirected_to_vision_not_extracted():
    with pytest.raises(UnsupportedFile, match="vision"): extract("pic.PNG", b"\x89PNG")

def test_a_broken_office_file_is_a_clear_error_not_garbage():
    for name in ("a.pptx", "a.zip", "a.pages", "a.docx"):
        with pytest.raises(ExtractionError): extract(name, b"PK\x03\x04 definitely not a zip")

# ---------------- pdf ----------------
def test_pdf_text_is_extracted_per_page():
    r = extract("report.pdf", make_pdf([["Hello PDF world", "second line"], ["Page two content"]]))
    assert r.kind == "pdf" and "--- Page 1 ---" in r.text and "Hello PDF world" in r.text and "second line" in r.text and "--- Page 2 ---" in r.text and "Page two content" in r.text

def test_pdf_detected_by_magic_even_with_wrong_extension():
    assert "Hello" in extract("report.dat", make_pdf([["Hello"]])).text

def test_pdf_with_no_text_warns_about_scans():
    r = extract("scan.pdf", make_pdf([[""]])); assert r.text == "" and "scanned" in r.warning and "OCR" in r.warning

def test_corrupt_pdf_is_a_clean_error():
    with pytest.raises(ExtractionError): extract("broken.pdf", b"%PDF-1.4\n garbage not a pdf")

def test_pdf_page_cap(monkeypatch):
    monkeypatch.setattr(ex, "MAX_PDF_PAGES", 2)
    r = extract("long.pdf", make_pdf([[f"page {i}"] for i in range(1, 6)])); assert "page 1" in r.text and "page 2" in r.text and "page 4" not in r.text and "first 2 of 5" in r.warning

def test_missing_pypdf_gives_an_actionable_error(monkeypatch):
    import builtins; real = builtins.__import__
    def fake(name, *a, **k):
        if name == "pypdf": raise ImportError("no pypdf")
        return real(name, *a, **k)
    monkeypatch.setattr(builtins, "__import__", fake)
    with pytest.raises(ExtractionError, match="setup.sh"): extract("a.pdf", make_pdf([["x"]]))

# ---------------- docx ----------------
def test_docx_paragraphs_headings_and_tables():
    r = extract("memo.docx", make_docx(["Project Plan", "We will ship in May.", "Details"], table=[["Task", "Owner"], ["Build", "Ana"]], headings={0: 1, 2: 2}))
    assert r.kind == "docx" and "# Project Plan" in r.text and "## Details" in r.text and "We will ship in May." in r.text
    assert "Task | Owner" in r.text and "Build | Ana" in r.text

def test_docx_detected_by_content_without_extension():
    assert "hello" in extract("noext", make_docx(["hello"])).text

def test_docx_with_dtd_is_refused_and_zip_bombs_are_refused():
    evil = io.BytesIO()
    with zipfile.ZipFile(evil, "w") as z: z.writestr("word/document.xml", '<!DOCTYPE x [<!ENTITY a "aaaa">]><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body/></w:document>')
    with pytest.raises(ExtractionError, match="DTD"): extract("evil.docx", evil.getvalue())
    bomb = io.BytesIO()
    with zipfile.ZipFile(bomb, "w", zipfile.ZIP_DEFLATED) as z: z.writestr("word/document.xml", b"0" * (ex.MAX_ZIP_MEMBER + 10))
    assert len(bomb.getvalue()) < 200_000                                         # tiny on disk...
    with pytest.raises(ExtractionError, match="zip bombs"): extract("bomb.docx", bomb.getvalue())   # ...huge unpacked

def test_damaged_docx_and_wrong_office_type():
    with pytest.raises(ExtractionError, match="damaged"): extract("x.docx", b"PK\x03\x04 not really a zip")
    with pytest.raises(ExtractionError, match="not a Word"): extract("x.docx", make_xlsx({"S": [["a"]]}))

# ---------------- xlsx ----------------
def test_xlsx_sheets_rows_gaps_and_numbers():
    r = extract("budget.xlsx", make_xlsx({"Q1": [["Item", "Cost"], ["GPU", 1200], ["Fan", None, "note"]], "Q2": [["Total", 99.5]]}))
    assert r.kind == "xlsx" and "=== Q1 ===" in r.text and "Item | Cost" in r.text and "GPU | 1200" in r.text and "Fan |  | note" in r.text and "=== Q2 ===" in r.text and "Total | 99.5" in r.text

def test_xlsx_row_and_sheet_caps(monkeypatch):
    monkeypatch.setattr(ex, "MAX_ROWS", 3); monkeypatch.setattr(ex, "MAX_SHEETS", 1)
    r = extract("big.xlsx", make_xlsx({"A": [[i] for i in range(10)], "B": [["hidden"]]}))
    assert "more rows not shown" in r.text and "hidden" not in r.text and "more sheets not shown" in r.text


# ---- isolate each binary-detection rule (each used to be masked by the other) ----
def test_a_single_nul_byte_in_otherwise_plain_text_is_binary():
    r = extract("x.dat", b"perfectly ordinary ascii text " * 200 + b"\x00" + b"more text" * 50)
    assert r.kind == "binary" and "sample" in r.text

def test_many_control_characters_without_any_nul_is_binary():
    data = (b"abc\x01\x02\x03\x04\x05\x06" * 400)
    assert b"\x00" not in data
    assert extract("x.dat", data).kind == "binary"

def test_normal_text_with_tabs_newlines_and_a_few_controls_is_still_text():
    assert "col1\tcol2" in extract("t.tsv", b"col1\tcol2\r\nv1\tv2\x0c\n").text

# ---- encrypted PDFs ----
def test_password_protected_pdf_is_refused_with_a_clear_message():
    from pypdf import PdfReader, PdfWriter
    r = PdfReader(io.BytesIO(make_pdf([["secret contents"]]))); w = PdfWriter(); [w.add_page(p) for p in r.pages]
    w.encrypt("hunter2", algorithm="RC4-128"); buf = io.BytesIO(); w.write(buf)
    with pytest.raises(ExtractionError, match="password-protected"): extract("locked.pdf", buf.getvalue())


def test_pdf_import_failure_is_diagnosed_and_names_the_python(monkeypatch):
    import builtins, sys; real = builtins.__import__
    def fake(name, *a, **k):
        if name == "pypdf": raise ImportError("No module named 'pypdf'")
        return real(name, *a, **k)
    monkeypatch.setattr(builtins, "__import__", fake)
    with pytest.raises(ExtractionError) as ei: extract("a.pdf", make_pdf([["x"]]))
    msg = str(ei.value); assert sys.executable in msg and "setup.sh" in msg and "pip install pypdf" in msg
