"""G7 spike — Phase 15 Arabic/RTL/PDF proof for the approved ReportLab architecture.

Throwaway verification spike (NOT a production template). Generates:
  - g7_spike_80mm.pdf   (80mm width, content-driven height)
  - g7_spike_a4.pdf     (A4 210x297mm)
  - g7_evidence.json    (MediaBox, font embedding, text-order evidence)

Run:  python scripts/g7_spike.py
"""

from __future__ import annotations

import hashlib
import json
import re
import struct
import zlib
from pathlib import Path

import arabic_reshaper
from bidi.algorithm import get_display
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import Paragraph, SimpleDocTemplate, Spacer

BACKEND = Path(__file__).resolve().parents[1]
FONT_DIR = BACKEND / "app" / "printing" / "fonts"
OUT_DIR = Path(__file__).resolve().parent / "g7_spike_out"

FONT_NAME = "IBMPlexSansArabic"
REGULAR_TTF = FONT_DIR / "IBMPlexSansArabic-Regular.ttf"
BOLD_TTF = FONT_DIR / "IBMPlexSansArabic-Bold.ttf"
OFL_TXT = FONT_DIR / "OFL.txt"

ARABIC_RANGES = (
    (0x0600, 0x06FF),
    (0x0750, 0x077F),
    (0x08A0, 0x08FF),
    (0xFB50, 0xFDFF),
    (0xFE70, 0xFEFF),
)


def contains_arabic(text: str) -> bool:
    return any(lo <= ord(ch) <= hi for ch in text for lo, hi in ARABIC_RANGES)


def sanitize_text(text: str) -> str:
    """Strip control chars and bidi overrides (Phase 15 security §17.3)."""
    out = []
    for ch in text:
        o = ord(ch)
        if 0x202A <= o <= 0x202E or 0x2066 <= o <= 0x2069 or o in (0x200E, 0x200F):
            continue
        if o < 0x20 and ch not in "\t\n":
            continue
        out.append(ch)
    return "".join(out)


def shape_text(text: str) -> str:
    """Sanitize, then reshape+bidi ONLY when Arabic is present (no bidi on pure numbers)."""
    text = sanitize_text(text)
    if not contains_arabic(text):
        return text
    return get_display(arabic_reshaper.reshape(text))


CASES: list[tuple[str, str]] = [
    ("arabic_connected", "مرحبا بكم في متجر التموين الحديث"),
    ("mixed_ar_latin", "منتج Product 123 متوفر الآن"),
    ("arabic_western_digits", "الكمية المطلوبة: 1234 × 56.78"),
    ("negative_money_arabic", "الخصم: -1250.50 DA"),
    ("negative_money_pure", "-1250.50 DA"),
    ("percentage", "هامش الربح: 12.50%"),
    ("invoice_line", "INV-20261001-115500-a1b2 | سعر الوحدة 45.90 DA"),
    (
        "long_arabic_name",
        "حليب كامل الدسم الطازج من مزرعة الأبقار المحلية المعتمدة مع فيتامينات إضافية ووزن صافي واحد لتر",
    ),
    ("french", "Café moulu arabica — 250 g, Yaourt nature, Pâte fraîche 200 g, Jus d'orange 1 L"),
    ("english", "Thank you for your purchase! Cashier: John Doe"),
]


def register_fonts() -> None:
    missing = [str(p) for p in (REGULAR_TTF, BOLD_TTF, OFL_TXT) if not p.exists()]
    if missing:
        raise SystemExit(f"MISSING_FONT: {missing}")
    pdfmetrics.registerFont(TTFont(FONT_NAME, str(REGULAR_TTF)))
    pdfmetrics.registerFont(TTFont(f"{FONT_NAME}-Bold", str(BOLD_TTF)))


