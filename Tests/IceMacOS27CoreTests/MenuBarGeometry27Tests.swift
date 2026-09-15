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

@Suite("IceIconVisibility27")
struct IceIconVisibility27Tests {
    // Measured on macOS 27.0: the external display is primary, the built-in one sits to its left.
    let screens = [
        CGRect(x: 0, y: 0, width: 1920, height: 1080),
        CGRect(x: -1512, y: 0, width: 1512, height: 982),
    ]

    @Test("An icon overhanging the top of a 30 pt bar is on screen")
    func overhangingTallerDisplay() {
        // Ice launched while the external menu bar was active: 33 pt window, top at 1082.
        #expect(IceIconVisibility27.isOnScreen(iconFrame: CGRect(x: 1394, y: 1049, width: 33, height: 33), screenFrames: screens))
    }

    @Test("An icon on the shorter display is on screen")
    func shorterDisplay() {
        #expect(IceIconVisibility27.isOnScreen(iconFrame: CGRect(x: -526, y: 949, width: 33, height: 33), screenFrames: screens))
    }

    @Test("An icon moved above the top of its display is not on screen")
    func aboveTop() {
        #expect(!IceIconVisibility27.isOnScreen(iconFrame: CGRect(x: 1394, y: 1080, width: 33, height: 33), screenFrames: screens))
        #expect(!IceIconVisibility27.isOnScreen(iconFrame: CGRect(x: -526, y: 982, width: 33, height: 33), screenFrames: screens))
    }
}
