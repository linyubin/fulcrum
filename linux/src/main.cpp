// Fulcrum Linux host — GTK4 floating launcher over one embedded Racket CS
// backend, speaking RVT1 through Rivet's platform/linux runtime.
//
// Mirrors the official Linux scaffold's threading model: boot the runtime
// off the main loop behind a mutex-guarded startup handoff, dispatch every
// completion to the main loop before touching widgets, and keep shutdown
// idempotent. Single-instance activation rides Rivet's first-party
// SingleInstanceLease (`fulcrum --toggle` forwards to the primary). The
// launcher-specific parts that have no rivet counterpart stay honest about
// their platform reach: X11 grabs keys and sets EWMH state directly;
// Wayland compositors own those decisions, and the status bar says so.
#include <gdk/x11/gdkx.h>
#include <gtk/gtk.h>

#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <X11/XKBlib.h>
#include <X11/keysym.h>
#include <X11/extensions/XTest.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "GeneratedBackend.hpp"
#include "system_services.hpp"

namespace {

struct ResultRow {
  std::string id;
  std::string title;
  std::string subtitle;
  std::string kind;
  std::string arg;
  std::string icon;
  std::string hint;
  std::string badge;
};

ResultRow parse_row(std::vector<std::string> const& cells) {
  ResultRow row;
  if (cells.size() >= 8) {
    row.id = cells[0];
    row.title = cells[1];
    row.subtitle = cells[2];
    row.kind = cells[3];
    row.arg = cells[4];
    row.icon = cells[5];
    row.hint = cells[6];
    row.badge = cells[7];
  }
  return row;
}

std::filesystem::path executable_path() {
  return std::filesystem::read_symlink("/proc/self/exe");
}

struct HotkeyGrab {
  Display* display{nullptr};
  Window window{None};
};

HotkeyGrab hotkey_grab;

// The launcher hotkey as (X11 modifier mask, keysym). The grammar is one
// spec shared with the backend (settings.rkt) and the other hosts:
// modifiers alt/ctrl/shift/cmd/win/super, then space | a-z | 0-9 |
// f1-f12 | comma | period | minus | equal | tab.
struct HotkeySpec {
  unsigned int mods{Mod1Mask};
  KeySym keysym{XK_space};
};

HotkeySpec current_hotkey;
KeyCode current_hotkey_code{0};

bool parse_hotkey(std::string const& spec, HotkeySpec& out) {
  unsigned int mods = 0;
  bool has_key = false;
  std::string key;
  std::string lowered = spec;
  std::transform(lowered.begin(), lowered.end(), lowered.begin(),
                 [](unsigned char c) {
                   return static_cast<char>(std::tolower(c));
                 });
  std::size_t start = 0;
  while (start <= lowered.size()) {
    std::size_t plus = lowered.find('+', start);
    std::string token = lowered.substr(
        start, plus == std::string::npos ? std::string::npos : plus - start);
    if (token.empty()) {
      return false;
    }
    if (token == "alt" || token == "option") {
      mods |= Mod1Mask;
    } else if (token == "ctrl" || token == "control") {
      mods |= ControlMask;
    } else if (token == "shift") {
      mods |= ShiftMask;
    } else if (token == "cmd" || token == "win" || token == "super") {
      mods |= Mod4Mask;
    } else if (!has_key) {
      has_key = true;
      key = token;
    } else {
      return false;
    }
    if (plus == std::string::npos) {
      break;
    }
    start = plus + 1;
  }
  if (!has_key || mods == 0) {
    return false;
  }
  KeySym sym = NoSymbol;
  if (key == "space") {
    sym = XK_space;
  } else if (key == "tab") {
    sym = XK_Tab;
  } else if (key == "comma") {
    sym = XK_comma;
  } else if (key == "period") {
    sym = XK_period;
  } else if (key == "minus") {
    sym = XK_minus;
  } else if (key == "equal") {
    sym = XK_equal;
  } else if (key.size() == 1 && key[0] >= 'a' && key[0] <= 'z') {
    sym = XK_a + static_cast<KeySym>(key[0] - 'a');
  } else if (key.size() == 1 && key[0] >= '0' && key[0] <= '9') {
    sym = XK_0 + static_cast<KeySym>(key[0] - '0');
  } else if (key.size() >= 2 && key[0] == 'f' &&
             key.find_first_not_of("0123456789", 1) == std::string::npos) {
    int n = std::atoi(key.c_str() + 1);
    if (n < 1 || n > 12) {
      return false;
    }
    sym = XK_F1 + static_cast<KeySym>(n - 1);
  } else {
    return false;
  }
  out.mods = mods;
  out.keysym = sym;
  return true;
}

// Rebinds the X11 grab to `spec`. Returns a human-readable note on failure
// ("" on success). A spec that does not parse is ignored quietly: the
// previous binding stays and the hotkey never becomes unreachable.
std::string apply_x11_hotkey(std::string const& spec) {
  Display* dpy = hotkey_grab.display;
  if (dpy == nullptr || hotkey_grab.window == None) {
    return "";
  }
  HotkeySpec parsed;
  if (!parse_hotkey(spec, parsed)) {
    return "";
  }
  if (current_hotkey_code != 0) {
    XUngrabKey(dpy, current_hotkey_code, current_hotkey.mods,
               hotkey_grab.window);
    XUngrabKey(dpy, current_hotkey_code, current_hotkey.mods | Mod2Mask,
               hotkey_grab.window);
    current_hotkey_code = 0;
  }
  KeyCode code = XKeysymToKeycode(dpy, parsed.keysym);
  if (code == 0) {
    return "X11 hotkey setup failed: cannot resolve the key keycode.";
  }
  XGrabKey(dpy, code, parsed.mods, hotkey_grab.window, True, GrabModeAsync,
           GrabModeAsync);
  XGrabKey(dpy, code, parsed.mods | Mod2Mask, hotkey_grab.window, True,
           GrabModeAsync, GrabModeAsync);  // with NumLock
  current_hotkey = parsed;
  current_hotkey_code = code;
  XSelectInput(dpy, hotkey_grab.window, KeyPressMask);
  return "";
}

// ---- native window management (win.* actions) -----------------------------
//
// The backend ranks the rows; the host performs the move, because only a
// client with an X connection can reach other apps' windows. Targets the
// active window, tiles relative to the monitor's _NET_WORKAREA, and asks
// the window manager via _NET_MOVERESIZE_WINDOW (the EWMH-sanctioned
// request that animates and respects constraints). Compile-tested like the
// rest of the Linux host; runtime verification tracks the Linux beta.

namespace wincmd {

struct Geometry {
  int x{0}, y{0}, w{0}, h{0};
};

std::map<unsigned long, Geometry>& saved() {
  static std::map<unsigned long, Geometry> map;
  return map;
}

bool send_moveresize(Display* dpy, Window target, int x, int y, int w, int h) {
  XEvent xev{};
  xev.xclient.type = ClientMessage;
  xev.xclient.window = target;
  xev.xclient.message_type =
      XInternAtom(dpy, "_NET_MOVERESIZE_WINDOW", False);
  xev.xclient.format = 32;
  // Bits 8-10: gravity (0 = use window's), bit 12: source indication
  // (1 = application).
  xev.xclient.data.l[0] = (1 << 12);
  xev.xclient.data.l[1] = x;
  xev.xclient.data.l[2] = y;
  xev.xclient.data.l[3] = w;
  xev.xclient.data.l[4] = h;
  return XSendEvent(dpy, DefaultRootWindow(dpy), False,
                    SubstructureRedirectMask | SubstructureNotifyMask,
                    &xev) != 0;
}

bool run_window_command(std::string const& id) {
  // GTK4 owns the Display; borrow it (nullptr on pure Wayland: the honest
  // failure path).
  GdkDisplay* gdk_display = gdk_display_get_default();
  if (gdk_display == nullptr || !GDK_IS_X11_DISPLAY(gdk_display)) {
    return false;
  }
  Display* dpy = gdk_x11_display_get_xdisplay(GDK_X11_DISPLAY(gdk_display));
  if (dpy == nullptr) {
    return false;
  }
  Window root = DefaultRootWindow(dpy);
  Atom active_atom = XInternAtom(dpy, "_NET_ACTIVE_WINDOW", True);
  if (active_atom == None) {
    return false;
  }
  Atom actual_type = None;
  int actual_format = 0;
  unsigned long nitems = 0, bytes_after = 0;
  unsigned char* data = nullptr;
  if (XGetWindowProperty(dpy, root, active_atom, 0, 1, False, XA_WINDOW,
                         &actual_type, &actual_format, &nitems, &bytes_after,
                         &data) != Success ||
      nitems < 1) {
    return false;
  }
  Window target = reinterpret_cast<unsigned long*>(data)[0];
  XFree(data);
  if (target == None) {
    return false;
  }

  // Work area of the monitor holding the window (root-relative).
  int x{0}, y{0};
  unsigned int w{0}, h{0}, bw{0}, depth{0};
  Window child = None;
  if (!XGetGeometry(dpy, target, &child, &x, &y, &w, &h, &bw, &depth)) {
    return false;
  }
  // Tiling area: the root _NET_WORKAREA (single-head accurate; per-head
  // workareas need XRandR probing, a later refinement).
  Atom workarea_atom = XInternAtom(dpy, "_NET_WORKAREA", True);
  long wx{0}, wy{0}, ww{0}, wh{0};
  if (workarea_atom != None) {
    unsigned char* wa = nullptr;
    if (XGetWindowProperty(dpy, root, workarea_atom, 0, 4, False, XA_CARDINAL,
                           &actual_type, &actual_format, &nitems,
                           &bytes_after, &wa) == Success &&
        nitems >= 4) {
      long* values = reinterpret_cast<long*>(wa);
      wx = values[0]; wy = values[1]; ww = values[2]; wh = values[3];
      XFree(wa);
    }
  }

  bool need_saved = id != "win.restore";
  if (need_saved) {
    saved()[target] = {x, y, static_cast<int>(w), static_cast<int>(h)};
  }

  if (id == "win.left") {
    return send_moveresize(dpy, target, static_cast<int>(wx), static_cast<int>(wy),
                           static_cast<int>(ww) / 2, static_cast<int>(wh));
  }
  if (id == "win.right") {
    return send_moveresize(dpy, target, static_cast<int>(wx) + static_cast<int>(ww) / 2,
                           static_cast<int>(wy), static_cast<int>(ww) / 2,
                           static_cast<int>(wh));
  }
  if (id == "win.maximize") {
    return send_moveresize(dpy, target, static_cast<int>(wx), static_cast<int>(wy),
                           static_cast<int>(ww), static_cast<int>(wh));
  }
  if (id == "win.almost-max") {
    int const mw = static_cast<int>(ww) * 9 / 10;
    int const mh = static_cast<int>(wh) * 88 / 100;
    return send_moveresize(dpy, target, static_cast<int>(wx) + (static_cast<int>(ww) - mw) / 2,
                           static_cast<int>(wy) + (static_cast<int>(wh) - mh) / 2, mw, mh);
  }
  if (id == "win.center") {
    return send_moveresize(dpy, target,
                           static_cast<int>(wx) + (static_cast<int>(ww) - static_cast<int>(w)) / 2,
                           static_cast<int>(wy) + (static_cast<int>(wh) - static_cast<int>(h)) / 2,
                           static_cast<int>(w), static_cast<int>(h));
  }
  if (id == "win.restore") {
    auto it = saved().find(target);
    if (it == saved().end()) {
      return false;
    }
    Geometry g = it->second;
    saved().erase(it);
    return send_moveresize(dpy, target, g.x, g.y, g.w, g.h);
  }
  return false;
}

}  // namespace wincmd

// ---- application state ---------------------------------------------------

struct Launcher {
  GtkWindow* window{nullptr};
  GtkSearchEntry* search{nullptr};
  GtkListBox* results{nullptr};
  GtkLabel* status{nullptr};
  // Live AI answer panel (hidden until the backend pushes ai-stream).
  GtkWidget* ai_panel{nullptr};
  GtkLabel* ai_phase{nullptr};
  GtkLabel* ai_text{nullptr};
  // FPP2 plugin detail panel (hidden until a detail row runs).
  GtkWidget* detail_panel{nullptr};
  GtkLabel* detail_text{nullptr};
  GtkLabel* detail_meta{nullptr};

