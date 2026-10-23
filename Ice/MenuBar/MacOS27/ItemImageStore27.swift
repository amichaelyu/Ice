//
//  ItemImageStore27.swift
//  Ice
//

import AppKit
import OSLog
import ScreenCaptureKit

/// Images of menu bar items on macOS 27, captured from the active menu bar.
///
/// MenuBarAgent draws every item into one bar window per display, so Ice's per-item window
/// captures are gone. Captured alone on transparency, that window holds the application
/// menu and every drawn item on a clear background (measured on macOS 27.0.1), so each
/// item is cropped out as it is. When the window cannot be found or captured, the display's
/// menu bar strip is captured instead and the bar behind each glyph is cut away. Items on an
/// inactive bar are drawn dimmer, so only the active bar is captured. Images are kept on
/// disk, so an item that is concealed still has one.
@available(macOS 27.0, *)
@MainActor
final class ItemImageStore27 {
    typealias CapturedImage = MenuBarItemImageCache.CapturedImage

    private struct IndexEntry: Codable {
        let fileName: String
        let scale: CGFloat
        /// Whether the tile was cut from a capture of the display, so it may still hold the bar.
        let cutFromBar: Bool
    }

    /// Bumped when stored images change shape, so older tiles are captured again.
    private static let storeVersion = "10"

    /// The margin left on each side of a glyph, in points, so items are spaced evenly and
    /// with the menu bar's own rhythm: its glyphs sit 18 to 29 points apart, median 22
    /// (measured on macOS 27.0), which is twice this margin.
    private static let glyphMargin: CGFloat = 11

    private let logger = Logger(category: "ItemImageStore27")
    private let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Ice/ItemImages", isDirectory: true)
    private var index = [String: IndexEntry]()
    private var loaded = [String: CapturedImage]()
    private var photoSchedule = PhotoSchedule27()

    /// The capture under way, so captures follow one another instead of overlapping.
    private var captureTask: Task<Void, Never>?

    /// Counts the captures started, so only the last one clears ``captureTask``.
    private var captureGeneration = 0

    /// When the last capture finished, so a fresh one is not taken of an unchanged bar.
    private var lastCaptureFinishedAt: ContinuousClock.Instant?

    /// How long the images just captured stand before the bar is worth capturing again.
    private static let captureFreshness = Duration.milliseconds(700)

    private var appearanceObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?

    /// MenuBarAgent's bar window on the display last captured, kept so it is not looked up
    /// again for every capture.
    private var barWindow: (displayID: CGDirectDisplayID, window: SCWindow)?

    /// Whether the last capture came from the bar window, so a change of path is logged once.
    private var capturedBarWindow: Bool?

