import Foundation

/// Manages persistent configuration stored in ~/.config/snaptratranslator/config.json.
/// Also reads from UserDefaults on first run for migration from previous versions.
final class ConfigManager {
    static let shared = ConfigManager()

    private let configDir: URL
    private let configFile: URL
    private var cache: [String: String] = [:]

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        configDir = home.appendingPathComponent(".config/snaptratranslator")
        configFile = configDir.appendingPathComponent("config.json")
        loadFromDisk()
        migrateFromUserDefaultsIfNeeded()
    }

    // MARK: - Keys

    static let azureTranslatorKey = "azureTranslatorKey"
    static let azureTranslatorRegion = "azureTranslatorRegion"
    static let azureTTSKey = "azureTTSKey"
    static let azureTTSRegion = "azureTTSRegion"

    // MARK: - Public API

    func get(_ key: String) -> String? {
        let value = cache[key]
        return (value?.isEmpty ?? true) ? nil : value
    }

    func set(_ key: String, value: String?) {
        if let value, !value.isEmpty {
            cache[key] = value
        } else {
            cache.removeValue(forKey: key)
        }
        saveToDisk()
    }

    // MARK: - Convenience

    var azureTranslatorKey: String? {
        get { get(ConfigManager.azureTranslatorKey) }
        set { set(ConfigManager.azureTranslatorKey, value: newValue) }
    }

    var azureTranslatorRegion: String? {
        get { get(ConfigManager.azureTranslatorRegion) ?? "global" }
        set { set(ConfigManager.azureTranslatorRegion, value: newValue) }
    }

    var azureTTSKey: String? {
        get { get(ConfigManager.azureTTSKey) }
        set { set(ConfigManager.azureTTSKey, value: newValue) }
    }

    var azureTTSRegion: String? {
        get { get(ConfigManager.azureTTSRegion) ?? "centralus" }
        set { set(ConfigManager.azureTTSRegion, value: newValue) }
    }

    // MARK: - Disk I/O

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: configFile.path) else { return }
        do {
            let data = try Data(contentsOf: configFile)
            if let dict = try JSONSerialization.jsonObject(with: data) as? [String: String] {
                cache = dict
            }
        } catch {
            print("[ConfigManager] Failed to load config: \(error)")
        }
    }

    private func saveToDisk() {
        do {
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: cache, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: configFile, options: .atomic)
        } catch {
            print("[ConfigManager] Failed to save config: \(error)")
        }
    }

    // MARK: - Migration from UserDefaults (previous sandboxed version)

    private func migrateFromUserDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        let migrationKey = "snaptracfg_migrated_to_file"
        guard !defaults.bool(forKey: migrationKey) else { return }
        defaults.set(true, forKey: migrationKey)

        let prefix = "snaptracfg_"
        let keys = [Self.azureTranslatorKey, Self.azureTranslatorRegion, Self.azureTTSKey, Self.azureTTSRegion]
        var migrated = 0
        for key in keys {
            if let value = defaults.string(forKey: prefix + key), !value.isEmpty, cache[key] == nil {
                cache[key] = value
                migrated += 1
            }
        }
        if migrated > 0 {
            saveToDisk()
            print("[ConfigManager] Migrated \(migrated) keys from UserDefaults to config.json")
        }
    }
}
