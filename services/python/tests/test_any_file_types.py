"""Every kind of file can be read: PowerPoint, Excel, OpenDocument, RTF, EPUB, SQLite, plist, archives, legacy Office, anything else."""
import gzip, io, plistlib, sqlite3, tarfile, zipfile
import pytest
from jarvis_bridge.files.extract import ExtractionError, extract
from officegen import make_xlsx

NS = ('xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"')

def make_pptx() -> bytes:
    def sp(text, title=False):
        ph = '<p:nvPr><p:ph type="title"/></p:nvPr>' if title else "<p:nvPr/>"
        return f'<p:sp><p:nvSpPr><p:cNvPr id="2" name="s"/><p:cNvSpPr/>{ph}</p:nvSpPr><p:txBody><a:p><a:r><a:t>{text}</a:t></a:r></a:p></p:txBody></p:sp>'
    table = ('<p:graphicFrame><a:graphic><a:graphicData><a:tbl><a:tr><a:tc><a:txBody><a:p><a:r><a:t>Region</a:t></a:r></a:p></a:txBody></a:tc>'
             '<a:tc><a:txBody><a:p><a:r><a:t>Sales</a:t></a:r></a:p></a:txBody></a:tc></a:tr></a:tbl></a:graphicData></a:graphic></p:graphicFrame>')
    def slide(*shapes): return f'<p:sld {NS}><p:cSld><p:spTree>{"".join(shapes)}</p:spTree></p:cSld></p:sld>'
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("ppt/presentation.xml", f'<p:presentation {NS}><p:sldIdLst><p:sldId id="256" r:id="rId2"/><p:sldId id="257" r:id="rId3"/></p:sldIdLst></p:presentation>')
        z.writestr("ppt/_rels/presentation.xml.rels", '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
                   '<Relationship Id="rId2" Target="slides/slide2.xml"/><Relationship Id="rId3" Target="slides/slide1.xml"/></Relationships>')
        z.writestr("ppt/slides/slide2.xml", slide(sp("Launch plan", True), sp("Ship in March"), table))          # first in the deck, second on disk
        z.writestr("ppt/slides/slide1.xml", slide(sp("Appendix", True), sp("Raw numbers")))
        z.writestr("ppt/slides/_rels/slide2.xml.rels", '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
                   '<Relationship Id="rId1" Target="../notesSlides/notesSlide1.xml"/></Relationships>')
        z.writestr("ppt/notesSlides/notesSlide1.xml", f'<p:notes {NS}><p:cSld><p:spTree>{sp("Mention the budget")}</p:spTree></p:cSld></p:notes>')
        z.writestr("ppt/media/image1.png", b"\x89PNG")
    return buf.getvalue()

def zipped(files: dict, **mime) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        for k, v in files.items(): z.writestr(k, v)
    return buf.getvalue()


def test_pptx_slides_in_deck_order_with_titles_tables_notes_and_a_note_about_images():
    r = extract("deck.pptx", make_pptx())
    assert r.kind == "pptx"
    assert r.text.index("Slide 1: Launch plan") < r.text.index("Slide 2: Appendix")                 # deck order, not file order
    assert "Ship in March" in r.text and "Region | Sales" in r.text and "Speaker notes: Mention the budget" in r.text
    assert "1 image(s)" in r.warning

def test_pptx_detected_by_content_even_with_a_wrong_extension():
    assert extract("deck.bin", make_pptx()).kind == "pptx"

def test_xlsx_variants_and_content_detection():
    data = make_xlsx({"Budget": [["Item", "Cost"], ["GPU", 1200]]})
    assert "GPU | 1200" in extract("b.xlsm", data).text and extract("noext", data).kind == "xlsx"

def test_opendocument_text_sheet_and_slides():
    ns = ('xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" '
          'xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0"')
    odt = zipped({"mimetype": "application/vnd.oasis.opendocument.text", "content.xml": f'<office:document-content {ns}><office:body><office:text>'
                  '<text:h text:outline-level="1">Minutes</text:h><text:p>Hello<text:s text:c="2"/>there<text:line-break/>again</text:p></office:text></office:body></office:document-content>'})
    r = extract("m.odt", odt); assert r.kind == "odf" and "# Minutes" in r.text and "Hello  there\nagain" in r.text
    ods = zipped({"mimetype": "application/vnd.oasis.opendocument.spreadsheet", "content.xml": f'<office:document-content {ns}><office:body><office:spreadsheet>'
                  '<table:table table:name="Costs"><table:table-row><table:table-cell><text:p>Item</text:p></table:table-cell><table:table-cell><text:p>Cost</text:p></table:table-cell></table:table-row>'
                  '</table:table></office:spreadsheet></office:body></office:document-content>'})
    assert "=== Costs ===" in extract("c.ods", ods).text and "Item | Cost" in extract("c.ods", ods).text
    odp = zipped({"mimetype": "application/vnd.oasis.opendocument.presentation", "content.xml": f'<office:document-content {ns}><office:body><office:presentation>'
                  '<draw:page><text:p>First slide</text:p></draw:page><draw:page><text:p>Second slide</text:p></draw:page></office:presentation></office:body></office:document-content>'})
    t = extract("p.odp", odp).text; assert "--- Slide 1 ---" in t and "Second slide" in t

