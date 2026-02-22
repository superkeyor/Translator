import AppKit
import Combine
import Foundation

final class SettingsStore: ObservableObject {
    @Published var playPronunciation: Bool {
        didSet { defaults.set(playPronunciation, forKey: AppSettingKey.playPronunciation) }
    }
    @Published var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: AppSettingKey.launchAtLogin) }
    }
    @Published var singleKey: SingleKey {
        didSet { defaults.set(singleKey.rawValue, forKey: AppSettingKey.singleKey) }
    }
    @Published var sourceLanguage: String {
        didSet { defaults.set(sourceLanguage, forKey: AppSettingKey.sourceLanguage) }
    }
    @Published var targetLanguage: String {
        didSet { defaults.set(targetLanguage, forKey: AppSettingKey.targetLanguage) }
    }
    @Published var debugShowOcrRegion: Bool {
        didSet { defaults.set(debugShowOcrRegion, forKey: AppSettingKey.debugShowOcrRegion) }
    }
    @Published var continuousTranslation: Bool {
        didSet { defaults.set(continuousTranslation, forKey: AppSettingKey.continuousTranslation) }
    }
    @Published var paragraphModifier: ParagraphModifier {
        didSet { defaults.set(paragraphModifier.rawValue, forKey: AppSettingKey.paragraphModifier) }
    }
    @Published var paragraphTranslationEnabled: Bool {
        didSet { defaults.set(paragraphTranslationEnabled, forKey: AppSettingKey.paragraphTranslationEnabled) }
    }
    /// Short name of the preferred dictionary, or empty string for "All (System Default)",
    /// or "__none__" to skip local dictionary lookup entirely.
    @Published var preferredDictionary: String {
        didSet { defaults.set(preferredDictionary, forKey: AppSettingKey.preferredDictionary) }
    }
    /// Custom audio API URL for pronunciation. Use {word} as placeholder for the word.
    /// Empty string disables the API. Example: https://api.dictionaryapi.dev/api/v2/entries/en/{word}
    /// The API should return JSON with phonetics[].audio or binary audio data (mp3/wav).
    @Published var customAudioAPIURL: String {
        didSet { defaults.set(customAudioAPIURL, forKey: AppSettingKey.customAudioAPIURL) }
    }
    /// Azure-specific source language (defaults to "en").
    @Published var azureSourceLanguage: String {
        didSet { defaults.set(azureSourceLanguage, forKey: AppSettingKey.azureSourceLanguage) }
    }
    /// Azure-specific target language (defaults to "zh-Hans").
    @Published var azureTargetLanguage: String {
        didSet { defaults.set(azureTargetLanguage, forKey: AppSettingKey.azureTargetLanguage) }
    }
    /// Whether definitions are expanded by default in pinned overlay mode.
    @Published var defaultExpandPinned: Bool {
        didSet { defaults.set(defaultExpandPinned, forKey: AppSettingKey.defaultExpandPinned) }
    }
    /// Whether definitions are expanded by default in cursor-follow mode.
    @Published var defaultExpandCursor: Bool {
        didSet { defaults.set(defaultExpandCursor, forKey: AppSettingKey.defaultExpandCursor) }
    }
    /// Global hotkey string for toggling translation on/off.
    /// Format: "modifiers+keyCode" (e.g. "command+shift+49" for ⌘⇧Space).
    /// Empty string means no global hotkey.
    @Published var globalToggleHotkey: String {
        didSet { defaults.set(globalToggleHotkey, forKey: AppSettingKey.globalToggleHotkey) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let playPronunciationValue = defaults.object(forKey: AppSettingKey.playPronunciation) as? Bool
        let launchAtLoginValue = defaults.object(forKey: AppSettingKey.launchAtLogin) as? Bool
        let loginStatus = LoginItemManager.isEnabled()
        let singleKeyValue = defaults.string(forKey: AppSettingKey.singleKey)
        let debugShowOcrRegionValue = defaults.object(forKey: AppSettingKey.debugShowOcrRegion) as? Bool
        let continuousTranslationValue = defaults.object(forKey: AppSettingKey.continuousTranslation) as? Bool
        let paragraphModifierValue = defaults.string(forKey: AppSettingKey.paragraphModifier)
        let paragraphTranslationEnabledValue = defaults.object(forKey: AppSettingKey.paragraphTranslationEnabled) as? Bool

        playPronunciation = playPronunciationValue ?? true
        launchAtLogin = launchAtLoginValue ?? loginStatus
        singleKey = SingleKey(rawValue: singleKeyValue ?? "leftControl") ?? .leftControl
        sourceLanguage = defaults.string(forKey: AppSettingKey.sourceLanguage) ?? "en"
        let defaultTarget = Self.defaultTargetLanguage()
        targetLanguage = defaults.string(forKey: AppSettingKey.targetLanguage) ?? defaultTarget
        debugShowOcrRegion = debugShowOcrRegionValue ?? false
        continuousTranslation = continuousTranslationValue ?? true
        paragraphModifier = ParagraphModifier(rawValue: paragraphModifierValue ?? "option") ?? .option
        paragraphTranslationEnabled = paragraphTranslationEnabledValue ?? false
        preferredDictionary = defaults.string(forKey: AppSettingKey.preferredDictionary) ?? ""
        
        // Azure-specific language settings
        azureSourceLanguage = defaults.string(forKey: AppSettingKey.azureSourceLanguage) ?? "en"
        azureTargetLanguage = defaults.string(forKey: AppSettingKey.azureTargetLanguage) ?? defaultTarget
        
        // Expand/collapse defaults
        defaultExpandPinned = (defaults.object(forKey: AppSettingKey.defaultExpandPinned) as? Bool) ?? true
        defaultExpandCursor = (defaults.object(forKey: AppSettingKey.defaultExpandCursor) as? Bool) ?? false

        // Global toggle hotkey (e.g. "command+shift+49" for ⌘⇧Space)
        globalToggleHotkey = defaults.string(forKey: AppSettingKey.globalToggleHotkey) ?? ""

        // Migrate from old useFreeDictionaryAPI boolean to new customAudioAPIURL string
        let defaultDictionaryAPIURL = "https://api.dictionaryapi.dev/api/v2/entries/en/{word}"
        if let savedURL = defaults.string(forKey: AppSettingKey.customAudioAPIURL) {
            customAudioAPIURL = savedURL
        } else if let oldBoolValue = defaults.object(forKey: AppSettingKey.useFreeDictionaryAPI) as? Bool {
            // Migrate from old boolean setting
            customAudioAPIURL = oldBoolValue ? defaultDictionaryAPIURL : ""
        } else {
            customAudioAPIURL = defaultDictionaryAPIURL
        }
    }

    var hotkeyDisplayText: String {
        singleKey.title
    }

    private static func defaultTargetLanguage() -> String {
        let supportedLanguages: Set<String> = [
            "zh-Hans",
            "zh-Hant",
            "en",
            "ja",
            "ko",
            "fr",
            "de",
            "es",
            "it",
            "pt",
            "ru",
            "ar",
            "th",
            "vi",
        ]
        
        let preferredLanguages = Locale.preferredLanguages
        guard let firstPreferred = preferredLanguages.first else {
            return "zh-Hans"
        }
        
        let locale = Locale(identifier: firstPreferred)

        let languageCode: String
        let scriptCode: String?
        if #available(macOS 13.0, *) {
            languageCode = locale.language.languageCode?.identifier ?? ""
            scriptCode = locale.language.script?.identifier
        } else {
            languageCode = locale.languageCode ?? ""
            scriptCode = locale.scriptCode
        }

        if languageCode == "zh" {
            return scriptCode == "Hant" ? "zh-Hant" : "zh-Hans"
        }
        
        if supportedLanguages.contains(languageCode) {
            return languageCode
        }

        return "zh-Hans"
    }
}
