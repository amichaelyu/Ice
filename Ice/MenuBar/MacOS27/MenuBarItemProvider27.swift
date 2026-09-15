//
//  MenuBarItemProvider27.swift
//  Ice
//

import ApplicationServices
import Cocoa
import OSLog

/// Reads menu bar items through Accessibility on macOS 27.
///
/// macOS 27 draws status items inside MenuBarAgent instead of giving each one a
/// WindowServer window, so the window list Ice used is empty. Every process still
/// publishes its items under `AXExtrasMenuBar`, with frames, for the display that
/// has the active menu bar.
@available(macOS 27.0, *)
enum MenuBarItemProvider27 {
    /// The bundle identifier of the process that hosts the system items.
    static let menuBarAgentBundleID = "com.apple.MenuBarAgent"

    private struct Entry {
        let element: AXUIElement
        let bundleID: String
        let frame: CGRect
    }

    private struct RawItem {
        let element: AXUIElement
        let bundleID: String
        let pid: pid_t
        let identifier: String
        let title: String?
        let index: Int
        let frame: CGRect
    }

    private static let logger = Logger(category: "MenuBarItemProvider27")

    /// Accessibility calls block, so they run on their own queue, off the Swift
    /// concurrency pool (see `MenuBarItemImageCache.captureQueue`).
    private static let queue = DispatchQueue(label: "com.jordanbaird.Ice.MenuBarItemProvider27", qos: .userInitiated)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries = [CGWindowID: Entry]()
    nonisolated(unsafe) private static var lastOverflowButtonFrame: CGRect?
    nonisolated(unsafe) private static var lastSystemItemFrames = [CGRect]()
    /// Only read and written on `queue`.
    nonisolated(unsafe) private static var scanSchedule = AccessibilityScanSchedule27()

