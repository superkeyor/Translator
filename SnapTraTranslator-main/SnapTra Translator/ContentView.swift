//
//  ContentView.swift
//  Snap Translate
//
//  Created by 杨玉杰 on 2026/1/12.
//

import SwiftUI
import Translation

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var appeared = false
    @State private var selectedTab: SettingsTab = .general

    private var allPermissionsGranted: Bool {
        model.permissions.status.screenRecording
    }

    @available(macOS 15.0, *)
    private var targetLanguageReady: Bool {
        guard let status = model.languagePackManager?.getStatus(
            from: model.settings.sourceLanguage,
            to: model.settings.targetLanguage
        ) else {
            return false
        }
        return status == .installed
    }

    private var allReady: Bool {
        if #available(macOS 15.0, *) {
            return allPermissionsGranted && targetLanguageReady
        }
        return allPermissionsGranted
    }



    var body: some View {
        VStack(spacing: 0) {
            // App header — always visible
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .opacity(appeared ? 1 : 0)
                    .scaleEffect(appeared ? 1 : 0.8)

                Text("SnapTra Translator")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                    .opacity(appeared ? 1 : 0)
            }
            .padding(.top, 16)
            .padding(.bottom, 8)

            // Tab picker
            Picker("", selection: $selectedTab) {
                Text("General").tag(SettingsTab.general)
                Text("Dictionaries").tag(SettingsTab.dictionaries)
                Text("Translation").tag(SettingsTab.translation)
                Text("Pronunciation").tag(SettingsTab.pronunciation)
                Text("Azure").tag(SettingsTab.azure)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            // Tab content
            TabView(selection: $selectedTab) {
                GeneralTabView()
                    .environmentObject(model)
                    .tag(SettingsTab.general)

                DictionariesTabView(settings: model.settings)
                    .environmentObject(model)
                    .tag(SettingsTab.dictionaries)

                TranslationTabView()
                    .environmentObject(model)
                    .tag(SettingsTab.translation)

                PronunciationTabView(settings: model.settings)
                    .tag(SettingsTab.pronunciation)

                AzureTabView()
                    .tag(SettingsTab.azure)
            }
            .tabViewStyle(.automatic)
            .frame(maxHeight: .infinity)

            // Status bar
            HStack(spacing: 12) {
                if allReady {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.green)
                        Text("Ready to translate")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
                Spacer()
                Button {
                    Task { @MainActor in
                        await model.permissions.refreshStatusAsync()
                        if #available(macOS 15.0, *) {
                            let _ = await model.languagePackManager?.checkLanguagePair(
                                from: model.settings.sourceLanguage,
                                to: model.settings.targetLanguage
                            )
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Refresh")
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .padding(.vertical, 5)
                .padding(.horizontal, 9)
                .background(Capsule().fill(Color(NSColor.quaternaryLabelColor)))
                .contentShape(Capsule())
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .animation(.easeInOut(duration: 0.2), value: allReady)
        }
        .frame(width: 440)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            Task { await model.permissions.refreshStatusAsync() }
            withAnimation(.easeOut(duration: 0.5)) {
                appeared = true
            }
        }
    }
}

// MARK: - Settings Tabs

private enum SettingsTab: Int, Hashable {
    case general, dictionaries, translation, pronunciation, azure
}

// MARK: - General Tab

private struct GeneralTabView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                // Permissions
                SettingsCard {
                    ContentPermissionRow(
                        icon: "rectangle.dashed.badge.record",
                        title: "Screen Recording",
                        isGranted: model.permissions.status.screenRecording,
                        action: { model.permissions.requestAndOpenScreenRecording() }
                    )
                }

                // Hotkey
                SettingsCard {
                    HotkeyKeycapSelector(selectedKey: $model.settings.singleKey)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }

                // Paragraph translation hint
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text("Tip: Hold the modifier key and hover to translate. Select \"None\" to disable the modifier trigger and use only the global on/off hotkey instead. With text selected, use the same action to translate the selection via Azure (if configured).")
                        .font(.system(size: 11))
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                }
                .padding(.horizontal, 4)

                // Global toggle hotkey
                SettingsCard {
                    GlobalHotkeyRecorderView(hotkey: $model.settings.globalToggleHotkey)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }

                // Popover expand/collapse defaults
                SettingsCard {
                    VStack(spacing: 0) {
                        HStack(spacing: 8) {
                            Image(systemName: "rectangle.expand.vertical")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                            Text("Default Expand Definitions")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.primary)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)

                        SettingsDivider()

                        SettingsToggleRow(
                            title: "Pinned Mode",
                            subtitle: "Auto-expand when popover is pinned",
                            isOn: $model.settings.defaultExpandPinned
                        )
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)

                        SettingsDivider()

                        SettingsToggleRow(
                            title: "Follow Cursor Mode",
                            subtitle: "Auto-expand when following cursor",
                            isOn: $model.settings.defaultExpandCursor
                        )
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                }

                // Toggles
                SettingsCard {
                    VStack(spacing: 0) {
                        SettingsToggleRow(
                            title: "Continuous Translation",
                            subtitle: "Keep translating as mouse moves",
                            isOn: $model.settings.continuousTranslation
                        )
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)

                        SettingsDivider()

                        SettingsToggleRow(
                            title: "Launch at Login",
                            subtitle: "Start automatically when you log in",
                            isOn: $model.settings.launchAtLogin
                        )
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)

                        SettingsDivider()

                        SettingsToggleRow(
                            title: "Debug OCR Region",
                            subtitle: "Show capture area when shortcut is pressed",
                            isOn: $model.settings.debugShowOcrRegion
                        )
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - Dictionaries Tab

