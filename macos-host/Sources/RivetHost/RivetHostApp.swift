import SwiftUI
import AppKit
import Carbon.HIToolbox
import RivetEmbedding
import RivetRuntime
import RivetSystem

@main
struct FulcrumApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = LauncherModel()

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

/// Owns the floating panel, the global hotkey, and the clipboard watcher.
/// The SwiftUI scene graph stays inside the panel's content view.
/// AppKit delegates run on the main thread; Swift 6 concurrency makes that
/// explicit with @MainActor.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel?
    private var hotkeyRef: EventHotKeyRef?
    private var activeHotkeySpec: String?
    private var eventHandler: EventHandlerRef?
    private var clipboardTimer: Timer?
    private var keyMonitor: Any?
    private var lastPasteboardChange: Int = -1
    private(set) var model: LauncherModel?
    // Retained for the process lifetime: dropping it releases the lock file.
    private var instanceLease: RivetSingleInstance?
    // Menu bar presence: the discoverable way in when the hotkey is
    // forgotten, and the only quit affordance (Esc just hides).
    private var menuBar: RivetMenuBarController?
    // Update flow (updater 0.2): panel window + RPC orchestration.
    private var updateController: UpdateController?
    private var updateWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One instance owns the global hotkey; second launches exit here via
        // the first-party rivet lease instead of growing a second panel. The
        // lease is retained so the lock holds for the process lifetime.
        if let lease = try? RivetSingleInstance(applicationID: "site.jrtx.fulcrum") {
            guard lease.isPrimary else {
                NSApp.terminate(nil)
                return
            }
            instanceLease = lease
        }
        Self.shared = self
        let launcherModel = LauncherModel()
        model = launcherModel
        let updater = UpdateController()
        updateController = updater
        updater.attach(model: launcherModel)
        launcherModel.onBackendReady = { [weak self] in
            self?.backendReady()
        }
        installPanel(model: launcherModel)
        installHotkeyHandler()
        applyHotkey("alt+space")
        installKeyMonitor()
        installMenuBar(model: launcherModel)
        installClipboardWatcher(model: launcherModel)
        launcherModel.start()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: backend readiness

    /// The embedded backend answered health: read the host-rendered
    /// settings (hotkey, theme, language) into the app and arm the
    /// throttled silent update check (the throttle itself lives
    /// backend-side, so this is one cheap RPC the backend may decline).
    private func backendReady() {
        guard let model else { return }
        Task { [weak self] in
            if let api = model.api {
                if let spec = try? await api.getHotkey() {
                    self?.applyHotkey(spec)
                }
                if let theme = try? await api.getTheme() {
                    Self.applyTheme(theme)
                }
                if let rows = try? await api.settingsList(),
                   let language = rows.first(where: { $0.id == "language" }) {
                    I18nService.shared.setLanguage(language.badge)
                }
            }
            self?.updateController?.silentStartupCheck()
        }
    }

    // MARK: theme

    /// The theme setting is backend-owned (settings-as-rows); the host
    /// consumes it as the app-wide NSAppearance, which the panel vibrancy
    /// follows.
    @MainActor
    static func applyTheme(_ value: String) {
        switch value {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    // MARK: update panel

    /// The update panel lives in its own small window: the launcher panel is
    /// transient (Esc hides it), while the update flow must survive focus
    /// changes until the user decides.
    nonisolated func showUpdatePanel() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let controller = self.updateController ?? UpdateController()
            self.updateController = controller
            let window = self.updateWindow ?? Self.makeUpdateWindow(controller: controller)
            self.updateWindow = window
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    private static func makeUpdateWindow(controller: UpdateController) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 220),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Fulcrum"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: UpdatePanelView(controller: controller))
        return window
    }

    // MARK: panel

    private func installPanel(model: LauncherModel) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 440),
                            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        // The content view's vibrancy material owns the visuals; the panel
        // itself is transparent so the rounded corners read cleanly.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let hosting = NSHostingView(rootView: LauncherView().environmentObject(model))
        panel.contentView = hosting
        centerOnActiveScreen(panel)
        self.panel = panel

        model.onToggle = { [weak self] in self?.togglePanel() }
        model.onHide = { [weak self] in self?.hidePanel() }
    }

    private func centerOnActiveScreen(_ panel: NSPanel) {
        let screens = NSScreen.screens
        let screen = screens.first { $0 == NSScreen.main } ?? screens.first ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.maxY - size.height / 4 - size.height
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func togglePanel() {
        guard let panel else { return }
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    func showPanel() {
        guard let panel else { return }
        // Paste-to-frontmost hides the whole app so the keystroke lands in
        // the previous one; summoning again brings it back.
        if NSApp.isHidden {
            NSApp.unhide(nil)
        }
        centerOnActiveScreen(panel)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model?.beginSearch()
    }

    func hidePanel() {
        panel?.orderOut(nil)
    }

    // MARK: global hotkey

    /// Installs the Carbon event handler once (it cannot capture context
    /// and hops to the main actor through AppDelegate.shared).
    private func installHotkeyHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(),
                                         { _, _, _ -> OSStatus in
                                             DispatchQueue.main.async {
                                                 AppDelegate.shared?.hotkeyFired()
                                             }
                                             return noErr
                                         },
                                         1, &eventType, nil, &eventHandler)
        guard status == noErr else {
            model?.setPersistentStatus("Fulcrum could not install its global hotkey handler (OSStatus \(status)).")
            return
        }
    }

    /// Binds the launcher hotkey from the settings spec ("alt+space", …).
    /// Runs at launch with the default and again whenever the backend
    /// pushes the hotkey State (startup pull or a settings change). A spec
    /// that does not parse or a taken combo falls back to Ctrl+Alt+Space
    /// with a status note — the launcher must never end up unreachable.
    func applyHotkey(_ spec: String) {
        if let previous = hotkeyRef {
            UnregisterEventHotKey(previous)
            hotkeyRef = nil
        }
        if let binding = Hotkey.parse(spec),
           registerHotkey(keyCode: binding.keyCode, modifiers: binding.modifiers) {
            activeHotkeySpec = spec
        } else if registerHotkey(keyCode: UInt32(kVK_Space),
                                 modifiers: UInt32(controlKey | optionKey)) {
            activeHotkeySpec = "ctrl+alt+space"
            if spec != "ctrl+alt+space" {
                model?.setPersistentStatus(
                    "Fulcrum is ready — \(Hotkey.display(spec)) was taken, using ⌃⌥Space.")
                return
            }
        } else {
            model?.setPersistentStatus(
                "The hotkeys Fulcrum tried are taken by other tools. Change it in settings → hotkey, or release the combo and restart Fulcrum.")
            return
        }
        if model?.ready == true {
            model?.setPersistentStatus(
                "Ready — press \(Hotkey.display(activeHotkeySpec ?? spec)) anywhere")
        }
    }

    private func registerHotkey(keyCode: UInt32, modifiers: UInt32) -> Bool {
        let hotKeyID = EventHotKeyID(signature: OSType(0x46454C43) /* FULC */,
                                     id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0,
                                         &ref)
        if status == noErr {
            hotkeyRef = ref
        }
        return status == noErr
    }

    fileprivate func hotkeyFired() {
        togglePanel()
    }

    // MARK: panel keys

    /// Esc/↑↓ while the query field keeps focus. A local monitor is the only
    /// reliable interception point: the field editor sits at the head of the
    /// responder chain, so a key-handling background view never sees keyDown.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let panel = self.panel,
                  panel.isVisible,
                  event.window === panel else { return event }
            switch event.keyCode {
            case 53:                              // esc
              // In the ⌘K panel: back to the search rows.
              if self.model?.showingActions == true {
                  self.model?.closeActions()
              } else if self.model?.aiStream != nil {
                  // A finished AI answer dismisses first; the launcher
                  // stays for the next query.
                  self.model?.dismissAiStream()
              } else if self.model?.query.isEmpty == true {
                  // Alfred/Raycast convention: clear the query first,
                  // hide only when it is already empty — a stray Esc
                  // never throws away typed text.
                  self.model?.hide()
              } else {
                  self.model?.clearQuery()
              }
            case 40 where event.modifierFlags.contains(.command):
                  self.model?.openActionsForSelection()   // ⌘K
            case 125: self.model?.moveSelection(1)   // down
            case 126: self.model?.moveSelection(-1)  // up
            default:  return event
            }
            return nil
        }
    }

    // MARK: menu bar

    /// First-party rivet menu bar: Open runs the same toggle as the
    /// hotkey; Check for Updates opens the update panel; Quit is the only
    /// way out of the resident process.
    private func installMenuBar(model: LauncherModel) {
        let controller = RivetMenuBarController()
        controller.install(
            title: "Fulcrum",
            menuItems: [
                ("Open Fulcrum", "open", { [weak self] in
                    self?.showPanel()
                }),
                ("Check for Updates…", "update", { [weak self] in
                    guard let self else { return }
                    self.updateController?.checkForUpdates()
                    self.showUpdatePanel()
                }),
                ("Quit Fulcrum", "quit", {
                    NSApp.terminate(nil)
                })
            ])
        menuBar = controller
    }

    // MARK: clipboard watcher

    private func installClipboardWatcher(model: LauncherModel) {
        lastPasteboardChange = NSPasteboard.general.changeCount
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            // The timer fires on the main run loop; Swift 6 requires that to
            // be stated when touching MainActor state.
            MainActor.assumeIsolated {
                guard let self, let api = model.api else { return }
                let changeCount = NSPasteboard.general.changeCount
                guard changeCount != self.lastPasteboardChange else { return }
                self.lastPasteboardChange = changeCount
                guard let text = NSPasteboard.general.string(forType: .string),
                      !text.isEmpty else { return }
                let payload = String(text.prefix(100_000))
                Task.detached {
                    _ = try? await api.clipboardRecord(payload)
                }
            }
        }
    }
}

/// The Carbon hotkey callback is a C function pointer and cannot capture
/// context; it hops to the main actor through this shared reference.
extension AppDelegate {
    nonisolated(unsafe) static var shared: AppDelegate?
}