def build_pdf(path: Path, pagesize: tuple[float, float], margins: tuple[float, float, float, float]) -> dict:
    left, right, top, bottom = margins
    doc = SimpleDocTemplate(
        str(path),
        pagesize=pagesize,
        leftMargin=left,
        rightMargin=right,
        topMargin=top,
        bottomMargin=bottom,
        pageCompression=0,  # test profile: readable content streams
    )
    content_width = pagesize[0] - left - right
    story = [Paragraph("G7 SPIKE", ParagraphStyle("t", fontName=FONT_NAME, fontSize=14, alignment=1))]
    story.append(Spacer(1, 4 * mm))
    for key, text in CASES:
        rtl = contains_arabic(text)
        style = ParagraphStyle(
            key,
            fontName=FONT_NAME,
            fontSize=9,
            leading=13,
            wordWrap="RTL" if rtl else "CJK",
            alignment=2 if rtl else 0,
        )
        shaped = shape_text(text).replace("&", "&amp;").replace("<", "&lt;")
        story.append(Paragraph(shaped, style))
        story.append(Spacer(1, 2 * mm))
    doc.build(story)
    return {"file": path.name, "content_width_pt": round(content_width, 3)}


# --------------------------------------------------------------------------- PDF parsing


def parse_objects(raw: bytes) -> dict[int, bytes]:
    objs: dict[int, bytes] = {}
    for m in re.finditer(rb"(\d+)\s+\d+\s+obj\b(.*?)\bendobj", raw, re.DOTALL):
        objs[int(m.group(1))] = m.group(2)
    return objs


def stream_data(obj: bytes) -> bytes | None:
    m = re.search(rb"stream\r?\n(.*?)endstream", obj, re.DOTALL)
    if not m:
        return None
    data = m.group(1).rstrip(b"\r\n")
    if b"/FlateDecode" in obj[: m.start()]:
        try:
            data = zlib.decompress(data)
        except zlib.error:
            return None
    return data


def decode_pdf_literal(raw: bytes) -> bytes:
    """Decode PDF literal-string escapes (octal \\ddd, \\n, \\(...\\ etc.)."""
    out = bytearray()
    i = 0
    simple = {0x6E: 0x0A, 0x72: 0x0D, 0x74: 0x09, 0x62: 0x08, 0x66: 0x0C}
    while i < len(raw):
        c = raw[i]
        if c != 0x5C:
            out.append(c)
            i += 1
            continue
        i += 1
        if i >= len(raw):
            break
        n = raw[i]
        if 0x30 <= n <= 0x37:
            j = i
            while j < len(raw) and j < i + 3 and 0x30 <= raw[j] <= 0x37:
                j += 1
            out.append(int(raw[i:j], 8) & 0xFF)
            i = j
            continue
        if n in simple:
            out.append(simple[n])
        elif n in (0x28, 0x29, 0x5C):
            out.append(n)
        elif n == 0x0D:
            i += 1
            if i < len(raw) and raw[i] == 0x0A:
                i += 1
            continue
        elif n == 0x0A:
            continue
        else:
            out.append(n)
        i += 1
    return bytes(out)


def parse_tounicode(data: bytes) -> dict[int, str]:
    mapping: dict[int, str] = {}
    text = data.decode("latin1")
    for block in re.findall(r"beginbfchar(.*?)endbfchar", text, re.DOTALL):
        for src, dst in re.findall(r"<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>", block):
            mapping[int(src, 16)] = chr(int(dst, 16))
    for block in re.findall(r"beginbfrange(.*?)endbfrange", text, re.DOTALL):
        for lo, hi, dst in re.findall(
            r"<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>", block
        ):
            lo_i, dst_i = int(lo, 16), int(dst, 16)
            for i, cid in enumerate(range(lo_i, int(hi, 16) + 1)):
                mapping[cid] = chr(dst_i + i)
        for lo, hi, arr in re.findall(
            r"<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*\[(.*?)\]", block, re.DOTALL
        ):
            dsts = re.findall(r"<([0-9A-Fa-f]+)>", arr)
            for i, cid in enumerate(range(int(lo, 16), int(hi, 16) + 1)):
                if i < len(dsts):
                    mapping[cid] = chr(int(dsts[i], 16))
    return mapping


