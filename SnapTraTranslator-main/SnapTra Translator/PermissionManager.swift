import AppKit
import ApplicationServices
import Combine
import Foundation
import ScreenCaptureKit

struct PermissionStatus: Equatable {
    var screenRecording: Bool
}

@MainActor
final class PermissionManager: ObservableObject {
    @Published private(set) var status: PermissionStatus = PermissionStatus(screenRecording: false)

    /// Tracks whether CGRequestScreenCaptureAccess() has already been called
    /// this session.  Calling it more than once triggers a redundant system
    /// dialog (especially on macOS 14.4+) that asks the user to quit & reopen
    /// even after they've already granted permission.
    private var hasRequestedThisSession = false

    func refreshStatus() {
        Task { await refreshStatusAsync() }
    }

    func refreshStatusAsync() async {
        let screenRecordingAllowed = await screenRecordingStatus()
        status = PermissionStatus(screenRecording: screenRecordingAllowed)
    }

    func requestAndOpenScreenRecording() {
        // Only call CGRequestScreenCaptureAccess() ONCE per session and only
        // when permission is not yet granted.  This adds the app to the Screen
        // Recording list in System Settings.  After the first call we just open
        // Settings and let the user toggle the switch & restart.
        if !hasRequestedThisSession && !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            hasRequestedThisSession = true
        }
        openScreenRecordingSettings()
        refreshAfterDelay()
    }

    func openScreenRecordingSettings() {
        openPrivacyPane(anchor: "Privacy_ScreenCapture")
    }

    private func openPrivacyPane(anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + anchor) {
            NSWorkspace.shared.open(url)
        }
    }

    private func screenRecordingStatus() async -> Bool {
        return CGPreflightScreenCaptureAccess()
    }

    private func refreshAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.refreshStatus()
        }
    }
}
