#!/usr/bin/env python3
"""Case — Fulcrum plugin (FPP1).

Every common casing of the typed text at once: UPPER, lower, Title,
Sentence, camelCase, PascalCase, snake_case, kebab-case,
SCREAMING_SNAKE, dot.case. ↵ copies the selected form. Offline.
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


def words_of(text):
    """Split on spaces, punctuation and camelCase humps."""
    spaced = re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", text)
    spaced = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1 \2", spaced)
    return [w for w in re.split(r"[^A-Za-z0-9]+", spaced) if w]


def handle_query(query):
    text = query.strip()
    if not text:
        return [row("Type text to convert", "case hello world · ↵ copies a form", "")]
    words = words_of(text)
    lower = [w.lower() for w in words]
    forms = [
        (text.upper(), "UPPER CASE"),
        (text.lower(), "lower case"),
        (" ".join(w.capitalize() for w in lower), "Title Case"),
        ((lower[0].capitalize() + " " + " ".join(lower[1:])).strip() if lower else "", "Sentence case"),
        ((lower[0] + "".join(w.capitalize() for w in lower[1:])) if lower else "", "camelCase"),
        ("".join(w.capitalize() for w in lower), "PascalCase"),
        ("_".join(lower), "snake_case"),
        ("-".join(lower), "kebab-case"),
        ("_".join(lower).upper(), "SCREAMING_SNAKE_CASE"),
        (".".join(lower), "dot.case"),
    ]
    seen = set()
    rows = []
    for value, label in forms:
        if not value or value in seen:
            continue
        seen.add(value)
        rows.append(row(value, f"{label} · ↵ copies", value))
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
