import CoreGraphics
import Foundation
import Testing
@testable import IceMacOS27Core

@Suite("SyntheticWindowID27")
struct SyntheticWindowID27Tests {
    @Test("The same item always gets the same identifier")
    func stable() {
        let first = SyntheticWindowID27.make(bundleID: "eu.exelban.Stats", identifier: "Item#", index: 0)
        let second = SyntheticWindowID27.make(bundleID: "eu.exelban.Stats", identifier: "Item#", index: 0)
        #expect(first == second)
    }

    @Test("Different items get different identifiers")
    func distinct() {
        let first = SyntheticWindowID27.make(bundleID: "eu.exelban.Stats", identifier: "Item#", index: 0)
        let second = SyntheticWindowID27.make(bundleID: "eu.exelban.Stats", identifier: "Item#", index: 1)
        #expect(first != second)
    }

    @Test("Synthetic identifiers are recognisable and real ones are not")
    func recognisable() {
        let synthetic = SyntheticWindowID27.make(bundleID: "ru.keepcoder.Telegram", identifier: "Item-0", index: 0)
        #expect(SyntheticWindowID27.isSynthetic(synthetic))
        #expect(!SyntheticWindowID27.isSynthetic(24))
        #expect(!SyntheticWindowID27.isSynthetic(100_000))
    }
}

@Suite("OverflowDetection27")
struct OverflowDetection27Tests {
    // Measured on macOS 27.0, built-in display: the overflow button sits at x −619…−602.
    let button = CGRect(x: -619, y: 99, width: 17, height: 30)

    @Test("Folded items overlap the overflow button")
    func folded() {
        #expect(OverflowDetection27.isInOverflow(itemFrame: CGRect(x: -649, y: 102, width: 47, height: 24), chevronFrame: button))
        #expect(OverflowDetection27.isInOverflow(itemFrame: CGRect(x: -634, y: 102, width: 24, height: 24), chevronFrame: button))
    }

    @Test("A drawn item next to the button is not folded")
    func drawnNextToButton() {
        #expect(!OverflowDetection27.isInOverflow(itemFrame: CGRect(x: -588, y: 102, width: 24, height: 24), chevronFrame: button))
    }

    @Test("Items shown left of the notch while expanded are not folded")
    func expanded() {
        #expect(!OverflowDetection27.isInOverflow(itemFrame: CGRect(x: -904, y: 102, width: 36, height: 24), chevronFrame: button))
    }

    @Test("Without an overflow button nothing is folded")
    func noButton() {
        #expect(!OverflowDetection27.isInOverflow(itemFrame: CGRect(x: 0, y: 0, width: 24, height: 24), chevronFrame: nil))
    }
}

@Suite("ClockBridgeZone27")
struct ClockBridgeZone27Tests {
    let clock = CGRect(x: 1787, y: 0, width: 113, height: 30)

    @Test("A click on a system item is bridged while concealing")
    func bridged() {
        #expect(ClockBridgeZone27.shouldBridge(click: CGPoint(x: 1840, y: 15), systemItemFrames: [clock], isConcealing: true))
    }

    @Test("A click one point outside the frame still counts")
    func edgeTolerance() {
        #expect(ClockBridgeZone27.shouldBridge(click: CGPoint(x: 1786.5, y: 15), systemItemFrames: [clock], isConcealing: true))
    }

    @Test("A click elsewhere is not bridged")
    func elsewhere() {
        #expect(!ClockBridgeZone27.shouldBridge(click: CGPoint(x: 900, y: 12), systemItemFrames: [clock], isConcealing: true))
    }

    @Test("Nothing is bridged while nothing is concealed")
    func notConcealing() {
        #expect(!ClockBridgeZone27.shouldBridge(click: CGPoint(x: 1840, y: 15), systemItemFrames: [clock], isConcealing: false))
    }
}

@Suite("ItemHitTest27")
struct ItemHitTest27Tests {
    // Measured on macOS 27.0 with the external menu bar active.
    let stats = ItemHitTest27.Item(frame: CGRect(x: 1478, y: 2, width: 33, height: 24), ownerPID: 100, isOnScreen: true)
    let clock = CGRect(x: 1787, y: 0, width: 113, height: 30)
    // Built-in display: an item folded behind the overflow button, and the button itself.
    let folded = ItemHitTest27.Item(frame: CGRect(x: -649, y: 102, width: 47, height: 24), ownerPID: 200, isOnScreen: false)
    let overflowButton = CGRect(x: -619.5, y: 99, width: 17.5, height: 30)

    @Test("The pointer on a drawn item is inside an item")
    func drawnItem() {
        #expect(ItemHitTest27.isInsideItem(point: CGPoint(x: 1497, y: 14), items: [stats], concealedPIDs: [], systemFrames: [clock]))
    }

