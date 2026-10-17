#!/usr/bin/env python3
"""npm — Fulcrum plugin (FPP1).

`npm zod` searches the npm registry: name@version, description, weekly
quality signal. ↵ opens the package page. Public registry search API,
no key.
"""

import json
import sys
import urllib.parse
import urllib.request
import webbrowser

TIMEOUT_SECONDS = 1.6
SEARCH = "https://registry.npmjs.org/-/v1/search?size=10&text="


def row(title, subtitle, arg):
    return {"title": title, "subtitle": subtitle, "arg": arg, "icon": "plugin"}


def handle_query(query):
    text = query.strip()
    if not text:
        return [row("Type a package name", "npm zod · npm react router · ↵ opens the package", "")]
    request = urllib.request.Request(SEARCH + urllib.parse.quote(text),
                                     headers={"User-Agent": "fulcrum-npm-plugin"})
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except Exception:  # noqa: BLE001
        return [row("npm registry unreachable", "offline or registry.npmjs.org not responding", "")]
    rows = []
    for item in payload.get("objects", []):
        package = item.get("package", {})
        name = package.get("name", "")
        if not name:
            continue
        version = package.get("version", "")
        description = (package.get("description") or "").strip()
        score = item.get("score", {}).get("final")
        quality = f"score {score:.2f} · " if isinstance(score, (int, float)) else ""
        link = package.get("links", {}).get("npm") or f"https://www.npmjs.com/package/{name}"
        rows.append(row(f"{name}@{version}", f"{quality}{description[:90]} · ↵ opens", link))
    if not rows:
        rows.append(row("No packages", f"nothing on npm for “{text}”", ""))
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
