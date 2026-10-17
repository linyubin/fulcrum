#!/usr/bin/env python3
"""Base64 — Fulcrum plugin (FPP1).

Encodes the typed text to Base64 and, when the text itself is valid
Base64, also decodes it. URL-safe variant included. ↵ copies the row.
Offline, standard library only.
"""

import base64
import binascii
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


def try_decode(text):
    """Decoded UTF-8 text when the input is valid Base64, else None."""
    candidate = text.strip()
    if len(candidate) < 2 or not re.fullmatch(r"[A-Za-z0-9+/_=-]+", candidate):
        return None
    padded = candidate.rstrip("=")
    padded += "=" * (-len(padded) % 4)
    for decoder in (base64.b64decode, base64.urlsafe_b64decode):
        try:
            raw = decoder(padded)
            decoded = raw.decode("utf-8")
        except (binascii.Error, ValueError, UnicodeDecodeError):
            continue
        if decoded and all(ch.isprintable() or ch in "\n\t\r" for ch in decoded):
            return decoded
    return None


def handle_query(query):
    text = query.strip()
    if not text:
        return [row("Type text to encode or Base64 to decode",
                    "b64 hello · b64 aGVsbG8= · ↵ copies", "")]
    data = text.encode("utf-8")
    rows = []
    decoded = try_decode(text)
    if decoded is not None:
        preview = decoded.replace("\n", "⏎")
        rows.append(row(preview[:120], "Decoded · ↵ copies", decoded))
    standard = base64.b64encode(data).decode("ascii")
    rows.append(row(standard, "Base64 · ↵ copies", standard))
    url_safe = base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")
    if url_safe != standard:
        rows.append(row(url_safe, "Base64 URL-safe, unpadded · ↵ copies", url_safe))
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
