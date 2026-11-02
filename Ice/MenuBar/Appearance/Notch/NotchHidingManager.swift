//
//  NotchHidingManager.swift
//  Ice
//

import AppKit
import Combine
import OSLog

/// A manager that hides the notch by rewriting the desktop wallpaper.
///
/// For each target screen, the manager renders a copy of the user's wallpaper with a
/// solid black strip under the menu bar, and sets it as the desktop picture. It remembers
/// the user's original wallpaper per screen, regenerates when the user picks a new one,
/// and restores the original when the feature is turned off or the app quits.
///
/// macOS records a wallpaper for every space and every display it has seen, but Ice can
/// only change the one showing. A generated file therefore outlives the moment it was
/// set: a space or a disconnected display may still name it, and shows the stock macOS
/// wallpaper if it is gone. Generated files are named after what they were rendered from,
/// so that the same screen and wallpaper reuse the same file, and a file is deleted only
/// once macOS no longer names it.
@MainActor
final class NotchHidingManager: ObservableObject {
    /// The directory that generated wallpapers are written to.
    let outputDirectory = NotchHidingManager.applicationSupportDirectory
        .appendingPathComponent("Ice", isDirectory: true)
        .appendingPathComponent("NotchWallpapers", isDirectory: true)

    /// The directory that the standalone NotchHider app wrote its wallpapers to.
    ///
    /// Ice took over NotchHider's job. A wallpaper inside this directory is a black-bar
    /// copy that NotchHider made, never the user's real wallpaper, so it is treated as
    /// generated and never recorded as an original.
    private let legacyOutputDirectory = NotchHidingManager.applicationSupportDirectory
        .appendingPathComponent("NotchHider", isDirectory: true)

    /// The defaults domain of the standalone NotchHider app.
    private static let legacySuiteName = "com.michaelyu.NotchHider"

    /// The key under which NotchHider recorded the user's original wallpapers,
    /// as `[screenID: path]`.
    private static let legacyOriginalsKey = "originalWallpapers"

    /// The file in which macOS records the wallpaper of every space and display.
    private static let wallpaperStoreURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")

    /// The number of generated wallpapers kept, newest first, beyond those that are
    /// showing or that the wallpaper store names.
    private static let recentWallpaperLimit = 6

    /// The wallpaper macOS reports for a screen it has nothing usable to show on,
    /// while it draws its stock wallpaper there.
    ///
    /// Seen on macOS 27.0 (2026-11-02) for an external display as it was connected, with
    /// no trace of it in the wallpaper store: it is a fallback, not the user's choice.
    private static let fallbackWallpaperPath = "/System/Library/CoreServices/DefaultDesktop.heic"

