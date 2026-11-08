#!/usr/bin/env python3
"""Assemble panel/index.html (one self-contained file) from panel/src + panel/vendor.
Run:  python3 panel/build.py      (no dependencies)"""
import base64, json, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
os.environ.setdefault("PANEL_KEY", "build")
import server  # noqa: E402  (only for the REGIONS table)

def rd(*p, mode="r"):
    with open(os.path.join(HERE, *p), mode) as fh:
        return fh.read()

FONTS = [
    ("Big Shoulders Display", 800, "big-shoulders-display-latin-800-normal.woff2"),
    ("Big Shoulders Display", 600, "big-shoulders-display-latin-600-normal.woff2"),
    ("Hanken Grotesk", 400, "hanken-grotesk-latin-400-normal.woff2"),
    ("Hanken Grotesk", 600, "hanken-grotesk-latin-600-normal.woff2"),
    ("JetBrains Mono", 400, "jetbrains-mono-latin-400-normal.woff2"),
]
faces = "".join(
    '@font-face{font-family:"%s";font-weight:%d;font-style:normal;font-display:swap;src:url(data:font/woff2;base64,%s) format("woff2")}\n'
    % (fam, w, base64.b64encode(rd("vendor", "fonts", f, mode="rb")).decode()) for fam, w, f in FONTS)
regions = {k: list(v) for k, v in server.REGIONS.items()}
js = (rd("src", "app.js").replace("@@BASE@@", server.BASE)
      .replace("@@REGIONS@@", json.dumps(regions, separators=(",", ":")))
      .replace("@@LAND@@", rd("vendor", "land-mask.b64").strip()))
html = ('<!doctype html>\n<html lang="en"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">'
        '<meta name="robots" content="noindex,nofollow"><meta name="color-scheme" content="dark">'
        '<title>Saeka \u00b7 server control</title>'
        '<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns=%27http://www.w3.org/2000/svg%27 viewBox=%270 0 24 24%27%3E%3Ccircle cx=%2712%27 cy=%2712%27 r=%279%27 fill=%27none%27 stroke=%27%23ffb21a%27 stroke-width=%272.5%27/%3E%3Ccircle cx=%2712%27 cy=%2712%27 r=%274%27 fill=%27%23ffb21a%27/%3E%3C/svg%3E">'
        '<style>\n' + faces + rd("src", "style.css") + '\n</style></head><body>\n'
        + rd("src", "body.html") +
        '\n<script>/* qrcode-generator (c) Kazuhiko Arase, MIT */\n' + rd("vendor", "qrcode.min.js") + '\n</script>\n'
        '<script>\n' + js + '\n</script>\n</body></html>\n')
with open(os.path.join(HERE, "index.html"), "w", encoding="utf-8") as fh:
    fh.write(html)
print("wrote panel/index.html  %d KB" % (len(html) // 1024))
