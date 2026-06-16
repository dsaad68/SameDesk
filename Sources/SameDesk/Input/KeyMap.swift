import CoreGraphics
import Foundation

/// Maps browser `KeyboardEvent.code` (physical key strings) to macOS virtual
/// keycodes (`CGKeyCode`).
///
/// We deliberately use `event.code`, NOT the deprecated, layout-dependent
/// `keyCode`: JS `keyCode` does not match macOS virtual keycodes at all (e.g.
/// macOS `kVK_Escape` = 53, but JS `keyCode` 53 is the digit "5"). `code` is the
/// stable physical-key identifier, which we can map deterministically.
enum KeyMap {
    static let table: [String: CGKeyCode] = [
        // Letters
        "KeyA": 0x00, "KeyB": 0x0B, "KeyC": 0x08, "KeyD": 0x02, "KeyE": 0x0E,
        "KeyF": 0x03, "KeyG": 0x05, "KeyH": 0x04, "KeyI": 0x22, "KeyJ": 0x26,
        "KeyK": 0x28, "KeyL": 0x25, "KeyM": 0x2E, "KeyN": 0x2D, "KeyO": 0x1F,
        "KeyP": 0x23, "KeyQ": 0x0C, "KeyR": 0x0F, "KeyS": 0x01, "KeyT": 0x11,
        "KeyU": 0x20, "KeyV": 0x09, "KeyW": 0x0D, "KeyX": 0x07, "KeyY": 0x10,
        "KeyZ": 0x06,

        // Number row
        "Digit1": 0x12, "Digit2": 0x13, "Digit3": 0x14, "Digit4": 0x15,
        "Digit5": 0x17, "Digit6": 0x16, "Digit7": 0x1A, "Digit8": 0x1C,
        "Digit9": 0x19, "Digit0": 0x1D,

        // Whitespace / editing
        "Enter": 0x24, "Tab": 0x30, "Space": 0x31, "Backspace": 0x33,
        "Escape": 0x35, "Delete": 0x75, "ForwardDelete": 0x75,

        // Punctuation
        "Minus": 0x1B, "Equal": 0x18, "BracketLeft": 0x21, "BracketRight": 0x1E,
        "Backslash": 0x2A, "Semicolon": 0x29, "Quote": 0x27, "Backquote": 0x32,
        "Comma": 0x2B, "Period": 0x2F, "Slash": 0x2C,

        // Arrows
        "ArrowLeft": 0x7B, "ArrowRight": 0x7C, "ArrowDown": 0x7D, "ArrowUp": 0x7E,

        // Navigation cluster
        "Home": 0x73, "End": 0x77, "PageUp": 0x74, "PageDown": 0x79,
        "Insert": 0x72,

        // Modifiers
        "ShiftLeft": 0x38, "ShiftRight": 0x3C,
        "ControlLeft": 0x3B, "ControlRight": 0x3E,
        "AltLeft": 0x3A, "AltRight": 0x3D,
        "MetaLeft": 0x37, "MetaRight": 0x36,
        "CapsLock": 0x39, "Function": 0x3F,

        // Function keys
        "F1": 0x7A, "F2": 0x78, "F3": 0x63, "F4": 0x76, "F5": 0x60,
        "F6": 0x61, "F7": 0x62, "F8": 0x64, "F9": 0x65, "F10": 0x6D,
        "F11": 0x67, "F12": 0x6F, "F13": 0x69, "F14": 0x6B, "F15": 0x71,
        "F16": 0x6A, "F17": 0x40, "F18": 0x4F, "F19": 0x50, "F20": 0x5A,

        // Keypad
        "Numpad0": 0x52, "Numpad1": 0x53, "Numpad2": 0x54, "Numpad3": 0x55,
        "Numpad4": 0x56, "Numpad5": 0x57, "Numpad6": 0x58, "Numpad7": 0x59,
        "Numpad8": 0x5B, "Numpad9": 0x5C,
        "NumpadDecimal": 0x41, "NumpadMultiply": 0x43, "NumpadAdd": 0x45,
        "NumpadSubtract": 0x4E, "NumpadDivide": 0x4B, "NumpadEnter": 0x4C,
        "NumpadEqual": 0x51, "NumLock": 0x47
    ]

    static func virtualKey(for code: String) -> CGKeyCode? {
        table[code]
    }
}
