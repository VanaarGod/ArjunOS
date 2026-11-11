"""Builds REAL minimal PDF / DOCX / XLSX files in memory for extraction tests (no binary fixtures committed)."""
import io, zipfile

def make_pdf(pages: list[list[str]]) -> bytes:
    objs: list[bytes] = []
    kids = " ".join(f"{3 + 2 * i} 0 R" for i in range(len(pages)))
    objs.append(b"<</Type/Catalog/Pages 2 0 R>>")
    objs.append(f"<</Type/Pages/Kids[{kids}]/Count {len(pages)}>>".encode())
    font_id = 3 + 2 * len(pages)
    for i, lines in enumerate(pages):
        content = "BT /F1 12 Tf 72 720 Td 14 TL " + " T* ".join(f"({l.replace('(', '[').replace(')', ']')}) Tj" for l in lines) + " ET"
        objs.append(f"<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]/Contents {4 + 2 * i} 0 R/Resources<</Font<</F1 {font_id} 0 R>>>>>>".encode())
        objs.append(f"<</Length {len(content)}>>\nstream\n{content}\nendstream".encode())
    objs.append(b"<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>")
    out, offs = bytearray(b"%PDF-1.4\n"), []
    for n, o in enumerate(objs, 1):
        offs.append(len(out)); out += f"{n} 0 obj\n".encode() + o + b"\nendobj\n"
    xref = len(out)
    out += f"xref\n0 {len(objs) + 1}\n0000000000 65535 f \n".encode() + b"".join(f"{o:010d} 00000 n \n".encode() for o in offs)
    out += f"trailer\n<</Size {len(objs) + 1}/Root 1 0 R>>\nstartxref\n{xref}\n%%EOF\n".encode()
    return bytes(out)

def make_docx(paragraphs: list, table: list | None = None, headings: dict | None = None) -> bytes:
    ns = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"'
    body = ""
    for i, p in enumerate(paragraphs):
        style = f'<w:pPr><w:pStyle w:val="Heading{headings[i]}"/></w:pPr>' if headings and i in headings else ""
        body += f"<w:p>{style}<w:r><w:t>{p}</w:t></w:r></w:p>"
    if table:
        body += "<w:tbl>" + "".join("<w:tr>" + "".join(f"<w:tc><w:p><w:r><w:t>{c}</w:t></w:r></w:p></w:tc>" for c in row) + "</w:tr>" for row in table) + "</w:tbl>"
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", "<Types/>"); z.writestr("word/document.xml", f"<w:document {ns}><w:body>{body}</w:body></w:document>")
    return buf.getvalue()

def make_xlsx(sheets: dict) -> bytes:
    """sheets: {name: [[cell, ...], ...]} where cells are str or numbers."""
    ns = 'xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'
    shared: list[str] = []
    def sidx(s):
        if s not in shared: shared.append(s)
        return shared.index(s)
    sheet_xml = []
    for rows in sheets.values():
        rx = ""
        for r, row in enumerate(rows, 1):
            cx = ""
            for c, v in enumerate(row):
                ref = f"{chr(65 + c)}{r}"
                if v is None: continue
                cx += f'<c r="{ref}" t="s"><v>{sidx(v)}</v></c>' if isinstance(v, str) else f'<c r="{ref}"><v>{v}</v></c>'
            rx += f'<row r="{r}">{cx}</row>'
        sheet_xml.append(f"<worksheet {ns}><sheetData>{rx}</sheetData></worksheet>")
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", "<Types/>")
        z.writestr("xl/workbook.xml", f"<workbook {ns}><sheets>" + "".join(f'<sheet name="{n}" sheetId="{i}"/>' for i, n in enumerate(sheets, 1)) + "</sheets></workbook>")
        z.writestr("xl/sharedStrings.xml", f"<sst {ns}>" + "".join(f"<si><t>{s}</t></si>" for s in shared) + "</sst>")
        for i, x in enumerate(sheet_xml, 1): z.writestr(f"xl/worksheets/sheet{i}.xml", x)
    return buf.getvalue()
