#!/usr/bin/env python3
"""Lorem Ipsum — Fulcrum plugin (FPP1).

Placeholder text on demand: `lorem` gives one paragraph, `lorem 3`
three paragraphs, `lorem 40 words` forty words, `lorem 5 sentences`
five sentences. The row previews the text; ↵ copies all of it. Offline.
"""

import json
import random
import subprocess
import sys

WORDS = (
    "lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod "
    "tempor incididunt ut labore et dolore magna aliqua enim ad minim veniam "
    "quis nostrud exercitation ullamco laboris nisi aliquip ex ea commodo "
    "consequat duis aute irure in reprehenderit voluptate velit esse cillum "
    "fugiat nulla pariatur excepteur sint occaecat cupidatat non proident sunt "
    "culpa qui officia deserunt mollit anim id est laborum"
).split()


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


def sentence(rng):
    count = rng.randint(6, 14)
    words = [rng.choice(WORDS) for _ in range(count)]
    words[0] = words[0].capitalize()
    return " ".join(words) + "."


def paragraph(rng):
    return " ".join(sentence(rng) for _ in range(rng.randint(3, 6)))


def generate(count, unit):
    # The classic opening keeps the first sentence recognizable as lorem ipsum.
    rng = random.Random()
    if unit == "words":
        words = ["Lorem", "ipsum", "dolor", "sit", "amet"][:count]
        while len(words) < count:
            words.append(rng.choice(WORDS))
        return " ".join(words[:count])
    if unit == "sentences":
        first = "Lorem ipsum dolor sit amet, consectetur adipiscing elit."
        return " ".join([first] + [sentence(rng) for _ in range(count - 1)])
    first = ("Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do "
             "eiusmod tempor incididunt ut labore et dolore magna aliqua. ")
    paragraphs = [first + paragraph(rng)] + [paragraph(rng) for _ in range(count - 1)]
    return "\n\n".join(paragraphs)


def handle_query(query):
    tokens = query.strip().lower().split()
    count = 1
    unit = "paragraphs"
    for token in tokens:
        if token.isdigit():
            count = max(1, min(50, int(token)))
        elif token.startswith("word"):
            unit = "words"
        elif token.startswith("sent"):
            unit = "sentences"
        elif token.startswith("para"):
            unit = "paragraphs"
    if unit == "words":
        count = max(1, min(500, count))
    text = generate(count, unit)
    preview = text.replace("\n\n", " ⏎ ")
    return [row(preview[:140] + ("…" if len(preview) > 140 else ""),
                f"{count} {unit} · {len(text.split())} words · ↵ copies", text)]


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