  std::unique_ptr<rivet::linux_runtime::Backend> backend;
  std::unique_ptr<rivet_app::API> api;
  std::vector<ResultRow> rows;
  guint search_source{0};
  // Matches the macOS/Windows hosts: only the newest query may paint, so a
  // slow completion can never overwrite a newer result set.
  std::atomic<int> search_generation{0};
  // Re-entry guard for the download-progress poller (updater 0.2).
  std::atomic<bool> update_polling{false};
  // Clipboard-history capture: the GTK host has no change notification, so
  // a 1s poll (same cadence as the macOS pasteboard timer) diffs the
  // clipboard text and records new values backend-side.
  std::string last_clipboard_text;

  // Official scaffold startup handoff: the boot thread publishes either a
  // started backend or an error; the main loop adopts it exactly once.
  std::mutex startup_mutex;
  std::thread startup_thread;
  std::unique_ptr<rivet::linux_runtime::Backend> startup_backend;
  std::string startup_error;
  std::atomic<bool> shutting_down{false};
  // Ctrl+K mode: `rows` currently holds secondary actions and
  // search_rows remembers the live result list.
  bool actions_mode{false};
  std::vector<ResultRow> search_rows;

  static Launcher& instance() {
    static Launcher launcher;
    return launcher;
  }

  void set_status(std::string const& message) {
    gtk_label_set_text(status, message.c_str());
  }

