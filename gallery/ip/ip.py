#!/usr/bin/env python3
"""IP Address — Fulcrum plugin (FPP1).

Your addresses at a glance: the primary local IPv4, every interface
address Python can see, the hostname, and the public IP (api.ipify.org,
no key). ↵ copies the selected address. Network for the public IP only.
"""

import json
import socket
import subprocess
import sys
import urllib.request

TIMEOUT_SECONDS = 1.6


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


def primary_local_ip():
    # A UDP "connect" picks the outbound interface without sending a packet.
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
            probe.settimeout(0.5)
            probe.connect(("8.8.8.8", 80))
            return probe.getsockname()[0]
    except OSError:
        return None


def all_local_ips():
    addresses = []
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None):
            address = info[4][0]
            if address not in addresses and not address.startswith("127.") \
                    and address != "::1" and "%" not in address:
                addresses.append(address)
    except OSError:
        pass
    return addresses


def public_ip():
    request = urllib.request.Request("https://api.ipify.org",
                                     headers={"User-Agent": "fulcrum-ip-plugin"})
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
            return response.read().decode("ascii").strip()
    except Exception:  # noqa: BLE001 — any network failure reads as "unavailable"
        return None


def handle_query(query):
    rows = []
    primary = primary_local_ip()
    if primary:
        rows.append(row(primary, "Local IPv4 (outbound interface) · ↵ copies", primary))
    for address in all_local_ips():
        if address != primary:
            rows.append(row(address, "Local address · ↵ copies", address))
    hostname = socket.gethostname()
    rows.append(row(hostname, "Hostname · ↵ copies", hostname))
    public = public_ip()
    if public:
        rows.append(row(public, "Public IP (api.ipify.org) · ↵ copies", public))
    else:
        rows.append(row("Public IP unavailable", "offline or api.ipify.org unreachable", ""))
    return rows[:10]


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