private struct DictionariesTabView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings: SettingsStore
    @State private var dictionaries: [InstalledDictionary] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                SettingsCard {
                    VStack(alignment: .leading, spacing: 0) {
                        // Header
                        HStack(spacing: 8) {
                            Image(systemName: "books.vertical")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                            Text("Preferred Dictionary")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.primary)
                            Spacer()
                            Text("\(dictionaries.count) found")
                                .font(.system(size: 11))
                                .foregroundColor(Color(NSColor.tertiaryLabelColor))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)

                        SettingsDivider()

                        // "All Dictionaries" option
                        DictionaryRow(
                            name: "All Dictionaries (System Default)",
                            shortName: nil,
                            isSelected: settings.preferredDictionary.isEmpty
                        ) {
                            settings.preferredDictionary = ""
                        }

                        // "None" option — skip local dictionary lookup entirely
                        DictionaryRow(
                            name: "None (Skip Dictionary)",
                            shortName: nil,
                            isSelected: settings.preferredDictionary == "__none__"
                        ) {
                            settings.preferredDictionary = "__none__"
                        }

                        if dictionaries.isEmpty {
                            Text("No active dictionaries found")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                        } else {
                            ForEach(dictionaries) { dict in
                                DictionaryRow(
                                    name: dict.name,
                                    shortName: dict.shortName != dict.name ? dict.shortName : nil,
                                    isSelected: settings.preferredDictionary == dict.id
                                ) {
                                    settings.preferredDictionary = dict.id
                                }
                            }
                        }
                    }
                }

                // Hint
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text("Select a dictionary for word lookups, use all active dictionaries, or choose None to skip.")
                        .font(.system(size: 11))
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                }
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .onAppear {
            DictionaryListService.shared.refresh()
            dictionaries = DictionaryListService.shared.dictionaries
        }
    }
}

/// A single selectable dictionary row with radio indicator.
private struct DictionaryRow: View {
    let name: String
    let shortName: String?
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(isSelected ? .accentColor : Color(NSColor.tertiaryLabelColor))

                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    if let shortName {
                        Text(shortName)
                            .font(.system(size: 10))
                            .foregroundColor(Color(NSColor.tertiaryLabelColor))
                            .lineLimit(1)
                    }
                }

                Spacer()

                if isSelected {
                    Text("Active")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(Color.accentColor.opacity(0.12))
                        )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(isHovering ? Color(NSColor.quaternaryLabelColor).opacity(0.5) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
        .help(shortName != nil ? "ID: \(shortName!)" : name)
    }
}

// MARK: - Pronunciation Tab

private struct PronunciationTabView: View {
    @ObservedObject var settings: SettingsStore
    
