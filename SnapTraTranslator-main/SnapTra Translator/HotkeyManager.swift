import AppKit
import Foundation

final class HotkeyManager {
    var onTrigger: (() -> Void)?
    var onRelease: (() -> Void)?

    /// Optional modifier flag that is allowed alongside the hotkey
    /// (used for paragraph translation mode).
    var allowedAdditionalModifier: NSEvent.ModifierFlags?

    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var globalKeyDownMonitor: Any?
    private var localKeyDownMonitor: Any?
    private var isSingleKeyDown = false
    private var activeSingleKey: SingleKey?
    private var pendingRelease: DispatchWorkItem?
    private var pendingTrigger: DispatchWorkItem?
    private let releaseConfirmationDelay: TimeInterval = 0.15
    /// Delay before firing trigger — if a non-modifier key arrives within
    /// this window, the trigger is suppressed entirely.
    private let triggerDelay: TimeInterval = 0.12
    /// True when a non-modifier key is held while the modifier is down
    /// — suppresses translation trigger.
    private var nonModifierKeyHeld = false
    /// True after onTrigger has actually been called (past the delay).
    private var triggerFired = false

    func start(singleKey: SingleKey) {
        stop()
        guard singleKey != .none else { return }
        activeSingleKey = singleKey
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
        // Monitor key-down / key-up so we can detect when non-modifier keys
        // are pressed alongside the modifier.
        globalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            self?.handleKeyEvent(event)
        }
        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            self?.handleKeyEvent(event)
            return event
        }
    }

    func stop() {
        pendingRelease?.cancel()
        pendingRelease = nil
        pendingTrigger?.cancel()
        pendingTrigger = nil
        if let m = globalFlagsMonitor { NSEvent.removeMonitor(m); globalFlagsMonitor = nil }
        if let m = localFlagsMonitor { NSEvent.removeMonitor(m); localFlagsMonitor = nil }
        if let m = globalKeyDownMonitor { NSEvent.removeMonitor(m); globalKeyDownMonitor = nil }
        if let m = localKeyDownMonitor { NSEvent.removeMonitor(m); localKeyDownMonitor = nil }
        isSingleKeyDown = false
        activeSingleKey = nil
        nonModifierKeyHeld = false
        triggerFired = false
    }

    /// Track non-modifier key presses so we can suppress translation when
    /// the user is performing a regular shortcut (e.g. Ctrl+C).
    private func handleKeyEvent(_ event: NSEvent) {
        guard isSingleKeyDown else { return }
        if event.type == .keyDown {
            nonModifierKeyHeld = true
            // Cancel pending trigger if it hasn't fired yet
            pendingTrigger?.cancel()
            pendingTrigger = nil
            // If trigger already fired, cancel it immediately
            if triggerFired {
                triggerFired = false
                isSingleKeyDown = false
                onRelease?()
            }
        }
        // We reset nonModifierKeyHeld when the modifier itself is re-evaluated
        // in handleFlagsChanged, not on keyUp, to avoid edge-cases.
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard let key = activeSingleKey, key != .none else {
            return
        }
        let keyCode = Int64(event.keyCode)
        let expectedKeyCode = Int64(SingleKeyMapping.keyCode(for: key))

        let targetFlag = SingleKeyMapping.modifierFlag(for: key)
        let eventFlags = event.modifierFlags
        let isTargetFlagPresent = eventFlags.contains(targetFlag)

        if isTargetFlagPresent {
            pendingRelease?.cancel()
            pendingRelease = nil
        }
        if isTargetFlagPresent && !isSingleKeyDown {
            guard keyCode == expectedKeyCode else {
                return
            }
            let relevantFlags: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
            var otherFlags = eventFlags.intersection(relevantFlags).subtracting(targetFlag)
            // Allow paragraph modifier to be held alongside the hotkey
            if let allowed = allowedAdditionalModifier {
                otherFlags = otherFlags.subtracting(allowed)
            }
            guard otherFlags.isEmpty else {
                return
            }
            // Reset the non-modifier tracking on fresh trigger
            nonModifierKeyHeld = false
            triggerFired = false
            isSingleKeyDown = true

            // Delay trigger so we can detect modifier+key combos before firing
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                guard self.isSingleKeyDown, !self.nonModifierKeyHeld else { return }
                self.triggerFired = true
                self.onTrigger?()
            }
            pendingTrigger?.cancel()
            pendingTrigger = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + triggerDelay, execute: workItem)
        } else if !isTargetFlagPresent && isSingleKeyDown {
            // Modifier released
            pendingTrigger?.cancel()
            pendingTrigger = nil
            let didFire = triggerFired
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                guard !NSEvent.modifierFlags.contains(targetFlag) else { return }
                guard self.isSingleKeyDown else { return }
                self.isSingleKeyDown = false
                self.nonModifierKeyHeld = false
                self.triggerFired = false
                if didFire {
                    self.onRelease?()
                }
            }
            pendingRelease?.cancel()
            pendingRelease = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + releaseConfirmationDelay, execute: workItem)
        }
    }
}