def test_rtf_keeps_text_and_drops_fonts_and_formatting():
    r = extract("n.rtf", rb"{\rtf1\ansi{\fonttbl{\f0 Arial;}}{\colortbl;\red0\green0\blue0;}Hello \b world\b0\par Caf\'e9 \u8364? done}")
    assert r.kind == "rtf" and r.text.splitlines()[0] == "Hello world" and "Café € done" in r.text and "Arial" not in r.text

def test_epub_reads_chapters_in_reading_order():
    opf = '<package xmlns="http://www.idpf.org/2007/opf"><manifest><item id="a" href="c2.xhtml"/><item id="b" href="c1.xhtml"/></manifest><spine><itemref idref="b"/><itemref idref="a"/></spine></package>'
    cont = '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>'
    data = zipped({"mimetype": "application/epub+zip", "META-INF/container.xml": cont, "OEBPS/content.opf": opf,
                   "OEBPS/c1.xhtml": "<html><body><h1>One</h1><p>It began.</p></body></html>", "OEBPS/c2.xhtml": "<html><body><p>It ended.</p></body></html>"})
    r = extract("book.epub", data); assert r.kind == "epub" and r.text.index("It began.") < r.text.index("It ended.")

def test_sqlite_databases_show_schema_counts_and_sample_rows():
    con = sqlite3.connect(":memory:"); con.execute("CREATE TABLE users(id INTEGER, name TEXT, avatar BLOB)")
    con.executemany("INSERT INTO users VALUES (?,?,?)", [(i, f"user{i}", b"\x00" * 10) for i in range(8)]); con.commit()
    r = extract("app.db", con.serialize())
    assert r.kind == "sqlite" and "users  (8 rows)" in r.text and "id INTEGER, name TEXT, avatar BLOB" in r.text and "user0" in r.text and "<blob 10 bytes>" in r.text and "user7" not in r.text

def test_property_lists_xml_and_binary():
    d = {"Name": "Demo", "Count": 3, "Data": b"abc"}
    for fmt in (plistlib.FMT_XML, plistlib.FMT_BINARY):
        r = extract("Info.plist", plistlib.dumps(d, fmt=fmt)); assert r.kind == "plist" and '"Name": "Demo"' in r.text and "<3 bytes>" in r.text

def test_zip_and_tar_archives_list_files_and_read_the_text_inside():
    z = extract("proj.zip", zipped({"README.md": "# Hello project", "src/app.py": "print('hi')", "logo.png": b"\x89PNG" + bytes(100)}))
    assert z.kind == "archive" and "README.md" in z.text and "logo.png" in z.text and "Hello project" in z.text and "print('hi')" in z.text and "\x89PNG" not in z.text
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as t:
        for name, body in (("notes.txt", b"tar notes"), ("bin.dat", bytes(range(256)))):
            info = tarfile.TarInfo(name); info.size = len(body); t.addfile(info, io.BytesIO(body))
    r = extract("backup.tar.gz", buf.getvalue()); assert r.kind == "archive" and "tar notes" in r.text and "bin.dat" in r.text

def test_a_single_gzip_file_is_unpacked_and_read():
    assert extract("server.log.gz", gzip.compress(b"2026-11-10 ERROR disk full")).text == "2026-11-10 ERROR disk full"

def test_archive_with_path_traversal_names_is_only_listed_never_written():
    r = extract("evil.zip", zipped({"../../etc/cron.d/x": "* * * * * root evil"}))
    assert "../../etc/cron.d/x" in r.text                       # shown as a label; nothing is ever extracted to disk

def test_iwork_files_say_exactly_what_can_and_cannot_be_read():
    r = extract("deck.key", zipped({"Index/Document.iwa": bytes(range(256)), "preview.jpg": b"\xff\xd8" + bytes(50)}))
    assert "Index/Document.iwa" in r.text and "Export to PDF" in r.warning

def test_zip_bombs_are_refused():
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z: z.writestr("big.txt", b"0" * (60 * 1024 * 1024))
    with pytest.raises(ExtractionError, match="too large"): extract("bomb.zip", buf.getvalue())
