import AppKit
import Combine
import Foundation
import SwiftUI
import Translation
import UserNotifications

struct OverlayContent: Equatable {
    var word: String
    var phonetic: String?
    var phonetics: [String]
    var translation: String
    var definitions: [DictionaryEntry.Definition]
    /// Raw dictionary HTML for WebView rendering (nil → use parsed definitions)
    var rawHTML: String?

    init(word: String, phonetic: String?, translation: String, definitions: [DictionaryEntry.Definition] = [], phonetics: [String] = [], rawHTML: String? = nil) {
        self.word = word
        self.phonetic = phonetic
        self.phonetics = phonetics
        self.translation = translation
        self.definitions = definitions
        self.rawHTML = rawHTML
    }
}

enum OverlayState: Equatable {
    case idle
    case loading(String?)
    case result(OverlayContent)
    case error(String)
    case noWord
}

@MainActor
final class AppModel: ObservableObject {
    @Published var overlayState: OverlayState = .idle
    @Published var overlayAnchor: CGPoint = .zero
    @Published var isOverlayPinned: Bool = false
    @Published var isDefinitionsExpanded: Bool = false
    @Published var isTranslationEnabled: Bool = true

    @Published var settings: SettingsStore
    let permissions: PermissionManager
    let translationBridge: TranslationBridge
    private var _languagePackManager: Any?

    @available(macOS 15.0, *)
    var languagePackManager: LanguagePackManager? {
        get { _languagePackManager as? LanguagePackManager }
        set { _languagePackManager = newValue }
    }

    private let hotkeyManager = HotkeyManager()
    private let globalHotkeyManager = GlobalHotkeyManager()
    private let captureService = ScreenCaptureService()
    private let ocrService = OCRService()
    private let dictionaryService = DictionaryService()
    private let speechService = SpeechService()
    private let azureTranslator = AzureTranslatorService()
    private let accessibilityService = AccessibilityService()
    private var cancellables = Set<AnyCancellable>()
    private var lookupTask: Task<Void, Never>?
    private var activeLookupID: UUID?
    private var isHotkeyActive = false
    private var isParagraphMode = false
    private var lastAvailabilityKey: String?
    private var cachedLanguageStatus: (key: String, isInstalled: Bool)?
    
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var clickOutsideGlobalMonitor: Any?
    private var clickOutsideLocalMonitor: Any?
    private var debounceWorkItem: DispatchWorkItem?
    private var lastOcrPosition: CGPoint?
    private let debounceInterval: TimeInterval = 0.1
    private let positionThreshold: CGFloat = 10.0

    private let debugOverlayWindowController = DebugOverlayWindowController()
    lazy var overlayWindowController = OverlayWindowController(model: self)