    private var isAPIEnabled: Bool {
        !settings.customAudioAPIURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                // Playback toggle
                SettingsCard {
                    VStack(spacing: 0) {
                        SettingsToggleRow(
                            title: "Play Pronunciation",
                            subtitle: "Audio playback after translation",
                            isOn: $settings.playPronunciation
                        )
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                }

                // Dictionary API URL setting
                SettingsCard {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 8) {
                            Image(systemName: "network")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                            Text("Dictionary API")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.primary)
                            Spacer()
                            if isAPIEnabled {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(.green)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)

                        SettingsDivider()

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Audio API URL")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.primary)
                            
                            TextField("https://example.com/audio?word={word}", text: $settings.customAudioAPIURL)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11, design: .monospaced))
                            
                            Text("Use {word} as placeholder. API should return JSON with phonetics[].audio or binary audio (mp3/wav). Leave empty to disable.")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                            
                            // Quick fill button for default API
                            HStack(spacing: 8) {
                                Button {
                                    settings.customAudioAPIURL = "https://api.dictionaryapi.dev/api/v2/entries/en/{word}"
                                } label: {
                                    Text("Use Default Dictionary API")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(.accentColor)
                                }
                                .buttonStyle(.plain)
                                
                                if !settings.customAudioAPIURL.isEmpty {
                                    Button {
                                        settings.customAudioAPIURL = ""
                                    } label: {
                                        Text("Clear")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundColor(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                }

                // Pronunciation fallback description
                SettingsCard {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "list.number")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                            Text("Fallback Order")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.primary)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            fallbackStepRow(number: 1, text: "Dictionary API audio", enabled: isAPIEnabled)
                            fallbackStepRow(number: 2, text: "Azure TTS (if key configured)", enabled: true)
                            fallbackStepRow(number: 3, text: "System text-to-speech", enabled: true)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }

                // Hint
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text("Pronunciation falls through each source until one succeeds.")
                        .font(.system(size: 11))
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                }
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func fallbackStepRow(number: Int, text: String, enabled: Bool) -> some View {
        HStack(spacing: 8) {
            Text("\(number).")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(enabled ? .secondary : Color(NSColor.tertiaryLabelColor))
                .frame(width: 16, alignment: .trailing)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(enabled ? .primary : Color(NSColor.tertiaryLabelColor))
                .strikethrough(!enabled, color: Color(NSColor.tertiaryLabelColor))
            Spacer()
            if enabled {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.green)
            } else {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 10))
                    .foregroundColor(Color(NSColor.tertiaryLabelColor))
            }
        }
    }
}

// MARK: - Translation Tab (macOS 15+ Translation Framework)

private struct TranslationTabView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if #available(macOS 15.0, *) {
                    SettingsCard {
                        VStack(spacing: 0) {
                            HStack(spacing: 8) {
                                Image(systemName: "translate")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.secondary)
                                Text("Translation Framework")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.primary)
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)

                            SettingsDivider()

                            TranslationLanguageRow(
                                targetLanguage: $model.settings.targetLanguage,
                                sourceLanguage: $model.settings.sourceLanguage
                            )
                        }
                    }

                    // Fallback description
                    SettingsCard {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: "list.number")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.secondary)
                                Text("Translation Fallback Order")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.primary)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                translationFallbackRow(number: 1, text: "Local Dictionary", enabled: true)
                                translationFallbackRow(number: 2, text: "Translation Framework (macOS 15+)", enabled: true)
                                translationFallbackRow(number: 3, text: "Azure Translator API", enabled: true)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }

                    // Hint
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text("Install language packs in System Settings > General > Language & Region > Translation Languages.")
                            .font(.system(size: 11))
                            .foregroundColor(Color(NSColor.tertiaryLabelColor))
                    }
                    .padding(.horizontal, 4)
                } else {
                    // Pre-macOS 15 fallback
                    SettingsCard {
                        VStack(spacing: 0) {
                            HStack(spacing: 8) {
                                Image(systemName: "translate")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.secondary)
                                Text("Language")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.primary)
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)

                            SettingsDivider()

                            LanguagePickerRow(
                                targetLanguage: $model.settings.targetLanguage,
                                sourceLanguage: $model.settings.sourceLanguage
                            )
                        }
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text("Translation Framework requires macOS 15+. Configure Azure API as an alternative.")
                            .font(.system(size: 11))
                            .foregroundColor(Color(NSColor.tertiaryLabelColor))
                    }
                    .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func translationFallbackRow(number: Int, text: String, enabled: Bool) -> some View {
        HStack(spacing: 8) {
            Text("\(number).")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(enabled ? .secondary : Color(NSColor.tertiaryLabelColor))
                .frame(width: 16, alignment: .trailing)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(enabled ? .primary : Color(NSColor.tertiaryLabelColor))
            Spacer()
        }
    }
}

