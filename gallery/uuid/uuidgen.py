#!/usr/bin/env python3
"""UUID — Fulcrum plugin (FPP1).

Fresh random (v4) UUIDs. `uuid` makes one, `uuid 5` makes five, `uuid up`
makes an uppercase one. ↵ copies the selected UUID. Offline.
"""

import json
import subprocess
import sys
import uuid as uuid_module


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
    tokens = query.strip().lower().split()
    count = 1
    upper = False
    for token in tokens:
        if token.isdigit():
            count = max(1, min(10, int(token)))
        elif token in ("up", "upper", "uppercase"):
            upper = True
    rows = []
    for index in range(count):
        value = str(uuid_module.uuid4())
        if upper:
            value = value.upper()
        label = "UUID v4 · ↵ copies" if count == 1 else f"UUID v4 #{index + 1} · ↵ copies"
        rows.append(row(value, label, value))
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
