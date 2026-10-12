import AppKit
import CoreGraphics

/// Snippet auto-expansion (Raycast-style text expansion): a CGEventTap
/// observes keystrokes system-wide, keeps a rolling buffer of typed
/// characters, and when a snippet keyword lands against a word boundary,
/// replaces it with the snippet text — N backspaces, then the expansion
/// typed via unicode key events. No clipboard churn.
///
/// Platform rules:
/// - Requires the Accessibility permission (same grant as paste-to-
///   frontmost; without it the tap installs NULL and the engine stays off).
/// - Events typed into Fulcrum's own panel are ignored (no double
///   processing, and the search field must not self-expand).
/// - Repairs are skipped while an expansion is in flight.
@MainActor
final class ExpansionEngine {
    /// keyword → expansion text. Replaced wholesale on refresh.
    private var triggers: [String: String] = [:]
    private var enabled = true
    /// Rolling tail of recently typed characters.
    private var buffer: [Character] = []
    /// True while our own injected events are in flight.
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// True while our own injected events are in flight (nonisolated(unsafe)
    /// because the tap callback is a C function pointer; all mutations are
    /// main-actor hops).
    private nonisolated(unsafe) static var repairing = false

    /// Max keyword length we will track (snippets keywords are short).
    private static let maxTriggerLength = 48
    /// Characters that end a word and may trigger expansion.
    private static let boundaryCharacters: Set<Character> =
        [" ", "\n", "\t", ".", ",", ";", ":", "!", "?", ")", "]", "}"]

    static let shared = MainActor.assumeIsolated { ExpansionEngine() }

    private init() {}

    // MARK: lifecycle

    /// Installs the event tap. Safe to call again: an existing tap is
    /// reused. Returns false when the tap could not be created (missing
    /// Accessibility trust).
    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        guard enabled, !triggers.isEmpty else { return false }
        let eventMask = (1 << CGEventType.keyDown.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(eventMask),
            callback: ExpansionEngine.tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            return false
        }
        tap = port
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func stop() {
        if let port = tap { CGEvent.tapEnable(tap: port, enable: false) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        buffer.removeAll()
    }

    /// Replaces the trigger table and applies the new settings. Starts or
    /// stops the tap as needed.
    func refresh(enabled: Bool, snippets: [(keyword: String, text: String)]) {
        self.enabled = enabled
        var table: [String: String] = [:]
        for (keyword, text) in snippets {
            let k = keyword.trimmingCharacters(in: .whitespaces)
            if !k.isEmpty, k.count <= Self.maxTriggerLength, !text.isEmpty {
                table[k] = text
            }
        }
        triggers = table
        if enabled, !table.isEmpty {
            _ = start()
        } else {
            stop()
        }
    }

    // MARK: tap callback

    /// The C-function-pointer entry: hops to the main actor.
    private static let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }
        // Both values are read-only across this hop: the event is never
        // mutated, and userInfo is the engine's own opaque pointer.
        nonisolated(unsafe) let eventPointer = Unmanaged.passUnretained(event)
        nonisolated(unsafe) let enginePointer = userInfo
        DispatchQueue.main.async {
            guard let engine = enginePointer?.load(as: ExpansionEngine.self) else {
                return
            }
            engine.handle(eventPointer.takeUnretainedValue())
        }
        return Unmanaged.passUnretained(event)
    }

    fileprivate func handle(_ event: CGEvent) {
        // Never process our own repairs, other apps' paste synthetic keys,
        // or anything typed into Fulcrum's own panel.
        if Self.repairing { return }
        // Typing into Fulcrum's own panel must never self-expand.
        if AppDelegate.shared?.panelIsKey == true { return }

        var length = 8
        var chars = [unichar](repeating: 0, count: length)
        event.keyboardGetUnicodeString(
            maxStringLength: length,
            actualStringLength: &length,
            unicodeString: &chars)
        guard length > 0, let scalar = Unicode.Scalar(chars[0]) else {
            // A non-text key (arrows, modifiers): word boundaries reset.
            buffer.removeAll()
            return
        }
        let character = Character(scalar)
        if character == "\u{7F}" || character == "\u{08}" {
            // Backspace: the user just removed a character.
            if !buffer.isEmpty { buffer.removeLast() }
            return
        }
        if Self.boundaryCharacters.contains(character) {
            let candidate = String(buffer)
            buffer.removeAll()
            if let expansion = expansion(for: candidate) {
                expand(replacing: candidate.count, with: expansion)
            }
            return
        }
        buffer.append(character)
        if buffer.count > Self.maxTriggerLength { buffer.removeFirst() }
    }

    /// Exact keyword match, whole-word (everything before the keyword is a
    /// boundary or start of input).
    private func expansion(for candidate: String) -> String? {
        guard let expansion = triggers[candidate] else { return nil }
        return expansion
    }

    // MARK: repair

    /// Deletes `count` characters and types `text` in their place.
    private func expand(replacing count: Int, with text: String) {
        Self.repairing = true
        let source = CGEventSource(stateID: .combinedSessionState)
        // The boundary event that fired this expansion is still in
        // delivery; a short delay lets it land before the repair.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            for _ in 0..<count {
                let backspace = CGEvent(keyboardEventSource: source,
                                        virtualKey: 51, keyDown: true)
                backspace?.post(tap: .cghidEventTap)
                let up = CGEvent(keyboardEventSource: source,
                                 virtualKey: 51, keyDown: false)
                up?.post(tap: .cghidEventTap)
            }
            for character in text {
                var chars = Array(String(character).utf16)
                let down = CGEvent(keyboardEventSource: source,
                                   virtualKey: 0, keyDown: true)
                down?.keyboardSetUnicodeString(stringLength: chars.count,
                                               unicodeString: &chars)
                down?.post(tap: .cghidEventTap)
                var upChars = Array(String(character).utf16)
                let up = CGEvent(keyboardEventSource: source,
                                 virtualKey: 0, keyDown: false)
                up?.keyboardSetUnicodeString(stringLength: upChars.count,
                                             unicodeString: &upChars)
                up?.post(tap: .cghidEventTap)
            }
            Self.repairing = false
            self?.buffer.removeAll()
        }
    }
}