  // Marshal a status string from any worker thread onto the main loop.
  static void post_status(std::string message) {
    g_idle_add([](gpointer user_data) -> int {
      std::unique_ptr<std::string> text(static_cast<std::string*>(user_data));
      Launcher::instance().set_status(*text);
      return G_SOURCE_REMOVE;
    }, new std::string(std::move(message)));
  }

  // ---- backend-rendered settings -------------------------------------------

  // The theme setting is backend-owned; GTK can only ask for the dark
  // variant explicitly — light/system fall back to the user's GTK theme.
  static void apply_theme(std::string const& theme) {
    GtkSettings* settings = gtk_settings_get_default();
    if (settings == nullptr) {
      return;
    }
    g_object_set(settings, "gtk-application-prefer-dark-theme",
                 theme == "dark" ? TRUE : FALSE, nullptr);
  }

  void apply_ai_stream(rivet_app::AiStream const& stream) {
    if (stream.phase == "idle") {
      dismiss_ai_panel();
      return;
    }
    gtk_widget_set_visible(ai_panel, TRUE);
    gtk_label_set_text(ai_text, stream.text.c_str());
    if (stream.phase == "running") {
      gtk_label_set_text(ai_phase, "AI is answering…");
    } else if (stream.phase == "error") {
      gtk_label_set_text(ai_phase, "AI request failed");
    } else {
      gtk_label_set_text(ai_phase, "AI answer");
    }
  }

  void dismiss_ai_panel() { gtk_widget_set_visible(ai_panel, FALSE); }

  void apply_plugin_detail(rivet_app::DetailView const& view) {
    gtk_widget_set_visible(detail_panel, TRUE);
    gtk_label_set_text(detail_text, view.text.c_str());
    std::string meta;
    for (auto const& pair : view.metadata) {
      if (pair.size() >= 2) {
        if (!meta.empty()) meta += "\n";
        meta += pair[0] + "  ·  " + pair[1];
      }
    }
    gtk_label_set_text(detail_meta, meta.c_str());
  }

  void dismiss_detail_panel() {
    gtk_widget_set_visible(detail_panel, FALSE);
  }

  // The backend bumped search-revision (FPP2 daemon push): refresh the
  // rows for whatever query is on screen, debounced through the same
  // 120 ms path as typing.
  void refresh_for_revision() {
    if (search_source != 0) {
      g_source_remove(search_source);
    }
    search_source =
        g_timeout_add(250, [](gpointer) -> int {
          Launcher& l = Launcher::instance();
          l.search_source = 0;
          l.run_search(gtk_editable_get_text(GTK_EDITABLE(l.search)));
          return G_SOURCE_REMOVE;
        }, nullptr);
  }

  // One-time read of the backend-owned settings the host renders (hotkey,
  // theme). The backend pushes changes afterwards via the reserved $state
  // events; this seeds the initial values.
  void pull_host_settings() {
    if (api == nullptr) {
      return;
    }
    auto* api_raw = api.get();
    std::thread([api_raw]() mutable {
      std::string hotkey;
      std::string theme;
      try {
        hotkey = api_raw->get_hotkey().get();
      } catch (...) {
      }
      try {
        theme = api_raw->get_theme().get();
      } catch (...) {
      }
      g_idle_add([](gpointer user_data) -> int {
        std::unique_ptr<std::pair<std::string, std::string>> values(
            static_cast<std::pair<std::string, std::string>*>(user_data));
        Launcher& launcher = Launcher::instance();
        if (!values->first.empty()) {
          std::string note = apply_x11_hotkey(values->first);
          if (!note.empty()) {
            launcher.set_status(note);
          }
        }
        if (!values->second.empty()) {
          apply_theme(values->second);
        }
        return G_SOURCE_REMOVE;
      }, new std::pair<std::string, std::string>(hotkey, theme));
    }).detach();
  }

  // ---- clipboard history capture --------------------------------------------

  static void on_clipboard_read(GObject* source, GAsyncResult* result,
                                gpointer) {
    Launcher& launcher = Launcher::instance();
    gchar* text =
        gdk_clipboard_read_text_finish(GDK_CLIPBOARD(source), result, nullptr);
    if (text == nullptr) {
      return;
    }
    if (text != launcher.last_clipboard_text) {
      launcher.last_clipboard_text = text;
      std::string payload = text;
      std::thread([payload]() mutable {
        Launcher& launcher = Launcher::instance();
        if (launcher.shutting_down.load(std::memory_order_acquire)) {
          return;
        }
        auto* api_raw = launcher.api.get();
        if (api_raw == nullptr) {
          return;
        }
        try {
          api_raw->clipboard_record(payload);
        } catch (...) {
          // Persistence must never take the launcher down.
        }
      }).detach();
    }
    g_free(text);
  }

  static gboolean poll_clipboard(gpointer) {
    Launcher& launcher = Launcher::instance();
    if (launcher.api == nullptr ||
        launcher.shutting_down.load(std::memory_order_acquire)) {
      return G_SOURCE_CONTINUE;
    }
    GdkClipboard* clipboard =
        gtk_widget_get_clipboard(GTK_WIDGET(launcher.window));
    gdk_clipboard_read_text_async(clipboard, nullptr, on_clipboard_read,
                                  nullptr);
    return G_SOURCE_CONTINUE;
  }

  // Updater 0.2 (in-app install stays macOS-only on this line): the 4-hour
  // throttle and manifest verification are backend-owned, so the silent
  // launch check is one cheap RPC the backend may decline ("throttled").
  // Failures are silent by design — a resident launcher must never nag.
  void start_silent_update_check() {
    if (api == nullptr) {
      return;
    }
    auto* api_raw = api.get();
    std::thread([api_raw]() mutable {
      try {
        auto const check = api_raw->update_check(false).get();
        if (check.status != "available") {
          return;
        }
        post_status("Update available: Fulcrum v" +
                    check.available_version.value_or("?") +
                    " — type \"update\" to download");
      } catch (...) {
        // silent: network down, feed unreachable — never nag
      }
    }).detach();
  }

  // Mirror the backend's download thread into the status bar; when the
  // artifact is verified the user gets the open-folder / manual-install
  // guidance (the "update" launcher rows drive reveal on this state).
  void start_update_progress_poll() {
    if (api == nullptr || update_polling.exchange(true)) {
      return;
    }
    auto* api_raw = api.get();
    std::thread([api_raw]() mutable {
      while (true) {
        try {
          auto const state = api_raw->update_state().get();
          if (state.phase == "downloaded") {
            post_status("Update downloaded — type \"update\" to open the "
                        "folder, then extract the tar.gz to upgrade");
            break;
          }
          if (state.phase == "error") {
            post_status("Update download failed: " +
                        state.message.value_or("unknown error"));
            break;
          }
          if (state.phase != "downloading") {
            break;
          }
          post_status("Downloading update… " + std::to_string(state.percent) + "%");
        } catch (...) {
          break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1000));
      }
      // Re-entry guard only: clear it from the worker so a later download
      // can poll again.
      Launcher::instance().update_polling.store(false, std::memory_order_release);
    }).detach();
  }

