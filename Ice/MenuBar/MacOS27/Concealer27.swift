//
//  Concealer27.swift
//  Ice
//

import Cocoa
import OSLog

/// Hides menu bar items on macOS 27, where Ice's expanding dividers no longer work.
///
/// On macOS 27 the section of each application comes from a saved layout, first
/// taken from the user's Ice layout: MenuBarAgent reorders items on its own, so their
/// order on the bar no longer says which section they belong to. The concealer hides
/// applications through `MenuBarAssessmentAssertion27`, following that layout and the
/// state of Ice's sections.
@available(macOS 27.0, *)
@MainActor
final class Concealer27 {
    private let controller = ConcealmentController27(backend: MenuBarAssessmentAssertion27())
    private let logger = Logger(category: "Concealer27")
    private weak var appState: AppState?
    private var observers = [NSObjectProtocol]()
    private var applyTask: Task<Void, Never>?
    private var suspendedUntil: ContinuousClock.Instant?

    /// Whether any application is meant to be concealed right now.
    private(set) var isConcealing = false

    /// Process identifiers of the applications meant to be concealed right now.
    private(set) var concealedPIDs = Set<pid_t>()

    /// The section of each application. Applications missing from it are visible.
    private var savedLayout: [String: MacOS27Section] {
        let stored = Defaults.dictionary(forKey: .macOS27Layout) as? [String: Int] ?? [:]
        return stored.compactMapValues(MacOS27Section.init(rawValue:))
    }

    func performSetup(with appState: AppState) {
        self.appState = appState
        guard MenuBarAssessmentAssertion27.isAvailable else {
            logger.error("MenuBarClientCore assertions are unavailable, so items will not be hidden")
            return
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.update()
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.controller.releaseAll()
            }
        })
        update()
    }

    /// Derives what to conceal from Ice's sections and applies it.
    func update() {
        guard let appState, MenuBarAssessmentAssertion27.isAvailable else {
            return
        }
        if let suspendedUntil, ContinuousClock.now < suspendedUntil {
            return
        }
        let applications = NSWorkspace.shared.runningApplications
        let running = Set(applications.compactMap(\.bundleIdentifier))
        let layout = SectionLayout27.effectiveLayout(observed: [:], saved: savedLayout, running: running)
        let target = ConcealmentPlanner27.concealedSets(layout: layout, state: revealState(appState))
        let concealed = ConcealmentPlanner27.effectivelyConcealed(sets: target)
        isConcealing = !target.isEmpty
        concealedPIDs = Set(applications.compactMap { application in
            guard let bundleID = application.bundleIdentifier, concealed.contains(bundleID) else {
                return nil
            }
            return application.processIdentifier
        })
        let previous = applyTask
        applyTask = Task { [controller, logger] in
            await previous?.value
            do {
                try await controller.apply(target: target, running: running)
            } catch {
                logger.error("Could not apply concealment: \(error, privacy: .public)")
            }
        }
    }

    /// Releases every assertion for a moment, so a click can reach a system item.
    func suspend(for duration: Duration) {
        suspendedUntil = .now + duration
        isConcealing = false
        concealedPIDs.removeAll()
        let previous = applyTask
        applyTask = Task { [controller] in
            await previous?.value
            controller.releaseAll()
        }
        Task { [weak self] in
            try? await Task.sleep(for: duration)
            self?.suspendedUntil = nil
            self?.update()
        }
    }

    /// Builds the item cache from the saved layout rather than the order on the bar.
    func cacheFromSavedLayout(items: [MenuBarItem], displayID: CGDirectDisplayID?) -> MenuBarItemManager.ItemCache {
        var cache = MenuBarItemManager.ItemCache(displayID: displayID)
        let layout = savedLayout
        for item in items.sorted(by: { $0.bounds.minX < $1.bounds.minX }) where item.canBeHidden && !item.isSystemClone {
            if item.isControlItem {
                if item.tag == .visibleControlItem {
                    cache[.visible].append(item)
                }
                continue
            }
            switch layout[item.sourceApplication?.bundleIdentifier ?? ""] ?? .visible {
            case .visible: cache[.visible].append(item)
            case .hidden: cache[.hidden].append(item)
            case .alwaysHidden: cache[.alwaysHidden].append(item)
            }
        }
        return cache
    }

    // MARK: Private

    private func revealState(_ appState: AppState) -> RevealState27 {
        if appState.settings.general.useIceBar {
            // The Ice Bar shows hidden items in its own panel, so the bar stays concealed.
            return .allHidden
        }
        let manager = appState.menuBarManager
        if let alwaysHidden = manager.section(withName: .alwaysHidden), alwaysHidden.isEnabled, !alwaysHidden.isHidden {
            return .allRevealed
        }
        if let hidden = manager.section(withName: .hidden), !hidden.isHidden {
            return .hiddenRevealed
        }
        return .allHidden
    }
}