    init() {
        let versionFile = directory.appendingPathComponent("version.txt")
        if (try? String(contentsOf: versionFile, encoding: .utf8)) == Self.storeVersion {
            if
                let data = try? Data(contentsOf: directory.appendingPathComponent("index.json")),
                let stored = try? JSONDecoder().decode([String: IndexEntry].self, from: data)
            {
                index = stored
            }
        } else {
            try? FileManager.default.removeItem(at: directory)
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.barWindow = nil
            }
        }
        // Glyphs are stored in the colour that suits the current appearance, so a switch
        // between light and dark needs them captured again.
        appearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: DistributedNotificationCenter.interfaceThemeChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.discardImages()
            }
        }
    }

    /// Drops every stored image, so they are captured again.
    private func discardImages() {
        loaded.removeAll()
        index.removeAll()
        photoSchedule = PhotoSchedule27()
        let directory = directory
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: directory)
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
        guard !entry.cutFromBar || isUsable(cgImage, key: key) else {
            // Stored before this check existed, or stored against a wallpaper that defeated it.
            // Forgetting it is what lets `photographMissing` take the item again.
            index[key] = nil
            let fileName = entry.fileName
            let directory = directory
            Task.detached(priority: .utility) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName))
            }
            writeIndex()
            return nil
        }
        let image = CapturedImage(cgImage: cgImage, scale: entry.scale)
        loaded[key] = image
        return image
    }

    /// The owning application's icon, drawn at the size of a menu bar item, for an item that has
    /// no photograph.
    ///
    /// An item macOS folds away behind its « is drawn nowhere and cannot be photographed, and on
    /// a crowded notched bar that can be every item of a section. With no image for any of them,
    /// the layout window showed "Unable to display menu bar items" in the section's place, and
    /// the items could not be dragged out of it. The icon is marked as a stand-in and never
    /// stored, so ``photographMissing(items:appState:)`` still goes after the item, and the
    /// first photograph replaces it.
    func standInImage(for item: MenuBarItem) -> CapturedImage? {
        guard let application = item.sourceApplication, let bundleID = application.bundleIdentifier else {
            return nil
        }
        if let image = standIns[bundleID] {
            return image
        }
        guard let icon = application.icon ?? application.bundleURL.map({ NSWorkspace.shared.icon(forFile: $0.path) }) else {
            return nil
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let size = CGSize(width: Self.standInIconSize + Self.glyphMargin * 2, height: Self.standInTileHeight)
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int((size.width * scale).rounded()),
                pixelsHigh: Int((size.height * scale).rounded()),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ),
            let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else {
            return nil
        }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        icon.draw(
            in: CGRect(
                x: Self.glyphMargin,
                y: (size.height - Self.standInIconSize) / 2,
                width: Self.standInIconSize,
                height: Self.standInIconSize
            ),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        guard let cgImage = bitmap.cgImage else {
            return nil
        }
        let image = CapturedImage(cgImage: cgImage, scale: scale, isStandIn: true)
        standIns[bundleID] = image
        return image
    }

    /// The side of a stand-in icon, about the height of a menu bar glyph.
    private static let standInIconSize: CGFloat = 16

    /// The height of a photographed tile, which is the item's own (measured on macOS 27.0: 24 points).
    private static let standInTileHeight: CGFloat = 24

    /// Stand-in icons already drawn, by bundle identifier.
    private var standIns = [String: CapturedImage]()

    /// Captures the active menu bar and stores the images of the items drawn on it.
    /// Captures follow one another rather than overlapping: a single reveal set four of them
    /// going at once, 260–290 ms each (measured 2026-09-16), all asking the display server
    /// for the same strip while MenuBarAgent was animating the bar.
    func captureActiveMenuBar(appState: AppState, force: Bool = false) async {
        if !force {
            // A capture already under way photographs the same bar this caller wants.
            if let captureTask {
                await captureTask.value
                return
            }
            // And one that has just been taken still describes it.
            if let last = lastCaptureFinishedAt, ContinuousClock.now - last < Self.captureFreshness {
                return
            }
        }
        captureGeneration += 1
        let generation = captureGeneration
        let previous = captureTask
        let task = Task { [weak self] in
            await previous?.value
            await self?.performCapture(appState: appState)
        }
        captureTask = task
        await task.value
        if captureGeneration == generation {
            captureTask = nil
        }
    }

    private func performCapture(appState: AppState) async {
        // The bar animates for about 250 ms after concealment changes. A capture taken then
        // photographs items in mid-slide, which are thrown away as unsettled anyway, and adds
        // its own load at the moment the animation can least afford it.
        if let remaining = appState.concealer27.timeUntilSettled() {
            try? await Task.sleep(for: remaining)
        }
        let started = ProcessInfo.processInfo.systemUptime
        logger.debug("Menu bar capture: started")
        defer {
            lastCaptureFinishedAt = .now
            logger.debug("Menu bar capture: took \((ProcessInfo.processInfo.systemUptime - started) * 1000, privacy: .public) ms")
        }
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
        // Only items that sat still through the capture are stored. See `settledTags`.
        func frames(_ items: [MenuBarItem]) -> [String: CGRect] {
            Dictionary(items.map { ($0.tag.description, $0.bounds) }, uniquingKeysWith: { first, _ in first })
        }
        let fromBarWindow = await captureBarWindow(displayID: displayID, displayBounds: displayBounds)
        if capturedBarWindow != (fromBarWindow != nil) {
            capturedBarWindow = fromBarWindow != nil
            logger.notice("Capturing menu bar items from \(fromBarWindow != nil ? "MenuBarAgent's bar window" : "the display", privacy: .public)")
        }
        if let fromBarWindow {
            let (barImage, windowFrame, scale) = fromBarWindow
            let settled = ItemImages27.settledTags(before: frames(items), after: frames(await MenuBarItemProvider27.items()))
            var skipped = 0
            var stored = 0
            for item in items where item.isOnScreen && !item.isControlItem && !concealedPIDs.contains(item.ownerPID) {
                guard settled.contains(item.tag.description) else {
                    skipped += 1
                    continue
                }
                guard
                    let rect = ItemImages27.cropRect(itemFrame: item.bounds, stripFrame: windowFrame, scale: scale),
                    let image = barImage.cropping(to: rect),
                    let glyph = glyphOnTransparency(image, scale: scale)
                else {
                    continue
                }
                store(glyph, scale: scale, key: item.tag.description, cutFromBar: false)
                stored += 1
            }
            writeIndex()
            logger.debug("Stored \(stored, privacy: .public) item images from MenuBarAgent's bar window, skipped \(skipped, privacy: .public) that moved")
            return
        }
        guard let captured = await captureStrip(displayID: displayID, size: stripFrame.size) else {
            return
        }
        let (strip, scale) = captured
        let settled = ItemImages27.settledTags(before: frames(items), after: frames(await MenuBarItemProvider27.items()))
        var skipped = 0
        var stored = 0
        // MenuBarAgent draws every glyph on a bar in one colour, white or black. Deciding which
        // for the whole strip, rather than tile by tile, keeps a dark patch of wallpaper behind
        // one item from passing for its glyph (see `ItemImages27.toneVotes`).
        var votes = (light: 0, dark: 0)
        for item in items where item.isOnScreen && !item.isControlItem && !concealedPIDs.contains(item.ownerPID) {
            guard
                settled.contains(item.tag.description),
                let rect = ItemImages27.cropRect(itemFrame: item.bounds, stripFrame: stripFrame, scale: scale),
                let crop = strip.cropping(to: rect),
                let pixels = Self.pixels(of: crop)
            else {
                continue
            }
            let tileVotes = ItemImages27.toneVotes(pixels: pixels, width: crop.width, height: crop.height)
            votes.light += tileVotes.light
            votes.dark += tileVotes.dark
        }
        let tone: ItemImages27.GlyphTone? = votes.light + votes.dark == 0 ? nil : (votes.light >= votes.dark ? .light : .dark)
        for item in items where item.isOnScreen && !item.isControlItem && !concealedPIDs.contains(item.ownerPID) {
            guard settled.contains(item.tag.description) else {
                skipped += 1
                continue
            }
            guard
                let rect = ItemImages27.cropRect(itemFrame: item.bounds, stripFrame: stripFrame, scale: scale),
                let image = strip.cropping(to: rect),
                let glyph = withoutBackground(image, scale: scale, tone: tone)
            else {
                continue
            }
            store(glyph, scale: scale, key: item.tag.description, cutFromBar: true)
            stored += 1
        }
        writeIndex()
        logger.debug("Stored \(stored, privacy: .public) item images from display \(displayID, privacy: .public), skipped \(skipped, privacy: .public) that moved")
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
        // One application at a time, waiting for each capture before revealing the next.
        // Revealed together (measured 2026-09-17) thirteen items no longer fitted the narrow
        // built-in bar and macOS folded nine of them into its own overflow, where they cannot
        // be photographed at all. Revealed in a burst without waiting, they were caught
        // mid-fade instead: the concealment applies behind them were still landing a second
        // and a half later, long after the capture judged the bar settled.
        for bundleID in bundleIDs.sorted().prefix(Self.photographsPerPass) {
            appState.concealer27.showTemporarily(bundleID: bundleID)
            // A shown item is drawn 0.4–0.6 s after its application is allowed (measured).
            try? await Task.sleep(for: .milliseconds(600))
            // Forced: this capture is the point of having shown the application at all, so it
            // must not be answered by one taken before the item appeared.
            await captureActiveMenuBar(appState: appState, force: true)
            appState.concealer27.endTemporaryShow(bundleID: bundleID)
            // Only an application that came away with an image counts as photographed. One
            // whose tile was refused, or whose item macOS folded away, would otherwise wait
            // out the full ten minutes with no glyph at all in the Ice Bar.
            photoSchedule.recordAttempt(
                bundleID: bundleID,
                now: ProcessInfo.processInfo.systemUptime,
                stored: hasImage(forBundleID: bundleID)
            )
        }
    }

    /// How many applications one pass photographs, so a first run does not spend a minute
    /// revealing items one after another.
    private static let photographsPerPass = 6

    /// Whether any of the application's items has a stored image.
    private func hasImage(forBundleID bundleID: String) -> Bool {
        index.keys.contains { $0.hasPrefix(bundleID + ":") }
    }

    // MARK: Private

    /// MenuBarAgent's bar window, which ScreenCaptureKit lists as off screen.
    private static let menuBarAgentID = "com.apple.MenuBarAgent"
    private static let barWindowLayer = 24

    /// Captures MenuBarAgent's bar window on the display alone, on transparency, with its frame
    /// in global points and the capture's scale; `nil` when the window cannot be told apart or
    /// the capture fails or comes back empty.
    private func captureBarWindow(
        displayID: CGDirectDisplayID,
        displayBounds: CGRect
    ) async -> (image: CGImage, frame: CGRect, scale: CGFloat)? {
        if barWindow?.displayID != displayID {
            barWindow = nil
        }
        do {
            let window: SCWindow
            if let cached = barWindow?.window {
                window = cached
            } else {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                let candidates = content.windows.filter {
                    $0.owningApplication?.bundleIdentifier == Self.menuBarAgentID && $0.windowLayer == Self.barWindowLayer
                }
                guard let index = ItemImages27.barWindowIndex(frames: candidates.map(\.frame), display: displayBounds) else {
                    return nil
                }
                window = candidates[index]
                barWindow = (displayID, window)
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            configuration.width = Int(window.frame.width * CGFloat(filter.pointPixelScale))
            configuration.height = Int(window.frame.height * CGFloat(filter.pointPixelScale))
            configuration.shouldBeOpaque = false
            configuration.ignoreShadowsSingleWindow = true
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            guard
                window.frame.width > 0,
                let pixels = Self.pixels(of: image),
                !ItemImages27.isClear(pixels: pixels)
            else {
                barWindow = nil
                return nil
            }
            return (image, window.frame, CGFloat(image.width) / window.frame.width)
        } catch {
            barWindow = nil
            logger.error("Could not capture MenuBarAgent's bar window: \(error, privacy: .public)")
            return nil
        }
    }

    private func captureStrip(displayID: CGDirectDisplayID, size: CGSize) async -> (CGImage, CGFloat)? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                return nil
            }
            // Ice's own windows are left out of the capture. The camera and microphone indicator
            // is drawn beside the items, so without this it was photographed as if it were one of
            // them: two of the Ice Bar's tiles came back as an orange microphone.
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let ownWindows = content.windows.filter { $0.owningApplication?.processID == ownPID }
            let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
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

    /// The colour glyphs are drawn in, which is the readable one on the flat background
    /// the Ice Bar and the layout window use.
    private static func glyphColor() -> (r: UInt8, g: UInt8, b: UInt8) {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark ? (255, 255, 255) : (0, 0, 0)
    }

    /// The image's pixels, four bytes each, as the image rules expect them.
    private static func pixels(of image: CGImage) -> [UInt8]? {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? data : nil
    }

    /// The image with the menu bar behind the glyph made transparent, the glyph recoloured
    /// for the panel, and the bar's own padding replaced by an even margin.
    private func withoutBackground(_ image: CGImage, scale: CGFloat, tone: ItemImages27.GlyphTone?) -> CGImage? {
        let width = image.width
        let height = image.height
        let count = width * height * 4
        let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        defer { bytes.deallocate() }
        bytes.initialize(repeating: 0, count: count)
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = Array(UnsafeBufferPointer(start: bytes, count: count))
        let background = ItemImages27.backgroundColor(pixels: pixels, width: width, height: height)
        let removed = ItemImages27.removingBackground(pixels: pixels, width: width, height: height, background: background, tone: tone)
        // An item caught mid-fade cannot be rescued by any background estimate: what is left
        // is a faint glyph inside a wide haze of bar, and storing it is what made the Ice
        // Bar's icons pale and too wide. Refuse the tile; the item is photographed again
        // later, standing still. This comes before faint marks are dropped, or a faded glyph
        // would be dropped whole and stored as an empty tile.
        if ItemImages27.isFaded(pixels: removed, width: width, height: height) {
            logger.debug("Refusing a tile of an item caught mid-fade")
            return nil
        }
        // Wallpaper detail in the glyph's own colour survives the colour test; marks that
        // never reach solid are dropped whole, so the trim below does not keep them either.
        var keyed = ItemImages27.tinted(
            pixels: ItemImages27.droppingFaintMarks(pixels: removed, width: width, height: height),
            colour: Self.glyphColor()
        )
        // The bitmap holds premultiplied colours, so each channel follows the new opacity.
        for index in stride(from: 0, to: count, by: 4) {
            let opacity = Double(keyed[index + 3]) / 255
            for channel in 0..<3 {
                keyed[index + channel] = UInt8((Double(keyed[index + channel]) * opacity).rounded())
            }
        }
        keyed.withUnsafeMutableBytes { buffer in
            bytes.update(from: buffer.bindMemory(to: UInt8.self).baseAddress!, count: count)
        }
        guard let keyedImage = context.makeImage() else {
            return nil
        }
        return Self.padded(keyedImage, pixels: keyed, scale: scale)
    }

    /// An item cropped from MenuBarAgent's bar window, which is already a glyph on transparency,
    /// recoloured for the panel if it is a template glyph and given an even margin.
    private func glyphOnTransparency(_ image: CGImage, scale: CGFloat) -> CGImage? {
        guard let raw = Self.pixels(of: image) else {
            return nil
        }
        if ItemImages27.isFaded(pixels: raw, width: image.width, height: image.height) {
            logger.debug("Refusing a tile of an item caught mid-fade")
            return nil
        }
        var pixels = ItemImages27.clearingFaintAlpha(pixels: raw)
        // Colour icons come through intact and keep their colours.
        if ItemImages27.isMonochrome(pixels: pixels) {
            let tinted = ItemImages27.tinted(pixels: pixels, colour: Self.glyphColor())
            for index in stride(from: 0, to: pixels.count, by: 4) {
                let opacity = Double(tinted[index + 3]) / 255
                for channel in 0..<3 {
                    pixels[index + channel] = UInt8((Double(tinted[index + channel]) * opacity).rounded())
                }
            }
        }
        guard let cleared = Self.image(fromPixels: pixels, width: image.width, height: image.height) else {
            return nil
        }
        return Self.padded(cleared, pixels: pixels, scale: scale)
    }

    /// Premultiplied pixels as an image.
    private static func image(fromPixels pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        var pixels = pixels
        return pixels.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        }
    }

    /// The glyph in the image, given as its pixels too, drawn into a fresh tile with an even margin
    /// on either side; `nil` when nothing is drawn.
    ///
    /// A fresh tile rather than a crop with margins, because a capture often ends right at the
    /// glyph's edge and then cropping has no room left.
    private static func padded(_ image: CGImage, pixels: [UInt8], scale: CGFloat) -> CGImage? {
        let height = image.height
        guard let columns = ItemImages27.glyphColumns(pixels: pixels, width: image.width, height: height) else {
            return nil
        }
        let margin = Int((glyphMargin * scale).rounded())
        let glyphWidth = columns.upperBound - columns.lowerBound + 1
        let paddedWidth = glyphWidth + margin * 2
        guard
            let glyph = image.cropping(to: CGRect(x: columns.lowerBound, y: 0, width: glyphWidth, height: height)),
            let padded = CGContext(
                data: nil,
                width: paddedWidth,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: paddedWidth * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return image
        }
        padded.draw(glyph, in: CGRect(x: margin, y: 0, width: glyphWidth, height: height))
        return padded.makeImage() ?? image
    }

    /// Whether a finished tile is a glyph on transparency rather than a piece of the bar.
    ///
    /// Checked both when a tile is stored and when a stored one is first read back. A tile that
    /// kept the bar used to stay for good: `photographMissing` only photographs items with no
    /// image at all, so nothing ever replaced it, and on a notched Mac opening the layout window
    /// does not help either — macOS folds most items away and they cannot be photographed there.
    /// Three such tiles stood for a week on @jasonsmithio's machine (jordanbaird/Ice#995).
    private func isUsable(_ image: CGImage, key: String) -> Bool {
        guard let pixels = Self.pixels(of: image) else {
            return true
        }
        guard ItemImages27.keepsTheBar(pixels: pixels, width: image.width, height: image.height) else {
            return true
        }
        logger.notice("Refusing a tile of \(key, privacy: .public): the bar is still behind the glyph")
        return false
    }

    private func store(_ image: CGImage, scale: CGFloat, key: String, cutFromBar: Bool) {
        guard !cutFromBar || isUsable(image, key: key) else {
            return
        }
        let fileName = ItemImages27.fileName(forTag: key)
        loaded[key] = CapturedImage(cgImage: image, scale: scale)
        index[key] = IndexEntry(fileName: fileName, scale: scale, cutFromBar: cutFromBar)
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
        let version = Self.storeVersion
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: directory.appendingPathComponent("index.json"), options: .atomic)
            try? version.write(to: directory.appendingPathComponent("version.txt"), atomically: true, encoding: .utf8)
        }
    }
}
