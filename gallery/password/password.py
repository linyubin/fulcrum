#!/usr/bin/env python3
"""Password — Fulcrum plugin (FPP1).

Strong random passwords from the OS entropy source. `pw` gives 20
characters with symbols; `pw 32` sets the length (8–128); `pw 16 nosym`
drops symbols; `pw words` makes a four-word passphrase. Five candidates
per query, ↵ copies one. Offline, never logged.
"""

import json
import secrets
import string
import subprocess
import sys

LETTERS_DIGITS = string.ascii_letters + string.digits
SYMBOLS = "!@#$%^&*()-_=+[]{};:,.?/"
# A small built-in word list keeps passphrases offline; entropy per word is
# log2(len) ≈ 7.6 bits, four words ≈ 30 bits plus a separator and digit.
WORDS = (
    "anchor apple arrow autumn badge bamboo basket beacon bridge button cabin "
    "candle canyon castle cedar cherry cliff cloud cobalt comet copper coral "
    "crystal dagger daisy delta desert diamond dolphin dragon eagle ember "
    "falcon feather fern forest fossil garden glacier granite harbor hazel "
    "honey island ivory jasper jungle kettle lantern lemon lilac lotus maple "
    "marble meadow meteor mirror mosaic nectar nickel oasis olive onyx orbit "
    "orchid otter oyster pebble pepper pillar planet plum prairie quartz raven "
    "reef ribbon river rocket saffron salmon sapphire shadow silver sparrow "
    "spruce summit sunset thistle thunder timber topaz tulip tundra velvet "
    "violet walnut willow winter zephyr"
).split()


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


def password(length, symbols):
    alphabet = LETTERS_DIGITS + (SYMBOLS if symbols else "")
    while True:
        candidate = "".join(secrets.choice(alphabet) for _ in range(length))
        has_lower = any(c.islower() for c in candidate)
        has_upper = any(c.isupper() for c in candidate)
        has_digit = any(c.isdigit() for c in candidate)
        has_symbol = (not symbols) or any(c in SYMBOLS for c in candidate)
        if has_lower and has_upper and has_digit and has_symbol:
            return candidate


def passphrase():
    words = [secrets.choice(WORDS) for _ in range(4)]
    index = secrets.randbelow(4)
    words[index] = words[index].capitalize()
    return "-".join(words) + str(secrets.randbelow(100))


def handle_query(query):
    tokens = query.strip().lower().split()
    length = 20
    symbols = True
    words = False
    for token in tokens:
        if token.isdigit():
            length = max(8, min(128, int(token)))
        elif token in ("nosym", "nosymbols", "alnum"):
            symbols = False
        elif token in ("words", "phrase", "passphrase"):
            words = True
    rows = []
    for _ in range(5):
        if words:
            value = passphrase()
            rows.append(row(value, "Passphrase · 4 words + digit · ↵ copies", value))
        else:
            value = password(length, symbols)
            kind = "letters, digits" + (", symbols" if symbols else "")
            rows.append(row(value, f"{length} chars · {kind} · ↵ copies", value))
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
