# Fulcrum User Guide

Everything you need to use Fulcrum, written for someone who has never
used a launcher before. [中文版](user-guide.zh-CN.md)

## What is a launcher?

Normally, using your computer means hunting: clicking through menus to
find an app, digging through folders for a file, typing the same reply
over and over. A **launcher** replaces all of that with one habit: press
a key, type what you want, press Enter. It is a search box for your
entire computer, and it floats above whatever you are doing.

Fulcrum is that, for macOS, Windows, and Linux — with the same features
and the same keyboard on all three. Nothing you search or copy leaves
your machine.

## The one habit

- **Summon**: press `Alt+Space` (on macOS: `⌥Space`). A panel appears.
- **Type**: what you want — an app name, a calculation, a search.
- **Enter**: run the selected result.
- **Esc**: dismiss what is on screen, one layer at a time. With text in
  the box, the first Esc clears it; when it is already empty, the second
  Esc hides the panel. Fulcrum never runs anything on Esc.
- **↑ / ↓**: move the selection. **Ctrl+K** (`⌘K` on macOS): open extra
  actions for the selected result (copy, delete, pin, paste…).
- Hide the panel any time; it stays out of your way until summoned
  again. The panel also hides itself when you click elsewhere.

> The hotkey is configurable — see [Settings](#settings). If
> `Alt+Space` does nothing, another app owns it; Fulcrum falls back to
> `Ctrl+Alt+Space` and tells you in its status bar.

## Everyday features

### Launch apps

Just type the app's name — `firefox`, `term`, `calc`. Fulcrum searches
your installed applications with fuzzy matching: `ffx` finds Firefox,
typos tolerated. The apps you launch most often float to the top over
time.

### Calculate inline

Type any expression where you would type a search: `128*768`,
`(2+3)^4`, `sqrt(2)`. The answer appears as a result; Enter copies it to
the clipboard. Functions (`sin`, `log2`, `min`…), constants (`pi`, `e`),
and exact arithmetic all work.

### Clipboard history

Every piece of text you copy is remembered (on this machine only) —
searchable, pinnable, and never sent anywhere.

- Type `clip` (or any words from something you copied earlier) and pick
  the entry.
- **Enter pastes it directly into the app you were just using** — no
  switch, no Ctrl+V. This is the everyday magic: copy from here, paste
  from anywhere.
- Ctrl+K on an entry offers **Copy** (the classical behavior), **Pin**
  (keeps it from being pushed out), and **Delete**.

Clipboard history can be turned off in Settings. On Linux it requires
the GTK host, which records changes while Fulcrum is running.

### Snippets

A snippet is a piece of text you keep under a keyword: your address, a
bank account, the standard reply to a meeting invite.

Create one without leaving the launcher:

```
add snippet addr 42 Wall Street, New York
```

That's it — the keyword is `addr`, the text is everything after it, and
the row that appears saves it on Enter. Type the keyword or any part of
the text to find it again; Enter copies it, Ctrl+K offers **Paste to
frontmost** and **Delete**. Query `snippets` to list them all.

Snippets sync with the [Sync beta](#sync-beta).

### Quicklinks

A quicklink is a bookmark with a keyword claim. Create one inline:

```
add link yt https://youtube.com/search?q={query}
```

Now `yt lofi hip hop` opens that search. `{query}` in the URL is
replaced by what you typed after the keyword. Query `quicklinks` to see
and delete them.

### Web search

Fulcrum speaks DuckDuckGo-style bangs:

| Type | Opens |
|---|---|
| `!g rockets` | Google search |
| `!d rockets` | DuckDuckGo search |
| `!gh rivet` | GitHub search |
| `!so segfault` | Stack Overflow search |
| `!w saturn` | Wikipedia article |
| `!yt lofi` | YouTube search |
| `!m eiffel tower` | Google Maps |
| `!t fulcrum` | X/Twitter search |

Any other text that isn't a match elsewhere offers a general web search
as the last result (bang `!g` by default, configurable).

### Window management

Type `window` or parts of a command name: **Left Half**, **Right Half**,
**Maximize**, **Almost Maximize**, **Center**, **Restore**. The command
tiles whatever window was in front before you summoned Fulcrum. Restore
undoes the last tiling on that window.

### Find files (macOS)

`find invoice` searches file names through Spotlight. On Windows and
Linux this feature honestly reports that it needs the platform search
index rather than pretending to search.

### System commands

Type `lock`, `sleep`, or `restart` to lock the screen, suspend, or
reboot — Fulcrum offers only the commands that exist on your platform.

## AI (bring your own key)

Fulcrum's AI is "BYOK": you use your own API key from OpenAI,
Anthropic, or a local Ollama. Fulcrum charges nothing and sees nothing —
the key stays in a local file that is never synced, and the prompt only
leaves your machine when you run an AI command.

Setup, once:

1. Query `settings`, run the `ai-provider` row until it shows your
   provider (`openai`, `anthropic`, or `ollama`).
2. Type `ai key sk-…` (your actual key) and press Enter. For Ollama no
   key is needed — just have `ollama serve` running.

Use it:

- `ai summarize` — summarize whatever is on your clipboard.
- `ai clean` — fix grammar and spelling of the clipboard text.
- `ai translate zh` — translate the clipboard into Chinese (or any
  language).
- `ai explain` — explain the clipboard content.
- `ai chat explain kayfabe` — a question that remembers the previous
  exchanges in this session.
- Or just ask directly: anything that ends in `?` and is long enough
  gets an "Ask AI" row automatically.

The answer **streams into the panel as it is generated** — you can read
while it thinks — and lands on the clipboard when finished. Esc
dismisses it; Ctrl+K on the last-answer row (`ai`) can paste it straight
into the app you were using.

## Plugins

Plugins extend Fulcrum in any language that can print JSON — the bundled
gallery ships eleven real ones: unit conversion (`u`), Unix timestamps
(`ts`), regular expressions (`re`), timezones (`tz`), GitHub repo search
(`gh`), crates.io (`crate`), Homebrew (`brew`), Docker images (`dk`),
winget (`winget`), Bitwarden (`bw`), and currency conversion (`cur`).

- Query `gallery` to see everything; Enter installs or uninstalls.
- Query `plugins` to see what is installed and toggle each one off/on.
- Query `plugins <name>` for a plugin's detail page: every command with
  a copyable example.
- `install plugin /path/to/folder` installs a plugin from any folder —
  see [docs/plugins.md](plugins.md) to write one. A plugin is one
  manifest and one script; Python is enough.

## Settings

Query `settings` and run a row to change it — each row cycles through
its valid values:

- **language** — UI language (zh/en; update dialogs follow it).
- **theme** — system / light / dark. The panel follows it immediately.
- **hotkey** — cycles through `alt+space`, `ctrl+alt+space`,
  `ctrl+shift+space`, `alt+shift+space`. If a combo is taken on your
  machine, Fulcrum falls back and tells you.
- **max-results** — how many rows the list shows.
- **clipboard-enabled** — record clipboard history on/off.
- **web-search-enabled** — offer web-search rows on/off.
- **plugins-enabled** — load plugins on/off.
- **ai-provider** — see the AI section.

Power users can edit `settings.json` directly (its location is shown by
querying `settings` and running the reveal row, or in
`FULCRUM_DATA_DIR`). The hotkey accepts any spec of the form
`mod+key` — modifiers `alt/ctrl/shift/cmd/win/super` (at least one) and
a key from: `space`, `a`–`z`, `0`–`9`, `f1`–`f12`, `comma`, `period`,
`minus`, `equal`, `tab`. The same spec works on all three platforms.

## Updates

Query `update` and run **Check for updates now**. When a new version is
available the download runs in the background with live progress.
On macOS, Fulcrum swaps itself and relaunches; on Windows and Linux the
downloaded installer is revealed with honest manual-step guidance.
Updates are signed; a failed verification is refused, never installed.

## Sync beta

If you use iCloud Drive, Dropbox, Syncthing, or any folder-syncing
service, set `sync-root` (via `settings.json` or the `FULCRUM_SYNC_DIR`
environment variable) to a folder inside your synced drive. Your
settings and snippets mirror there, so a new or wiped machine restores
itself on first launch. Clipboard history and AI keys deliberately do
**not** sync.

## Keyboard reference

| Key | Action |
|---|---|
| `Alt+Space` (default) | Show / hide the panel |
| type | Search everything |
| `↑` / `↓` | Move selection |
| `Enter` | Run the selected result (clipboard rows paste) |
| `Ctrl+K` / `⌘K` | Secondary actions for the selection |
| `Esc` | Dismiss: actions → AI answer → query text → panel |

## Troubleshooting

- **The hotkey does nothing.** Another app owns that combo. Fulcrum
  falls back to `Ctrl+Alt+Space` and says so in the status bar; you can
  also open Fulcrum from the tray icon (Windows), the menu bar (macOS),
  or `fulcrum --toggle` (Linux).
- **Paste-to-frontmost does nothing on macOS.** Fulcrum needs the
  Accessibility permission to send the keystroke: System Settings →
  Privacy & Security → Accessibility → enable Fulcrum. The window
  management commands use the same permission.
- **Paste-to-frontmost on Linux.** Works out of the box on X11. On
  Wayland, install `wtype` (compositors do not allow apps to inject
  input directly — that is a feature, and Fulcrum respects it).
- **Linux (Wayland): the hotkey does nothing and there is no tray.**
  Wayland compositors forbid global key grabs — this is a security
  property of the platform, not a Fulcrum bug (check with
  `echo $XDG_SESSION_TYPE`). The supported way: bind your own
  compositor shortcut to the `fulcrum --toggle` command (GNOME:
  Settings → Keyboard → Custom Shortcuts; KDE: System Settings →
  Shortcuts). For background residency after login, add an autostart
  entry: `~/.config/autostart/fulcrum.desktop` with
  `Exec=/path/to/fulcrum` — the app starts hidden and stays resident;
  `fulcrum --toggle` shows it. Closing the panel window hides it, it
  does not quit.
- **AI says "no API key".** Run `ai key <secret>` after picking the
  provider in settings. Ollama needs no key, only `ollama serve`
  running.
- **Clipboard history is empty on Linux.** Entries are recorded while
  Fulcrum is running; the panel only shows what was captured since
  launch.
- **Where is my data?** Everything lives in one data directory
  (`FULCRUM_DATA_DIR`): stores as JSON, keys in `ai-keys.json`. Delete
  it and Fulcrum starts clean.

## Privacy

Search, history, and snippets never leave your device. There is no
telemetry. The only network requests Fulcrum makes are: the update
check you trigger (or the throttled silent one, against the signed
release feed), the web searches you explicitly run, and the AI prompts
you explicitly run — sent only to the provider you configured, with
your key.
