#!/usr/bin/env python3
"""The app themes the installer offers, read from catalog.json beside this file.

    themes.py list [--plain]     one row per theme: number, name, a slice of the app in its colours
    themes.py resolve <choice>   the theme name for a number or name, or nothing (exit 1)
    themes.py source <name>      "none" (Mendix's Atlas), "builtin", or the path of the bundle's <name>.css
    themes.py skin <name>        the path of the bundle's <name>.skin.scss (its frame), if it has one
    themes.py preview            the path of preview.html
    themes.py logo <name> <app>  copy the mx-codr mark in that theme's colours into <app>/theme/web/

Colours are 24-bit when COLORTERM says so, else the nearest of the 256-colour palette;
--plain (or NO_COLOR) prints names and descriptions only.
"""
import json
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def catalog():
    with open(os.path.join(HERE, "catalog.json")) as handle:
        return json.load(handle)


def colour(hexcode, layer):
    h = hexcode.lstrip("#")
    r, g, b = int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)
    if os.environ.get("COLORTERM", "") in ("truecolor", "24bit"):
        return "\033[%d;2;%d;%d;%dm" % (layer, r, g, b)
    return "\033[%d;5;%dm" % (layer, 16 + 36 * (r * 5 // 255) + 6 * (g * 5 // 255) + (b * 5 // 255))


def bg(hexcode):
    return colour(hexcode, 48)


def fg(hexcode):
    return colour(hexcode, 38)


def list_themes(plain):
    reset, bold, grey = "\033[0m", "\033[1m", "\033[38;5;245m"
    for number, theme in enumerate(catalog(), 1):
        t, desc = theme["light"], theme["description"].replace(" -- ", " — ")
        default = "  (default)" if number == 1 else ""
        if plain:
            print("    %d  %-8s %s%s" % (number, theme["name"], desc, default))
            continue
        # A slice of the app: the side menu, the top bar, the page, a selected row, the Save button.
        top = theme.get("frame", {}).get("top") or t["rail"]
        swatch = (bg(t["rail"]) + fg(t["rail-ink-active"]) + " ▤ " + reset +
                  bg(top) + fg("#ffffff") + " Your App " + reset +
                  bg(t["ground"]) + fg(t["ink"]) + " Orders " + reset +
                  bg(t["surface-selected"]) + fg(t["ink"]) + " INV-042 " + reset +
                  bg(t["brand"]) + fg(t["brand-ink"]) + " Save " + reset)
        print("    %s%d%s  %-8s %s  %s%s%s%s" % (bold, number, reset, theme["name"], swatch, grey, desc, default, reset))


def resolve(choice):
    themes = catalog()
    choice = (choice or "").strip().lower()
    if not choice:
        return themes[0]["name"]
    if choice.isdigit() and 1 <= int(choice) <= len(themes):
        return themes[int(choice) - 1]["name"]
    for theme in themes:
        if theme["name"] == choice:
            return theme["name"]
    return ""


def main(argv):
    command = argv[1] if len(argv) > 1 else ""
    if command == "list":
        list_themes("--plain" in argv or bool(os.environ.get("NO_COLOR")))
        return 0
    if command == "resolve" and len(argv) <= 3:
        name = resolve(argv[2] if len(argv) == 3 else "")
        if name:
            print(name)
        return 0 if name else 1
    if command == "source" and len(argv) == 3:
        for theme in catalog():
            if theme["name"] == argv[2]:
                source = theme["source"]
                print(source if source in ("none", "builtin") else os.path.join(HERE, source))
                return 0
        return 1
    if command == "skin" and len(argv) == 3:
        path = os.path.join(HERE, argv[2] + ".skin.scss")
        if os.path.isfile(path):
            print(path)
            return 0
        return 1
    if command == "logo" and len(argv) == 4:
        # The browser and home-screen icons, the sign-in logo and Atlas's top bar logo, by the
        # names mxbuild copies from theme/web/ over its own (logos/<name>/ mirrors theme/web/).
        source = os.path.join(HERE, "logos", argv[2])
        if not os.path.isdir(source) or not os.path.isdir(os.path.join(argv[3], "theme", "web")):
            return 1
        for folder, _dirs, files in os.walk(source):
            target = os.path.join(argv[3], "theme", "web", os.path.relpath(folder, source))
            os.makedirs(target, exist_ok=True)
            for name in files:
                shutil.copyfile(os.path.join(folder, name), os.path.join(target, name))
        # `mxcli run --watch` copies theme/web/ only when a stylesheet changes: nudge one.
        main_scss = os.path.join(argv[3], "theme", "web", "main.scss")
        if os.path.isfile(main_scss):
            os.utime(main_scss)
        return 0
    if command == "preview":
        print(os.path.join(HERE, "preview.html"))
        return 0
    print(__doc__.strip(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.stdout.reconfigure(newline="\n")
    sys.exit(main(sys.argv))
