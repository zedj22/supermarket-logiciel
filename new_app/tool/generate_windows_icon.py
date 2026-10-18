"""Compose windows/runner/resources/app_icon.ico from the rasterized brand PNGs.

Pipeline, run from ``new_app/``::

    flutter test --dart-define=GENERATE_BRAND_ASSETS=true test/tools/generate_brand_icon_test.dart
    python tool/generate_windows_icon.py

The gated test rasterizes ``lib/core/widgets/klick_logo.dart`` — the exact
painter the app draws — into ``build/brand/klick_pos_logo_<size>.png`` with
a transparent background. This script wraps those PNGs, byte for byte, as a
Vista+ ICO (PNG-compressed 32-bit entries, what Windows 10/11 Explorer and
the taskbar expect): ICONDIR, one ICONDIRENTRY per size, then the blobs.
"""

import struct
import sys
from pathlib import Path

SIZES = (16, 24, 32, 48, 64, 128, 256)
ROOT = Path(__file__).resolve().parent.parent
PNG_DIR = ROOT / "build" / "brand"
ICO_PATH = ROOT / "windows" / "runner" / "resources" / "app_icon.ico"


def main() -> int:
    blobs = []
    for size in SIZES:
        png = PNG_DIR / f"klick_pos_logo_{size}.png"
        if not png.is_file():
            print(
                f"missing {png} - run the gated generator test first",
                file=sys.stderr,
            )
            return 1
        blobs.append((size, png.read_bytes()))

    header = struct.pack("<HHH", 0, 1, len(blobs))
    offset = 6 + 16 * len(blobs)
    entries = b""
    for size, data in blobs:
        dim = 0 if size == 256 else size  # 0 encodes 256 in the ICO entry
        entries += struct.pack(
            "<BBBBHHII", dim, dim, 0, 0, 1, 32, len(data), offset
        )
        offset += len(data)

    ICO_PATH.parent.mkdir(parents=True, exist_ok=True)
    ICO_PATH.write_bytes(header + entries + b"".join(data for _, data in blobs))
    print(f"wrote {ICO_PATH} ({', '.join(str(s) for s, _ in blobs)} px)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
