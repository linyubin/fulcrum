#!/usr/bin/env python3
"""Color — Fulcrum plugin (FPP1).

Converts a color between HEX, RGB and HSL and shows the CSS forms:
`color #D97706`, `color d97706`, `color fff`, `color rgb(217, 119, 6)`,
`color hsl(32, 95%, 44%)`. ↵ copies the selected form. Offline.
"""

import colorsys
import json
import re
import subprocess
import sys


def row(title, subtitle, arg):
    return {"title": title, "subtitle": subtitle, "arg": arg, "icon": "plugin"}


def copy_to_clipboard(text):
    for command in (["pbcopy"], ["wl-copy"], ["xclip", "-selection", "clipboard"],
                    ["clip.exe"]):
        try:
            subprocess.run(command, input=text.encode("utf-8"), check=True,
                           timeout=2, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL)
            return True
        except (OSError, subprocess.SubprocessError):
            continue
    return False


def parse(text):
    """(r, g, b) 0–255 for a hex, rgb() or hsl() string, else None."""
    value = text.strip().lower()
    hex_match = re.fullmatch(r"#?([0-9a-f]{3}|[0-9a-f]{6})", value)
    if hex_match:
        digits = hex_match.group(1)
        if len(digits) == 3:
            digits = "".join(ch * 2 for ch in digits)
        return tuple(int(digits[i:i + 2], 16) for i in (0, 2, 4))
    rgb_match = re.fullmatch(r"rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*(?:,[^)]*)?\)", value)
    if rgb_match:
        channels = tuple(min(255, int(v)) for v in rgb_match.groups())
        return channels
    hsl_match = re.fullmatch(
        r"hsla?\(\s*(\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)%\s*,\s*(\d+(?:\.\d+)?)%\s*(?:,[^)]*)?\)",
        value)
    if hsl_match:
        hue, sat, lig = (float(v) for v in hsl_match.groups())
        r, g, b = colorsys.hls_to_rgb((hue % 360) / 360, lig / 100, sat / 100)
        return tuple(round(c * 255) for c in (r, g, b))
    plain = re.fullmatch(r"(\d+)[ ,]+(\d+)[ ,]+(\d+)", value)
    if plain:
        return tuple(min(255, int(v)) for v in plain.groups())
    return None


def handle_query(query):
    rgb = parse(query)
    if rgb is None:
        return [row("Type a color", "color #D97706 · color rgb(217,119,6) · color hsl(32,95%,44%)", "")]
    r, g, b = rgb
    hex_form = "#{:02X}{:02X}{:02X}".format(r, g, b)
    hue, lig, sat = colorsys.rgb_to_hls(r / 255, g / 255, b / 255)
    hsl_form = "hsl({:.0f}, {:.0f}%, {:.0f}%)".format(hue * 360, sat * 100, lig * 100)
    rgb_form = "rgb({}, {}, {})".format(r, g, b)
    luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
    contrast = "dark text reads best" if luminance > 140 else "light text reads best"
    return [
        row(hex_form, f"HEX · {contrast} · ↵ copies", hex_form),
        row(rgb_form, "RGB · ↵ copies", rgb_form),
        row(hsl_form, "HSL · ↵ copies", hsl_form),
        row(hex_form.lower(), "HEX lowercase · ↵ copies", hex_form.lower()),
        row("0x{:02X}{:02X}{:02X}".format(r, g, b), "Hex literal · ↵ copies",
            "0x{:02X}{:02X}{:02X}".format(r, g, b)),
    ]


def handle_run(arg):
    if not arg:
        return {"status": "error", "message": "nothing to copy"}
    if copy_to_clipboard(arg):
        return {"status": "ok"}
    return {"status": "error", "message": "no clipboard tool found"}


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except json.JSONDecodeError:
            continue
        request_id = request.get("request_id", 0)
        op = request.get("op")
        if op == "query":
            response = {"request_id": request_id,
                        "results": handle_query(str(request.get("query", "")))}
        elif op == "run":
            response = {"request_id": request_id}
            response.update(handle_run(str(request.get("arg", ""))))
        else:
            response = {"request_id": request_id, "status": "error",
                        "message": f"unknown op {op!r}"}
        sys.stdout.write(json.dumps(response) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
