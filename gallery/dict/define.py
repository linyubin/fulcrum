#!/usr/bin/env python3
"""Dictionary — Fulcrum plugin (FPP1).

`define serendipity` looks the word up: phonetics, then one row per
sense with its part of speech and an example when there is one. ↵
copies the definition. Uses the free dictionaryapi.dev (English).
"""

import json
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

TIMEOUT_SECONDS = 1.6
API = "https://api.dictionaryapi.dev/api/v2/entries/en/"


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
    word = query.strip().split(" ")[0].lower() if query.strip() else ""
    if not word:
        return [row("Type a word", "define serendipity · ↵ copies a definition", "")]
    request = urllib.request.Request(API + urllib.parse.quote(word),
                                     headers={"User-Agent": "fulcrum-dictionary-plugin"})
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
            entries = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return [row(f"No entry for “{word}”", "dictionaryapi.dev knows no such word", "")]
        return [row("Dictionary unavailable", f"dictionaryapi.dev answered {error.code}", "")]
    except Exception:  # noqa: BLE001
        return [row("Dictionary unreachable", "offline or dictionaryapi.dev not responding", "")]
    rows = []
    for entry in entries if isinstance(entries, list) else []:
        phonetic = entry.get("phonetic") or next(
            (p.get("text") for p in entry.get("phonetics", []) if p.get("text")), "")
        if phonetic and not rows:
            rows.append(row(f"{entry.get('word', word)} {phonetic}",
                            "pronunciation · ↵ copies", f"{entry.get('word', word)} {phonetic}"))
        for meaning in entry.get("meanings", []):
            part = meaning.get("partOfSpeech", "")
            for sense in meaning.get("definitions", [])[:3]:
                definition = sense.get("definition", "")
                if not definition:
                    continue
                example = sense.get("example")
                subtitle = f"{part} · “{example}”" if example else part
                rows.append(row(definition, subtitle + " · ↵ copies", definition))
                if len(rows) >= 10:
                    return rows
    if not rows:
        rows.append(row(f"No definitions for “{word}”", "", ""))
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