  static std::string event_payload(rivet::Value const& value) {
    // Event values are bare strings per the backend contract: RVT1 event
    // frames arrive as [name, value] and the runtime hands us value.
    if (auto const* text = std::get_if<std::string>(&value.data)) {
      return *text;
    }
    return {};
  }

  // Paste-to-frontmost: the clipboard already carries the text (set on the
  // main thread in handle_event); after the panel hides and focus returns
  // to the previous app, synthesize Ctrl+V — XTEST on X11, `wtype` on
  // Wayland. GDK is main-thread-only, so the X11 check happens on the main
  // thread and this worker touches only Xlib (XInitThreads ran at startup)
  // or spawns a process.
  static void paste_keystroke_async(bool x11_session) {
    std::thread([x11_session]() {
      std::this_thread::sleep_for(std::chrono::milliseconds(180));
      if (x11_session) {
        Display* dpy = XOpenDisplay(nullptr);
        if (dpy != nullptr) {
          KeyCode ctrl = XKeysymToKeycode(dpy, XK_Control_L);
          KeyCode v = XKeysymToKeycode(dpy, XK_v);
          if (ctrl != 0 && v != 0) {
            XTestFakeKeyEvent(dpy, ctrl, True, CurrentTime);
            XTestFakeKeyEvent(dpy, v, True, CurrentTime);
            XTestFakeKeyEvent(dpy, v, False, CurrentTime);
            XTestFakeKeyEvent(dpy, ctrl, False, CurrentTime);
            XFlush(dpy);
          }
          XCloseDisplay(dpy);
          return;
        }
      }
      GError* error = nullptr;
      if (!g_spawn_command_line_async("wtype -M ctrl -P v -p v -m ctrl",
                                      &error)) {
        Launcher::post_status(
            "Paste-to-frontmost on Wayland needs `wtype` (install it), or "
            "run Fulcrum in an X11 session.");
        if (error != nullptr) {
          g_error_free(error);
        }
      }
    }).detach();
  }

  void handle_state_push(rivet::Value const& value) {
    // Reserved "$state" frames carry [state-name, wire-value].
    auto const* fields = std::get_if<rivet::Value::List>(&value.data);
    if (fields == nullptr || fields->size() != 2) {
      return;
    }
    auto const* state_name = std::get_if<std::string>(&(fields->at(0).data));
    if (state_name == nullptr) {
      return;
    }
    if (*state_name == "ai-stream") {
      rivet_app::AiStream stream;
      try {
        stream = rivet_app::detail::decode_AiStream(fields->at(1));
      } catch (...) {
        return;
      }
      g_idle_add([](gpointer user_data) -> int {
        std::unique_ptr<rivet_app::AiStream> stream(
            static_cast<rivet_app::AiStream*>(user_data));
        Launcher::instance().apply_ai_stream(*stream);
        return G_SOURCE_REMOVE;
      }, new rivet_app::AiStream(std::move(stream)));
    } else if (*state_name == "theme") {
      if (auto const* theme = std::get_if<std::string>(&(fields->at(1).data))) {
        std::string value_copy = *theme;
        g_idle_add([](gpointer user_data) -> int {
          std::unique_ptr<std::string> theme(
              static_cast<std::string*>(user_data));
          apply_theme(*theme);
          return G_SOURCE_REMOVE;
        }, new std::string(std::move(value_copy)));
      }
    } else if (*state_name == "search-revision") {
      g_idle_add([](gpointer) -> int {
        Launcher::instance().refresh_for_revision();
        return G_SOURCE_REMOVE;
      }, nullptr);
    } else if (*state_name == "hotkey") {
      if (auto const* spec = std::get_if<std::string>(&(fields->at(1).data))) {
        std::string spec_copy = *spec;
        g_idle_add([](gpointer user_data) -> int {
          std::unique_ptr<std::string> spec(
              static_cast<std::string*>(user_data));
          std::string note = apply_x11_hotkey(*spec);
          if (!note.empty()) {
            Launcher::instance().set_status(note);
          }
          return G_SOURCE_REMOVE;
        }, new std::string(std::move(spec_copy)));
      }
    }
  }

  void handle_event(std::string const& name, std::string const& payload) {
    if (name == "copy-to-clipboard") {
      if (GdkClipboard* clipboard =
              gtk_widget_get_clipboard(GTK_WIDGET(window))) {
        gdk_clipboard_set_text(clipboard, payload.c_str());
      }
      hide();
    } else if (name == "paste-to-frontmost") {
      if (GdkClipboard* clipboard =
              gtk_widget_get_clipboard(GTK_WIDGET(window))) {
        gdk_clipboard_set_text(clipboard, payload.c_str());
      }
      hide();
      bool const x11_session =
          GDK_IS_X11_DISPLAY(gdk_display_get_default());
      paste_keystroke_async(x11_session);
    } else if (name == "ai-finished") {
      // The answer lands on the clipboard, but the panel stays: the user
      // is reading the streamed text right now.
      if (GdkClipboard* clipboard =
              gtk_widget_get_clipboard(GTK_WIDGET(window))) {
        gdk_clipboard_set_text(clipboard, payload.c_str());
      }
      set_status("Answer copied to the clipboard");
    } else if (name == "open-url") {
      gtk_show_uri(GTK_WINDOW(window), payload.c_str(), GDK_CURRENT_TIME);
      hide();
    } else if (name == "update-available") {
      set_status(payload);
    }
  }

  // All request/response traffic runs on short-lived worker threads; the
  // callbacks only marshal (boxed) results back through g_idle_add.

  struct SearchOutcome {
    bool ok{false};
    int generation{0};
    std::vector<ResultRow> rows;
    std::string error;
  };

  void run_search(std::string const& query) {
    if (api == nullptr || shutting_down.load(std::memory_order_acquire)) {
      return;
    }
    auto* api_raw = api.get();
    auto* boxed = new SearchOutcome;
    boxed->generation = search_generation.fetch_add(1) + 1;
    std::thread([api_raw, query, boxed]() mutable {
      try {
        for (auto const& cells : api_raw->search(query).get()) {
          boxed->rows.push_back(parse_row(cells));
        }
        boxed->ok = true;
      } catch (std::exception const& e) {
        boxed->error = e.what();
      }
      g_idle_add([](gpointer user_data) -> int {
        std::unique_ptr<SearchOutcome> job(
            static_cast<SearchOutcome*>(user_data));
        Launcher& launcher = Launcher::instance();
        if (job->generation == launcher.search_generation.load()) {
          launcher.apply_search(std::move(*job));
        }
        return G_SOURCE_REMOVE;
      }, boxed);
    }).detach();
  }

  void apply_search(SearchOutcome result) {
    if (!result.ok) {
      set_status("Search failed: " + result.error);
      return;
    }
    rows = std::move(result.rows);
    refresh_results();
  }

