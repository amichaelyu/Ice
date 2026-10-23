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
        let identifier: String
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
    /// System item frames per display. MenuBarAgent describes the bars of both displays in its
    /// windows, unlike other applications, whose items only have frames on the active one.
    nonisolated(unsafe) private static var lastSystemFramesByDisplay = [CGDirectDisplayID: [CGRect]]()
    /// Every frame in those windows, per display, system items included. A bar whose menu bar is
    /// not the active one has no other account of what it draws: applications report frames for
    /// the active bar alone.
    nonisolated(unsafe) private static var lastBarFramesByDisplay = [CGDirectDisplayID: [CGRect]]()
    /// How many of each bar's entries belong to applications rather than the system group.
    nonisolated(unsafe) private static var lastApplicationEntriesByDisplay = [CGDirectDisplayID: Int]()
    /// The overflow button each bar lists, per display, with an empty frame where the bar lists
    /// it without geometry. The one under `AXExtrasMenuBar` belongs to the active bar alone, so a
    /// "«" on the other display, or one missed because the active bar moved mid-read, was nowhere
    /// to be found, and a notched bar overflowing as macOS means it to read as stuck (seen on
    /// macOS 27.0.1 with the built-in display as the main one).
    nonisolated(unsafe) private static var lastOverflowButtonsByDisplay = [CGDirectDisplayID: CGRect]()
    /// How far left of the clock's own left edge the other system items reach (measured on
    /// macOS 27.0: 122 points on both displays — battery, Wi-Fi and Control Centre).
    private static let systemItemsSpan: CGFloat = 130
    /// The leftmost item drawn on each display, from the last read while that display's
    /// menu bar was active. Hover hit-testing needs it for the display that is not active,
    /// where Accessibility reports no frames at all.
    nonisolated(unsafe) private static var lastLeftEdges = [CGDirectDisplayID: CGFloat]()
    /// Processes whose items are concealed. Accessibility keeps reporting their frames where
    /// they were last drawn, so without this they would pass for drawn items.
    nonisolated(unsafe) private static var concealedPIDs = Set<pid_t>()
    /// Only read and written on `queue`.
    nonisolated(unsafe) private static var scanSchedule = AccessibilityScanSchedule27()
    /// Each process's items from its last read. Only read and written on `queue`.
    nonisolated(unsafe) private static var itemsByPID = [pid_t: [RawItem]]()

    /// Returns the items on the active menu bar, ordered left to right.
    ///
    /// A caller that asks while another read is under way, or in the moment after one
    /// finished, is answered from that read. Ice ran one Accessibility sweep per caller
    /// before, and they arrive in bursts: revealing the hidden items set six of them going
    /// in little over a second (measured 2026-09-16), each asking every running process,
    /// while MenuBarAgent was animating the bar. The window is short on purpose — the
    /// before-and-after reads that decide which items sat still for a capture are further
    /// apart than this, so they still see the bar twice.
    static func items() async -> [MenuBarItem] {
        await withCheckedContinuation { continuation in
            queue.async {
                let fresh: [MenuBarItem]? = lock.withLock {
                    guard
                        let items = lastItems,
                        ProcessInfo.processInfo.systemUptime - lastReadAt < freshInterval
                    else {
                        return nil
                    }
                    return items
                }
                if let fresh {
                    logger.debug("Item scan: answered from the read just finished")
                    continuation.resume(returning: fresh)
                    return
                }
                let items = readItems()
                lock.withLock {
                    lastItems = items
                    lastReadAt = ProcessInfo.processInfo.systemUptime
                }
                continuation.resume(returning: items)
            }
        }
    }

    /// Returns the items of the given processes, asking only them and MenuBarAgent.
    ///
    /// For a caller that wants one application's items: the other processes are left out of
    /// the read, and their items in the provider's other answers stay as they were last read.
    static func items(pids: Set<pid_t>) async -> [MenuBarItem] {
        await withCheckedContinuation { continuation in
            queue.async {
                let fresh = lock.withLock {
                    ProcessInfo.processInfo.systemUptime - lastReadAt < freshInterval ? lastItems : nil
                }
                let items = fresh ?? readItems(pids: pids)
                continuation.resume(returning: items.filter { pids.contains($0.ownerPID) })
            }
        }
    }

    /// Returns the system items, asking MenuBarAgent alone.
    static func systemItems() async -> [MenuBarItem] {
        let agents = NSRunningApplication.runningApplications(withBundleIdentifier: menuBarAgentBundleID)
        return await items(pids: Set(agents.map(\.processIdentifier)))
    }

    /// How long a finished read stands in for the next one.
    private static let freshInterval: TimeInterval = 0.12
    nonisolated(unsafe) private static var lastItems: [MenuBarItem]?
    nonisolated(unsafe) private static var lastReadAt: TimeInterval = 0

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

    /// The Accessibility element of the system item drawn at the given point, from the last
    /// read. Control Centre opens from a press on it without lifting concealment.
    static func systemItem(at point: CGPoint) -> (element: AXUIElement, identifier: String)? {
        lock.withLock {
            entries.values
                .first { $0.bundleID == menuBarAgentBundleID && $0.frame.insetBy(dx: -1, dy: -1).contains(point) }
                .map { ($0.element, $0.identifier) }
        }
    }

    /// The Accessibility element of the system item with the given identifier, from the last read.
    ///
    /// Control Centre's is `com.apple.menuextra.controlcenter` (measured on macOS 27.0, alongside
    /// `…battery`, `…wifi` and `…clock`).
    static func systemItem(withIdentifier identifier: String) -> AXUIElement? {
        lock.withLock {
            entries.values
                .first { $0.bundleID == menuBarAgentBundleID && $0.identifier == identifier }?
                .element
        }
    }

    /// Tells the provider which processes are concealed right now.
    static func setConcealedPIDs(_ pids: Set<pid_t>) {
        lock.withLock { concealedPIDs = pids }
    }

    /// The leftmost item drawn on the given display, from the last read while its menu bar
    /// was active.
    static func leftEdge(for displayID: CGDirectDisplayID) -> CGFloat? {
        lock.withLock { lastLeftEdges[displayID] }
    }

    /// Frames of the system items drawn on the given display, from the last read.
    ///
    /// A click on the clock of the display whose menu bar is not active has to be recognised
    /// too, or it reaches MenuBarAgent while the assertion still stands and is ignored — which
    /// is why that clock used to need two or three clicks.
    static func systemItemFrames(for displayID: CGDirectDisplayID) -> [CGRect] {
        lock.withLock { lastSystemFramesByDisplay[displayID] ?? [] }
    }

    /// Frames of everything MenuBarAgent draws on the given display, from the last read.
    static func barFrames(for displayID: CGDirectDisplayID) -> [CGRect] {
        lock.withLock { lastBarFramesByDisplay[displayID] ?? [] }
    }

    /// How many items of applications the given display's bar lists, from the last read, or `nil`
    /// if that bar was not read. Items folded away beside the notch are listed by neither display.
    static func applicationEntryCount(for displayID: CGDirectDisplayID) -> Int? {
        lock.withLock { lastApplicationEntriesByDisplay[displayID] }
    }

    /// Frame of the system overflow button ("<<" / ">>"), from the last read.
    static func overflowButtonFrame() -> CGRect? {
        lock.withLock { lastOverflowButtonFrame }
    }

    /// The overflow button the given display's bar lists, from the last read, or `nil` if it
    /// lists none. The frame is empty when the bar lists the button without geometry.
    static func overflowButtonFrame(for displayID: CGDirectDisplayID) -> CGRect? {
        lock.withLock { lastOverflowButtonsByDisplay[displayID] }
    }

    /// The Accessibility element of the item with the given synthetic identifier, from the
    /// last read. Items drawn on another display are included (see `ItemDrawing27`).
    static func element(forWindowID windowID: CGWindowID) -> AXUIElement? {
        lock.withLock { entries[windowID]?.element }
    }

    // MARK: Reading

    /// Reads the processes the schedule asks for, or the given ones and MenuBarAgent, and
    /// returns every item in the cache.
    private static func readItems(pids requested: Set<pid_t>? = nil, retryIfMenuBarMoves: Bool = true) -> [MenuBarItem] {
        // Timed: a scan that runs while MenuBarAgent is animating the bar is a suspect for
        // the stutter of that animation.
        let started = ProcessInfo.processInfo.systemUptime
        logger.debug("Item scan: started")
        defer {
            let milliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
            logger.debug("Item scan: took \(milliseconds, privacy: .public) ms")
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var chevronFrame: CGRect?
        // A read that races a change of the active menu bar can mix displays, so it
        // is repeated once when the menu bar moves during the read.
        let activeDisplayID = Bridging.getActiveMenuBarDisplayID()
        let activeDisplayBounds = activeDisplayID.map(CGDisplayBounds)

        // MenuBarAgent comes first, and its frames are published before the other
        // processes are asked: a click on the clock needs them, and right after launch
        // the whole read can take seconds (measured 12.7 s).
        let applications = runningApplications()
        let now = ProcessInfo.processInfo.systemUptime
        let running = Set(applications.map(\.processIdentifier))
        scanSchedule.update(running: running, now: now)
        itemsByPID = itemsByPID.filter { running.contains($0.key) }
        let sweeping = requested == nil && scanSchedule.isSweepDue(now: now)
        if sweeping {
            scanSchedule.recordSweep(now: now)
        }

        for app in applications {
            guard let bundleID = app.bundleIdentifier else {
                continue
            }
            let pid = app.processIdentifier
            if let requested, !requested.contains(pid), bundleID != menuBarAgentBundleID {
                continue
            }
            let timeout: Float
            if pid == ownPID {
                timeout = 0.25
            } else if bundleID == menuBarAgentBundleID {
                timeout = AccessibilityScanSchedule27.normalTimeout
            } else if let scheduled = scanSchedule.timeout(for: pid, sweeping: sweeping || requested != nil, now: now) {
                timeout = scheduled
            } else {
                continue
            }
            let (items, timedOut) = readApplication(pid: pid, bundleID: bundleID, timeout: timeout, chevronFrame: &chevronFrame)
            itemsByPID[pid] = items
            if pid != ownPID, bundleID != menuBarAgentBundleID {
                scanSchedule.record(pid: pid, timedOut: timedOut, hasItems: !items.isEmpty)
            }
            if bundleID == menuBarAgentBundleID {
                let systemFrames = items
                    .filter { activeDisplayBounds?.intersects($0.frame) ?? true }
                    .map(\.frame)
                lock.withLock {
                    lastSystemItemFrames = systemFrames
                    lastOverflowButtonFrame = chevronFrame
                }
            }
        }

        if retryIfMenuBarMoves, Bridging.getActiveMenuBarDisplayID() != activeDisplayID {
            return readItems(pids: requested, retryIfMenuBarMoves: false)
        }
        let rawItems = applications.flatMap { itemsByPID[$0.processIdentifier] ?? [] }
        var newEntries = [CGWindowID: Entry]()
        var items = [MenuBarItem]()
        for raw in rawItems.sorted(by: { $0.frame.minX < $1.frame.minX }) {
            guard let tag = tag(for: raw, ownPID: ownPID) else {
                continue
            }
            let windowID = SyntheticWindowID27.make(bundleID: raw.bundleID, identifier: tag.title, index: raw.index)
            newEntries[windowID] = Entry(element: raw.element, bundleID: raw.bundleID, identifier: raw.identifier, frame: raw.frame)
            items.append(MenuBarItem(
                tag: tag,
                syntheticWindowID: windowID,
                ownerPID: raw.pid,
                bounds: raw.frame,
                title: raw.title,
                isOnScreen: ItemDrawing27.isDrawn(itemFrame: raw.frame, activeDisplayBounds: activeDisplayBounds, chevronFrame: chevronFrame)
            ))
        }
        // Where the items' own run of the bar begins, for hover hit-testing. Only what is
        // drawn counts: a concealed item keeps a stale frame further left, which would make
        // Ice treat the freed part of the bar as occupied. A read of a few processes leaves
        // the others' frames as old as their last read, so it does not count.
        let concealed = lock.withLock { concealedPIDs }
        let leftEdge = requested != nil ? nil : items
            .filter { item in
                guard !concealed.contains(item.ownerPID) else {
                    return false
                }
                // Ice's own items are collapsed to nothing on macOS 27 and report a frame at
                // the origin, which would drag the edge to the left of the whole bar and make
                // every spot count as occupied, so hovering would never reveal anything again.
                return item.isOnScreen && item.ownerPID != ownPID && !item.isControlItem && item.bounds.width > 4
            }
            .map(\.bounds.minX)
            .min()
        lock.withLock {
            entries = newEntries
            if let activeDisplayID, let leftEdge {
                lastLeftEdges[activeDisplayID] = leftEdge
            }
        }
        return items
    }

    /// The running processes that can have menu bar items, MenuBarAgent first.
    ///
    /// XPC services, such as WebKit's content processes, have none, and many of them never
    /// answer Accessibility at all.
    private static func runningApplications() -> [NSRunningApplication] {
        let candidates = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.pathExtension != "xpc" }
        return candidates.filter { $0.bundleIdentifier == menuBarAgentBundleID }
            + candidates.filter { $0.bundleIdentifier != menuBarAgentBundleID }
    }

    /// Reads one process's items, and for MenuBarAgent the bars it draws as well.
    private static func readApplication(
        pid: pid_t,
        bundleID: String,
        timeout: Float,
        chevronFrame: inout CGRect?
    ) -> (items: [RawItem], timedOut: Bool) {
        let isMenuBarAgent = bundleID == menuBarAgentBundleID
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, timeout)
        // The messaging timeout belongs to each element reference, not to the process, so
        // every element read below is given it too. Left alone they wait about six seconds.
        let (values, result) = attributeValues(
            application,
            isMenuBarAgent ? [kAXExtrasMenuBarAttribute, kAXWindowsAttribute] : [kAXExtrasMenuBarAttribute]
        )
        guard
            result == .success,
            let bar = element(from: values[0]),
            let children = elements(bar, kAXChildrenAttribute, timeout: timeout)
        else {
            return ([], result == .cannotComplete)
        }
        var rawItems = [RawItem]()
        for (index, child) in children.enumerated() {
            var item = child
            if isMenuBarAgent {
                let group = attributes(of: child, [kAXRoleAttribute, kAXChildrenAttribute, kAXPositionAttribute, kAXSizeAttribute], timeout: timeout)
                if group.role == kAXButtonRole {
                    // The system overflow control ("<<" / ">>").
                    chevronFrame = group.frame
                    continue
                }
                // MenuBarAgent wraps each system item in a hosting group; the identifier
                // and the drawn frame belong to the item inside it.
                item = group.children?.first ?? child
            }
            let attributes = attributes(of: item, Self.itemAttributes, timeout: timeout)
            // Items whose frames are on another display stay in the list, marked as not
            // drawn, so a concealed item keeps its section (see `ItemDrawing27`).
            guard let frame = attributes.frame else {
                continue
            }
            rawItems.append(RawItem(
                element: item,
                bundleID: bundleID,
                pid: pid,
                identifier: attributes.identifier ?? "",
                title: attributes.title,
                index: index,
                frame: frame
            ))
        }
        if isMenuBarAgent {
            readBars(values[1] as? [AXUIElement] ?? [], timeout: timeout)
        }
        return (rawItems, false)
    }

    /// Reads the bars MenuBarAgent draws, one window per display.
    private static func readBars(_ windows: [AXUIElement], timeout: Float) {
        // MenuBarAgent's window on the display whose bar is not active holds every item
        // drawn there, not only the system ones, so taking them all made Ice treat any
        // click as a click on a system item and lift concealment for it. The system
        // items are the rightmost group, and the clock is the widest of them: keep the
        // items within the span they occupy (measured on macOS 27.0: 237 points from the
        // leftmost of them to the clock's right edge).
        // Each window is one display's bar, and what it lists belongs to that bar: an
        // item's frame where it is drawn, and an entry with no geometry on the other
        // display. So the windows are read one at a time, and a display is taken from the
        // window's own frame — an entry with no geometry would otherwise be filed under
        // whichever display happens to contain the origin.
        var framesByDisplay = [CGDirectDisplayID: [CGRect]]()
        var barsByDisplay = [CGDirectDisplayID: (entries: Int, systemItemsWithGeometry: Int)]()
        var overflowButtonsByDisplay = [CGDirectDisplayID: CGRect]()
        for window in windows {
            let window = attributes(of: window, [kAXChildrenAttribute, kAXPositionAttribute, kAXSizeAttribute], timeout: timeout)
            guard let windowFrame = window.frame else {
                continue
            }
            var display = CGDirectDisplayID(0)
            var matches: UInt32 = 0
            CGGetDisplaysWithPoint(CGPoint(x: windowFrame.midX, y: windowFrame.minY + 1), 1, &display, &matches)
            guard matches > 0 else {
                continue
            }
            // An entry the bar lists without geometry answers no position at all, so a
            // missing frame is kept as an empty one: the entry is what counts.
            let windowChildren = (window.children ?? []).map { child in
                attributes(of: child, [kAXRoleAttribute, kAXChildrenAttribute, kAXPositionAttribute, kAXSizeAttribute], timeout: timeout)
            }
            let childFrames = windowChildren.map { child in
                guard let inner = child.children?.first else {
                    return child.frame ?? .zero
                }
                return attributes(of: inner, [kAXPositionAttribute, kAXSizeAttribute], timeout: timeout).frame ?? .zero
            }
            // The overflow button is a button among the bar's entries, as it is under
            // `AXExtrasMenuBar`. It stays counted with them: the counts were measured
            // with it in (see `Concealer27.checkStuckOverflow`).
            if let button = windowChildren.first(where: { $0.role == kAXButtonRole }) {
                overflowButtonsByDisplay[display] = button.frame ?? .zero
            }
            // Added to, not replaced: one window per display is what macOS 27.0 has, but
            // a second one would otherwise take the first one's entries away with it.
            framesByDisplay[display, default: []].append(contentsOf: childFrames)
            // Every entry is counted, and the system items only where they have geometry:
            // the bar that is not active lists some of them without (see
            // `StuckOverflow27.applicationEntryCounts(bars:)`).
            var systemFrames = [CGRect]()
            if let clock = childFrames.max(by: { $0.width < $1.width }), clock.width > 80 {
                systemFrames = childFrames.filter { $0.width > 1 && $0.minX >= clock.minX - systemItemsSpan }
            }
            barsByDisplay[display, default: (0, 0)].entries += childFrames.count
            barsByDisplay[display, default: (0, 0)].systemItemsWithGeometry += systemFrames.count
        }
        let entriesByDisplay = StuckOverflow27.applicationEntryCounts(bars: barsByDisplay)
        let perDisplay = framesByDisplay.compactMapValues { frames -> [CGRect]? in
            guard let clock = frames.max(by: { $0.width < $1.width }), clock.width > 80 else {
                return nil
            }
            return frames.filter { $0.width > 1 && $0.minX >= clock.minX - systemItemsSpan }
        }
        lock.withLock {
            lastSystemFramesByDisplay = perDisplay
            lastBarFramesByDisplay = framesByDisplay
            lastApplicationEntriesByDisplay = entriesByDisplay
            lastOverflowButtonsByDisplay = overflowButtonsByDisplay
        }
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

    /// What Ice reads of an item: its frame, identifier and description or title.
    private static let itemAttributes = [
        kAXPositionAttribute,
        kAXSizeAttribute,
        kAXIdentifierAttribute,
        kAXDescriptionAttribute,
        kAXTitleAttribute,
    ]

    private struct Attributes {
        var role: String?
        var children: [AXUIElement]?
        var frame: CGRect?
        var identifier: String?
        /// The description, or else the title.
        var title: String?
    }

    /// Reads the given attributes of an element in one call.
    private static func attributes(of element: AXUIElement, _ names: [String], timeout: Float? = nil) -> Attributes {
        if let timeout {
            AXUIElementSetMessagingTimeout(element, timeout)
        }
        let (values, _) = attributeValues(element, names)
        var attributes = Attributes()
        var position: CFTypeRef?
        var size: CFTypeRef?
        var description: String?
        var title: String?
        for (name, value) in zip(names, values) {
            switch name {
            case kAXRoleAttribute: attributes.role = nonEmpty(value)
            case kAXChildrenAttribute: attributes.children = value as? [AXUIElement]
            case kAXPositionAttribute: position = value
            case kAXSizeAttribute: size = value
            case kAXIdentifierAttribute: attributes.identifier = nonEmpty(value)
            case kAXDescriptionAttribute: description = nonEmpty(value)
            case kAXTitleAttribute: title = nonEmpty(value)
            default: break
            }
        }
        attributes.title = description ?? title
        if let position, let size {
            attributes.frame = frame(position: position, size: size)
        }
        return attributes
    }

    /// The values of the given attributes, `nil` where the element has none.
    private static func attributeValues(_ element: AXUIElement, _ names: [String]) -> ([CFTypeRef?], AXError) {
        var values: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(element, names as CFArray, AXCopyMultipleAttributeOptions(), &values)
        guard result == .success, let values = values as? [CFTypeRef], values.count == names.count else {
            return (Array(repeating: nil, count: names.count), result == .success ? .failure : result)
        }
        // A missing attribute comes back as an error wrapped in an `AXValue`.
        return (values.map { value in
            if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { // swiftlint:disable:this force_cast
                return nil
            }
            return value
        }, result)
    }

    private static func nonEmpty(_ value: CFTypeRef?) -> String? {
        guard let string = value as? String, !string.isEmpty else {
            return nil
        }
        return string
    }

    private static func element(from value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement) // swiftlint:disable:this force_cast
    }

    private static func elements(_ element: AXUIElement, _ attribute: String, timeout: Float) -> [AXUIElement]? {
        AXUIElementSetMessagingTimeout(element, timeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? [AXUIElement]
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        attributes(of: element, [kAXPositionAttribute, kAXSizeAttribute]).frame
    }

    private static func frame(position positionValue: CFTypeRef, size sizeValue: CFTypeRef) -> CGRect? {
        guard
            CFGetTypeID(positionValue) == AXValueGetTypeID(),
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
