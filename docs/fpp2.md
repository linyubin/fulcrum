# Fulcrum Plugin Protocol v2 (FPP2) — Design Draft

**Status: draft.** This document is the implementation target for the
protocol wave (Fulcrum 0.9/1.0). It is a design, not a spec — the spec
will replace this file's "wire protocol" section once the reference
plugin and conformance tests land. FPP1
([docs/plugins.md](plugins.md)) is frozen and permanently supported;
everything here is additive.

## Why FPP2

FPP1's process-per-call model was the right floor: trivially safe,
trivially correct, any language. It is also a ceiling — three structural
limits no amount of surface polish can fix:

1. **Cold start on every keystroke-batch.** A plugin that shells out to
   `docker` or an API pays interpreter boot + connection setup dozens of
   times a minute while the user types. Latency compounds; timeouts must
   stay generous enough to cover the worst cold start.
2. **Text rows are the whole UI.** Eight string columns cannot express a
   detail page, secondary actions on a plugin result, or input. Plugins
   that need more escape into "open a website", which exits Fulcrum.
3. **No state, no settings.** A plugin cannot remember anything between
   invocations except files it smuggles into its own directory, and the
   user cannot configure one except by hand-editing files.

FPP2 lifts all three while keeping the two properties that make FPP1
trustworthy: **the process boundary stays** (a plugin is still a foreign
program; the backend never links its code), and **a broken plugin can
never take the launcher down** (every op stays timeout-bounded; crashes
surface as honest status rows).

## Compatibility

- A manifest without a `protocol` field is FPP1, forever.
- `"protocol": 2` opts a plugin into the extensions below. The backend
  negotiates: an old Fulcrum meeting `protocol: 2` serves the plugin as
  FPP1 (the v1 ops still work — see "Layering"); a new Fulcrum meeting
  an FPP1 manifest serves it exactly as today.
- **Layering rule:** FPP2 is FPP1 plus additive manifest fields, plus
  additive response fields, plus new ops the plugin may simply refuse
  (`{"status":"error","message":"unsupported op"}`). No v1 shape ever
  changes meaning.

## Manifest v2

```json
{
  "id": "docker",
  "protocol": 2,
  "name": "Docker",
  "version": "2.0.0",
  "description": "Containers, images, and logs",
  "icon": "plugin",
  "mode": "daemon",
  "entry": {"exec": ["python3", "docker_plugin.py"]},
  "commands": [
    {"id": "search", "name": "Search containers", "keyword": "dk",
     "example": "dk nginx"}
  ],
  "preferences": [
    {"name": "host", "type": "text", "label": "Docker host",
     "default": "unix:///var/run/docker.sock", "required": false,
     "description": "DOCKER_HOST override"},
    {"name": "token", "type": "secret", "label": "Registry token"}
  ],
  "permissions": ["network:registry-1.docker.io", "exec:docker"]
}
```

| New field | Meaning |
|---|---|
| `protocol` | `2`. Absent = FPP1. |
| `mode` | `"on-demand"` (default, FPP1 semantics) or `"daemon"` (persistent process — see lifecycle). |
| `preferences[]` | Declarative user settings, ≤ 16 entries. `type`: `text` \| `secret` \| `boolean` \| `select` (with `choices: []`). Stored by the backend, injected per request — plugins never manage config files. |
| `commands[].actions` | Optional per-command default actions shown in the ⌘K panel (see result actions). |

`permissions[]` remains **advisory** in FPP2.0 — displayed at install and
in the plugin center, enforced by nothing. The staged path to enforcement
is below. Honesty rule unchanged: nothing in the docs or UI may imply a
sandbox that does not exist.

## Wire protocol

Unchanged framing: one JSON object per line, UTF-8, UTF-8-safe, unknown
fields ignored. `request_id` — present but unused in FPP1's one-call-per-
process world — becomes meaningful: daemon-mode plugins may receive a
second request before answering the first (e.g. a slow `run` while
`query` keeps typing responsive) and must correlate responses by id.

### query / run — additive result fields

```text
← {"request_id":1,"results":[
     {"title":"web-1 · running",
      "subtitle":"nginx:1.27 · up 3 days",
      "arg":"web-1",
      "icon":"plugin",
      "actions":[{"id":"logs","title":"Stream logs"},
                 {"id":"stop","title":"Stop container"}],
      "detail-request":true}]}
```

- `actions[]` — ≤ 4 per result. The host offers them in the ⌘K panel;
  selecting one sends `run-action`. The host's built-in actions (copy
  arg, open URL) stay available and need no declaration.
- `detail-request: true` — Enter opens the detail view (below) instead
  of running; the run still happens from inside the detail view or via
  a declared action. Plain rows keep FPP1 semantics.

### detail (new op)

Sent when the user opens a row marked `detail-request`.

```text
→ {"op":"detail","command":"search","arg":"web-1","request_id":3}
← {"request_id":3,
   "text":"nginx:1.27 — up 3 days\n\nports: 80→8080, 443→8443\nrestarts: 0",
   "metadata":[["state","running"],["image","nginx:1.27"],["health","ok"]]}
```

- `text` is plain text (≤ 16 KiB) rendered natively — a text view on
  every host, no WebView, no markdown engine in v2.0.
- `metadata` is ≤ 12 key-value pairs rendered as a property list.
- Both fields optional; an empty response renders an honest "the plugin
  returned no detail".

### run-action (new op)