// MARK: - API Keys Tab

private struct AzureTabView: View {

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                // Azure language settings
                SettingsCard {
                    VStack(spacing: 0) {
                        HStack(spacing: 8) {
                            Image(systemName: "globe")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                            Text("Azure Languages")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.primary)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)

                        SettingsDivider()

                        HStack(spacing: 12) {
                            Text("From")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundColor(.primary)
                            Spacer()
                            Text("English")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)

                        SettingsDivider()

                        HStack(spacing: 12) {
                            Text("To")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundColor(.primary)
                            Spacer()
                            Text("Chinese (Simplified)")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                }

                // Azure API keys
                SettingsCard {
                    VStack(spacing: 0) {
                        HStack(spacing: 8) {
                            Image(systemName: "key")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                            Text("Azure API Keys")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.primary)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)

                        SettingsDivider()

                        AzureAPISettingsSection()
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                    }
                }

                // Hint
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text("Azure is used as fallback when the Translation Framework is unavailable, and for paragraph translation.")
                        .font(.system(size: 11))
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                }
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - Shared Components

/// A rounded card container matching the app's design language.
private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(NSColor.windowBackgroundColor))
                .shadow(color: .black.opacity(0.04), radius: 8, x: 0, y: 2)
                .shadow(color: .black.opacity(0.02), radius: 1, x: 0, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(NSColor.quaternaryLabelColor), lineWidth: 0.5)
        )
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.horizontal, 14)
            .opacity(0.5)
    }
}

struct ContentPermissionRow: View {
    let icon: String
    let title: String
    let isGranted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(isGranted ? .green : .secondary)
                    .frame(width: 24)

                Text(title)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(.primary)

                Spacer()

                HStack(spacing: 6) {
                    Circle()
                        .fill(isGranted ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                        .shadow(color: isGranted ? .green.opacity(0.5) : .orange.opacity(0.5), radius: 3)

                    Text(isGranted ? "Granted" : "Required")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(isGranted ? .green : .orange)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(isGranted ? Color.green.opacity(0.1) : Color.orange.opacity(0.1))
                )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.25), value: isGranted)
    }
}

@available(macOS 15.0, *)
struct TranslationLanguageRow: View {
    @Binding var targetLanguage: String
    @Binding var sourceLanguage: String
    @EnvironmentObject var model: AppModel
    @State private var showingUnavailableAlert = false
    @State private var unavailableLanguageName = ""

