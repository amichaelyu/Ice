//
//  FocusWatcher27.swift
//  Ice
//

import Foundation

/// Watches which Focus is on.
///
/// Reads the Do Not Disturb database in `~/Library/DoNotDisturb/DB` (see `FocusIndicator27`).
/// That directory is behind Full Disk Access: measured on macOS 27.0.1 (2026-10-22), the first
/// read of `Assertions.json` made tccd log a `kTCCServiceSystemPolicyAllFiles` request for Ice and
/// the read failed. So the indicator is opt-in, and the watcher says whether it could read the
/// file at all (``hasAccess``) for the settings pane to point the user at the grant.
///
/// The ways round it are closed, so do not try them again (same date and system):
/// - `DNDStateService` in the private DoNotDisturb framework: donotdisturbd answers "XPC
///   connection without any valid entitlements tried to connect, will reject".
/// - Accessibility: Control Centre has no `AXExtrasMenuBar`, and MenuBarAgent's extras bar lists
///   only sound, Wi-Fi, Control Centre and the clock while Ice conceals — the Focus item is gone.
///
/// With access, `Assertions.json` changes the moment a Focus is turned on or off, so the watcher
/// follows the file — and the directory, since it may be replaced rather than written in place,
/// which leaves a source on the old file hearing nothing — and reads again a moment after it
/// changes. A reading every few seconds besides is the safety net for a change the sources miss,
/// and without access it is all there is: it notices a later grant without a relaunch.
///
/// Only while Ice is hiding something: the rest of the time macOS draws its own Focus item and
/// there is nothing for Ice to do.
@MainActor
final class FocusWatcher27: ObservableObject {
    /// The Focus that is on right now, as far as the last reading goes.
    ///
    /// Assigned on every reading, changed or not, so the indicator is placed again as the items
    /// beside it come and go.
    @Published private(set) var mode: FocusIndicator27.Mode?

    /// Whether the last reading could open the database: `nil` before the first reading and
    /// while not watching, `false` when Full Disk Access is missing.
    @Published private(set) var hasAccess: Bool?

    private var timer: Timer?
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var pendingRead: DispatchWorkItem?

    /// How often the database is read regardless, while Ice is hiding something.
    private static let interval: TimeInterval = 5

    /// How long to wait after a change before reading, so a burst of writes costs one reading
    /// and a file being replaced is read once it is whole.
    private static let debounce: TimeInterval = 0.2

    nonisolated private static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/DoNotDisturb/DB", isDirectory: true)
    nonisolated private static let assertionsFile = directory.appendingPathComponent("Assertions.json")
    private static let modeConfigurationsFile = directory.appendingPathComponent("ModeConfigurations.json")

    /// Starts or stops watching. Stopping clears what was last seen.
    func setWatching(_ watching: Bool) {
        guard watching != (timer != nil) else {
            return
        }
        guard watching else {
            timer?.invalidate()
            timer = nil
            stopSources()
            mode = nil
            hasAccess = nil
            return
        }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.read()
            }
        }
        // The common run loop mode, or the reading stops while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        read()
    }

    private func stopSources() {
        pendingRead?.cancel()
        pendingRead = nil
        directorySource?.cancel()
        directorySource = nil
        fileSource?.cancel()
        fileSource = nil
    }

    /// Puts the sources in place where they are missing.
    ///
    /// - Returns: Whether both sources are in place. Opening fails without Full Disk Access.
    private func startSources() -> Bool {
        if directorySource == nil {
            directorySource = Self.source(for: Self.directory, events: .write) { [weak self] in
                self?.changed()
            }
        }
        if fileSource == nil {
            fileSource = Self.source(for: Self.assertionsFile, events: [.write, .extend, .delete, .rename]) { [weak self] in
                self?.changed()
            }
        }
        return directorySource != nil && fileSource != nil
    }

    /// Reads again once the writes have settled.
    private func changed() {
        guard timer != nil else {
            return
        }
        pendingRead?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.timer != nil else {
                    return
                }
                // `Assertions.json` is opened afresh: after the file is replaced, the old source
                // watches a file nobody writes to any more.
                self.fileSource?.cancel()
                self.fileSource = nil
                self.read()
            }
        }
        pendingRead = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce, execute: work)
    }

    /// What one attempt to read `Assertions.json` found.
    private enum Reading {
        case contents(Data)
        /// No database yet: no Focus has been set up, which is not the same as missing access.
        case missing
        case denied
    }

    private nonisolated static func readAssertions() -> Reading {
        do {
            return .contents(try Data(contentsOf: assertionsFile))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .missing
        } catch {
            return .denied
        }
    }

    /// Whether Ice can read the Focus state right now, which is whether it has Full Disk Access.
    ///
    /// One read of `Assertions.json`, leaving the watcher as it is; a missing file counts as
    /// readable, as it does for the watcher. The settings pane asks this when the indicator is
    /// turned on, to send the user to the Full Disk Access list straight away: macOS has no
    /// prompt for that grant.
    nonisolated static func canReadFocusState() -> Bool {
        if case .denied = readAssertions() {
            return false
        }
        return true
    }

    private func read() {
        let assertions: Data
        switch Self.readAssertions() {
        case .contents(let data):
            assertions = data
        case .missing:
            stopSources()
            hasAccess = true
            mode = nil
            return
        case .denied:
            denied()
            return
        }
        guard startSources() else {
            denied()
            return
        }
        hasAccess = true
        mode = FocusIndicator27.activeMode(
            assertions: assertions,
            modeConfigurations: try? Data(contentsOf: Self.modeConfigurationsFile)
        )
    }

    /// Without Full Disk Access only the timer is left, to notice when it is granted.
    private func denied() {
        stopSources()
        hasAccess = false
        mode = nil
    }

    /// A source that calls back on the main thread when the file or directory at the URL changes.
    private static func source(
        for url: URL,
        events: DispatchSource.FileSystemEvent,
        handler: @escaping @MainActor () -> Void
    ) -> DispatchSourceFileSystemObject? {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            return nil
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: events,
            queue: .main
        )
        source.setEventHandler {
            MainActor.assumeIsolated {
                handler()
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        return source
    }
}