```text
→ {"op":"run-action","command":"search","arg":"web-1",
   "action":"logs","request_id":4}
← {"request_id":4,"status":"ok"}
```

Status semantics identical to `run`.

### Preferences delivery

Preference values travel two ways, deliberately redundant:

1. **Environment at spawn** — `FULCRUM_PLUGIN_PREF_<NAME>` (secrets
   included, since the process boundary is the trust line anyway).
2. **Every request object** — `"prefs": {"host": "...", "token": "..."}`
   (secret values included in-process, never logged by the backend).

Editing, in the launcher's own idiom (the query box is the only text
entry Fulcrum has — the honest input device):

```text
docker set host tcp://192.168.1.20:2375
```

The backend validates against the manifest schema (`select` values must
match `choices`, `required` must be non-empty), persists to
`plugin-prefs.json` in the data dir, and notifies daemon-mode plugins
with a `prefs-changed` event. `secret` values live in the local-only
keys file beside `ai-keys.json` — **never in sync**, never in plain
settings. The plugin center lists each preference with its current
value (secrets masked) and a copyable example of the `set` line.

## Daemon mode (`"mode": "daemon"`)

The backend keeps one long-lived process per daemon plugin for the
backend session:

- **Lazy start** — spawned on first query touching the plugin, not at
  boot. An unused daemon costs nothing.
- **Bounded ops** — daemon removes cold-start cost, not the timeout
  contract: each op carries the same per-op timeout (default 2000 ms,
  same settings key). A daemon that stops answering is treated exactly
  like a hung FPP1 process: that op fails honestly.
- **Concurrency** — requests may interleave (correlate by
  `request_id`). The backend caps concurrent in-flight ops per plugin
  (4) and total daemons (8, LRU shutdown) so one plugin cannot fork-bomb
  the session.
- **Crash policy** — restart with backoff (1 s, 5 s, 30 s); after three
  crashes inside five minutes the plugin is marked failed for the
  session with an honest status row and a one-click restart.
- **Push updates** — a daemon may send
  `{"event":"results-changed","command":"search"}` at most once per
  second per command; the backend re-runs that command's query if (and
  only if) its keyword currently matches the on-screen query. This is
  the whole "live results" feature — no subscription API, no streaming
  rows, one rate-limited nudge.
- **Shutdown** — SIGTERM, then SIGKILL after 500 ms. Daemons must not
  persist anything outside their plugin directory.

On-demand plugins keep exact FPP1 semantics; `mode` is per-plugin, not
global. The Docker plugin above can go daemon while `epoch` stays
spawn-per-query forever.

## Permissions: the staged road to enforcement

FPP2.0 ships declaration + display + consent (status quo presentation,
now with structured values instead of free text). Enforcement lands in
stages, gated exactly as the business plan requires — automated review
before any store:

1. **Registry gate (registry launch):** the `fulcrum-gallery` CI runs
   the plugin, records network and exec syscalls where the platform
   allows, and fails the PR on undeclared `network:`/`exec:` grants.
   Declared-and-true, enforced by review tooling rather than runtime.
2. **Proxy enforcement (FPP2.1, experimental):** the backend runs a
   loopback HTTP(S) proxy with a per-plugin allowlist; daemon plugins
   get `HTTPS_PROXY` injected, making undeclared hosts fail closed for
   well-behaved HTTP stacks. Honest about its limits (raw sockets bypass
   it; it is a guardrail, not a sandbox).
3. **OS sandbox (store gate):** per-platform sandboxing (macOS
   App Sandbox / Windows AppContainer / Linux namespaces) only when the
   paid store demands it. Declared in the business plan, not promised
   in this protocol.

## What FPP2 deliberately does not do

- **No WebView, no HTML, no JS bridge.** Detail is text + metadata;
  forms (input fields) come later as declarative schemas rendered
  natively — v2.1, after daemon mode proves out. Nothing in FPP2 asks
  the hosts to embed a browser.
- **No in-process plugins.** Raycast's in-process TypeScript model
  gives richer APIs at the cost of a runtime we would have to embed and
  version forever. The process boundary is the compatibility and trust
  story; FPP2 keeps it.
- **No background execution after quit.** Daemons live for the backend
  session and die with it. A "menu-bar agent that runs while Fulcrum
  doesn't" is a different product with a different threat model.
- **No binary distribution.** Plugins stay source directories executed
  by interpreters on PATH — auditable by review, portable across
  platforms, and honest about the PATH caveats FPP1 already documents.

## Implementation sequence

1. **Wire + manifest** — protocol negotiation, daemon lifecycle, request
   interleaving, `run-action`. (The engine owns all of it; hosts see
   only new row fields and the detail surface.)
2. **Detail view** — wire shape + three native detail renderers (text +
   metadata; the macOS one is an NSTextView in a panel section, the
   pattern the AI streaming panel already established).
3. **Preferences** — store, `set` syntax, plugin-center rows, env +
   payload injection, `prefs-changed`.
4. **Registry client** — [docs/registry.md](registry.md); the gallery
   index carries `protocol` and `min-app-version` so the catalog and
   the protocol land together.
5. **Conformance kit** — a fixture plugin exercising every op, the
   crash/backoff paths, and the timeout contract, wired into CI the way
   the FPP1 fixture is.

Steps 1–3 are backend-heavy with modest host work (row fields, detail
renderer, preference rows) — the same shape as the ⌘K wave, which is
the encouraging precedent.
