#!/usr/bin/env python3
"""Weather — Fulcrum plugin (FPP1).

`wx` shows the weather where you are (by IP), `wx Tokyo` for a place:
current conditions, then today's and tomorrow's range. ↵ copies the
line. Uses wttr.in's JSON feed (no key).
"""

import json
import subprocess
import sys
import urllib.parse
import urllib.request

TIMEOUT_SECONDS = 1.8


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


def first_value(entries, key):
    for entry in entries or []:
        value = entry.get(key)
        if isinstance(value, list) and value:
            return value[0].get("value", "")
        if isinstance(value, str):
            return value
    return ""


def handle_query(query):
    place = query.strip()
    url = "https://wttr.in/" + urllib.parse.quote(place) + "?format=j1"
    request = urllib.request.Request(url, headers={"User-Agent": "fulcrum-weather-plugin"})
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except Exception:  # noqa: BLE001
        return [row("Weather unreachable", "offline or wttr.in not responding", "")]
    current = (payload.get("current_condition") or [{}])[0]
    area = (payload.get("nearest_area") or [{}])[0]
    where = first_value([area], "areaName") or place or "here"
    country = first_value([area], "country")
    location = f"{where}, {country}" if country else where
    description = first_value([current], "weatherDesc")
    temp_c = current.get("temp_C", "?")
    feels = current.get("FeelsLikeC", "?")
    humidity = current.get("humidity", "?")
    wind = current.get("windspeedKmph", "?")
    now_line = f"{temp_c}°C {description} · feels {feels}°C · {humidity}% humidity · wind {wind} km/h"
    rows = [row(f"{location}: {now_line}", "now · ↵ copies", f"{location}: {now_line}")]
    labels = ("Today", "Tomorrow", "Day after")
    for label, day in zip(labels, payload.get("weather", [])[:3]):
        hourly = day.get("hourly") or []
        midday = hourly[len(hourly) // 2] if hourly else {}
        summary = first_value([midday], "weatherDesc")
        line = (f"{label}: {day.get('mintempC', '?')}–{day.get('maxtempC', '?')}°C"
                f"{' · ' + summary if summary else ''}"
                f" · sunrise {first_value(day.get('astronomy'), 'sunrise')}")
        rows.append(row(line, f"{day.get('date', '')} · ↵ copies", line))
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