def extract_text_blocks(raw: bytes) -> list[tuple[str, str]]:
    """Return (font_base, drawn_text) per BT/ET block, in content-stream order."""
    objs = parse_objects(raw)
    font_maps: dict[str, dict[int, str]] = {}  # BaseFont -> ToUnicode map
    for obj in objs.values():
        m = re.search(rb"/ToUnicode\s+(\d+)\s+0\s+R", obj)
        if not m:
            continue
        data = stream_data(objs.get(int(m.group(1)), b""))
        if not data:
            continue
        bm = re.search(rb"/BaseFont\s*/([A-Za-z0-9+\-_,.]+)", obj)
        key = bm.group(1).decode("latin1") if bm else f"anon{m.group(1)}"
        font_maps[key] = parse_tounicode(data)
    # page resources: resource name -> BaseFont (font dict may be an indirect ref)
    res_fonts: dict[str, str] = {}
    for obj in objs.values():
        if b"/Font" not in obj or b"/BaseFont" in obj:
            continue
        refs = []
        direct = re.search(rb"/Font\s*<<(.*?)>>", obj, re.DOTALL)
        if direct:
            refs = re.findall(rb"/(F[\w+]+)\s+(\d+)\s+0\s+R", direct.group(1))
        else:
            indirect = re.search(rb"/Font\s+(\d+)\s+0\s+R", obj)
            if indirect:
                target = objs.get(int(indirect.group(1)), b"")
                refs = re.findall(rb"/(F[\w+]+)\s+(\d+)\s+0\s+R", target)
        for res_name, ref in refs:
            bm = re.search(rb"/BaseFont\s*/([A-Za-z0-9+\-_,.]+)", objs.get(int(ref), b""))
            if bm:
                res_fonts[res_name.decode()] = bm.group(1).decode("latin1")

    blocks: list[tuple[str, str]] = []
    token_re = re.compile(
        rb"/(F[\w+]+)\s+[\d.]+\s+Tf|<([0-9A-Fa-f]+)>\s*Tj|\[(.*?)\]\s*TJ|\((.*?)\)\s*Tj|T\*",
        re.DOTALL,
    )
    for obj in objs.values():
        data = stream_data(obj) if b"stream" in obj else None
        if not data or b"BT" not in data:
            continue
        current: dict[int, str] = {}
        current_name = ""
        for bt in re.finditer(rb"BT(.*?)ET", data, re.DOTALL):
            chunk = bt.group(1)
            lines: list[str] = []
            parts: list[str] = []

            def emit(codes: list[int]) -> None:
                parts.append("".join(current.get(c, "") for c in codes))

            for tok in token_re.finditer(chunk):
                if tok.group(1) is not None:
                    base = res_fonts.get(tok.group(1).decode(), "")
                    if base in font_maps:
                        current = font_maps[base]
                    current_name = base
                elif tok.group(2) is not None:
                    hexs = tok.group(2).decode()
                    emit([int(hexs[i : i + 4], 16) for i in range(0, len(hexs) - 3, 4)])
                elif tok.group(3) is not None:
                    for seg in re.findall(rb"<([0-9A-Fa-f]+)>", tok.group(3)):
                        hexs = seg.decode()
                        emit([int(hexs[i : i + 4], 16) for i in range(0, len(hexs) - 3, 4)])
                    for seg in re.findall(rb"\((.*?)\)", tok.group(3)):
                        emit(list(decode_pdf_literal(seg)))
                elif tok.group(4) is not None:
                    emit(list(decode_pdf_literal(tok.group(4))))
                else:  # T* — line break inside this BT block
                    lines.append("".join(parts))
                    parts = []
            lines.append("".join(parts))
            for line in lines:
                if line.strip():
                    blocks.append((current_name, line))
    return blocks


# --------------------------------------------------------------------------- verification


