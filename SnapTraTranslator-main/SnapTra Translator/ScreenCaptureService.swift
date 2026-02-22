import AppKit
import Foundation
import ScreenCaptureKit

struct CaptureRegion {
    var rect: CGRect
    var screen: NSScreen
    var displayID: CGDirectDisplayID
    var scaleFactor: CGFloat
}

final class ScreenCaptureService {
    let captureSize = CGSize(width: 520, height: 140)

    // Store SCDisplay as Any? to avoid ScreenCaptureKit type reference at property level
    private var _cachedDisplay: Any?
    private var cachedDisplayID: CGDirectDisplayID?
    private var lastCacheTime: Date?
    private let cacheExpiration: TimeInterval = 5.0

    func captureAroundCursor() async -> (image: CGImage, region: CaptureRegion)? {
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) else {
            return nil
        }
        guard let displayNumber = screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        let displayID = CGDirectDisplayID(displayNumber.int32Value)
        let scaleFactor = screen.backingScaleFactor
        let rectInScreen = captureRect(for: mouseLocation, in: screen.frame, size: captureSize)

        if #available(macOS 14.0, *) {
            return await captureWithScreenCaptureKit(
                rectInScreen: rectInScreen,
                screen: screen,
                displayID: displayID,
                scaleFactor: scaleFactor
            )
        } else {
            return captureWithCGWindowList(
                rectInScreen: rectInScreen,
                screen: screen,
                displayID: displayID,
                scaleFactor: scaleFactor
            )
        }
    }

    func invalidateCache() {
        _cachedDisplay = nil
        cachedDisplayID = nil
        lastCacheTime = nil
    }

    // MARK: - macOS 14+ ScreenCaptureKit path

    @available(macOS 14.0, *)
    private func captureWithScreenCaptureKit(
        rectInScreen: CGRect,
        screen: NSScreen,
        displayID: CGDirectDisplayID,
        scaleFactor: CGFloat
    ) async -> (image: CGImage, region: CaptureRegion)? {
        let cgRect = convertToDisplayLocalCoordinates(rectInScreen, screen: screen)
        do {
            let display = try await getDisplay(for: displayID)
            guard let display else { return nil }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = makeConfiguration(for: cgRect, scaleFactor: scaleFactor)
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            return (image, CaptureRegion(rect: rectInScreen, screen: screen, displayID: displayID, scaleFactor: scaleFactor))
        } catch {
            return nil
        }
    }

    @available(macOS 14.0, *)
    private func getDisplay(for displayID: CGDirectDisplayID) async throws -> SCDisplay? {
        let now = Date()
        if let cached = _cachedDisplay as? SCDisplay,
           let cachedID = cachedDisplayID,
           cachedID == displayID,
           let cacheTime = lastCacheTime,
           now.timeIntervalSince(cacheTime) < cacheExpiration {
            return cached
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            return nil
        }

        _cachedDisplay = display
        cachedDisplayID = displayID
        lastCacheTime = now
        return display
    }

    @available(macOS 14.0, *)
    private func makeConfiguration(for rect: CGRect, scaleFactor: CGFloat) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = rect
        let pixelWidth = Int(rect.width * scaleFactor)
        let pixelHeight = Int(rect.height * scaleFactor)
        configuration.width = pixelWidth
        configuration.height = pixelHeight
        configuration.queueDepth = 1
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        return configuration
    }

    // MARK: - Pre-macOS 14 fallback using CGWindowListCreateImage

    private func captureWithCGWindowList(
        rectInScreen: CGRect,
        screen: NSScreen,
        displayID: CGDirectDisplayID,
        scaleFactor: CGFloat
    ) -> (image: CGImage, region: CaptureRegion)? {
        let cgRect = convertToGlobalDisplayCoordinates(rectInScreen)
        guard let image = CGWindowListCreateImage(
            cgRect,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution]
        ) else {
            return nil
        }
        return (image, CaptureRegion(rect: rectInScreen, screen: screen, displayID: displayID, scaleFactor: scaleFactor))
    }

    // MARK: - Coordinate helpers

    private func captureRect(for point: CGPoint, in screenFrame: CGRect, size: CGSize) -> CGRect {
        let origin = CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        let rawRect = CGRect(origin: origin, size: size)
        return rawRect.intersection(screenFrame)
    }

    /// Convert NSScreen coordinates (bottom-left origin) to display-local coordinates (top-left origin)
    /// Used by ScreenCaptureKit path
    private func convertToDisplayLocalCoordinates(_ rect: CGRect, screen: NSScreen) -> CGRect {
        let screenFrame = screen.frame
        let localX = rect.minX - screenFrame.minX
        let localY = rect.minY - screenFrame.minY
        let flippedY = screenFrame.height - (localY + rect.height)
        return CGRect(x: localX, y: flippedY, width: rect.width, height: rect.height)
    }

    /// Convert NSScreen coordinates (bottom-left origin) to global CG display coordinates (top-left origin)
    /// Used by CGWindowListCreateImage fallback
    private func convertToGlobalDisplayCoordinates(_ rect: CGRect) -> CGRect {
        guard let mainScreen = NSScreen.screens.first else { return rect }
        let mainHeight = mainScreen.frame.height
        return CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}
