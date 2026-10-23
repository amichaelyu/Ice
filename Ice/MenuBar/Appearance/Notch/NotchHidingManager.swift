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

        // Resolution or arrangement changed: regenerate at the new size. Screen
        // changes often arrive in bursts, so wait for them to settle.
        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: 0.5, scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else {
                    return
                }
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
    static func screenID(_ screen: NSScreen) -> String {
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

    /// Returns the user's original wallpaper for the given screen.
    ///
    /// If Ice has not recorded one, falls back to the original that the standalone
    /// NotchHider app recorded. A user who switches from NotchHider to Ice has
    /// NotchHider's black-bar copy as their current wallpaper, and only NotchHider
    /// knows which wallpaper it replaced.
    private func original(for screen: NSScreen) -> URL? {
        let id = Self.screenID(screen)
        if let path = paths(forKey: .notchOriginalWallpapers)[id] {
            return URL(fileURLWithPath: path)
        }
        let legacy = UserDefaults(suiteName: Self.legacySuiteName)?
            .dictionary(forKey: Self.legacyOriginalsKey) as? [String: String]
        if let path = legacy?[id] {
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
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        for directory in [outputDirectory, legacyOutputDirectory] {
            let directoryPath = directory.standardizedFileURL.resolvingSymlinksInPath().path
            if path.hasPrefix(directoryPath + "/") {
                return true
            }
        }
        return paths(forKey: .notchGeneratedWallpapers).values.contains(url.standardizedFileURL.path)
    }

    // MARK: Apply and Restore

    /// Checks each screen's wallpaper, regenerating only when the user picked a new one.
    ///
    /// This compares URLs only, so it is cheap enough to run every few seconds.
    func poll() {
        for screen in NSScreen.screens {
            guard let current = NSWorkspace.shared.desktopImageURL(for: screen) else {
                continue
            }
            if isGenerated(current) {
                // A generated image is showing. If it should no longer be, fix it.
                if !isEnabled || !isTarget(screen) {
                    restore(screen)
                }
                continue
            }
            // A wallpaper we did not create: remember it as the user's original.
            let id = Self.screenID(screen)
            if paths(forKey: .notchOriginalWallpapers)[id] != current.path {
                setPath(current.path, for: id, forKey: .notchOriginalWallpapers)
            }
            if isEnabled && isTarget(screen) {
                apply(to: screen)
            }
        }
    }

    /// Regenerates and sets the wallpaper on every target screen, and restores the others.
    func applyAll() {
        for screen in NSScreen.screens {
            if isEnabled && isTarget(screen) {
                if let current = NSWorkspace.shared.desktopImageURL(for: screen), !isGenerated(current) {
                    setPath(current.path, for: Self.screenID(screen), forKey: .notchOriginalWallpapers)
                }
                apply(to: screen)
            } else {
                restore(screen)
            }
        }
    }

    /// Puts the original wallpaper back on every screen showing a generated one.
    func restoreAll() {
        for screen in NSScreen.screens {
            restore(screen)
        }
    }

    /// Renders and sets the wallpaper for the given screen.
    private func apply(to screen: NSScreen) {
        let id = Self.screenID(screen)
        guard
            let png = NotchWallpaperRenderer.render(
                original: original(for: screen),
                for: screen,
                roundedCorners: settings?.notchRoundedCorners ?? true
            )
        else {
            logger.error("Failed to render wallpaper for screen \(id, privacy: .public)")
            return
        }
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            let stamp = Int(Date().timeIntervalSince1970 * 1000)
            let url = outputDirectory.appendingPathComponent("screen-\(id)-\(stamp).png")
            try png.write(to: url, options: .atomic)
            // Record before setting, so a poll treats it as generated.
            setPath(url.path, for: id, forKey: .notchGeneratedWallpapers)
            try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: Self.options(for: screen))
            deleteStale(for: id, keeping: url)
        } catch {
            logger.error("Failed to set wallpaper for screen \(id, privacy: .public): \(error)")
        }
    }

    /// Puts the original wallpaper back on the given screen, if a generated one is showing.
    private func restore(_ screen: NSScreen) {
        let id = Self.screenID(screen)
        guard
            let current = NSWorkspace.shared.desktopImageURL(for: screen),
            isGenerated(current),
            let original = original(for: screen),
            FileManager.default.fileExists(atPath: original.path)
        else {
            return
        }
        do {
            var options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
            if options[.imageScaling] == nil {
                options[.imageScaling] = NSImageScaling.scaleProportionallyUpOrDown.rawValue
                options[.allowClipping] = true
            }
            try NSWorkspace.shared.setDesktopImageURL(original, for: screen, options: options)
            setPath(nil, for: id, forKey: .notchGeneratedWallpapers)
            deleteStale(for: id, keeping: nil)
        } catch {
            logger.error("Failed to restore wallpaper for screen \(id, privacy: .public): \(error)")
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

    /// Deletes the generated wallpapers for the given screen, except `keeping`.
    private func deleteStale(for screenID: String, keeping: URL?) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: outputDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        let prefix = "screen-\(screenID)-"
        for file in files where file.lastPathComponent.hasPrefix(prefix) && file.pathExtension == "png" {
            if let keeping, file.standardizedFileURL.path == keeping.standardizedFileURL.path {
                continue
            }
            try? FileManager.default.removeItem(at: file)
        }
    }
}