  void refresh_results() {
    // Rebuild the list; simple and correct beats incremental cleverness at
    // this list size (≤ max-results rows).
    for (GtkWidget* child = gtk_widget_get_first_child(GTK_WIDGET(results));
         child != nullptr;) {
      GtkWidget* next = gtk_widget_get_next_sibling(child);
      gtk_list_box_remove(results, child);
      child = next;
    }
    for (auto const& row : rows) {
      auto* box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
      gtk_widget_set_margin_top(box, 6);
      gtk_widget_set_margin_bottom(box, 6);
      gtk_widget_set_margin_start(box, 10);
      gtk_widget_set_margin_end(box, 10);
      auto* title = gtk_label_new(row.title.c_str());
      gtk_label_set_xalign(GTK_LABEL(title), 0.0);
      gtk_label_set_ellipsize(GTK_LABEL(title), PANGO_ELLIPSIZE_END);
      gtk_widget_add_css_class(title, "heading");
      auto* subtitle = gtk_label_new(
          row.subtitle.empty() ? row.kind.c_str() : row.subtitle.c_str());
      gtk_label_set_xalign(GTK_LABEL(subtitle), 0.0);
      gtk_label_set_ellipsize(GTK_LABEL(subtitle), PANGO_ELLIPSIZE_END);
      gtk_widget_add_css_class(subtitle, "caption");
      gtk_widget_add_css_class(subtitle, "dim-label");
      gtk_box_append(GTK_BOX(box), title);
      gtk_box_append(GTK_BOX(box), subtitle);
      gtk_list_box_append(results, box);
    }
    if (!rows.empty()) {
      gtk_list_box_select_row(results,
                              gtk_list_box_get_row_at_index(results, 0));
    }
  }

  struct RunOutcome {
    bool success{false};
    std::string status;
    std::string action_id;
    std::string arg;
  };

  void show_actions_for_selection() {
    if (api == nullptr || rows.empty() || actions_mode) {
      return;
    }
    GtkListBoxRow* selected = gtk_list_box_get_selected_row(results);
    int index = selected != nullptr ? gtk_list_box_row_get_index(selected) : 0;
    if (index < 0 || index >= static_cast<int>(rows.size())) {
      index = 0;
    }
    ResultRow const row = rows[static_cast<std::size_t>(index)];
    search_rows = rows;
    auto* api_raw = api.get();
    std::thread([api_raw, row]() mutable {
      std::vector<ResultRow> actions;
      std::string error;
      try {
        for (auto const& cells : api_raw->row_actions(row.id, row.arg).get()) {
          actions.push_back(parse_row(cells));
        }
      } catch (std::exception const& e) {
        error = e.what();
      }
      g_idle_add([](gpointer user_data) -> int {
        std::unique_ptr<std::vector<ResultRow>> job(
            static_cast<std::vector<ResultRow>*>(user_data));
        Launcher& launcher = Launcher::instance();
        launcher.actions_mode = true;
        launcher.rows = std::move(*job);
        launcher.refresh_results();
        if (launcher.rows.empty()) {
          launcher.set_status("No secondary actions for this result");
        }
        return G_SOURCE_REMOVE;
      }, new std::vector<ResultRow>(std::move(actions)));
      (void)error;
    }).detach();
  }

  void close_actions() {
    actions_mode = false;
    rows = std::move(search_rows);
    search_rows.clear();
    refresh_results();
    gtk_widget_grab_focus(GTK_WIDGET(search));
  }

  void run_selected() {
    if (api == nullptr || rows.empty()) {
      return;
    }
    GtkListBoxRow* selected = gtk_list_box_get_selected_row(results);
    int index = selected != nullptr ? gtk_list_box_row_get_index(selected) : 0;
    if (index < 0 || index >= static_cast<int>(rows.size())) {
      index = 0;
    }
    ResultRow const row = rows[static_cast<std::size_t>(index)];
    set_status("Running…");
    auto* api_raw = api.get();
    std::thread([api_raw, row]() mutable {
      auto* boxed = new RunOutcome;
      boxed->action_id = row.id;
      boxed->arg = row.arg;
      try {
        boxed->status = api_raw->run_action(row.id, row.arg).get();
        boxed->success = boxed->status == "ok" ||
                         boxed->status == "launched" ||
                         boxed->status == "copied" ||
                         boxed->status == "opened" ||
                         boxed->status == "started" ||
                         boxed->status == "detail" ||
                         boxed->status == "stay" ||
                         boxed->status == "downloading" ||
                         boxed->status == "delegated";
      } catch (std::exception const& e) {
        boxed->status = e.what();
      }
      g_idle_add([](gpointer user_data) -> int {
        std::unique_ptr<RunOutcome> job(static_cast<RunOutcome*>(user_data));
        if (job->success) {
          // Window commands ride "delegated": the backend ranks the rows,
          // the host performs the native window move on the frontmost
          // X11 window (main thread: GDK owns the display here).
          if (job->action_id.rfind("win.", 0) == 0) {
            if (!wincmd::run_window_command(job->action_id)) {
              Launcher::instance().set_status(
                  "Window command failed (X11/Wayland window manager refused).");
              return G_SOURCE_REMOVE;
            }
          }
          if (job->status == "started") {
            // AI run: the request continues on a backend thread; the
            // ai-stream State drives the streaming panel.
            Launcher::instance().set_status("AI is answering…");
            return G_SOURCE_REMOVE;
          }
          if (job->status == "stay") {
            // The result is meant to be read (update check, ...): the
            // notify event already wrote the status line (selectable, so
            // errors can be copied); keep the panel open.
            return G_SOURCE_REMOVE;
          }
          if (job->status == "detail") {
            // FPP2 plugin detail: fetch the payload and show it in the
            // panel slot. The RPC runs on a worker thread; the paint
            // marshals back through g_idle_add.
            Launcher::instance().dismiss_detail_panel();
            std::string const row_id = job->action_id;
            auto* api_raw = Launcher::instance().api.get();
            std::thread([api_raw, row_id, arg = job->arg]() mutable {
              try {
                auto view = api_raw->plugin_detail(row_id, arg).get();
                g_idle_add([](gpointer user_data) -> int {
                  std::unique_ptr<rivet_app::DetailView> view(
                      static_cast<rivet_app::DetailView*>(user_data));
                  Launcher::instance().apply_plugin_detail(*view);
                  return G_SOURCE_REMOVE;
                }, new rivet_app::DetailView(std::move(view)));
              } catch (std::exception const& e) {
                Launcher::post_status(std::string("Detail error: ") + e.what());
              }
            }).detach();
            return G_SOURCE_REMOVE;
          }
          if (job->status == "downloading") {
            // The backend download thread owns the transfer; the host
            // mirrors its progress into the status bar.
            Launcher::instance().hide();
            Launcher::instance().start_update_progress_poll();
            return G_SOURCE_REMOVE;
          }
          if (Launcher::instance().actions_mode) {
            // A mutating action (pin, delete, copy) keeps the launcher
            // open, back on the search rows.
            Launcher::instance().close_actions();
          } else {
            Launcher::instance().hide();
          }
        } else {
          Launcher::instance().set_status("Action failed: " + job->status);
        }
        return G_SOURCE_REMOVE;
      }, boxed);
    }).detach();
  }

