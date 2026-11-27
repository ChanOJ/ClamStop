#!/usr/bin/env python3
"""Builds the website from one template and one strings file per language.

Standard library only. Run from anywhere:

    python3 site/src/build.py

Reads site/src/{template,404}.html and site/src/strings/<lang>.json, writes site/index.html,
site/<lang>/index.html, site/404.html, site/sitemap.xml, site/robots.txt, and extracts the
icons of site/img/ from Resources/AppIcon.icns. See site/src/README.md.
"""

import html
import json
import re
import struct
import sys
from pathlib import Path

SRC = Path(__file__).resolve().parent
SITE = SRC.parent
ICNS = SITE.parent / "Resources" / "AppIcon.icns"

BASE_URL = "https://chanoj.github.io/ClamStop/"
BASE_PATH = "/ClamStop/"
REPO_URL = "https://github.com/ChanOJ/ClamStop"
DEFAULT_LANG = "en"
# Placeholder: replace with the direct link to ClamStop Light once it is on the Mac App Store.
APP_STORE_URL = "https://www.apple.com/app-store/"
# Placeholder, same as Links.donation in the app: replace once the Stripe Payment Link exists.
DONATION_URL = "https://buy.stripe.com/placeholder"

# Pixel size of the PNG to extract -> icns entry that holds it.
ICONS = {64: b"ic12", 256: b"ic08"}

PLACEHOLDER = re.compile(r"\{\{\s*([\w.@-]+)\s*\}\}")
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def fail(message):
    sys.exit(f"build.py: {message}")


def extract_icons():
    data = ICNS.read_bytes()
    if data[:4] != b"icns":
        fail(f"{ICNS} is not an icns file")
    entries, offset = {}, 8
    while offset + 8 <= len(data):
        kind = data[offset:offset + 4]
        length = struct.unpack(">I", data[offset + 4:offset + 8])[0]
        if length < 8:
            fail(f"{ICNS} is damaged")
        entries[kind] = data[offset + 8:offset + length]
        offset += length
    for size, kind in ICONS.items():
        png = entries.get(kind, b"")
        if not png.startswith(PNG_SIGNATURE):
            fail(f"{ICNS} has no PNG entry {kind.decode()} ({size} px)")
        (SITE / "img" / f"icon-{size}.png").write_bytes(png)


def png_size(path):
    header = path.read_bytes()[:24]
    if not header.startswith(PNG_SIGNATURE):
        fail(f"{path} is not a PNG file")
    return struct.unpack(">II", header[16:24])


def localized_image(name, lang, suffix=""):
    """Path (relative to site/) of img/<name>-<lang><suffix>.png, else the English one, else None."""
    for code in (lang, DEFAULT_LANG):
        path = f"img/{name}-{code}{suffix}.png"
        if (SITE / path).is_file():
            return path
    return None


