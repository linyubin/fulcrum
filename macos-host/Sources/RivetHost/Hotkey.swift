import Carbon.HIToolbox

/// One hotkey grammar shared with the backend (settings.rkt) and the
/// Windows/Linux hosts: one or more modifiers (alt/ctrl/shift/cmd/win/
/// super) then a key — space, a-z, 0-9, f1-f12, comma, period, minus,
/// equal, tab. Both hosts parse the same spec so a setting written on one
/// platform binds on all three.
enum Hotkey {
    struct CarbonBinding {
        let keyCode: UInt32
        let modifiers: UInt32
    }

    /// Carbon (modifier mask, key code) for a spec, or nil when the spec
    /// does not parse — callers keep the previous binding in that case.
    static func parse(_ spec: String) -> CarbonBinding? {
        var modifiers: UInt32 = 0
        var keyToken: String?
        for token in spec.lowercased().split(separator: "+") {
            switch token {
            case "alt", "option": modifiers |= UInt32(optionKey)
            case "ctrl", "control": modifiers |= UInt32(controlKey)
            case "shift": modifiers |= UInt32(shiftKey)
            case "cmd", "win", "super": modifiers |= UInt32(cmdKey)
            default:
                if keyToken != nil { return nil }
                keyToken = String(token)
            }
        }
        guard let key = keyToken, modifiers != 0,
              let keyCode = keyCode(for: key) else { return nil }
        return CarbonBinding(keyCode: keyCode, modifiers: modifiers)
    }

    /// Human-readable form for status lines: "ctrl+shift+space" → "⌃⇧Space".
    static func display(_ spec: String) -> String {
        var symbols = ""
        var key = ""
        for token in spec.lowercased().split(separator: "+") {
            switch token {
            case "alt", "option": symbols += "⌥"
            case "ctrl", "control": symbols += "⌃"
            case "shift": symbols += "⇧"
            case "cmd", "win", "super": symbols += "⌘"
            default: key = keyDisplay(String(token))
            }
        }
        return symbols + key
    }

    private static func keyDisplay(_ key: String) -> String {
        switch key {
        case "space": return "Space"
        case "tab": return "Tab"
        case "comma": return ","
        case "period": return "."
        case "minus": return "-"
        case "equal": return "="
        default:
            if key.hasPrefix("f"), Int(key.dropFirst()) != nil { return key.uppercased() }
            return key.uppercased()
        }
    }

    private static func keyCode(for key: String) -> UInt32? {
        switch key {
        case "space": return UInt32(kVK_Space)
        case "tab": return UInt32(kVK_Tab)
        case "comma": return UInt32(kVK_ANSI_Comma)
        case "period": return UInt32(kVK_ANSI_Period)
        case "minus": return UInt32(kVK_ANSI_Minus)
        case "equal": return UInt32(kVK_ANSI_Equal)
        case "f1": return UInt32(kVK_F1)
        case "f2": return UInt32(kVK_F2)
        case "f3": return UInt32(kVK_F3)
        case "f4": return UInt32(kVK_F4)
        case "f5": return UInt32(kVK_F5)
        case "f6": return UInt32(kVK_F6)
        case "f7": return UInt32(kVK_F7)
        case "f8": return UInt32(kVK_F8)
        case "f9": return UInt32(kVK_F9)
        case "f10": return UInt32(kVK_F10)
        case "f11": return UInt32(kVK_F11)
        case "f12": return UInt32(kVK_F12)
        default: break
        }
        if key.count == 1, let c = key.first {
            if let letter = letterKeyCodes[String(c.uppercased())] {
                return UInt32(letter)
            }
            if c.isNumber, let digit = digitKeyCodes[String(c)] {
                return UInt32(digit)
            }
        }
        return nil
    }

    // The ANSI key codes are layout history, not a sequence: table them.
    private static let letterKeyCodes: [String: Int] = [
        "A": kVK_ANSI_A, "S": kVK_ANSI_S, "D": kVK_ANSI_D, "F": kVK_ANSI_F,
        "H": kVK_ANSI_H, "G": kVK_ANSI_G, "Z": kVK_ANSI_Z, "X": kVK_ANSI_X,
        "C": kVK_ANSI_C, "V": kVK_ANSI_V, "B": kVK_ANSI_B, "Q": kVK_ANSI_Q,
        "W": kVK_ANSI_W, "E": kVK_ANSI_E, "R": kVK_ANSI_R, "Y": kVK_ANSI_Y,
        "T": kVK_ANSI_T, "O": kVK_ANSI_O, "U": kVK_ANSI_U, "I": kVK_ANSI_I,
        "P": kVK_ANSI_P, "L": kVK_ANSI_L, "J": kVK_ANSI_J, "K": kVK_ANSI_K,
        "N": kVK_ANSI_N, "M": kVK_ANSI_M
    ]

    private static let digitKeyCodes: [String: Int] = [
        "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8,
        "9": kVK_ANSI_9, "0": kVK_ANSI_0
    ]
}
