import AppKit
import Foundation

enum SingleKey: String, CaseIterable, Identifiable {
    case none
    case leftShift
    case leftControl
    case leftOption
    case leftCommand
    case rightShift
    case rightControl
    case rightOption
    case rightCommand
    case fn

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none:
            return "None"
        case .leftShift:
            return "Left Shift"
        case .leftControl:
            return "Left Ctrl"
        case .leftOption:
            return "Left Opt"
        case .leftCommand:
            return "Left Cmd"
        case .rightShift:
            return "Right Shift"
        case .rightControl:
            return "Right Ctrl"
        case .rightOption:
            return "Right Opt"
        case .rightCommand:
            return "Right Cmd"
        case .fn:
            return "Fn"
        }
    }
}

/// Modifier key that, when held together with the hotkey, triggers paragraph translation.
enum ParagraphModifier: String, CaseIterable, Identifiable {
    case control = "control"
    case option = "option"
    case command = "command"
    case shift = "shift"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .control: return "⌃ Control"
        case .option: return "⌥ Option"
        case .command: return "⌘ Command"
        case .shift: return "⇧ Shift"
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .control: return .control
        case .option: return .option
        case .command: return .command
        case .shift: return .shift
        }
    }
}

enum AppSettingKey {
    static let playPronunciation = "playPronunciation"
    static let launchAtLogin = "launchAtLogin"
    static let singleKey = "singleKey"
    static let sourceLanguage = "sourceLanguage"
    static let targetLanguage = "targetLanguage"
    static let debugShowOcrRegion = "debugShowOcrRegion"
    static let continuousTranslation = "continuousTranslation"
    static let lastScreenRecordingStatus = "lastScreenRecordingStatus"
    static let paragraphModifier = "paragraphModifier"
    static let paragraphTranslationEnabled = "paragraphTranslationEnabled"
    static let preferredDictionary = "preferredDictionary"
    static let useFreeDictionaryAPI = "useFreeDictionaryAPI"  // Legacy, migrated to customAudioAPIURL
    static let customAudioAPIURL = "customAudioAPIURL"
    static let azureSourceLanguage = "azureSourceLanguage"
    static let azureTargetLanguage = "azureTargetLanguage"
    static let defaultExpandPinned = "defaultExpandPinned"
    static let defaultExpandCursor = "defaultExpandCursor"
    static let globalToggleHotkey = "globalToggleHotkey"
}
