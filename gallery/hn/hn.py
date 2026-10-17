#!/usr/bin/env python3
"""Hacker News — Fulcrum plugin (FPP1).

`hn` lists the current front page; `hn rust async` searches stories.
Rows show points, comments and the domain; ↵ opens the story in the
browser. Uses the public Algolia HN API (no key).
"""

import json
import sys
import urllib.parse
import urllib.request
import webbrowser

TIMEOUT_SECONDS = 1.6
FRONT_PAGE = "https://hn.algolia.com/api/v1/search?tags=front_page&hitsPerPage=10"
SEARCH = "https://hn.algolia.com/api/v1/search?tags=story&hitsPerPage=10&query="


def row(title, subtitle, arg):
    return {"title": title, "subtitle": subtitle, "arg": arg, "icon": "plugin"}


def fetch(url):
    request = urllib.request.Request(url, headers={"User-Agent": "fulcrum-hn-plugin"})
    with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
        return json.loads(response.read().decode("utf-8"))


def domain_of(url):
    host = urllib.parse.urlparse(url).netloc
    return host[4:] if host.startswith("www.") else host


def handle_query(query):
    text = query.strip()
    url = SEARCH + urllib.parse.quote(text) if text else FRONT_PAGE
    try:
        payload = fetch(url)
    except Exception:  # noqa: BLE001 — offline / API down reads as one honest row
        return [row("Hacker News unreachable", "offline or hn.algolia.com not responding", "")]
    rows = []
    for hit in payload.get("hits", []):
        title = hit.get("title") or hit.get("story_title") or "(untitled)"
        object_id = hit.get("objectID", "")
        discussion = f"https://news.ycombinator.com/item?id={object_id}"
        link = hit.get("url") or discussion
        points = hit.get("points") or 0
        comments = hit.get("num_comments") or 0
        where = domain_of(link) if hit.get("url") else "news.ycombinator.com"
        rows.append(row(title, f"{points} points · {comments} comments · {where} · ↵ opens", link))
    if not rows:
        rows.append(row("No stories", f"nothing on Hacker News for “{text}”", ""))
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