    private let commonLanguages: [(id: String, name: String)] = [
        ("zh-Hans", "Chinese (Simplified)"),
        ("zh-Hant", "Chinese (Traditional)"),
        ("en", "English"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("fr", "French"),
        ("de", "German"),
        ("es", "Spanish"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("ru", "Russian"),
        ("ar", "Arabic"),
        ("th", "Thai"),
        ("vi", "Vietnamese")
    ]

    var body: some View {
        HStack(spacing: 12) {
            Text("Translate to")
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(.primary)

            Spacer()

            statusIcon

            Picker("", selection: $targetLanguage) {
                ForEach(commonLanguages, id: \.id) { lang in
                    Text(lang.name).tag(lang.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(.accentColor)
            .onChange(of: targetLanguage) { _, newValue in
                Task { @MainActor in
                    let status = await model.languagePackManager?.checkLanguagePair(
                        from: sourceLanguage,
                        to: newValue
                    )
                    if status != .installed {
                        checkLanguageAvailability(newValue)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .alert("Language Pack Required", isPresented: $showingUnavailableAlert) {
            Button("Open Settings") {
                model.languagePackManager?.openTranslationSettings()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The language pack for \(unavailableLanguageName) is not installed. Please download it in System Settings > General > Language & Region > Translation Languages.")
        }
        .onAppear {
            Task { @MainActor in
                let status = await model.languagePackManager?.checkLanguagePair(
                    from: sourceLanguage,
                    to: targetLanguage
                )
                if status != .installed {
                    checkLanguageAvailability(targetLanguage)
                }
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        let isChecking = model.languagePackManager?.isChecking ?? false
        let isSameLanguage = sourceLanguage == targetLanguage || 
            (sourceLanguage.hasPrefix("en") && targetLanguage.hasPrefix("en")) ||
            (sourceLanguage.hasPrefix("zh") && targetLanguage.hasPrefix("zh"))
        let status = getLanguagePackStatus(targetLanguage)

        if isChecking {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
        } else if isSameLanguage {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.green)
                .help("Same language - no translation needed")
        } else if let status = status {
            Button {
                Task { @MainActor in
                    let newStatus = await model.languagePackManager?.checkLanguagePair(
                        from: sourceLanguage,
                        to: targetLanguage
                    )
                    if newStatus != .installed {
                        checkLanguageAvailability(targetLanguage)
                    }
                }
            } label: {
                Image(systemName: status == .installed ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(status == .installed ? .green : .red)
            }
            .buttonStyle(.plain)
            .help(status == .installed ? "Language pack installed" : "Click to check and download")
        }
    }

    private func getLanguagePackStatus(_ language: String) -> LanguageAvailability.Status? {
        guard sourceLanguage != language else { return nil }
        return model.languagePackManager?.getStatus(from: sourceLanguage, to: language)
    }

    private func checkLanguageAvailability(_ language: String) {
        guard let status = getLanguagePackStatus(language) else { return }

        if status != .installed {
            unavailableLanguageName = commonLanguages.first(where: { $0.id == language })?.name ?? language
            showingUnavailableAlert = true
        }
    }
}

/// Language picker for pre-macOS 15 (no Translation framework status icons).
/// Shows local dictionaries at the top of the list and the standard language list.
struct LanguagePickerRow: View {
    @Binding var targetLanguage: String
    @Binding var sourceLanguage: String

    private let commonLanguages: [(id: String, name: String)] = [
        ("zh-Hans", "Chinese (Simplified)"),
        ("zh-Hant", "Chinese (Traditional)"),
        ("en", "English"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("fr", "French"),
        ("de", "German"),
        ("es", "Spanish"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("ru", "Russian"),
        ("ar", "Arabic"),
        ("th", "Thai"),
        ("vi", "Vietnamese"),
    ]

    var body: some View {
        HStack(spacing: 12) {
            Text("Translate to")
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(.primary)

            Spacer()

            Picker("", selection: $targetLanguage) {
                ForEach(commonLanguages, id: \.id) { lang in
                    Text(lang.name).tag(lang.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Global Hotkey Recorder

struct GlobalHotkeyRecorderView: View {
    @Binding var hotkey: String
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "keyboard")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                Text("Global Toggle Hotkey")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                Spacer()
            }

            HStack(spacing: 10) {
                // Display current hotkey or recording state
                Text(displayText)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(isRecording ? .orange : (hotkey.isEmpty ? .secondary : .primary))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(minWidth: 120)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isRecording ? Color.orange.opacity(0.1) : Color(NSColor.controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(isRecording ? Color.orange : Color(NSColor.separatorColor), lineWidth: 1)
                    )

                Button(isRecording ? "Cancel" : "Record") {
                    if isRecording {
                        stopRecording()
                    } else {
                        startRecording()
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .buttonStyle(.bordered)

                if !hotkey.isEmpty {
                    Button("Clear") {
                        hotkey = ""
                        stopRecording()
                    }
                    .font(.system(size: 12, weight: .medium))
                    .buttonStyle(.bordered)
                }
            }

            Text("Press a key combination (e.g. ⌘⇧T) to toggle translation on/off globally.")
                .font(.system(size: 11))
                .foregroundColor(Color(NSColor.tertiaryLabelColor))
        }
    }

    private var displayText: String {
        if isRecording {
            return "Press shortcut…"
        }
        if hotkey.isEmpty {
            return "Not set"
        }
        return GlobalHotkeyManager.displayString(for: hotkey)
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            var parts: [String] = []
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.command) { parts.append("command") }
            if flags.contains(.shift) { parts.append("shift") }
            if flags.contains(.option) { parts.append("option") }
            if flags.contains(.control) { parts.append("control") }

            // Require at least one modifier
            guard !parts.isEmpty else { return event }

            parts.append("\(event.keyCode)")
            hotkey = parts.joined(separator: "+")
            stopRecording()
            return nil  // consume the event
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}