  void show() {
    actions_mode = false;
    dismiss_ai_panel();
    dismiss_detail_panel();
    gtk_editable_set_text(GTK_EDITABLE(search), "");
    run_search("");
    gtk_widget_set_visible(GTK_WIDGET(window), TRUE);
    gtk_window_present(window);
  }

  void hide() { gtk_widget_set_visible(GTK_WIDGET(window), FALSE); }

  void toggle() {
    if (gtk_widget_get_visible(GTK_WIDGET(window))) {
      hide();
    } else {
      show();
    }
  }

  // ---- backend lifecycle -------------------------------------------------

  void start_backend() {
    // raco rivet build/dev stages runtime/*.boot and res/core.zo beside the
    // executable; that is the only layout the official CLI produces.
    std::filesystem::path const root = executable_path().parent_path();
    std::filesystem::path const petite = root / "runtime" / "petite.boot";
    std::filesystem::path const scheme = root / "runtime" / "scheme.boot";
    std::filesystem::path const racket_boot = root / "runtime" / "racket.boot";
    std::filesystem::path const core = root / "res" / "core.zo";
    if (!std::filesystem::exists(petite) ||
        !std::filesystem::exists(scheme) ||
        !std::filesystem::exists(racket_boot) ||
        !std::filesystem::exists(core)) {
      set_status("Missing Rivet runtime layout (runtime/*.boot, res/core.zo) "
                 "next to the executable. Build with raco rivet build/dev.");
      return;
    }

    rivet::linux_runtime::RacketRuntimeConfig config;
    config.executable_path = executable_path().string();
    config.petite_boot = petite.string();
    config.scheme_boot = scheme.string();
    config.racket_boot = racket_boot.string();
    config.backend_bundle = core.string();
    config.module_name = rivet_app::kModuleName;
    config.entry_symbol = rivet_app::kEntryName;

    startup_thread = std::thread([config = std::move(config)]() mutable {
      auto backend =
          std::make_unique<rivet::linux_runtime::Backend>(std::move(config));
      try {
        backend->start();
        std::lock_guard lock(Launcher::instance().startup_mutex);
        Launcher::instance().startup_backend = std::move(backend);
      } catch (std::exception const& e) {
        std::lock_guard lock(Launcher::instance().startup_mutex);
        Launcher::instance().startup_error = e.what();
      }
      g_idle_add([](gpointer) -> int {
        Launcher::instance().on_backend_ready();
        return G_SOURCE_REMOVE;
      }, nullptr);
    });
  }

  void on_backend_ready() {
    if (startup_thread.joinable()) {
      startup_thread.join();
    }

    std::unique_ptr<rivet::linux_runtime::Backend> backend;
    std::string error;
    {
      std::lock_guard lock(startup_mutex);
      backend = std::move(startup_backend);
      error = std::move(startup_error);
    }

    if (shutting_down.load(std::memory_order_acquire)) {
      if (backend != nullptr) {
        backend->stop();
      }
      return;
    }
    if (!error.empty()) {
      set_status("Fulcrum backend failed to start: " + error);
      return;
    }
    if (backend == nullptr) {
      set_status("Fulcrum backend error: startup completed without a backend");
      return;
    }

    backend_ = std::move(backend);
    api = std::make_unique<rivet_app::API>(*backend_);

    backend_->set_event_handler(
        [](std::string const& name, rivet::Value const& value) {
          if (name == "$state") {
            // Reserved state pushes need the raw list payload; decode on
            // the main loop (handle_state_push marshals internally).
            auto* job = new std::pair<std::string, rivet::Value>(
                name, value);
            g_idle_add([](gpointer user_data) -> int {
              std::unique_ptr<std::pair<std::string, rivet::Value>> frame(
                  static_cast<std::pair<std::string, rivet::Value>*>(
                      user_data));
              Launcher::instance().handle_state_push(frame->second);
              return G_SOURCE_REMOVE;
            }, job);
            return;
          }
          auto* job = new std::pair<std::string, std::string>(
              name, event_payload(value));
          g_idle_add([](gpointer user_data) -> int {
            std::unique_ptr<std::pair<std::string, std::string>> payload(
                static_cast<std::pair<std::string, std::string>*>(user_data));
            Launcher::instance().handle_event(payload->first, payload->second);
            return G_SOURCE_REMOVE;
          }, job);
        });

    set_status("Ready — hotkey or `fulcrum --toggle`");
    run_search("");
    start_silent_update_check();
    pull_host_settings();
    g_timeout_add(1000, poll_clipboard, nullptr);
  }

  void stop_backend() {
    shutting_down.store(true, std::memory_order_release);
    if (startup_thread.joinable()) {
      startup_thread.join();
    }
    if (backend_ != nullptr) {
      backend_->stop();
    }
  }

 private:
  std::unique_ptr<rivet::linux_runtime::Backend> backend_;
};

// ---- X11 global hotkey ----------------------------------------------------

gboolean on_x11_hotkey(GIOChannel*, GIOCondition, gpointer) {
  Launcher::instance().toggle();
  // Drain pending X events for the connection.
  while (XPending(hotkey_grab.display) > 0) {
    XEvent event;
    XNextEvent(hotkey_grab.display, &event);
  }
  return G_SOURCE_CONTINUE;
}

std::string install_x11_hotkey(GdkDisplay* display, GtkWindow* window) {
  if (GDK_IS_X11_DISPLAY(display) == 0) {
    return "Wayland session: compositors do not allow global key grabs. "
           "Bind `fulcrum --toggle` to a key in your compositor settings.";
  }
  hotkey_grab.display = gdk_x11_display_get_xdisplay(GDK_X11_DISPLAY(display));
  hotkey_grab.window =
      gdk_x11_surface_get_xid(gtk_native_get_surface(GTK_NATIVE(window)));

  // Bootstrap grab so the launcher is reachable before the backend
  // answers; the stored hotkey spec re-binds once the state arrives.
  std::string note = apply_x11_hotkey("alt+space");
  if (!note.empty()) {
    return note;
  }

  int x11_fd = ConnectionNumber(hotkey_grab.display);
  GIOChannel* channel = g_io_channel_unix_new(x11_fd);
  g_io_add_watch(channel, G_IO_IN, on_x11_hotkey, nullptr);
  g_io_channel_unref(channel);
  return "";
}

// ---- single instance via the first-party rivet lease ----------------------
// `fulcrum --toggle` forwards the argument to the running primary, whose
// activation handler presents the panel on the GTK main loop (the handler
// itself runs on the lease's watcher thread).

gboolean activate_on_main(gpointer) {
  Launcher::instance().show();
  return G_SOURCE_REMOVE;
}

void on_activation(std::vector<std::string> arguments) {
  (void)arguments;  // fulcrum only ever forwards --toggle
  g_idle_add(activate_on_main, nullptr);
}

// ---- GTK wiring -----------------------------------------------------------