    /// Returns the items on the active menu bar, ordered left to right.
    static func items() async -> [MenuBarItem] {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: readItems())
            }
        }
    }

    /// Returns the current frame of the item with the given synthetic identifier.
    ///
    /// Ice's own items are answered from the last read: asking our own process
    /// from the main thread would wait for the main thread itself.
    static func currentBounds(for windowID: CGWindowID) -> CGRect? {
        guard let entry = lock.withLock({ entries[windowID] }) else {
            return nil
        }
        if entry.bundleID == Constants.bundleIdentifier {
            return entry.frame
        }
        return frame(of: entry.element) ?? entry.frame
    }

    /// Frames of the system items hosted by MenuBarAgent, from the last read.
    static func systemItemFrames() -> [CGRect] {
        lock.withLock { lastSystemItemFrames }
    }

    /// Frame of the system overflow button ("<<" / ">>"), from the last read.
    static func overflowButtonFrame() -> CGRect? {
        lock.withLock { lastOverflowButtonFrame }
    }

    // MARK: Reading

    private static func readItems(retryIfMenuBarMoves: Bool = true) -> [MenuBarItem] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var rawItems = [RawItem]()
        var chevronFrame: CGRect?
        // A read that races a change of the active menu bar can mix displays, so it
        // is repeated once when the menu bar moves during the read.
        let activeDisplayID = Bridging.getActiveMenuBarDisplayID()
        let activeDisplayBounds = activeDisplayID.map(CGDisplayBounds)

        // MenuBarAgent comes first, and its frames are published before the other
        // processes are asked: a click on the clock needs them, and right after launch
        // the whole read can take seconds (measured 12.7 s).
        let runningApplications = NSWorkspace.shared.runningApplications
        let applications = runningApplications.filter { $0.bundleIdentifier == menuBarAgentBundleID }
            + runningApplications.filter { $0.bundleIdentifier != menuBarAgentBundleID }
        let now = ProcessInfo.processInfo.systemUptime
        scanSchedule.retain(running: Set(applications.map(\.processIdentifier)))

        for app in applications {
            guard let bundleID = app.bundleIdentifier else {
                continue
            }
            let pid = app.processIdentifier
            let timeout: Float
            if pid == ownPID {
                timeout = 0.25
            } else if let scheduled = scanSchedule.timeout(for: pid, now: now) {
                timeout = scheduled
            } else {
                continue
            }
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, timeout)
            var barValue: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(application, kAXExtrasMenuBarAttribute as CFString, &barValue)
            if pid != ownPID {
                scanSchedule.record(pid: pid, timedOut: result == .cannotComplete, now: now)
            }
            guard
                result == .success,
                let barValue,
                CFGetTypeID(barValue) == AXUIElementGetTypeID(),
                let children = elements(barValue as! AXUIElement, kAXChildrenAttribute) // swiftlint:disable:this force_cast
            else {
                continue
            }
            if pid != ownPID, !children.isEmpty {
                scanSchedule.recordItems(pid: pid)
            }
            for (index, child) in children.enumerated() {
                if bundleID == menuBarAgentBundleID, string(child, kAXRoleAttribute) == kAXButtonRole {
                    // The system overflow control ("<<" / ">>").
                    chevronFrame = frame(of: child)
                    continue
                }
                // MenuBarAgent wraps each system item in a hosting group; the identifier
                // and the drawn frame belong to the item inside it.
                let element = bundleID == menuBarAgentBundleID
                    ? (elements(child, kAXChildrenAttribute)?.first ?? child)
                    : child
                guard
                    let frame = frame(of: element),
                    activeDisplayBounds.map({ $0.intersects(frame) }) ?? true
                else {
                    continue
                }
                rawItems.append(RawItem(
                    element: element,
                    bundleID: bundleID,
                    pid: pid,
                    identifier: string(element, kAXIdentifierAttribute) ?? "",
                    title: string(element, kAXDescriptionAttribute) ?? string(element, kAXTitleAttribute),
                    index: index,
                    frame: frame
                ))
            }
            if bundleID == menuBarAgentBundleID {
                let systemFrames = rawItems.filter { $0.bundleID == menuBarAgentBundleID }.map(\.frame)
                lock.withLock {
                    lastSystemItemFrames = systemFrames
                    lastOverflowButtonFrame = chevronFrame
                }
            }
        }

        if retryIfMenuBarMoves, Bridging.getActiveMenuBarDisplayID() != activeDisplayID {
            return readItems(retryIfMenuBarMoves: false)
        }
        var newEntries = [CGWindowID: Entry]()
        var items = [MenuBarItem]()
        for raw in rawItems.sorted(by: { $0.frame.minX < $1.frame.minX }) {
            guard let tag = tag(for: raw, ownPID: ownPID) else {
                continue
            }
            let windowID = SyntheticWindowID27.make(bundleID: raw.bundleID, identifier: tag.title, index: raw.index)
            newEntries[windowID] = Entry(element: raw.element, bundleID: raw.bundleID, frame: raw.frame)
            items.append(MenuBarItem(
                tag: tag,
                syntheticWindowID: windowID,
                ownerPID: raw.pid,
                bounds: raw.frame,
                title: raw.title,
                isOnScreen: !OverflowDetection27.isInOverflow(itemFrame: raw.frame, chevronFrame: chevronFrame)
            ))
        }
        lock.withLock {
            entries = newEntries
            lastOverflowButtonFrame = chevronFrame
            lastSystemItemFrames = newEntries.values.filter { $0.bundleID == menuBarAgentBundleID }.map(\.frame)
        }
        return items
    }

    private static func tag(for raw: RawItem, ownPID: pid_t) -> MenuBarItemTag? {
        if raw.pid == ownPID {
            // Only Ice's control items, identified by `ControlItem`.
            return MenuBarItemTag.controlItems.first { $0.title == raw.identifier }
        }
        let title = raw.identifier.isEmpty ? "Item-\(raw.index)" : raw.identifier
        return MenuBarItemTag(namespace: .string(raw.bundleID), title: title)
    }

    // MARK: Accessibility Helpers

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let string = value(element, attribute) as? String, !string.isEmpty else {
            return nil
        }
        return string
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement) // swiftlint:disable:this force_cast
    }

    private static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        value(element, attribute) as? [AXUIElement]
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard
            let positionValue = value(element, kAXPositionAttribute),
            CFGetTypeID(positionValue) == AXValueGetTypeID(),
            let sizeValue = value(element, kAXSizeAttribute),
            CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard
            AXValueGetValue(positionValue as! AXValue, .cgPoint, &position), // swiftlint:disable:this force_cast
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) // swiftlint:disable:this force_cast
        else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }
}

@available(macOS 27.0, *)
extension MenuBarItem {
    /// Creates an item read through Accessibility on macOS 27.
    init(
        tag: MenuBarItemTag,
        syntheticWindowID: CGWindowID,
        ownerPID: pid_t,
        bounds: CGRect,
        title: String?,
        isOnScreen: Bool
    ) {
        self.tag = tag
        self.windowID = syntheticWindowID
        self.ownerPID = ownerPID
        self.sourcePID = ownerPID
        self.bounds = bounds
        self.title = title
        self.isOnScreen = isOnScreen
    }
}
