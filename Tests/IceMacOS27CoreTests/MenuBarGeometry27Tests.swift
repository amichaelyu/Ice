import CoreGraphics
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
    let chevron = CGRect(x: -644, y: 102.5, width: 24, height: 24)

    @Test("An item reporting the chevron's position is in the overflow")
    func folded() {
        #expect(OverflowDetection27.isInOverflow(itemFrame: CGRect(x: -644, y: 102.5, width: 42, height: 24), chevronFrame: chevron))
    }

    @Test("An item elsewhere on the bar is not in the overflow")
    func drawn() {
        #expect(!OverflowDetection27.isInOverflow(itemFrame: CGRect(x: -585, y: 102.5, width: 24, height: 24), chevronFrame: chevron))
    }

    @Test("Without a chevron nothing is in the overflow")
    func noChevron() {
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
