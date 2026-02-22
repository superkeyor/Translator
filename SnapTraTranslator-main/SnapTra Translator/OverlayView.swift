import AppKit
import SwiftUI

struct OverlayView: View {
    @EnvironmentObject var model: AppModel

    private var isVisible: Bool {
        if case .idle = model.overlayState { return false }
        return true
    }

    var body: some View {
        ZStack {
            if isVisible {
                overlayContent
            }
        }
    }

    @ViewBuilder
    private var overlayContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.overlayState {
            case .idle:
                EmptyView()

            case .loading(let word):
                loadingView(word: word)

            case .result(let content):
                resultView(content: content)

            case .error(let message):
                errorView(message: message)

            case .noWord:
                noWordView
            }
        }
        .frame(minWidth: 200, maxWidth: 420, alignment: .leading)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.85))
        .background(
            LinearGradient(
                colors: [
                    Color.white.opacity(0.12),
                    Color.white.opacity(0.04)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .inset(by: 0.5)
                .stroke(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.4),
                            .white.opacity(0.15),
                            .white.opacity(0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.08), radius: 2, x: 0, y: 1)
        .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)
        .shadow(color: .black.opacity(0.16), radius: 24, x: 0, y: 12)
    }

    // MARK: - Loading View

    @ViewBuilder
    private func loadingView(word: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let word {
                Text(word)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                    .tracking(0.2)
            }
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.85)
                Text("Translating")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(.secondary)
                LoadingDotsView()
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 18)
    }

    // MARK: - Result View

    @ViewBuilder
    private func resultView(content: OverlayContent) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: Word + Phonetic (always visible, not scrollable)
            headerSection(content: content)

            // Primary Translation
            primaryTranslationSection(content: content)

            // Expandable details section
            let hasDetails = content.rawHTML != nil || !content.definitions.isEmpty
            if hasDetails && model.isDefinitionsExpanded {
                if let rawHTML = content.rawHTML {
                    // Render rich dictionary HTML via WebView.
                    // WKWebView handles its own scrolling natively.
                    DictionaryHTMLWebView(html: rawHTML, maxHeight: 400) {
                        // Re-size overlay when WebView content height is known
                        model.overlayWindowController.resizeToFit()
                    }
                } else {
                    // Fallback to parsed definitions
                    ScrollView(.vertical, showsIndicators: true) {
                        definitionsSection(definitions: content.definitions)
                    }
                    .frame(maxHeight: 400)
                }
            }

            // Toolbar: always visible
            toolbarSection(content: content, hasDefinitions: hasDetails)
        }
    }

    @ViewBuilder
    private func headerSection(content: OverlayContent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Word title with action buttons
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(content.word)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                    .tracking(0.3)

                // Copy button
                CopyButton(text: content.word)

                Spacer()

                // Pin button
                Button {
                    model.isOverlayPinned.toggle()
                    model.overlayWindowController.isPinned = model.isOverlayPinned
                    if model.isOverlayPinned {
                        model.overlayWindowController.setInteractive(true)
                        model.overlayWindowController.setDraggable(true)
                    } else {
                        model.overlayWindowController.setDraggable(false)
                    }
                } label: {
                    Image(systemName: model.isOverlayPinned ? "pin.fill" : "pin")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(model.isOverlayPinned ? Color(red: 0.2, green: 0.6, blue: 1.0) : .secondary)
                        .frame(width: 20, height: 20)
                        .background(
                            Circle()
                                .fill(model.isOverlayPinned ? Color(red: 0.2, green: 0.6, blue: 1.0).opacity(0.12) : Color.secondary.opacity(0.1))
                        )
                }
                .buttonStyle(.plain)
                .help(model.isOverlayPinned ? "Unpin overlay" : "Pin overlay (keep visible)")

                // Close button
                Button {
                    model.dismissOverlay()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 20, height: 20)
                        .background(
                            Circle()
                                .fill(Color.secondary.opacity(0.1))
                        )
                }
                .buttonStyle(.plain)
            }

            // Phonetic notations (show all variants: BrE, AmE, etc.)
            if !content.phonetics.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(content.phonetics.enumerated()), id: \.offset) { _, ph in
                        Text(ph)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(Color.secondary.opacity(0.06))
                                    )
                            )
                    }
                }
            } else if let phonetic = content.phonetic, !phonetic.isEmpty {
                Text(phonetic)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.secondary.opacity(0.06))
                            )
                    )
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func primaryTranslationSection(content: OverlayContent) -> some View {
        // Only hide the blue translation line when it adds no information:
        // the translation is identical to the looked-up word (no actual translation).
        let shouldHideTranslation = content.translation == content.word

        if !shouldHideTranslation {
            HStack(spacing: 8) {
                // Blue translation text (always show for quick preview)
                Text(content.translation)
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundColor(Color(red: 0.2, green: 0.6, blue: 1.0))
                    .tracking(0.3)

                CopyButton(text: content.translation)

                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private func definitionsSection(definitions: [DictionaryEntry.Definition]) -> some View {
        let grouped = groupedTranslations(from: definitions)
        if grouped.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Divider()
                    .padding(.horizontal, 18)
                    .opacity(0.6)

                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(grouped.enumerated()), id: \.offset) { _, group in
                        definitionGroupRow(partOfSpeech: group.0, translations: group.1)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
        }
    }

    @ViewBuilder
    private func toolbarSection(content: OverlayContent, hasDefinitions: Bool) -> some View {
        Divider()
            .padding(.horizontal, 18)
            .opacity(0.4)

        HStack(spacing: 12) {
            Button {
                model.openInDictionary()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "book")
                        .font(.system(size: 11, weight: .medium))
                    Text("Dictionary")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.secondary.opacity(0.08))
                )
            }
            .buttonStyle(.plain)
            .help("Open in Dictionary.app")

            Spacer()

            // Expand/collapse button (only show when there are definitions)
            if hasDefinitions {
                Button {
                    model.isDefinitionsExpanded.toggle()
                    // Resize the overlay window to fit the new content height
                    model.overlayWindowController.resizeToFit()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: model.isDefinitionsExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                        Text(model.isDefinitionsExpanded ? "Collapse" : "Expand")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.secondary.opacity(0.08))
                    )
                }
                .buttonStyle(.plain)
                .help(model.isDefinitionsExpanded ? "Collapse definitions" : "Expand definitions")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func definitionGroupRow(partOfSpeech: String, translations: [String]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if !partOfSpeech.isEmpty {
                Text(displayedPartOfSpeech(for: partOfSpeech))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(posColor(for: partOfSpeech))
                            .shadow(color: posColor(for: partOfSpeech).opacity(0.3), radius: 2, x: 0, y: 1)
                    )
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(translations.enumerated()), id: \.offset) { idx, tr in
                    Text("\(idx + 1). \(tr)")
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundColor(.primary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func displayedPartOfSpeech(for pos: String) -> String {
        let lowercased = pos.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch lowercased {
        case "n", "noun":
            return "n."
        case "v", "verb":
            return "v."
        case "vt", "transitive verb":
            return "vt."
        case "vi", "intransitive verb":
            return "vi."
        case "adj", "adjective":
            return "adj."
        case "adv", "adverb":
            return "adv."
        case "prep", "preposition":
            return "prep."
        case "conj", "conjunction":
            return "conj."
        case "pron", "pronoun":
            return "pron."
        case "interj", "interjection":
            return "interj."
        default:
            return pos
        }
    }

    private func groupedTranslations(from definitions: [DictionaryEntry.Definition]) -> [(String, [String])] {
        var order: [String] = []
        var grouped: [String: [String]] = [:]

        for definition in definitions {
            guard let translation = definition.translation?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !translation.isEmpty else { continue }
            let key = definition.partOfSpeech
            if grouped[key] == nil {
                order.append(key)
                grouped[key] = []
            }
            if grouped[key]?.contains(translation) == false {
                grouped[key]?.append(translation)
            }
        }

        return order.compactMap { key in
            guard let translations = grouped[key], !translations.isEmpty else { return nil }
            return (key, translations)
        }
    }

    private func posColor(for pos: String) -> Color {
        switch pos.lowercased() {
        case "n.", "n", "noun":
            return Color(red: 0.2, green: 0.6, blue: 1.0)  // Modern blue
        case "v.", "v", "verb":
            return Color(red: 0.2, green: 0.78, blue: 0.35)  // Modern green
        case "vt.", "vt", "transitive verb":
            return Color(red: 0.2, green: 0.78, blue: 0.35)  // Modern green
        case "vi.", "vi", "intransitive verb":
            return Color(red: 0.2, green: 0.78, blue: 0.35)  // Modern green
        case "adj.", "adj", "adjective":
            return Color(red: 1.0, green: 0.58, blue: 0.0)  // Vibrant orange
        case "adv.", "adv", "adverb":
            return Color(red: 0.69, green: 0.32, blue: 0.87)  // Modern purple
        case "prep.", "prep", "preposition":
            return Color(red: 1.0, green: 0.27, blue: 0.58)  // Modern pink
        case "conj.", "conj", "conjunction":
            return Color(red: 0.2, green: 0.78, blue: 0.87)  // Modern cyan
        case "pron.", "pron", "pronoun":
            return Color(red: 0.2, green: 0.69, blue: 0.64)  // Modern teal
        case "interj.", "interj", "interjection":
            return Color(red: 1.0, green: 0.27, blue: 0.27)  // Modern red
        default:
            return Color(red: 0.56, green: 0.56, blue: 0.58)  // Modern gray
        }
    }

    // MARK: - Error View

    @ViewBuilder
    private func errorView(message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(Color(red: 1.0, green: 0.58, blue: 0.0))
            Text(message)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundColor(.primary)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 18)
    }

    // MARK: - No Word View

    private var noWordView: some View {
        HStack(spacing: 12) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.secondary)
            Text("No word detected")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundColor(Color.primary.opacity(0.8))
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 18)
    }
}

// MARK: - Loading Dots Animation

struct LoadingDotsView: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 4.5, height: 4.5)
                    .scaleEffect(animating ? 1.0 : 0.5)
                    .opacity(animating ? 0.8 : 0.3)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.2),
                        value: animating
                    )
            }
        }
        .onAppear {
            animating = true
        }
    }
}

// MARK: - Copy Button

struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            copyToClipboard(text)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                copied = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation(.easeInOut(duration: 0.25)) {
                    copied = false
                }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(copied ? Color(red: 0.2, green: 0.78, blue: 0.35) : .secondary)
                .frame(width: 18, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(copied ? Color(red: 0.2, green: 0.78, blue: 0.35).opacity(0.12) : Color.secondary.opacity(0.08))
                )
                .scaleEffect(copied ? 1.1 : 1.0)
        }
        .buttonStyle(.plain)
        .help("Copy to clipboard")
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

// MARK: - Preview

#Preview {
    OverlayView()
        .environmentObject(AppModel(
            settings: SettingsStore(),
            permissions: PermissionManager()
        ))
        .frame(width: 500, height: 300)
        .background(Color.gray.opacity(0.3))
}
