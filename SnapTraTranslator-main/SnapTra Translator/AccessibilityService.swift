import AppKit
import Foundation

/// Service for extracting text from UI elements using the macOS Accessibility API.
/// Used for paragraph translation mode — extracts larger text blocks from the element under the cursor.
final class AccessibilityService {

    /// Get the currently selected text from the element at the given screen point.
    /// Returns nil if no selection or accessibility not available.
    func selectedText(at point: CGPoint) -> String? {
        let systemWideElement = AXUIElementCreateSystemWide()

        var elementRef: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(systemWideElement, Float(point.x), Float(point.y), &elementRef)

        guard result == .success, let element = elementRef else {
            return nil
        }

        // Try AXSelectedText first — this is the user's text selection
        if let selectedText = attribute(element, kAXSelectedTextAttribute) as? String,
           !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return selectedText
        }

        return nil
    }

    /// Try to get selected text using the clipboard (Cmd+C simulation).
    /// This is a fallback when accessibility doesn't return selected text directly.
    func selectedTextViaClipboard() -> String? {
        // Save current clipboard
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)

        // Clear clipboard
        pasteboard.clearContents()

        // Simulate Cmd+C
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true) // 'c' key
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)

        // Small delay for clipboard to update
        usleep(100_000) // 100ms

        let copiedText = pasteboard.string(forType: .string)

        // Restore previous clipboard content
        if let previous = previousContents {
            pasteboard.clearContents()
            pasteboard.setString(previous, forType: .string)
        }

        if let text = copiedText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        return nil
    }

    /// Extract the text of the paragraph or text block under the given screen point.
    /// Falls back through multiple strategies:
    /// 1. AXUIElement at point → AXSelectedText
    /// 2. AXUIElement at point → AXValue (full text of the element)
    /// 3. Nil if nothing found
    func paragraphText(at point: CGPoint) -> String? {
        let systemWideElement = AXUIElementCreateSystemWide()

        var elementRef: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(systemWideElement, Float(point.x), Float(point.y), &elementRef)

        guard result == .success, let element = elementRef else {
            print("[AccessibilityService] No element at position \(point), error: \(result.rawValue)")
            return nil
        }

        // Try AXSelectedText first
        if let selectedText = attribute(element, kAXSelectedTextAttribute) as? String, !selectedText.isEmpty {
            return selectedText
        }

        // Try to get the full value of the element (works for text fields, labels, etc.)
        if let value = attribute(element, kAXValueAttribute) as? String, !value.isEmpty {
            return value
        }

        // Try AXDescription or AXTitle
        if let desc = attribute(element, kAXDescriptionAttribute) as? String, !desc.isEmpty {
            return desc
        }
        if let title = attribute(element, kAXTitleAttribute) as? String, !title.isEmpty {
            return title
        }

        // Try to get the parent and its value (e.g., if we hit a word inside a text area)
        if let parent = attribute(element, kAXParentAttribute) {
            let parentElement = parent as! AXUIElement
            if let parentValue = attribute(parentElement, kAXValueAttribute) as? String, !parentValue.isEmpty {
                return parentValue
            }
        }

        return nil
    }

    /// Check if accessibility permissions are granted.
    var isAccessibilityEnabled: Bool {
        AXIsProcessTrusted()
    }

    /// Prompt the user to grant accessibility permissions.
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Helpers

    private func attribute(_ element: AXUIElement, _ attr: String) -> AnyObject? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attr as CFString, &value)
        return result == .success ? value : nil
    }
}
