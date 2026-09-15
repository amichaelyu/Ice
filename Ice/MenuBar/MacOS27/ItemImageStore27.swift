//
//  ItemImageStore27.swift
//  Ice
//

import AppKit
import OSLog
import ScreenCaptureKit

/// Images of menu bar items on macOS 27, captured from the active menu bar.
///
/// MenuBarAgent draws every item into one menu bar, so Ice's per-item window captures
/// are gone. Only a capture of the display holds the glyphs (measured on macOS 27.0: a
/// capture of MenuBarAgent's bar window holds just the application menu), and it
/// includes the bar's background. Images keep that background, and the Ice Bar and the
/// layout window take their colour from the same capture. Items on an inactive bar are
/// drawn dimmer, so only the active bar is captured. Images are kept on disk, so an item
/// that is concealed still has one.
@available(macOS 27.0, *)
@MainActor
final class ItemImageStore27 {
    typealias CapturedImage = MenuBarItemImageCache.CapturedImage

    private struct IndexEntry: Codable {
        let fileName: String
        let scale: CGFloat
    }

    private let logger = Logger(category: "ItemImageStore27")
    private let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Ice/ItemImages", isDirectory: true)
    private var index = [String: IndexEntry]()
    private var loaded = [String: CapturedImage]()
    private var photoSchedule = PhotoSchedule27()

    /// The colour of the active menu bar's background, from the last capture.
    private(set) var barColor: CGColor?

    init() {
        if
            let data = try? Data(contentsOf: directory.appendingPathComponent("index.json")),
            let stored = try? JSONDecoder().decode([String: IndexEntry].self, from: data)
        {
            index = stored
        }
    }

    /// The stored image of the given item, if there is one.
    func image(for item: MenuBarItem) -> CapturedImage? {
        let key = item.tag.description
        if let image = loaded[key] {
            return image
        }
        guard
            let entry = index[key],
            let source = CGImageSourceCreateWithURL(directory.appendingPathComponent(entry.fileName) as CFURL, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return nil
        }
        let image = CapturedImage(cgImage: cgImage, scale: entry.scale)
        loaded[key] = image
        return image
    }

    /// Captures the active menu bar and stores the images of the items drawn on it.
    func captureActiveMenuBar(appState: AppState) async {
        guard
            ScreenCapture.cachedCheckPermissions(),
            let displayID = Bridging.getActiveMenuBarDisplayID(),
            let screen = NSScreen.screens.first(where: { $0.displayID == displayID })
        else {
            return
        }
        let displayBounds = CGDisplayBounds(displayID)
        let barHeight = max(screen.frame.maxY - screen.visibleFrame.maxY, 22)
        let stripFrame = CGRect(x: displayBounds.minX, y: displayBounds.minY, width: displayBounds.width, height: barHeight)
        let items = await MenuBarItemProvider27.items()
        let concealedPIDs = appState.concealer27.concealedPIDs
        guard let captured = await captureStrip(displayID: displayID, size: stripFrame.size) else {
            return
        }
        let (strip, scale) = captured
        if let topRow = strip.cropping(to: CGRect(x: 0, y: 0, width: strip.width, height: max(1, Int(scale)))) {
            barColor = topRow.averageColor(option: .ignoreAlpha)
        }
        var stored = 0
        for item in items where item.isOnScreen && !item.isControlItem && !concealedPIDs.contains(item.ownerPID) {
            guard
                let rect = ItemImages27.cropRect(itemFrame: item.bounds, stripFrame: stripFrame, scale: scale),
                let image = strip.cropping(to: rect)
            else {
                continue
            }
            store(image, scale: scale, key: item.tag.description)
            stored += 1
        }
        writeIndex()
        logger.debug("Stored \(stored, privacy: .public) item images from display \(displayID, privacy: .public)")
    }

    /// Shows the applications of items that have no image for a moment, and captures them.
    func photographMissing(items: [MenuBarItem], appState: AppState) async {
        let now = ProcessInfo.processInfo.systemUptime
        let bundleIDs = Set(items.compactMap { item -> String? in
            guard !item.isControlItem, image(for: item) == nil else {
                return nil
            }
            return item.sourceApplication?.bundleIdentifier
        })
        .filter { photoSchedule.mayPhotograph(bundleID: $0, now: now) }
        guard !bundleIDs.isEmpty else {
            return
        }
        for bundleID in bundleIDs {
            photoSchedule.recordAttempt(bundleID: bundleID, now: now)
            appState.concealer27.showTemporarily(bundleID: bundleID)
        }
        // A shown item is drawn 0.4–0.6 s after its application is allowed (measured).
        try? await Task.sleep(for: .milliseconds(600))
        await captureActiveMenuBar(appState: appState)
        for bundleID in bundleIDs {
            appState.concealer27.endTemporaryShow(bundleID: bundleID)
        }
    }

    // MARK: Private

    private func captureStrip(displayID: CGDirectDisplayID, size: CGSize) async -> (CGImage, CGFloat)? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                return nil
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let scale = CGFloat(filter.pointPixelScale)
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = CGRect(origin: .zero, size: size)
            configuration.width = Int(size.width * scale)
            configuration.height = Int(size.height * scale)
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            return (image, scale)
        } catch {
            logger.error("Could not capture the menu bar: \(error, privacy: .public)")
            return nil
        }
    }

    private func store(_ image: CGImage, scale: CGFloat, key: String) {
        let fileName = ItemImages27.fileName(forTag: key)
        loaded[key] = CapturedImage(cgImage: image, scale: scale)
        index[key] = IndexEntry(fileName: fileName, scale: scale)
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            return
        }
        let directory = directory
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
        }
    }

    private func writeIndex() {
        guard let data = try? JSONEncoder().encode(index) else {
            return
        }
        let directory = directory
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: directory.appendingPathComponent("index.json"), options: .atomic)
        }
    }
}