    /// The user's Application Support directory.
    private nonisolated static var applicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    }

    /// The shared app state.
    private weak var appState: AppState?

    /// Observers of the settings, alive for the manager's lifetime.
    private var cancellables = Set<AnyCancellable>()

    /// The poll timer and system observers, alive only while the notch is hidden.
    private var activeCancellables = Set<AnyCancellable>()

    /// A Boolean value that indicates whether the screens changed and have not yet settled.
    ///
    /// While a display is being connected, its wallpaper may not be the one macOS will
    /// settle on, and recording it as the user's original would keep it for good.
    private var isReconfiguringScreens = false

    /// Logger for the notch hiding manager.
    private let logger = Logger(category: "NotchHidingManager")

    /// The notch settings.
    private var settings: NotchSettings? {
        appState?.settings.notch
    }

    /// A Boolean value that indicates whether the notch should be hidden.
    private var isEnabled: Bool {
        settings?.hideNotch ?? false
    }

    /// A Boolean value that indicates whether the poll timer and observers are running.
    private var isRunning: Bool {
        !activeCancellables.isEmpty
    }

    /// Performs the initial setup of the manager.
    func performSetup(with appState: AppState) {
        self.appState = appState
        configureCancellables()
    }

    /// Configures the observers of the settings.
    private func configureCancellables() {
        guard let settings else {
            return
        }

        var c = Set<AnyCancellable>()

        settings.$hideNotch
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hideNotch in
                guard let self else {
                    return
                }
                if hideNotch {
                    start()
                } else if isRunning {
                    stop()
                    restoreAll()
                }
            }
            .store(in: &c)

        settings.$notchMainDisplayOnly
            .combineLatest(settings.$notchRoundedCorners)
            .dropFirst()
            .removeDuplicates { $0 == $1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, isEnabled else {
                    return
                }
                applyAll()
            }
            .store(in: &c)

        cancellables = c
    }

    /// Applies the wallpapers and starts the poll timer and system observers.
    private func start() {
        applyAll()

        guard !isRunning else {
            return
        }

        var c = Set<AnyCancellable>()

        // Cheap periodic check for a wallpaper the user picked.
        Timer.publish(every: 2, tolerance: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.poll()
            }
            .store(in: &c)

        // A space may have its own wallpaper: check it right away.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.poll()
            }
            .store(in: &c)

        // Hold off polling until the screens settle.
        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                self?.isReconfiguringScreens = true
            }
            .store(in: &c)

        // Resolution or arrangement changed: regenerate at the new size. Screen
        // changes often arrive in bursts, so wait for them to settle.
        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: 0.5, scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else {
                    return
                }
                isReconfiguringScreens = false
                if isEnabled {
                    applyAll()
                } else {
                    poll()
                }
            }
            .store(in: &c)

        activeCancellables = c
        logger.info("Started hiding the notch")
    }

    /// Stops the poll timer and system observers.
    private func stop() {
        activeCancellables.removeAll()
        isReconfiguringScreens = false
        logger.info("Stopped hiding the notch")
    }

    /// Stops hiding the notch and puts the user's wallpapers back, for use
    /// when the app terminates.
    ///
    /// Does nothing if the notch is not being hidden, so that quitting Ice
    /// never touches a wallpaper it was not asked to change.
    func restoreForTermination() {
        guard isRunning else {
            return
        }
        stop()
        restoreAll()
    }

    // MARK: Screens

    /// Returns a Boolean value that indicates whether any screen has a notch.
    static var hasNotchedScreen: Bool {
        NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }
    }

    /// Returns a persistent identifier for the given screen.
    ///
    /// This is the display's UUID, which belongs to one monitor. The display number
    /// does not: macOS hands out the same small numbers to whichever displays are
    /// connected, so two monitors used at different times can share one.
    static func screenID(_ screen: NSScreen) -> String {
        if
            let uuid = CGDisplayCreateUUIDFromDisplayID(screen.displayID)?.takeRetainedValue(),
            let string = CFUUIDCreateString(nil, uuid)
        {
            return string as String
        }
        return legacyScreenID(screen)
    }

    /// Returns the identifier that Ice and NotchHider used for the given screen
    /// before identifying screens by UUID: the display number.
    private static func legacyScreenID(_ screen: NSScreen) -> String {
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return number.stringValue
        }
        return screen.localizedName
    }

    /// Returns the screen with the notch, or else the first screen.
    static func notchScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first
    }

    /// Returns the screens whose wallpaper should be rewritten.
    private func targetScreens() -> [NSScreen] {
        if settings?.notchMainDisplayOnly ?? true {
            return Self.notchScreen().map { [$0] } ?? []
        }
        return NSScreen.screens
    }

    /// Returns a Boolean value that indicates whether the given screen's
    /// wallpaper should be rewritten.
    private func isTarget(_ screen: NSScreen) -> Bool {
        let id = Self.screenID(screen)
        return targetScreens().contains { Self.screenID($0) == id }
    }

    // MARK: Persistence

    /// Returns the `[screenID: path]` dictionary stored under the given key.
    private func paths(forKey key: Defaults.Key) -> [String: String] {
        Defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    /// Sets the path for the given screen in the dictionary stored under the given key.
    private func setPath(_ path: String?, for screenID: String, forKey key: Defaults.Key) {
        var paths = paths(forKey: key)
        paths[screenID] = path
        Defaults.set(paths, forKey: key)
    }

    /// Records the given wallpaper, which Ice did not generate, as the user's original
    /// for the given screen.
    ///
    /// macOS's fallback wallpaper does not replace an original already recorded. Taken
    /// for the user's choice, it was put under the black strip and restored on quit.
    private func recordOriginal(_ url: URL, for screen: NSScreen) {
        let id = Self.screenID(screen)
        let recorded = paths(forKey: .notchOriginalWallpapers)[id]
        guard recorded != url.path else {
            return
        }
        if url.path == Self.fallbackWallpaperPath, original(for: screen) != nil {
            return
        }
        setPath(url.path, for: id, forKey: .notchOriginalWallpapers)
    }

    /// Returns the user's original wallpaper for the given screen.
    ///
    /// If Ice has not recorded one under the screen's UUID, falls back to the one
    /// recorded under its display number, first by Ice and then by the standalone
    /// NotchHider app. A user who switches from NotchHider to Ice has NotchHider's
    /// black-bar copy as their current wallpaper, and only NotchHider knows which
    /// wallpaper it replaced.
    private func original(for screen: NSScreen) -> URL? {
        let originals = paths(forKey: .notchOriginalWallpapers)
        if let path = originals[Self.screenID(screen)] ?? originals[Self.legacyScreenID(screen)] {
            return URL(fileURLWithPath: path)
        }
        let legacy = UserDefaults(suiteName: Self.legacySuiteName)?
            .dictionary(forKey: Self.legacyOriginalsKey) as? [String: String]
        if let path = legacy?[Self.legacyScreenID(screen)] {
            let url = URL(fileURLWithPath: path)
            return isGenerated(url) ? nil : url
        }
        return nil
    }

    /// Returns a Boolean value that indicates whether the given URL is a wallpaper
    /// generated by Ice, or by the standalone NotchHider app.
    private func isGenerated(_ url: URL?) -> Bool {
        guard let url else {
            return false
        }
        let path = Self.canonicalPath(url)
        for directory in [outputDirectory, legacyOutputDirectory] {
            if path.hasPrefix(Self.canonicalPath(directory) + "/") {
                return true
            }
        }
        return paths(forKey: .notchGeneratedWallpapers).values.contains(url.standardizedFileURL.path)
    }

    /// Returns the given file URL's path with symbolic links resolved, for comparing
    /// paths that may be spelled differently.
    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Returns the request for the generated wallpaper of the given screen.
    private func request(for screen: NSScreen) -> NotchWallpaperRenderer.Request? {
        NotchWallpaperRenderer.Request(
            original: original(for: screen),
            for: screen,
            roundedCorners: settings?.notchRoundedCorners ?? true
        )
    }

    /// Returns the URL of the file that the given request renders to.
    private func url(for request: NotchWallpaperRenderer.Request) -> URL {
        outputDirectory.appendingPathComponent(request.fileName)
    }

    /// Returns a Boolean value that indicates whether the given wallpaper is the
    /// generated one last set on the given screen, and still exists.
    private func isUpToDate(_ current: URL, for screen: NSScreen) -> Bool {
        guard let latest = paths(forKey: .notchGeneratedWallpapers)[Self.screenID(screen)] else {
            return false
        }
        return Self.canonicalPath(current) == Self.canonicalPath(URL(fileURLWithPath: latest))
            && FileManager.default.fileExists(atPath: latest)
    }

    // MARK: Apply and Restore

    /// Checks each screen's wallpaper, regenerating only when the user picked a new one,
    /// or when a generated one is outdated or missing.
    ///
    /// This compares URLs and reads file metadata only, so it is cheap enough to run
    /// every few seconds.
    func poll() {
        guard !isReconfiguringScreens else {
            return
        }
        var changed = false
        for screen in NSScreen.screens {
            guard let current = NSWorkspace.shared.desktopImageURL(for: screen) else {
                continue
            }
            if isGenerated(current) {
                if !isEnabled || !isTarget(screen) {
                    // A generated image is showing, and should no longer be.
                    changed = restore(screen) || changed
                } else if !isUpToDate(current, for: screen) {
                    // A space or display that kept an older generated image, which
                    // may have been deleted and replaced by the stock wallpaper.
                    changed = apply(to: screen) || changed
                }
                continue
            }
            // A wallpaper we did not create: remember it as the user's original.
            recordOriginal(current, for: screen)
            if isEnabled && isTarget(screen) {
                changed = apply(to: screen) || changed
            }
        }
        if changed {
            removeUnusedWallpapers()
        }
    }

    /// Sets the generated wallpaper on every target screen, and restores the others.
    func applyAll() {
        for screen in NSScreen.screens {
            if isEnabled && isTarget(screen) {
                if let current = NSWorkspace.shared.desktopImageURL(for: screen), !isGenerated(current) {
                    recordOriginal(current, for: screen)
                }
                apply(to: screen)
            } else {
                restore(screen)
            }
        }
        removeUnusedWallpapers()
    }

    /// Puts the original wallpaper back on every screen showing a generated one.
    func restoreAll() {
        for screen in NSScreen.screens {
            restore(screen)
        }
        removeUnusedWallpapers()
    }

    /// Sets the generated wallpaper for the given screen, rendering it only if no
    /// file for it exists yet.
    ///
    /// - Returns: Whether the screen's wallpaper changed.
    @discardableResult
    private func apply(to screen: NSScreen) -> Bool {
        let id = Self.screenID(screen)
        guard let request = request(for: screen) else {
            logger.error("No size to render a wallpaper for screen \(id, privacy: .public)")
            return false
        }
        let url = url(for: request)
        let fileManager = FileManager.default
        do {
            if fileManager.fileExists(atPath: url.path) {
                // Mark it as recently used, so it is among the last to be deleted.
                try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            } else {
                guard let png = NotchWallpaperRenderer.render(request) else {
                    logger.error("Failed to render wallpaper for screen \(id, privacy: .public)")
                    return false
                }
                try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
                try png.write(to: url, options: .atomic)
            }
            // Record before setting, so a poll treats it as generated and up to date.
            setPath(url.path, for: id, forKey: .notchGeneratedWallpapers)
            if NSWorkspace.shared.desktopImageURL(for: screen).map(Self.canonicalPath) == Self.canonicalPath(url) {
                return false
            }
            try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: Self.options(for: screen))
            return true
        } catch {
            logger.error("Failed to set wallpaper for screen \(id, privacy: .public): \(error)")
            return false
        }
    }

    /// Puts the original wallpaper back on the given screen, if a generated one is showing.
    ///
    /// The generated file is left in place: other spaces, and other displays, may
    /// still show it.
    ///
    /// - Returns: Whether the screen's wallpaper changed.
    @discardableResult
    private func restore(_ screen: NSScreen) -> Bool {
        let id = Self.screenID(screen)
        guard
            let current = NSWorkspace.shared.desktopImageURL(for: screen),
            isGenerated(current),
            let original = original(for: screen),
            FileManager.default.fileExists(atPath: original.path)
        else {
            return false
        }
        do {
            var options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
            if options[.imageScaling] == nil {
                options[.imageScaling] = NSImageScaling.scaleProportionallyUpOrDown.rawValue
                options[.allowClipping] = true
            }
            try NSWorkspace.shared.setDesktopImageURL(original, for: screen, options: options)
            setPath(nil, for: id, forKey: .notchGeneratedWallpapers)
            return true
        } catch {
            logger.error("Failed to restore wallpaper for screen \(id, privacy: .public): \(error)")
            return false
        }
    }

    /// Returns the desktop image options for a generated wallpaper on the given screen.
    private static func options(for screen: NSScreen) -> [NSWorkspace.DesktopImageOptionKey: Any] {
        var options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            .allowClipping: true,
        ]
        if let fill = NSWorkspace.shared.desktopImageOptions(for: screen)?[.fillColor] {
            options[.fillColor] = fill
        }
        return options
    }

    // MARK: Cleanup

    /// Deletes the generated wallpapers that nothing shows any more.
    ///
    /// A file is kept while a connected screen shows it, while it is among the most
    /// recently used, or while the wallpaper store names it for any space or display.
    /// If the store cannot be read, only the first two hold.
    private func removeUnusedWallpapers() {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: outputDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return
        }
        let showing = Set(NSScreen.screens.compactMap {
            NSWorkspace.shared.desktopImageURL(for: $0).map(Self.canonicalPath)
        })
        func modificationDate(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        let candidates = files
            .filter { $0.pathExtension == "png" && !showing.contains(Self.canonicalPath($0)) }
            .sorted { modificationDate($0) > modificationDate($1) }
            .dropFirst(Self.recentWallpaperLimit)
        guard !candidates.isEmpty else {
            return
        }
        let named = Self.fileNamesInWallpaperStore()
        if named == nil {
            logger.warning("Could not read the wallpaper store, so keeping only recent wallpapers")
        }
        for file in candidates where named?.contains(file.lastPathComponent) != true {
            try? fileManager.removeItem(at: file)
        }
    }

    /// Returns the names of the generated wallpapers that the wallpaper store names
    /// for any space or display, or `nil` if the store cannot be read.
    ///
    /// The store is a property list, and each wallpaper choice in it is a property
    /// list of its own, embedded as data, that holds the wallpaper's URL.
    private static func fileNamesInWallpaperStore() -> Set<String>? {
        guard
            let data = try? Data(contentsOf: wallpaperStoreURL),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else {
            return nil
        }
        var names = Set<String>()
        func collect(_ value: Any) {
            switch value {
            case let dictionary as [String: Any]:
                dictionary.values.forEach(collect)
            case let array as [Any]:
                array.forEach(collect)
            case let data as Data:
                if let nested = try? PropertyListSerialization.propertyList(from: data, format: nil) {
                    collect(nested)
                }
            case let string as String where string.contains("NotchWallpapers/"):
                let path = URL(string: string)?.path ?? string
                names.insert((path as NSString).lastPathComponent)
            default:
                break
            }
        }
        collect(plist)
        return names
    }
}