void on_search_changed(GtkSearchEntry*, gpointer) {
  Launcher& launcher = Launcher::instance();
  if (launcher.search_source != 0) {
    g_source_remove(launcher.search_source);
  }
  // Debounce fast typing.
  launcher.search_source =
      g_timeout_add(120, [](gpointer) -> int {
        Launcher& l = Launcher::instance();
        l.search_source = 0;
        l.run_search(gtk_editable_get_text(GTK_EDITABLE(l.search)));
        return G_SOURCE_REMOVE;
      }, nullptr);
}

void on_row_activated(GtkListBox*, GtkListBoxRow*, gpointer) {
  Launcher::instance().run_selected();
}

gboolean on_key_pressed(GtkEventControllerKey*, guint keyval, guint,
                        GdkModifierType state, gpointer) {
  // Ctrl+K equivalent: the selected row's secondary actions.
  if (keyval == GDK_KEY_k && (state & GDK_CONTROL_MASK) != 0) {
    Launcher::instance().show_actions_for_selection();
    return TRUE;
  }
  switch (keyval) {
    case GDK_KEY_Escape:
      // Inside the action panel: back to the search rows first.
      if (Launcher::instance().actions_mode) {
        Launcher::instance().close_actions();
        return TRUE;
      }
      // A plugin detail panel or a finished AI answer dismisses first.
      if (gtk_widget_get_visible(Launcher::instance().detail_panel)) {
        Launcher::instance().dismiss_detail_panel();
        return TRUE;
      }
      if (gtk_widget_get_visible(Launcher::instance().ai_panel)) {
        Launcher::instance().dismiss_ai_panel();
        return TRUE;
      }
      // Alfred/Raycast convention: clear the query first, hide only when
      // it is already empty.
      if (const gchar* text =
              gtk_editable_get_text(GTK_EDITABLE(Launcher::instance().search));
          text != nullptr && *text != '\0') {
        gtk_editable_set_text(GTK_EDITABLE(Launcher::instance().search), "");
        Launcher::instance().run_search("");
      } else {
        Launcher::instance().hide();
      }
      return TRUE;
    case GDK_KEY_Down:
    case GDK_KEY_Up: {
      Launcher& launcher = Launcher::instance();
      int const delta = keyval == GDK_KEY_Down ? 1 : -1;
      GtkListBoxRow* current = gtk_list_box_get_selected_row(launcher.results);
      int index = current != nullptr ? gtk_list_box_row_get_index(current) : 0;
      index = std::clamp(index + delta, 0,
                         static_cast<int>(launcher.rows.size()) - 1);
      if (!launcher.rows.empty()) {
        gtk_list_box_select_row(launcher.results,
                                gtk_list_box_get_row_at_index(launcher.results,
                                                              index));
      }
      return TRUE;
    }
    case GDK_KEY_Return:
    case GDK_KEY_KP_Enter:
      Launcher::instance().run_selected();
      return TRUE;
    default:
      return FALSE;
  }
}

void on_window_active_changed(GObject* obj, GParamSpec*, gpointer) {
  auto* gtk_window = GTK_WINDOW(obj);
  // Hide on focus loss, matching the other platform hosts.
  if (!gtk_window_is_active(gtk_window) &&
      gtk_widget_get_visible(GTK_WIDGET(gtk_window))) {
    Launcher::instance().hide();
  }
}

