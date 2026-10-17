#!/usr/bin/env python3
"""Word Count — Fulcrum plugin (FPP1).

Counts words, characters, lines and reading time. `wc some text` counts
the typed text; a bare `wc` counts whatever is on the clipboard. ↵
copies the one-line summary. Offline.
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


def read_clipboard():
    for command in (["pbpaste"], ["wl-paste", "--no-newline"],
                    ["xclip", "-selection", "clipboard", "-o"],
                    ["powershell", "-NoProfile", "-Command", "Get-Clipboard"]):
        try:
            done = subprocess.run(command, check=True, timeout=2,
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            return done.stdout.decode("utf-8", errors="replace")
        except (OSError, subprocess.SubprocessError):
            continue
    return ""


def handle_query(query):
    text = query
    source = "typed text"
    if not text.strip():
        text = read_clipboard()
        source = "clipboard"
        if not text.strip():
            return [row("Nothing to count", "wc <text> · or copy something and type wc", "")]
    words = re.findall(r"\S+", text)
    cjk = len(re.findall(r"[\u4e00-\u9fff\u3040-\u30ff\uac00-\ud7af]", text))
    characters = len(text)
    no_spaces = len(re.sub(r"\s", "", text))
    lines = text.count("\n") + (1 if text and not text.endswith("\n") else 0)
    sentences = len(re.findall(r"[.!?。！？]+", text)) or (1 if words else 0)
    word_total = len(words) + cjk  # CJK scripts carry no spaces: count characters as words
    minutes = max(1, round(word_total / 220)) if word_total else 0
    summary = (f"{word_total} words · {characters} chars · {no_spaces} non-space · "
               f"{lines} lines · {sentences} sentences · ~{minutes} min read")
    return [
        row(f"{word_total} words", f"{source} · ↵ copies the summary", summary),
        row(f"{characters} characters", f"{no_spaces} without spaces · ↵ copies the summary", summary),
        row(f"{lines} lines · {sentences} sentences", f"~{minutes} min read at 220 wpm · ↵ copies", summary),
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
