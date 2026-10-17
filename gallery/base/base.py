#!/usr/bin/env python3
"""Number Base — Fulcrum plugin (FPP1).

Shows a number in decimal, hexadecimal, octal and binary at once.
Accepts `base 255`, `base 0xff`, `base 0b1010`, `base 0o17`, `base ff`
(hex when it has letters), plus big integers. ↵ copies a form. Offline.
"""

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
    """(value, how-it-was-read) or None."""
    value = text.strip().lower().replace("_", "").replace(" ", "")
    if not value:
        return None
    negative = value.startswith("-")
    if negative:
        value = value[1:]
    try:
        if value.startswith("0x"):
            number, how = int(value[2:], 16), "read as hex"
        elif value.startswith("0b"):
            number, how = int(value[2:], 2), "read as binary"
        elif value.startswith("0o"):
            number, how = int(value[2:], 8), "read as octal"
        elif re.fullmatch(r"[0-9]+", value):
            number, how = int(value, 10), "read as decimal"
        elif re.fullmatch(r"[0-9a-f]+", value):
            number, how = int(value, 16), "read as hex (letters present)"
        else:
            return None
    except ValueError:
        return None
    return (-number if negative else number), how


def handle_query(query):
    parsed = parse(query)
    if parsed is None:
        return [row("Type a number", "base 255 · base 0xff · base 0b1010 · base 0o17 · ↵ copies", "")]
    number, how = parsed
    sign = "-" if number < 0 else ""
    magnitude = abs(number)
    forms = [
        (f"{number}", "Decimal"),
        (f"{sign}0x{magnitude:X}", "Hexadecimal"),
        (f"{sign}0o{magnitude:o}", "Octal"),
        (f"{sign}0b{magnitude:b}", "Binary"),
    ]
    if 0 <= number < 0x110000:
        try:
            glyph = chr(number)
            if glyph.isprintable():
                forms.append((glyph, f"Unicode U+{number:04X}"))
        except ValueError:
            pass
    rows = []
    for index, (value, label) in enumerate(forms):
        note = f" · {how}" if index == 0 else ""
        rows.append(row(value, f"{label}{note} · ↵ copies", value))
    return rows


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
