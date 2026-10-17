#!/usr/bin/env python3
"""Wikipedia — Fulcrum plugin (FPP1).

`wiki fulcrum` searches English Wikipedia: title and the opening line
of each article. ↵ opens the article. Public MediaWiki API, no key.
"""

import json
import sys
import urllib.parse
import urllib.request
import webbrowser

TIMEOUT_SECONDS = 1.6
API = ("https://en.wikipedia.org/w/api.php?action=query&list=search&format=json"
       "&srlimit=10&srprop=snippet&srsearch=")


def row(title, subtitle, arg):
    return {"title": title, "subtitle": subtitle, "arg": arg, "icon": "plugin"}


def strip_tags(text):
    out = []
    inside = False
    for ch in text:
        if ch == "<":
            inside = True
        elif ch == ">":
            inside = False
        elif not inside:
            out.append(ch)
    return "".join(out).replace("&quot;", '"').replace("&amp;", "&").replace("&#039;", "'")


def handle_query(query):
    text = query.strip()
    if not text:
        return [row("Type a topic", "wiki fulcrum · wiki Racket (programming language) · ↵ opens", "")]
    request = urllib.request.Request(API + urllib.parse.quote(text),
                                     headers={"User-Agent": "fulcrum-wikipedia-plugin/1.0"})
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except Exception:  # noqa: BLE001
        return [row("Wikipedia unreachable", "offline or en.wikipedia.org not responding", "")]
    rows = []
    for hit in payload.get("query", {}).get("search", []):
        title = hit.get("title", "")
        if not title:
            continue
        snippet = strip_tags(hit.get("snippet", ""))
        link = "https://en.wikipedia.org/wiki/" + urllib.parse.quote(title.replace(" ", "_"))
        rows.append(row(title, f"{snippet[:110]}… · ↵ opens" if snippet else "↵ opens", link))
    if not rows:
        rows.append(row("No articles", f"nothing on Wikipedia for “{text}”", ""))
    return rows[:10]


def handle_run(arg):
    if not arg:
        return {"status": "error", "message": "nothing to open"}
    if webbrowser.open(arg):
        return {"status": "ok"}
    return {"status": "error", "message": "no browser available"}


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
