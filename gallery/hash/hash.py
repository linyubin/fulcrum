#!/usr/bin/env python3
"""Hash — Fulcrum plugin (FPP1).

Digests of the typed text: MD5, SHA-1, SHA-256, SHA-512. ↵ copies the
selected digest. Offline, standard library only.
"""

import hashlib
import json
import subprocess
import sys

ALGORITHMS = ("md5", "sha1", "sha256", "sha512")


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


def handle_query(query):
    text = query.strip()
    if not text:
        return [row("Type text to hash", "hash hello world · ↵ copies the digest", "")]
    data = text.encode("utf-8")
    rows = []
    for name in ALGORITHMS:
        digest = hashlib.new(name, data).hexdigest()
        rows.append(row(digest, f"{name.upper()} · {len(data)} bytes · ↵ copies", digest))
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