    @Test("An empty spot is not inside an item")
    func emptySpot() {
        #expect(!ItemHitTest27.isInsideItem(point: CGPoint(x: 900, y: 12), items: [stats], concealedPIDs: [], systemFrames: [clock]))
    }

    @Test("A concealed item's stale frame does not count")
    func concealed() {
        #expect(!ItemHitTest27.isInsideItem(point: CGPoint(x: 1497, y: 14), items: [stats], concealedPIDs: [100], systemFrames: []))
    }

    @Test("A folded item does not count, but the overflow button does")
    func overflow() {
        #expect(!ItemHitTest27.isInsideItem(point: CGPoint(x: -640, y: 114), items: [folded], concealedPIDs: [], systemFrames: []))
        #expect(ItemHitTest27.isInsideItem(point: CGPoint(x: -611, y: 114), items: [folded], concealedPIDs: [], systemFrames: [overflowButton]))
    }

    @Test("System items count on either display")
    func systemItems() {
        #expect(ItemHitTest27.isInsideItem(point: CGPoint(x: 1843, y: 12), items: [], concealedPIDs: [], systemFrames: [clock]))
    }
}

@Suite("AccessibilityScanSchedule27")
struct AccessibilityScanSchedule27Tests {
    typealias Schedule = AccessibilityScanSchedule27

    @Test("The first read is a sweep, and the next one comes a minute later")
    func sweeps() {
        var schedule = Schedule()
        #expect(schedule.isSweepDue(now: 0))
        schedule.recordSweep(now: 0)
        #expect(!schedule.isSweepDue(now: 59))
        #expect(schedule.isSweepDue(now: 60))
    }

    @Test("A sweep asks every process with the normal timeout")
    func sweep() {
        var schedule = Schedule()
        schedule.update(running: [10], now: 0)
        #expect(schedule.timeout(for: 10, sweeping: true, now: 0) == Schedule.normalTimeout)
    }

    @Test("A process without items is left out of reads between sweeps")
    func noItems() {
        var schedule = Schedule()
        schedule.update(running: [10], now: 0)
        schedule.record(pid: 10, timedOut: false, hasItems: false)
        schedule.recordSweep(now: 0)
        #expect(schedule.timeout(for: 10, sweeping: false, now: 1) == nil)
    }

    @Test("A process that has shown items is always asked, even when it timed out")
    func itemOwners() {
        var schedule = Schedule()
        schedule.update(running: [10], now: 0)
        schedule.record(pid: 10, timedOut: false, hasItems: true)
        schedule.record(pid: 10, timedOut: true, hasItems: false)
        #expect(schedule.itemOwners == [10])
        #expect(schedule.timeout(for: 10, sweeping: false, now: 1) == Schedule.normalTimeout)
    }

    @Test("A process that started after the first sweep is asked during its first seconds")
    func launch() {
        var schedule = Schedule()
        schedule.update(running: [10], now: 0)
        schedule.recordSweep(now: 0)
        schedule.update(running: [10, 11], now: 5)
        #expect(schedule.timeout(for: 10, sweeping: false, now: 5) == nil)
        #expect(schedule.timeout(for: 11, sweeping: false, now: 5) == Schedule.normalTimeout)
        #expect(schedule.timeout(for: 11, sweeping: false, now: 5 + Schedule.launchInterval) == nil)
    }

    @Test("A process that timed out is left out until the next sweep, which asks it briefly")
    func unanswered() {
        var schedule = Schedule()
        schedule.update(running: [10], now: 0)
        schedule.recordSweep(now: 0)
        schedule.update(running: [10, 11], now: 1)
        schedule.record(pid: 11, timedOut: true, hasItems: false)
        #expect(schedule.timeout(for: 11, sweeping: false, now: 2) == nil)
        #expect(schedule.timeout(for: 11, sweeping: true, now: 60) == Schedule.retryTimeout)
        schedule.record(pid: 11, timedOut: false, hasItems: false)
        #expect(schedule.timeout(for: 11, sweeping: true, now: 120) == Schedule.normalTimeout)
    }

    @Test("Exited processes are forgotten, so a reused identifier starts fresh")
    func forgetting() {
        var schedule = Schedule()
        schedule.update(running: [10], now: 0)
        schedule.record(pid: 10, timedOut: false, hasItems: true)
        schedule.recordSweep(now: 0)
        schedule.update(running: [11], now: 1)
        #expect(schedule.itemOwners.isEmpty)
        schedule.update(running: [10, 11], now: 2)
        #expect(schedule.timeout(for: 10, sweeping: false, now: 2) == Schedule.normalTimeout)
    }
}