void on_activate(GtkApplication* app, gpointer) {
  Launcher& launcher = Launcher::instance();

  // The panel hides on focus loss; without a hold, GTK would treat the
  // hidden window as "last window closed" and shut the whole app down.
  g_application_hold(G_APPLICATION(app));

  auto* window = gtk_application_window_new(app);
  launcher.window = GTK_WINDOW(window);
  gtk_window_set_title(launcher.window, "Fulcrum");
  gtk_window_set_default_size(launcher.window, 680, 440);
  gtk_window_set_resizable(launcher.window, FALSE);
  gtk_window_set_hide_on_close(launcher.window, FALSE);
  gtk_widget_add_css_class(window, "fulcrum-window");

  auto* root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
  auto* search = gtk_search_entry_new();
  gtk_search_entry_set_placeholder_text(GTK_SEARCH_ENTRY(search),
                                        "Search apps, clipboard, snippets, the web…");
  gtk_widget_set_margin_top(search, 10);
  gtk_widget_set_margin_start(search, 10);
  gtk_widget_set_margin_end(search, 10);
  launcher.search = GTK_SEARCH_ENTRY(search);

  auto* status = gtk_label_new("Starting embedded Racket CS…");
  gtk_label_set_xalign(GTK_LABEL(status), 0.0);
  gtk_label_set_selectable(GTK_LABEL(status), TRUE);
  gtk_widget_set_margin_start(status, 12);
  gtk_widget_set_margin_top(status, 6);
  launcher.status = GTK_LABEL(status);

  // Live AI answer panel: hidden until the backend pushes the ai-stream
  // state, then shows the growing answer (GTK propagates the natural
  // height so short answers never reserve dead space).
  auto* ai_panel = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
  gtk_widget_set_visible(ai_panel, FALSE);
  gtk_widget_set_margin_start(ai_panel, 12);
  gtk_widget_set_margin_end(ai_panel, 12);
  gtk_widget_set_margin_top(ai_panel, 4);
  auto* ai_phase = gtk_label_new("AI is answering…");
  gtk_label_set_xalign(GTK_LABEL(ai_phase), 0.0);
  gtk_widget_add_css_class(ai_phase, "caption");
  gtk_widget_add_css_class(ai_phase, "dim-label");
  auto* ai_scroll = gtk_scrolled_window_new();
  gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(ai_scroll),
                                 GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
  gtk_scrolled_window_set_max_content_height(
      GTK_SCROLLED_WINDOW(ai_scroll), 170);
  gtk_scrolled_window_set_propagate_natural_height(
      GTK_SCROLLED_WINDOW(ai_scroll), TRUE);
  auto* ai_text = gtk_label_new("");
  gtk_label_set_wrap(GTK_LABEL(ai_text), TRUE);
  gtk_label_set_xalign(GTK_LABEL(ai_text), 0.0);
  gtk_label_set_selectable(GTK_LABEL(ai_text), TRUE);
  gtk_widget_add_css_class(ai_text, "monospace");
  gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(ai_scroll), ai_text);
  gtk_box_append(GTK_BOX(ai_panel), ai_phase);
  gtk_box_append(GTK_BOX(ai_panel), ai_scroll);
  launcher.ai_panel = ai_panel;
  launcher.ai_phase = GTK_LABEL(ai_phase);
  launcher.ai_text = GTK_LABEL(ai_text);

  // FPP2 plugin detail panel: same slot, static payload (text + a
  // metadata block).
  auto* detail_panel = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
  gtk_widget_set_visible(detail_panel, FALSE);
  gtk_widget_set_margin_start(detail_panel, 12);
  gtk_widget_set_margin_end(detail_panel, 12);
  gtk_widget_set_margin_top(detail_panel, 4);
  auto* detail_header = gtk_label_new("Details");
  gtk_label_set_xalign(GTK_LABEL(detail_header), 0.0);
  gtk_widget_add_css_class(detail_header, "caption");
  gtk_widget_add_css_class(detail_header, "dim-label");
  auto* detail_scroll = gtk_scrolled_window_new();
  gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(detail_scroll),
                                 GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
  gtk_scrolled_window_set_max_content_height(
      GTK_SCROLLED_WINDOW(detail_scroll), 180);
  gtk_scrolled_window_set_propagate_natural_height(
      GTK_SCROLLED_WINDOW(detail_scroll), TRUE);
  auto* detail_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
  auto* detail_text = gtk_label_new("");
  gtk_label_set_wrap(GTK_LABEL(detail_text), TRUE);
  gtk_label_set_xalign(GTK_LABEL(detail_text), 0.0);
  gtk_label_set_selectable(GTK_LABEL(detail_text), TRUE);
  auto* detail_meta = gtk_label_new("");
  gtk_label_set_wrap(GTK_LABEL(detail_meta), TRUE);
  gtk_label_set_xalign(GTK_LABEL(detail_meta), 0.0);
  gtk_label_set_selectable(GTK_LABEL(detail_meta), TRUE);
  gtk_widget_add_css_class(detail_meta, "dim-label");
  gtk_box_append(GTK_BOX(detail_box), detail_text);
  gtk_box_append(GTK_BOX(detail_box), detail_meta);
  gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(detail_scroll),
                                detail_box);
  gtk_box_append(GTK_BOX(detail_panel), detail_header);
  gtk_box_append(GTK_BOX(detail_panel), detail_scroll);
  launcher.detail_panel = detail_panel;
  launcher.detail_text = GTK_LABEL(detail_text);
  launcher.detail_meta = GTK_LABEL(detail_meta);

  auto* scrolled = gtk_scrolled_window_new();
  gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scrolled),
                                 GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
  auto* results = gtk_list_box_new();
  gtk_list_box_set_selection_mode(GTK_LIST_BOX(results), GTK_SELECTION_SINGLE);
  gtk_list_box_set_activate_on_single_click(GTK_LIST_BOX(results), FALSE);
  launcher.results = GTK_LIST_BOX(results);
  gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scrolled), results);

  auto* hint = gtk_label_new("↑↓ navigate · ↵ run · esc hide — Fulcrum");
  gtk_label_set_xalign(GTK_LABEL(hint), 0.0);
  gtk_widget_add_css_class(hint, "caption");
  gtk_widget_add_css_class(hint, "dim-label");
  gtk_widget_set_margin_start(hint, 12);
  gtk_widget_set_margin_top(hint, 4);
  gtk_widget_set_margin_bottom(hint, 8);

  gtk_box_append(GTK_BOX(root), search);
  gtk_box_append(GTK_BOX(root), status);
  gtk_box_append(GTK_BOX(root), ai_panel);
  gtk_box_append(GTK_BOX(root), detail_panel);
  gtk_box_append(GTK_BOX(root), scrolled);
  gtk_box_append(GTK_BOX(root), hint);
  gtk_window_set_child(launcher.window, root);

  g_signal_connect(search, "search-changed",
                   G_CALLBACK(on_search_changed), nullptr);
  g_signal_connect(results, "row-activated",
                   G_CALLBACK(on_row_activated), nullptr);

  auto* controller = gtk_event_controller_key_new();
  gtk_event_controller_set_propagation_phase(controller, GTK_PHASE_CAPTURE);
  g_signal_connect(controller, "key-pressed", G_CALLBACK(on_key_pressed),
                   nullptr);
  gtk_widget_add_controller(window, controller);

  g_signal_connect(window, "notify::is-active",
                   G_CALLBACK(on_window_active_changed), nullptr);

  // Realize once so the XID exists, then install the overlay chrome (X11
  // only, through EWMH) and the platform hotkey. Wayland compositors own
  // those decisions; the status message covers that honestly.
  gtk_widget_realize(window);
  if (GDK_IS_X11_DISPLAY(gtk_widget_get_display(window))) {
    Display* dpy =
        gdk_x11_display_get_xdisplay(gtk_widget_get_display(window));
    Window xid = gdk_x11_surface_get_xid(
        gtk_native_get_surface(GTK_NATIVE(window)));
    Atom wm_state = XInternAtom(dpy, "_NET_WM_STATE", False);
    Atom above = XInternAtom(dpy, "_NET_WM_STATE_ABOVE", False);
    Atom skip_taskbar = XInternAtom(dpy, "_NET_WM_STATE_SKIP_TASKBAR", False);
    Atom wm_window_type = XInternAtom(dpy, "_NET_WM_WINDOW_TYPE", False);
    Atom utility = XInternAtom(dpy, "_NET_WM_WINDOW_TYPE_UTILITY", False);
    XChangeProperty(dpy, xid, wm_window_type, XA_ATOM, 32, PropModeReplace,
                    reinterpret_cast<unsigned char*>(&utility), 1);
    XChangeProperty(dpy, xid, wm_state, XA_ATOM, 32, PropModeAppend,
                    reinterpret_cast<unsigned char*>(&above), 1);
    XChangeProperty(dpy, xid, wm_state, XA_ATOM, 32, PropModeAppend,
                    reinterpret_cast<unsigned char*>(&skip_taskbar), 1);
  }
  std::string hotkey_note =
      install_x11_hotkey(gtk_widget_get_display(window), launcher.window);
  if (!hotkey_note.empty()) {
    launcher.set_status(hotkey_note);
  }

  launcher.start_backend();
}

void on_shutdown(GApplication*, gpointer) {
  Launcher::instance().stop_backend();
}

}  // namespace

int main(int argc, char** argv) {
  // The first-party rivet lease replaces the old pid-file + SIGUSR1 scheme:
  // second launches forward --toggle to the primary and exit.
  rivet::system::SingleInstanceLease lease("site.jrtx.fulcrum");
  if (!lease.is_primary()) {
    if (!lease.forward_arguments({"--toggle"})) {
      std::cerr << "fulcrum: running instance not reachable\n";
      return 1;
    }
    return 0;
  }
  // A --toggle that arrives when no primary is running would otherwise fall
  // through to GApplication, which rejects the unknown option. There is
  // nothing to toggle yet.
  for (int i = 1; i < argc; ++i) {
    if (std::string{argv[i]} == "--toggle") {
      std::cerr << "fulcrum: no running instance to toggle\n";
      return 1;
    }
  }
  lease.set_activation_handler(on_activation);

  XInitThreads();
  auto* app =
      gtk_application_new("site.jrtx.fulcrum", G_APPLICATION_DEFAULT_FLAGS);
  g_signal_connect(app, "activate", G_CALLBACK(on_activate), nullptr);
  g_signal_connect(app, "shutdown", G_CALLBACK(on_shutdown), nullptr);
  int const status = g_application_run(G_APPLICATION(app), argc, argv);
  g_object_unref(app);
  return status;
}
