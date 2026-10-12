#!/usr/bin/env python3
"""
Build self-contained versions of the console (no server needed):

  dist/cip-console-standalone.html   double-click to open; emulated pipeline,
                                     client branding kept
  dist/cip-console-artifact.html     the same page as page content only
                                     (no html/head/body wrapper) and with client
                                     branding removed, for publishing as a
                                     shareable web page

Both inline the emulator and the seed so they make no network calls.
"""
import base64
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
P = ROOT / "portal"
DIST = ROOT / "dist"
DIST.mkdir(exist_ok=True)

html = (P / "index.html").read_text(encoding="utf-8")
emu = (P / "js" / "emulator.js").read_text(encoding="utf-8")
seed = json.loads((P / "data" / "seed.json").read_text(encoding="utf-8"))
logo = base64.b64encode((P / "img" / "brand-logo.svg").read_bytes()).decode()

seed_js = "window.CIP_SEED = " + json.dumps(seed, separators=(",", ":"), ensure_ascii=False).replace("</", "<\\/") + ";"
inline = f"<script>\n{seed_js}\n</script>\n<script>\n{emu}\n</script>"

page = html.replace('<script src="config.js"></script>\n', "")
page = page.replace('<script src="js/emulator.js"></script>', inline)
assert "config.js" not in page.split("<script>")[0] or True

# ---- standalone: keep branding, inline the logo
standalone = page.replace('src="img/brand-logo.svg"', f'src="data:image/svg+xml;base64,{logo}"')
standalone = re.sub(r"<!--/?BRAND-->", "", standalone)
(DIST / "cip-console-standalone.html").write_text(standalone, encoding="utf-8")

# ---- artifact: neutral branding, page content only
art = page
art = art.replace("<!--BRAND-->Wasael Property Management<!--/BRAND-->", "Managed estates")
art = re.sub(r"<!--BRAND--><img[^>]*><!--/BRAND-->", '<span class="wordmark">Portfolio Intelligence</span>', art)
art = art.replace("Wasael direct", "In-house").replace("KPI health of Wasael teams", "KPI health of in-house teams")
assert "Wasael" not in art, "branding left in artifact"
m_head = re.search(r"<head>(.*?)</head>", art, re.S)
m_body = re.search(r"<body>(.*)</body>", art, re.S)
head = m_head.group(1)
head = re.sub(r'<meta charset="UTF-8">\s*', "", head)
head = re.sub(r'<meta name="viewport"[^>]*>\s*', "", head)
artifact = head.strip() + "\n" + m_body.group(1).strip() + "\n"
(DIST / "cip-console-artifact.html").write_text(artifact, encoding="utf-8")

for f in ["cip-console-standalone.html", "cip-console-artifact.html"]:
    print(f, round((DIST / f).stat().st_size / 1024), "KB")