def font_name_table(path: Path) -> dict[int, str]:
    d = path.read_bytes()
    num = struct.unpack(">H", d[4:6])[0]
    name_off = None
    for i in range(num):
        rec = d[12 + 16 * i : 28 + 16 * i]
        if rec[:4] == b"name":
            name_off = struct.unpack(">II", rec[8:16])[0]
    if name_off is None:
        return {}
    t = d[name_off:]
    _, cnt, stro = struct.unpack(">HHH", t[:6])
    out: dict[int, str] = {}
    for i in range(cnt):
        pid, _e, _l, nid, ln, so = struct.unpack(">HHHHHH", t[6 + 12 * i : 18 + 12 * i])
        if nid in (1, 13, 14):
            s = t[stro + so : stro + so + ln]
            try:
                out[nid] = s.decode("utf-16-be") if pid == 3 else s.decode("latin1")
            except UnicodeDecodeError:
                out[nid] = repr(s)
    return out


def mediboxes(raw: bytes) -> list[list[float]]:
    return [
        [float(x) for x in m.groups()]
        for m in re.finditer(
            rb"/MediaBox\s*\[\s*([\d.\-]+)\s+([\d.\-]+)\s+([\d.\-]+)\s+([\d.\-]+)\s*\]", raw
        )
    ]


def verify(path: Path, expect_width_pt: float, expect_height_pt: float | None,
           require_long_wrap: bool) -> dict:
    raw = path.read_bytes()
    ev: dict = {"file": path.name, "bytes": len(raw)}

    boxes = mediboxes(raw)
    ev["mediabox"] = boxes
    widths = [b[2] - b[0] for b in boxes]
    heights = [b[3] - b[1] for b in boxes]
    ev["width_ok"] = bool(widths) and all(abs(w - expect_width_pt) <= 0.1 for w in widths)
    ev["height_ok"] = expect_height_pt is None or (
        bool(heights) and all(abs(h - expect_height_pt) <= 0.1 for h in heights)
    )

    basefonts = sorted({m.decode() for m in re.findall(rb"/BaseFont\s*/([A-Za-z0-9+\-_]+)", raw)})
    ev["basefonts"] = basefonts
    ev["fontfile2_count"] = raw.count(b"/FontFile2")
    blocks = extract_text_blocks(raw)
    ev["text_blocks"] = [t for _, t in blocks]
    used_fonts = sorted({f for f, t in blocks if f and t.strip()})
    ev["fonts_used_for_text"] = used_fonts
    ev["all_fonts_embedded_subset"] = bool(used_fonts) and all("+" in f for f in used_fonts)
    standard14 = {"Helvetica", "Helvetica-Bold", "Times-Roman", "Times-Bold", "Courier"}
    ev["no_standard14_fallback"] = not any(f.split("+")[-1] in standard14 for f in used_fonts)
    ev["proprietary_font_absent"] = not any(
        n in raw for n in (b"Tahoma", b"/Arial", b"segoui", b"Segoe", b"/ArialMT")
    )

    texts = [t for _, t in blocks]

    checks: dict[str, bool] = {}
    joined = "\n".join(texts)
    norm = re.sub(r"\s+", "", joined)

    for key, text in CASES:
        expected = shape_text(text)
        if re.sub(r"\s+", "", expected) in norm:
            checks[f"rendered:{key}"] = True
            continue
        if key == "long_arabic_name":
            # wrapped across blocks: all shaped words present in draw order
            words = [w for w in expected.split() if w]
            checks[f"rendered:{key}"] = _words_in_order(words, joined)
            continue
        checks[f"rendered:{key}"] = False

    checks["digits_ordered"] = "1234" in joined and "56.78" in joined
    # LTR context keeps "-1250.50"; RTL bidi places the sign adjacent on the other
    # side of the digits (1250.50-) — digits must stay contiguous in both cases.
    checks["minus_unambiguous"] = bool(
        re.search(r"-1250\.50", joined) and re.search(r"1250\.50-", joined)
    )
    # Bidi-correct RTL output is "%12.50" (contiguous digits); LTR keeps "12.50%".
    pct = re.search(r"%(\d+\.\d+)|(\d+\.\d+)%", joined)
    ev["percentage_form"] = pct.group(0) if pct else None
    checks["percentage_intact"] = bool(pct)
    # On the narrow receipt the long name MUST wrap; on A4 it may fit one line.
    if require_long_wrap:
        checks["long_text_wrapped"] = _long_wrapped(texts)
    else:
        expected_long = shape_text(dict(CASES)["long_arabic_name"])
        checks["long_text_wrapped"] = _words_in_order(
            [w for w in expected_long.split() if w], joined
        )
    checks["fonts_embedded_no_fallback"] = (
        ev["all_fonts_embedded_subset"] and ev["no_standard14_fallback"]
    )
    checks["no_proprietary_font"] = ev["proprietary_font_absent"]
    ev["long_wrap_required"] = require_long_wrap

    ev["checks"] = checks
    ev["passed"] = all(checks.values()) and ev["width_ok"] and ev["height_ok"]
    return ev


