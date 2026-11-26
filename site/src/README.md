# Website

Published at <https://chanoj.github.io/ClamStop/> by `.github/workflows/pages.yml`, which runs
the generator and deploys `site/` (without `src/`) on every push to `main` that touches it.

## Going online

The deployment is off until the app is ready. To publish:

1. **Settings > Pages > Build and deployment > Source**: **GitHub Actions**.
2. **Settings > Secrets and variables > Actions > Variables > New repository variable**: name
   `PUBLISH_SITE`, value `true`.
3. **Actions > Pages > Run workflow** on `main`.

Before that, check that a stable release exists (the download buttons point to it) and set the
direct App Store link of ClamStop Light in `APP_STORE_URL` (`build.py`).

## Edit

Change `template.html`, `404.html`, `strings/*.json` or `../style.css`, then build and commit the
generated files too:

```bash
python3 site/src/build.py
```

Preview:

```bash
python3 -m http.server 3417 --directory site
```

## Add a language

1. Copy `strings/en.json` to `strings/<code>.json` (`fr`, `de`, `ja`, `zh-Hans`, `es`) and
   translate the values. Set `lang.name` (in that language) and `meta.og_locale`. Keys ending in
   `_html` hold markup. The build fails on a missing or unused key.
2. Optional: add the localized images below; the English ones are used otherwise.
3. Build: the page appears in `site/<code>/`, with the language switcher, `hreflang` links and
   sitemap entries. The 404 page stays in English.

## Images (`../img/`)

| File | Content |
| --- | --- |
| `settings-<code>-light.png`, `settings-<code>-dark.png` | Settings window, 2x pixels |
| `menu-<code>-light.png`, `menu-<code>-dark.png` | Menu bar menu, 2x pixels (hidden while missing) |
| `og-<code>.png` | Open Graph image: `swift site/src/og-image.swift <code>` |
| `icon-*.png` | Extracted from `Resources/AppIcon.icns` by the build: do not edit |

Settings screenshots come from the installed app (no Screen Recording permission needed). The
app keeps running after writing the file: stop it afterwards. For the light appearance on a Mac
in dark mode:

```bash
/Applications/ClamStop.app/Contents/MacOS/ClamStop -NSRequiresAquaSystemAppearance YES --snapshot /tmp/settings-en-light.png
```

After a change of icon, run the Open Graph script again (the icons themselves are refreshed by
each deployment).
