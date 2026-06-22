#!/usr/bin/env python3
"""Generate Fastlane `deliver` metadata from APP_STORE_LISTINGS.md.

APP_STORE_LISTINGS.md is the single source of truth for App Store metadata.
This script parses it and writes the fastlane/metadata/<locale>/ tree that
`fastlane deliver` uploads. Run after editing the listings file:

    python3 scripts/gen_appstore_metadata.py

It also prints a per-field character count and flags anything that exceeds
App Store Connect's limits.
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "APP_STORE_LISTINGS.md")
OUT = os.path.join(ROOT, "fastlane", "metadata")

# Map the app's locale tokens (as written in APP_STORE_LISTINGS.md, in
# parentheses after each language heading) to App Store Connect locale codes.
LOCALE_MAP = {
    "en": "en-US",
    "de": "de-DE",
    "fr": "fr-FR",
    "es": "es-ES",   # Spanish (Spain). Switch to es-MX if you target Latin America.
    "nl": "nl-NL",
    "it": "it",
    "pt-BR": "pt-BR",
}

# Bold field label in the markdown -> deliver filename + ASC character limit.
FIELDS = {
    "App Name":          ("name.txt", 30),
    "Subtitle":          ("subtitle.txt", 30),
    "Promotional Text":  ("promotional_text.txt", 170),
    "Keywords":          ("keywords.txt", 100),
    "Description":       ("description.txt", 4000),
    "What's New":        ("release_notes.txt", 4000),
}

# Per-locale URL + global metadata. Adjust as needed.
SUPPORT_URL = "https://quickprotect.app/support/"
MARKETING_URL = "https://quickprotect.app/"
PRIVACY_URL = "https://quickprotect.app/support/privacy.html"
COPYRIGHT = "2026 Christian Bartels"
PRIMARY_CATEGORY = "UTILITIES"

FIELD_RE = re.compile(r"\*\*(.+?)\*\*\s*\n```\n(.*?)\n```", re.DOTALL)


def main():
    with open(SRC, encoding="utf-8") as f:
        text = f.read()

    # Split into language sections on level-2 headings.
    sections = re.split(r"^## ", text, flags=re.MULTILINE)[1:]

    had_error = False
    locales_written = []

    for section in sections:
        header = section.splitlines()[0]
        m = re.search(r"\(([A-Za-z-]+)\)", header)
        if not m:
            continue  # not a language section
        token = m.group(1)
        asc_locale = LOCALE_MAP.get(token)
        if not asc_locale:
            print(f"  ! skipping unknown locale token: {token!r} ({header.strip()})")
            continue

        locale_dir = os.path.join(OUT, asc_locale)
        os.makedirs(locale_dir, exist_ok=True)

        fields = dict(FIELD_RE.findall(section))
        for label, (filename, limit) in FIELDS.items():
            if label not in fields:
                print(f"  ! {asc_locale}: missing field {label!r}")
                had_error = True
                continue
            value = fields[label].strip()
            count = len(value)
            flag = ""
            if count > limit:
                flag = f"  *** OVER LIMIT ({count}/{limit}) ***"
                had_error = True
            print(f"  {asc_locale:6} {filename:22} {count:4}/{limit}{flag}")
            with open(os.path.join(locale_dir, filename), "w", encoding="utf-8") as out:
                out.write(value + "\n")

        # Per-locale URLs.
        for fname, url in (
            ("support_url.txt", SUPPORT_URL),
            ("marketing_url.txt", MARKETING_URL),
            ("privacy_url.txt", PRIVACY_URL),
        ):
            with open(os.path.join(locale_dir, fname), "w", encoding="utf-8") as out:
                out.write(url + "\n")

        locales_written.append(asc_locale)

    # Global (non-localized) metadata.
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "copyright.txt"), "w", encoding="utf-8") as out:
        out.write(COPYRIGHT + "\n")
    with open(os.path.join(OUT, "primary_category.txt"), "w", encoding="utf-8") as out:
        out.write(PRIMARY_CATEGORY + "\n")

    print(f"\nWrote metadata for {len(locales_written)} locales: {', '.join(locales_written)}")
    if had_error:
        print("\nFinished WITH WARNINGS — fix the items marked above before uploading.")
        sys.exit(1)
    print("OK")


if __name__ == "__main__":
    main()