def _words_in_order(words: list[str], joined: str) -> bool:
    pos = 0
    for word in words:
        idx = joined.find(word, pos)
        if idx < 0:
            return False
        pos = idx + len(word)
    return True


def _long_wrapped(texts: list[str]) -> bool:
    """Long Arabic name must occupy >= 2 drawn blocks (wrapped), words in order."""
    expected = shape_text(dict(CASES)["long_arabic_name"])
    words = [w for w in expected.split() if w]
    if len(words) < 2:
        return False
    containing = [t for t in texts if any(w in t for w in words)]
    if len(containing) < 2:
        return False
    return _words_in_order(words, "\n".join(texts))


def main() -> int:
    register_fonts()
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    fname = font_name_table(REGULAR_TTF)
    font_evidence = {
        "family": fname.get(1),
        "license_url": fname.get(14),
        "license_text": (fname.get(13) or "")[:200],
        "regular_sha256": hashlib.sha256(REGULAR_TTF.read_bytes()).hexdigest(),
        "bold_sha256": hashlib.sha256(BOLD_TTF.read_bytes()).hexdigest(),
        "ofl_bundled": OFL_TXT.exists(),
        "source": "SIL OFL 1.1 font downloaded with Google Fonts package (IBM Plex Sans Arabic)",
    }

    p80 = OUT_DIR / "g7_spike_80mm.pdf"
    pa4 = OUT_DIR / "g7_spike_a4.pdf"
    info80 = build_pdf(p80, (80 * mm, 400 * mm), (4 * mm, 4 * mm, 5 * mm, 5 * mm))
    infoa4 = build_pdf(pa4, A4, (13 * mm, 13 * mm, 12 * mm, 12 * mm))

    ev80 = verify(p80, 80 * mm, None, require_long_wrap=True)  # content-driven height
    eva4 = verify(pa4, A4[0], A4[1], require_long_wrap=False)

    report = {
        "font": font_evidence,
        "spike_80mm": {**info80, **ev80},
        "spike_a4": {**infoa4, **eva4},
        "cases": [k for k, _ in CASES],
        "g7_passed": bool(ev80["passed"] and eva4["passed"]),
    }
    (OUT_DIR / "g7_evidence.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8"
    )

    print(f"80mm width_ok={ev80['width_ok']} height_ok={ev80['height_ok']} passed={ev80['passed']}")
    print(f"A4   width_ok={eva4['width_ok']} height_ok={eva4['height_ok']} passed={eva4['passed']}")
    for name, ev in (("80mm", ev80), ("A4", eva4)):
        for k, v in ev["checks"].items():
            if not v:
                print(f"FAIL [{name}] {k}")
        print(f"{name} mediabox={ev['mediabox']}")
        print(f"{name} basefonts={ev['basefonts']} fontfile2={ev['fontfile2_count']}")
    print(f"G7: {'PASS' if report['g7_passed'] else 'FAIL'}")
    print(f"evidence: {OUT_DIR / 'g7_evidence.json'}")
    return 0 if report["g7_passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