def screenshot(name, lang, prefix, alt, caption):
    """A <figure> that follows the color scheme, or nothing while the screenshots are missing."""
    light = localized_image(name, lang, "-light")
    dark = localized_image(name, lang, "-dark")
    if not light or not dark:
        return ""
    # Screenshots are taken on a Retina display: shown at half their pixel size.
    width, height = (value // 2 for value in png_size(SITE / light))
    dark_width, dark_height = (value // 2 for value in png_size(SITE / dark))
    return (
        f'<figure class="shot shot-{name}">\n'
        f"  <picture>\n"
        f'    <source media="(prefers-color-scheme: dark)" srcset="{prefix}{dark}" '
        f'width="{dark_width}" height="{dark_height}">\n'
        f'    <img src="{prefix}{light}" width="{width}" height="{height}" '
        f'alt="{html.escape(alt)}">\n'
        f"  </picture>\n"
        f"  <figcaption>{html.escape(caption)}</figcaption>\n"
        f"</figure>"
    )


def page_path(lang):
    return "" if lang == DEFAULT_LANG else f"{lang}/"


def language_links(languages):
    links = [
        f'<link rel="alternate" hreflang="{code}" href="{BASE_URL}{page_path(code)}">'
        for code in languages
    ]
    links.append(f'<link rel="alternate" hreflang="x-default" href="{BASE_URL}">')
    return "\n  ".join(links)


def language_switcher(languages, current, prefix):
    if len(languages) < 2:
        return ""
    items = []
    for code, strings in languages.items():
        active = ' aria-current="page"' if code == current else ""
        href = f"{prefix}{page_path(code)}" or "./"
        items.append(
            f'<li><a href="{href}" lang="{code}" hreflang="{code}"{active}>'
            f'{html.escape(strings["lang.name"])}</a></li>'
        )
    label = html.escape(languages[current]["lang.switcher"])
    return f'<nav class="languages" aria-label="{label}"><ul>{"".join(items)}</ul></nav>'


def render(template, strings, variables, used):
    """Replaces {{key}}: `@name` is a computed value, anything else a translated string.

    Strings are escaped, except keys ending in `_html`, which may hold markup and `{{@name}}`.
    """
    def replace(match):
        key = match.group(1)
        if key.startswith("@"):
            if key not in variables:
                fail(f"unknown variable {key}")
            return variables[key]
        if key not in strings:
            fail(f"{variables['@lang']}: missing string {key}")
        used.add(key)
        if key.endswith("_html"):
            return render(strings[key], strings, variables, used)
        return html.escape(strings[key])

    return PLACEHOLDER.sub(replace, template)


def check_local_files(page, folder):
    for target in re.findall(r'(?:src|href|srcset)="([^"#:]+)"', page):
        path = SITE / target[len(BASE_PATH):] if target.startswith(BASE_PATH) else folder / target
        if path.is_dir():
            path /= "index.html"
        if not path.is_file():
            fail(f"broken link {target} in a page of {folder}")


def sitemap(languages):
    urls = []
    for code in languages:
        alternates = "".join(
            f'\n    <xhtml:link rel="alternate" hreflang="{other}" '
            f'href="{BASE_URL}{page_path(other)}"/>'
            for other in languages
        )
        urls.append(f"  <url>\n    <loc>{BASE_URL}{page_path(code)}</loc>{alternates}\n  </url>")
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"\n'
        '        xmlns:xhtml="http://www.w3.org/1999/xhtml">\n'
        + "\n".join(urls)
        + "\n</urlset>\n"
    )


def main():
    languages = {
        path.stem: json.loads(path.read_text(encoding="utf-8"))
        for path in sorted((SRC / "strings").glob("*.json"))
    }
    if DEFAULT_LANG not in languages:
        fail(f"strings/{DEFAULT_LANG}.json is missing")
    # English first in the switcher and the sitemap.
    languages = {DEFAULT_LANG: languages.pop(DEFAULT_LANG), **languages}

    extract_icons()
    template = (SRC / "template.html").read_text(encoding="utf-8")
    not_found = (SRC / "404.html").read_text(encoding="utf-8")

    written = []
    for lang, strings in languages.items():
        prefix = "" if lang == DEFAULT_LANG else "../"
        og_image = localized_image("og", lang)
        if not og_image:
            fail("img/og-en.png is missing: run swift site/src/og-image.swift")
        og_width, og_height = png_size(SITE / og_image)
        variables = {
            "@lang": lang,
            "@prefix": prefix,
            "@base_path": BASE_PATH,
            "@repo": REPO_URL,
            "@download": f"{REPO_URL}/releases/latest",
            "@releases": f"{REPO_URL}/releases",
            "@app_store": APP_STORE_URL,
            "@donation": DONATION_URL,
            "@url": f"{BASE_URL}{page_path(lang)}",
            "@og_image": f"{BASE_URL}{og_image}",
            "@og_width": str(og_width),
            "@og_height": str(og_height),
            "@hreflang": language_links(languages),
            "@switcher": language_switcher(languages, lang, prefix),
        }
        for token, name, key in (
            ("@shot_settings", "settings", "shot.settings"),
            ("@shot_menu", "menu", "shot.menu"),
        ):
            variables[token] = screenshot(
                name, lang, prefix, strings[f"{key}.alt"], strings[f"{key}.caption"]
            )

        used = {"lang.name", "lang.switcher", "og.tagline",
                "shot.settings.alt", "shot.settings.caption",
                "shot.menu.alt", "shot.menu.caption"}
        page = render(template, strings, variables, used)
        pages = {"index.html": page}
        # GitHub Pages serves a single 404.html, from the root of the site.
        error_page = render(not_found, strings, variables, used)
        if lang == DEFAULT_LANG:
            pages["404.html"] = error_page

        unused = set(strings) - used
        if unused:
            fail(f"{lang}: unused strings {', '.join(sorted(unused))}")

        folder = SITE / page_path(lang)
        folder.mkdir(exist_ok=True)
        for name, content in pages.items():
            written.append((content, folder))
            (folder / name).write_text(content, encoding="utf-8")
        print(f"{lang}: {(folder / 'index.html').relative_to(SITE.parent)}")

    (SITE / "sitemap.xml").write_text(sitemap(languages), encoding="utf-8")
    (SITE / "robots.txt").write_text(
        f"User-agent: *\nAllow: /\n\nSitemap: {BASE_URL}sitemap.xml\n", encoding="utf-8"
    )
    # Checked last: pages link to each other.
    for content, folder in written:
        check_local_files(content, folder)


if __name__ == "__main__":
    main()