    @MainActor
    init(settings: SettingsStore? = nil, permissions: PermissionManager? = nil) {
        let resolvedSettings = settings ?? SettingsStore()
        let resolvedPermissions = permissions ?? PermissionManager()
        self.settings = resolvedSettings
        self.permissions = resolvedPermissions
        self.translationBridge = TranslationBridge()
        if #available(macOS 15.0, *) {
            let manager = LanguagePackManager()
            self.languagePackManager = manager
            // Forward LanguagePackManager changes to AppModel so SwiftUI redraws
            manager.objectWillChange
                .sink { [weak self] _ in
                    self?.objectWillChange.send()
                }
                .store(in: &cancellables)
        }
        bindSettings()
        resolvedPermissions.$status
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        hotkeyManager.onTrigger = { [weak self] in
            self?.handleHotkeyTrigger()
        }
        hotkeyManager.onRelease = { [weak self] in
            self?.handleHotkeyRelease()
        }
        resolvedPermissions.refreshStatus()
        Task {
            await checkLanguageAvailability()
        }
    }

    func toggleTranslation() {
        isTranslationEnabled.toggle()
    }

    func handleHotkeyTrigger() {
        guard isTranslationEnabled else { return }
        isHotkeyActive = true
        lastOcrPosition = NSEvent.mouseLocation

        // Check for additional modifier → enables selection/paragraph mode
        if settings.paragraphTranslationEnabled {
            let paragraphFlag = settings.paragraphModifier.flag
            let currentFlags = NSEvent.modifierFlags
            isParagraphMode = currentFlags.contains(paragraphFlag)
        } else {
            isParagraphMode = false
        }

        stopClickOutsideMonitor()
        overlayWindowController.setInteractive(false)
        startMouseTracking()
        startLookup()
    }

    func handleHotkeyRelease() {
        isHotkeyActive = false
        stopMouseTracking()
        debugOverlayWindowController.hide()

        lookupTask?.cancel()
        lookupTask = nil
        activeLookupID = nil

        // If the overlay is pinned, keep it visible and interactive
        if isOverlayPinned {
            overlayWindowController.setInteractive(true)
            startClickOutsideMonitor()
            return
        }

        // If there's a result showing, keep it visible and interactive
        // so the user can scroll, copy, pin, or open Dictionary.
        if case .result = overlayState {
            overlayWindowController.setInteractive(true)
            overlayWindowController.setDraggable(true)
            startClickOutsideMonitor()
            return
        }

        // No result — hide
        overlayState = .idle
        overlayWindowController.setInteractive(false)
        overlayWindowController.hide()
    }

    /// 手动关闭气泡（用于非持续翻译模式）
    func dismissOverlay() {
        isOverlayPinned = false
        overlayWindowController.isPinned = false
        lookupTask?.cancel()
        lookupTask = nil
        activeLookupID = nil
        overlayState = .idle
        stopClickOutsideMonitor()
        overlayWindowController.setDraggable(false)
        overlayWindowController.setInteractive(false)
        overlayWindowController.hide()
    }

    /// Open the current word in Dictionary.app
    func openInDictionary() {
        let word: String
        if case .result(let content) = overlayState {
            word = content.word
        } else {
            return
        }
        let url = URL(string: "dict://\(word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? word)")!
        NSWorkspace.shared.open(url)
    }
    
    private func startMouseTracking() {
        guard globalMouseMonitor == nil else { return }
        
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            Task { @MainActor in
                self?.handleMouseMoved()
            }
        }
        
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            Task { @MainActor in
                self?.handleMouseMoved()
            }
            return event
        }
    }
    
    private func stopMouseTracking() {
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseMonitor = nil
        }
        if let monitor = localMouseMonitor {
            NSEvent.removeMonitor(monitor)
            localMouseMonitor = nil
        }
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        lastOcrPosition = nil
    }

    /// Install click monitors that dismiss the overlay when the user
    /// clicks outside its bounds. Skips dismiss when pinned.
    private func startClickOutsideMonitor() {
        stopClickOutsideMonitor()

        // Global monitor — catches clicks in other apps / outside our windows
        clickOutsideGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isOverlayPinned else { return }
                if !self.overlayWindowController.isMouseInsideOverlay() {
                    self.dismissOverlay()
                }
            }
        }

        // Local monitor — catches clicks inside our own app windows (e.g. menu bar)
        clickOutsideLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor in
                guard let self, !self.isOverlayPinned else { return }
                if !self.overlayWindowController.isMouseInsideOverlay() {
                    self.dismissOverlay()
                }
            }
            return event
        }
    }

    private func stopClickOutsideMonitor() {
        if let monitor = clickOutsideGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideGlobalMonitor = nil
        }
        if let monitor = clickOutsideLocalMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideLocalMonitor = nil
        }
    }
    
    private func handleMouseMoved() {
        guard isHotkeyActive else { return }

        // 如果关闭了持续翻译，鼠标移动不触发翻译
        guard settings.continuousTranslation else { return }

        // Don't re-trigger lookup when cursor is inside the overlay
        if overlayWindowController.isMouseInsideOverlay() {
            return
        }

        debounceWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self = self, self.isHotkeyActive else { return }

                let currentPosition = NSEvent.mouseLocation

                if let lastPosition = self.lastOcrPosition {
                    let dx = abs(currentPosition.x - lastPosition.x)
                    let dy = abs(currentPosition.y - lastPosition.y)
                    if dx < self.positionThreshold && dy < self.positionThreshold {
                        return
                    }
                }

                self.lastOcrPosition = currentPosition
                self.overlayAnchor = currentPosition
                if case .idle = self.overlayState {
                    self.startLookup()
                } else {
                    self.overlayWindowController.show(at: currentPosition)
                    self.startLookup()
                }
            }
        }
        debounceWorkItem = workItem

        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    private func startLookup() {
        lookupTask?.cancel()
        let lookupID = UUID()
        activeLookupID = lookupID
        lookupTask = Task { [weak self] in
            await self?.performLookup(lookupID: lookupID)
        }
    }

    func performLookup(lookupID: UUID) async {
        guard !Task.isCancelled, activeLookupID == lookupID else { return }
        guard permissions.status.screenRecording else {
            updateOverlay(state: .error("Enable Screen Recording"), anchor: NSEvent.mouseLocation)
            return
        }
        let mouseLocation = NSEvent.mouseLocation
        guard activeLookupID == lookupID else { return }

        // Paragraph/selection mode: check for selected text, fall back to OCR
        if isParagraphMode {
            await performSelectionOrParagraphLookup(lookupID: lookupID, mouseLocation: mouseLocation)
            return
        }

        await performWordLookup(lookupID: lookupID, mouseLocation: mouseLocation)
    }

    /// Core OCR word-level lookup flow.
    /// Fallback chain for words: local dictionary → Translation framework → Azure API
    private func performWordLookup(lookupID: UUID, mouseLocation: CGPoint) async {
        // 只在调试模式下显示初始 loading 状态
        if settings.debugShowOcrRegion {
            updateOverlay(state: .loading(nil), anchor: mouseLocation)
        }

        guard let capture = await captureService.captureAroundCursor() else {
            debugOverlayWindowController.hide()
            if settings.debugShowOcrRegion {
                updateOverlay(state: .error("Capture failed"), anchor: mouseLocation)
            }
            return
        }
        if settings.debugShowOcrRegion {
            debugOverlayWindowController.show(at: capture.region.rect)
        } else {
            debugOverlayWindowController.hide()
        }
        guard !Task.isCancelled, activeLookupID == lookupID else { return }
        let normalizedPoint = normalizedCursorPoint(mouseLocation, in: capture.region.rect)
        do {
            let words = try await ocrService.recognizeWords(in: capture.image, language: settings.sourceLanguage)
            guard !Task.isCancelled, activeLookupID == lookupID else { return }
            if settings.debugShowOcrRegion {
                let wordBoxes = words.map { $0.boundingBox }
                debugOverlayWindowController.show(at: capture.region.rect, wordBoxes: wordBoxes)
            }
            guard let selected = selectWord(from: words, normalizedPoint: normalizedPoint) else {
                // 只在调试模式下显示 "No word detected" 气泡
                if settings.debugShowOcrRegion {
                    updateOverlay(state: .noWord, anchor: mouseLocation)
                } else {
                    // 非调试模式下，如果没有钉住，则隐藏气泡
                    // If pinned, keep the existing overlay visible
                    if !isOverlayPinned {
                        overlayState = .idle
                        overlayWindowController.hide()
                    }
                }
                return
            }
            guard activeLookupID == lookupID else { return }

            updateOverlay(state: .loading(selected.text), anchor: mouseLocation)
            let sourceLangId = settings.sourceLanguage
            let targetLangId = settings.targetLanguage
            let sourceLanguageCode = sourceLangId.components(separatedBy: "-").first ?? sourceLangId
            if settings.playPronunciation {
                speechService.speak(selected.text, language: sourceLanguageCode, customAudioAPIURL: settings.customAudioAPIURL)
            }
            guard !Task.isCancelled, activeLookupID == lookupID else { return }

            // Fallback chain for words:
            // 1. Local dictionary lookup (skip when user chose "None")
            let targetIsEnglish = targetLangId.hasPrefix("en")
            let skipDictionary = settings.preferredDictionary == "__none__"
            let dictEntry: DictionaryEntry? = skipDictionary
                ? nil
                : dictionaryService.lookup(selected.text, preferEnglish: targetIsEnglish, preferredDictionary: settings.preferredDictionary)
            let phonetic = dictEntry?.phonetic
            let phonetics = dictEntry?.phonetics ?? []
            var definitions = dictEntry?.definitions ?? []
            let dictRawHTML = dictEntry?.rawHTML

            if sourceLangId == targetLangId {
                var processedDefinitions = definitions
                let isEnglish = sourceLangId.hasPrefix("en")
                
                if isEnglish && !definitions.isEmpty {
                    processedDefinitions = definitions.compactMap { def in
                        let trimmedMeaning = def.meaning.trimmingCharacters(in: .whitespacesAndNewlines)
                        let hasEnglishContent = trimmedMeaning.range(of: "[a-zA-Z]{3,}", options: .regularExpression) != nil
                        guard hasEnglishContent else { return nil }
                        return DictionaryEntry.Definition(
                            partOfSpeech: def.partOfSpeech,
                            meaning: def.meaning,
                            translation: trimmedMeaning,
                            examples: def.examples
                        )
                    }
                }
                
                let content = OverlayContent(
                    word: selected.text,
                    phonetic: phonetic,
                    translation: selected.text,
                    definitions: processedDefinitions,
                    phonetics: phonetics,
                    rawHTML: dictRawHTML
                )
                updateOverlay(state: .result(content), anchor: mouseLocation)
                return
            }

            // 2. Translation framework (macOS 15+) → 3. Azure Translator API
            let translated = await translateWithFallback(
                text: selected.text,
                sourceLangId: sourceLangId,
                targetLangId: targetLangId,
                mouseLocation: mouseLocation
            )
            guard !Task.isCancelled, activeLookupID == lookupID else { return }

            if let translatedText = translated {
                // Machine translation succeeded — also translate definitions if available
                if !definitions.isEmpty {
                    definitions = await translateDefinitionsInParallel(
                        definitions: definitions,
                        sourceLangId: sourceLangId,
                        targetLangId: targetLangId
                    )
                } else {
                    // No detailed definitions from dictionary — populate details
                    // with the full translation so the user can expand to see it
                    definitions = [
                        DictionaryEntry.Definition(
                            partOfSpeech: "",
                            meaning: translatedText,
                            translation: translatedText,
                            examples: []
                        )
                    ]
                }

                let content = OverlayContent(
                    word: selected.text,
                    phonetic: phonetic,
                    translation: translatedText,
                    definitions: definitions,
                    phonetics: phonetics,
                    rawHTML: dictRawHTML
                )
                updateOverlay(state: .result(content), anchor: mouseLocation)
            } else if !definitions.isEmpty {
                // Machine translation unavailable but local dictionary has results.
                // 1. Find a CJK / non-English translation from the definitions
                //    to use as the blue primary translation line.
                // 2. If none exists, fall back to the word itself (avoid showing
                //    a raw English definition paragraph in the blue line).
                // 3. Ensure every definition has a non-nil `translation` so it
                //    appears in the expandable details section.
                let hasChinese: (String) -> Bool = { text in
                    text.range(of: "\\p{Han}", options: .regularExpression) != nil
                }
                let primaryTranslation = definitions
                    .compactMap { $0.translation }
                    .first(where: { hasChinese($0) })
                    ?? definitions
                        .compactMap { $0.translation }
                        .first(where: { !$0.isEmpty })
                    ?? selected.text

                // Fill nil translations with the meaning so groupedTranslations
                // doesn't filter them out and the user can expand to read the
                // dictionary definitions.
                let filledDefinitions = definitions.map { def -> DictionaryEntry.Definition in
                    if let tr = def.translation, !tr.isEmpty {
                        return def
                    }
                    return DictionaryEntry.Definition(
                        partOfSpeech: def.partOfSpeech,
                        meaning: def.meaning,
                        translation: def.meaning,
                        examples: def.examples
                    )
                }

                let content = OverlayContent(
                    word: selected.text,
                    phonetic: phonetic,
                    translation: primaryTranslation,
                    definitions: filledDefinitions,
                    phonetics: phonetics,
                    rawHTML: dictRawHTML
                )
                updateOverlay(state: .result(content), anchor: mouseLocation)
            } else {
                // No translation AND no dictionary results
                updateOverlay(state: .error("Translation failed. Configure Azure API key in settings or install language pack (macOS 15+)."), anchor: mouseLocation)
            }
        } catch is CancellationError {
            // Task was cancelled, do nothing
        } catch TranslationError.timeout {
            updateOverlay(state: .error("Translation timeout. Please try again."), anchor: mouseLocation)
        } catch {
            updateOverlay(state: .error("Translation failed: \(error.localizedDescription)"), anchor: mouseLocation)
        }
    }

    /// Translate text using fallback chain: Translation framework → Azure API.
    private func translateWithFallback(
        text: String,
        sourceLangId: String,
        targetLangId: String,
        mouseLocation: CGPoint
    ) async -> String? {
        // 1. Try Translation framework (macOS 15+)
        if #available(macOS 15.0, *) {
            let sourceLanguage = Locale.Language(identifier: sourceLangId)
            let targetLanguage = Locale.Language(identifier: targetLangId)
            let languageKey = "\(sourceLangId)->\(targetLangId)"

            let isInstalled: Bool
            if let cached = cachedLanguageStatus, cached.key == languageKey {
                isInstalled = cached.isInstalled
            } else {
                let availability = LanguageAvailability()
                let status = await availability.status(from: sourceLanguage, to: targetLanguage)
                isInstalled = status == .installed
                cachedLanguageStatus = (languageKey, isInstalled)
            }

            if isInstalled {
                do {
                    let translated = try await translationBridge.translate(text: text)
                    return translated
                } catch {
                    print("[AppModel] Translation framework failed, trying Azure fallback: \(error)")
                }
            }
        }

        // 2. Fall back to Azure Translator API
        if let result = await azureTranslator.translate(
            text: text,
            from: sourceLangId,
            to: targetLangId
        ) {
            return result.translatedText
        }

        return nil
    }

    /// Perform selection-aware translation: check for selected text first, fall back to OCR word lookup.
    /// 1. Try accessibility API for selected text
    /// 2. Try clipboard (Cmd+C) for selected text
    /// 3. If no selection found, fall back to regular OCR word lookup
    private func performSelectionOrParagraphLookup(lookupID: UUID, mouseLocation: CGPoint) async {
        updateOverlay(state: .loading("Checking selection…"), anchor: mouseLocation)

        var selectedText: String? = nil

        // Step 1: Try accessibility API for selected text
        if accessibilityService.isAccessibilityEnabled {
            guard let screen = NSScreen.main else {
                updateOverlay(state: .error("No screen available"), anchor: mouseLocation)
                return
            }
            let flippedY = screen.frame.height - mouseLocation.y
            let accessibilityPoint = CGPoint(x: mouseLocation.x, y: flippedY)

            selectedText = accessibilityService.selectedText(at: accessibilityPoint)

            // Step 2: If no selected text via accessibility, try clipboard fallback
            if selectedText == nil {
                selectedText = accessibilityService.selectedTextViaClipboard()
            }
        }

        guard !Task.isCancelled, activeLookupID == lookupID else { return }

        // Step 3: If no selection found, fall back to OCR word lookup (just call the normal word lookup flow)
        guard let rawText = selectedText,
              !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // No selection — fall back to OCR word-level lookup
            isParagraphMode = false
            await performWordLookup(lookupID: lookupID, mouseLocation: mouseLocation)
            isParagraphMode = true
            return
        }

        let textToTranslate = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayText = textToTranslate.count > 100
            ? String(textToTranslate.prefix(100)) + "…"
            : textToTranslate

        updateOverlay(state: .loading(displayText), anchor: mouseLocation)

        let sourceLangId = settings.sourceLanguage
        let targetLangId = settings.targetLanguage

        if sourceLangId == targetLangId {
            let content = OverlayContent(
                word: displayText,
                phonetic: nil,
                translation: textToTranslate
            )
            updateOverlay(state: .result(content), anchor: mouseLocation)
            return
        }

        // For selected text / sentences: Translation framework → Azure API
        guard let translated = await translateWithFallback(
            text: textToTranslate,
            sourceLangId: sourceLangId,
            targetLangId: targetLangId,
            mouseLocation: mouseLocation
        ) else {
            updateOverlay(state: .error("Translation failed. Configure Azure API key or install language pack."), anchor: mouseLocation)
            return
        }
        guard !Task.isCancelled, activeLookupID == lookupID else { return }

        let content = OverlayContent(
            word: displayText,
            phonetic: nil,
            translation: translated
        )
        updateOverlay(state: .result(content), anchor: mouseLocation)
    }

    func updateOverlay(state: OverlayState, anchor: CGPoint? = nil) {
        guard isHotkeyActive || isOverlayPinned else { return }

        // When pinned, don't move the overlay — keep it where the user placed it.
        if !isOverlayPinned, let anchor {
            overlayAnchor = anchor
        }
        switch state {
        case .error:
            overlayState = state
            if !isOverlayPinned {
                overlayWindowController.show(at: overlayAnchor)
            }
            overlayWindowController.setInteractive(true)
        case .idle:
            break
        case .result:
            // Apply expand default based on current mode (pinned vs cursor)
            isDefinitionsExpanded = isOverlayPinned
                ? settings.defaultExpandPinned
                : settings.defaultExpandCursor
            overlayState = state
            if !isOverlayPinned {
                overlayWindowController.show(at: overlayAnchor)
            }
            overlayWindowController.setInteractive(true)
        default:
            overlayState = state
            if !isOverlayPinned {
                overlayWindowController.show(at: overlayAnchor)
            }
        }
    }



    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func bindSettings() {
        settings.$singleKey
            .sink { [weak self] singleKey in
                self?.hotkeyManager.start(singleKey: singleKey)
                // Re-apply allowed modifier after hotkey restart
                self?.updateAllowedModifier()
            }
            .store(in: &cancellables)

        // Bind paragraph modifier changes
        settings.$paragraphModifier
            .combineLatest(settings.$paragraphTranslationEnabled)
            .sink { [weak self] _, _ in
                self?.updateAllowedModifier()
            }
            .store(in: &cancellables)

        // Bind global toggle hotkey
        settings.$globalToggleHotkey
            .sink { [weak self] value in
                guard let self else { return }
                self.globalHotkeyManager.register(from: value)
            }
            .store(in: &cancellables)
        globalHotkeyManager.onToggle = { [weak self] in
            Task { @MainActor in
                self?.toggleTranslation()
            }
        }
        globalHotkeyManager.register(from: settings.globalToggleHotkey)

        settings.$launchAtLogin
            .sink { value in
                LoginItemManager.setEnabled(value)
            }
            .store(in: &cancellables)

        settings.$debugShowOcrRegion
            .sink { [weak self] isEnabled in
                if !isEnabled {
                    self?.debugOverlayWindowController.hide()
                }
            }
            .store(in: &cancellables)

        settings.$sourceLanguage
            .combineLatest(settings.$targetLanguage)
            .sink { [weak self] _, _ in
                guard let self = self else { return }
                // Cancel any ongoing translation when language changes
                self.lookupTask?.cancel()
                self.lookupTask = nil
                self.activeLookupID = nil
                // Only dismiss overlay if not pinned
                if self.overlayState != .idle && !self.isOverlayPinned {
                    self.overlayState = .idle
                    self.overlayWindowController.hide()
                }
                Task {
                    await self.checkLanguageAvailability()
                }
            }
            .store(in: &cancellables)

        permissions.$status
            .sink { [weak self] status in
                if status.screenRecording {
                    self?.restartHotkey()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.restartHotkey()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                self?.handleScreenConfigurationChange()
            }
            .store(in: &cancellables)
    }

    private func handleScreenConfigurationChange() {
        captureService.invalidateCache()
        guard isHotkeyActive else { return }
        lookupTask?.cancel()
        lookupTask = nil
        activeLookupID = nil
        // Only dismiss overlay if not pinned
        if !isOverlayPinned {
            overlayState = .idle
            overlayWindowController.hide()
        }
        debugOverlayWindowController.hide()
    }

    private func restartHotkey() {
        guard !isHotkeyActive else { return }
        hotkeyManager.start(singleKey: settings.singleKey)
        updateAllowedModifier()
    }

    private func updateAllowedModifier() {
        if settings.paragraphTranslationEnabled {
            hotkeyManager.allowedAdditionalModifier = settings.paragraphModifier.flag
        } else {
            hotkeyManager.allowedAdditionalModifier = nil
        }
    }

    private func checkLanguageAvailability() async {
        guard #available(macOS 15.0, *) else { return }
        let sourceLanguage = Locale.Language(identifier: settings.sourceLanguage)
        let targetLanguage = Locale.Language(identifier: settings.targetLanguage)
        let availability = LanguageAvailability()
        let status = await availability.status(from: sourceLanguage, to: targetLanguage)
        let languageKey = "\(sourceLanguage.minimalIdentifier)->\(targetLanguage.minimalIdentifier)"
        let key = "\(languageKey)-\(status)"
        
        cachedLanguageStatus = (languageKey, status == .installed)
        
        guard key != lastAvailabilityKey else { return }
        lastAvailabilityKey = key
        switch status {
        case .installed:
            break
        case .supported:
            sendNotification(title: "SnapTra Translator", body: "Language pack required. Please download in System Settings > General > Language & Region > Translation.")
        case .unsupported:
            sendNotification(title: "SnapTra Translator", body: "Translation not supported for this language pair.")
        @unknown default:
            break
        }
    }

    private func normalizedCursorPoint(_ mouseLocation: CGPoint, in rect: CGRect) -> CGPoint {
        let x = (mouseLocation.x - rect.minX) / rect.width
        let y = (mouseLocation.y - rect.minY) / rect.height
        return CGPoint(x: x, y: y)
    }

    private func translateDefinitionsInParallel(
        definitions: [DictionaryEntry.Definition],
        sourceLangId: String,
        targetLangId: String
    ) async -> [DictionaryEntry.Definition] {
        let targetIsChinese = targetLangId.hasPrefix("zh")
        let targetIsEnglish = targetLangId.hasPrefix("en")
        let isSameLanguage = sourceLangId == targetLangId

        return await withTaskGroup(of: (Int, DictionaryEntry.Definition?).self) { group in
            for (index, def) in definitions.enumerated() {
                group.addTask { [translationBridge] in
                    let trimmedTranslation = def.translation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let hasDictionaryTranslation = !trimmedTranslation.isEmpty
                    let shouldKeepDictionaryTranslation = targetIsChinese && hasDictionaryTranslation

                    if shouldKeepDictionaryTranslation {
                        return (index, def)
                    }

                    if targetIsEnglish {
                        let trimmedMeaning = def.meaning.trimmingCharacters(in: .whitespacesAndNewlines)
                        let hasEnglishContent = trimmedMeaning.range(of: "[a-zA-Z]{3,}", options: .regularExpression) != nil
                        if hasEnglishContent {
                            return (index, DictionaryEntry.Definition(
                                partOfSpeech: def.partOfSpeech,
                                meaning: def.meaning,
                                translation: trimmedMeaning,
                                examples: def.examples
                            ))
                        }
                        return (index, nil)
                    }

                    let translatedText: String
                    if isSameLanguage {
                        translatedText = def.meaning
                    } else if let meaningTranslation = try? await translationBridge.translate(
                        text: def.meaning
                    ) {
                        translatedText = meaningTranslation
                    } else {
                        translatedText = def.meaning
                    }

                    return (index, DictionaryEntry.Definition(
                        partOfSpeech: def.partOfSpeech,
                        meaning: def.meaning,
                        translation: translatedText,
                        examples: def.examples
                    ))
                }
            }

            var results: [(Int, DictionaryEntry.Definition)] = []
            for await (index, def) in group {
                if let def {
                    results.append((index, def))
                }
            }
            return results.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }

    private func selectWord(from words: [RecognizedWord], normalizedPoint: CGPoint) -> RecognizedWord? {
        let tolerance: CGFloat = 0.01

        // 筛选边界框包含光标的所有候选单词
        let candidates = words.filter { word in
            let expandedBox = word.boundingBox.insetBy(dx: -tolerance, dy: -tolerance)
            return expandedBox.contains(normalizedPoint)
        }

        guard !candidates.isEmpty else { return nil }

        // 选择边界框中心距离光标最近的单词
        return candidates.min { word1, word2 in
            let dist1 = hypot(word1.boundingBox.midX - normalizedPoint.x,
                              word1.boundingBox.midY - normalizedPoint.y)
            let dist2 = hypot(word2.boundingBox.midX - normalizedPoint.x,
                              word2.boundingBox.midY - normalizedPoint.y)
            return dist1 < dist2
        }
    }
}
