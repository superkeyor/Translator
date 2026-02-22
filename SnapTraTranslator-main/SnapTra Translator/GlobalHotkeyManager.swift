import AppKit
import Carbon
import Combine
import Foundation

/// Manages a global keyboard shortcut (e.g. ⌘⇧T) using Carbon Event API.
/// Used for the "Toggle Translation On/Off" hotkey.
final class GlobalHotkeyManager {
    var onToggle: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private static var sharedInstance: GlobalHotkeyManager?

    init() {
        Self.sharedInstance = self
    }

    deinit {
        unregister()
    }

    // MARK: - Registration

    /// Register a global hotkey from a settings string like "command+shift+49".
    func register(from settingsString: String) {
        unregister()
        guard !settingsString.isEmpty else { return }
        guard let parsed = Self.parse(settingsString) else {
            print("[GlobalHotkeyManager] Failed to parse: \(settingsString)")
            return
        }
        register(keyCode: parsed.keyCode, carbonModifiers: parsed.carbonModifiers)
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
    }

    // MARK: - Internal

    private func register(keyCode: UInt32, carbonModifiers: UInt32) {
        // Install handler
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let mgr = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                mgr.onToggle?()
                return noErr
            },
            1,
            &eventSpec,
            selfPtr,
            &eventHandlerRef
        )
        guard status == noErr else {
            print("[GlobalHotkeyManager] InstallEventHandler failed: \(status)")
            return
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x534E5450), id: 1) // "SNTP"
        let regStatus = RegisterEventHotKey(
            keyCode,
            carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if regStatus != noErr {
            print("[GlobalHotkeyManager] RegisterEventHotKey failed: \(regStatus)")
        }
    }

    // MARK: - Parsing

    struct ParsedHotkey {
        let keyCode: UInt32
        let carbonModifiers: UInt32
    }

    /// Parse a string like "command+shift+49" into key code and Carbon modifier flags.
    static func parse(_ string: String) -> ParsedHotkey? {
        let parts = string.lowercased().split(separator: "+").map(String.init)
        guard !parts.isEmpty else { return nil }

        var carbonMods: UInt32 = 0
        var keyCode: UInt32?

        for part in parts {
            switch part {
            case "command", "cmd":
                carbonMods |= UInt32(cmdKey)
            case "shift":
                carbonMods |= UInt32(shiftKey)
            case "option", "alt":
                carbonMods |= UInt32(optionKey)
            case "control", "ctrl":
                carbonMods |= UInt32(controlKey)
            default:
                if let code = UInt32(part) {
                    keyCode = code
                }
            }
        }

        guard let kc = keyCode else { return nil }
        return ParsedHotkey(keyCode: kc, carbonModifiers: carbonMods)
    }

    /// Build display string from a settings string like "command+shift+49".
    static func displayString(for settingsString: String) -> String {
        guard !settingsString.isEmpty else { return "Not Set" }
        let parts = settingsString.lowercased().split(separator: "+").map(String.init)
        var symbols: [String] = []
        var keyCode: UInt32?

        for part in parts {
            switch part {
            case "command", "cmd": symbols.append("⌘")
            case "shift": symbols.append("⇧")
            case "option", "alt": symbols.append("⌥")
            case "control", "ctrl": symbols.append("⌃")
            default:
                if let code = UInt32(part) { keyCode = code }
            }
        }

        if let kc = keyCode {
            symbols.append(keyName(for: UInt16(kc)))
        }

        return symbols.joined()
    }

    private static func keyName(for keyCode: UInt16) -> String {
        switch keyCode {
        case 49: return "Space"
        case 36: return "Return"
        case 48: return "Tab"
        case 51: return "Delete"
        case 53: return "Escape"
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 22: return "6"
        case 23: return "5"
        case 24: return "="
        case 25: return "9"
        case 26: return "7"
        case 27: return "-"
        case 28: return "8"
        case 29: return "0"
        case 30: return "]"
        case 31: return "O"
        case 32: return "U"
        case 33: return "["
        case 34: return "I"
        case 35: return "P"
        case 37: return "L"
        case 38: return "J"
        case 39: return "'"
        case 40: return "K"
        case 41: return ";"
        case 42: return "\\"
        case 43: return ","
        case 44: return "/"
        case 45: return "N"
        case 46: return "M"
        case 47: return "."
        default:
            return HotkeyModifiers.displayKey(for: keyCode)
        }
    }
}
