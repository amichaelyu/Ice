import CoreGraphics
import Testing
@testable import IceMacOS27Core

@Suite("StuckOverflow27")
struct StuckOverflow27Tests {
    // Measured on macOS 27.0: a 14-inch built-in display, 790 points unobscured on each side.
    let display = CGRect(x: 0, y: 0, width: 1800, height: 1169)
    var notch: ClosedRange<CGFloat>? {
        StuckOverflow27.notchSpan(displayBounds: display, leftAreaWidth: 790, rightAreaWidth: 790)
    }

    @Test("The notch spans the part of the bar between the unobscured areas")
    func span() {
        #expect(notch == 790...1010)
        #expect(StuckOverflow27.notchSpan(displayBounds: display, leftAreaWidth: nil, rightAreaWidth: nil) == nil)
    }

    @Test("Items laid out side by side are not stuck")
    func laidOut() {
        // Measured on macOS 27.0: neighbours overlap by 2 points.
        let frames = [
            CGRect(x: 1242, y: 7.5, width: 34, height: 24),
            CGRect(x: 1274, y: 7.5, width: 34, height: 24),
            CGRect(x: 1306, y: 7.5, width: 34, height: 24),
            CGRect(x: 1338, y: 7.5, width: 38, height: 24),
            CGRect(x: 1374, y: 7.5, width: 34, height: 24),
        ]
        #expect(!StuckOverflow27.isStuck(visibleItemFrames: frames, chevronFrame: nil, notchSpan: notch))
    }

    @Test("Items stacked on one another with no overflow button are stuck")
    func stacked() {
        let frames = [
            CGRect(x: 1020, y: 2, width: 30, height: 24),
            CGRect(x: 1022, y: 2, width: 30, height: 24),
            CGRect(x: 1400, y: 2, width: 30, height: 24),
        ]
        #expect(StuckOverflow27.isStuck(visibleItemFrames: frames, chevronFrame: nil, notchSpan: notch))
    }

    @Test("An item under the notch with no overflow button is stuck")
    func underNotch() {
        let frames = [CGRect(x: 980, y: 2, width: 30, height: 24), CGRect(x: 1400, y: 2, width: 30, height: 24)]
        #expect(StuckOverflow27.isStuck(visibleItemFrames: frames, chevronFrame: nil, notchSpan: notch))
    }

    @Test("Folded items are expected while the overflow button is there")
    func withChevron() {
        let frames = [CGRect(x: 1020, y: 2, width: 30, height: 24), CGRect(x: 1022, y: 2, width: 30, height: 24)]
        let chevron = CGRect(x: 1030, y: 2, width: 17, height: 30)
        #expect(!StuckOverflow27.isStuck(visibleItemFrames: frames, chevronFrame: chevron, notchSpan: notch))
    }

    @Test("A display without a notch is never stuck")
    func noNotch() {
        let frames = [CGRect(x: 1020, y: 2, width: 30, height: 24), CGRect(x: 1022, y: 2, width: 30, height: 24)]
        #expect(!StuckOverflow27.isStuck(visibleItemFrames: frames, chevronFrame: nil, notchSpan: nil))
    }

    @Test("Ice's collapsed items do not count")
    func collapsed() {
        let frames = [CGRect(x: 1400, y: 2, width: 0, height: 24), CGRect(x: 1400, y: 2, width: 30, height: 24)]
        #expect(!StuckOverflow27.isStuck(visibleItemFrames: frames, chevronFrame: nil, notchSpan: notch))
    }
}

@Suite("Stuck overflow on a bar that is not active")
struct StuckOverflowByCount27Tests {
    @Test("The system group is taken off every bar's entries")
    func countsApplicationItems() {
        // The active bar as measured on 2026-10-02: five application items and the four system ones.
        let counts = StuckOverflow27.applicationEntryCounts(bars: [1: (entries: 9, systemItemsWithGeometry: 4)])
        #expect(counts == [1: 5])
    }

    @Test("System items listed without geometry are not taken for application items")
    func systemItemsWithoutGeometry() {
        // Measured on macOS 27.0.1, 2026-10-22: both bars list the same ten entries. The active,
        // notched bar has geometry for its six system items; the external bar for four of them,
        // with six entries at 0,0 — Wi-Fi and battery among them.
        let counts = StuckOverflow27.applicationEntryCounts(bars: [
            1: (entries: 10, systemItemsWithGeometry: 6),
            2: (entries: 10, systemItemsWithGeometry: 4),
        ])
        #expect(counts == [1: 4, 2: 4])
        #expect(!StuckOverflow27.isStuck(drawnApplicationItems: counts[1]!, expectedApplicationItems: counts[2]!))
    }

    @Test("A bar missing items counts fewer of them")
    func countsWhatIsLeft() {
        // The built-in bar on 2026-10-02 with four of five items folded away.
        let counts = StuckOverflow27.applicationEntryCounts(bars: [
            1: (entries: 5, systemItemsWithGeometry: 4),
            2: (entries: 9, systemItemsWithGeometry: 0),
        ])
        #expect(counts == [1: 1, 2: 5])
    }

    @Test("With no system group to measure by, nothing is counted")
    func noSystemGroup() {
        let counts = StuckOverflow27.applicationEntryCounts(bars: [1: (entries: 9, systemItemsWithGeometry: 0)])
        #expect(counts.isEmpty)
    }

    @Test("A bar drawing fewer items than there are is stuck")
    func fewerThanExpected() {
        #expect(StuckOverflow27.isStuck(drawnApplicationItems: 1, expectedApplicationItems: 5))
    }

    @Test("A bar drawing them all is not")
    func allDrawn() {
        #expect(!StuckOverflow27.isStuck(drawnApplicationItems: 5, expectedApplicationItems: 5))
        #expect(!StuckOverflow27.isStuck(drawnApplicationItems: 6, expectedApplicationItems: 5))
    }

    @Test("With nothing to draw there is nothing to miss")
    func nothingExpected() {
        #expect(!StuckOverflow27.isStuck(drawnApplicationItems: 0, expectedApplicationItems: 0))
    }
}

@Suite("Stuck overflow on a notched bar")
struct NotchedBarStuck27Tests {
    @Test("A bar listing its own overflow button is never stuck")
    func listsChevron() {
        // As seen on macOS 27.0.1: the built-in bar overflowing with its « drawn, while the
        // external display's bar lists more items.
        #expect(!StuckOverflow27.isNotchedBarStuck(
            listsOverflowButton: true,
            listedApplicationItems: 6,
            mostListedElsewhere: 19,
            geometryLooksStuck: { true }
        ))
        #expect(!StuckOverflow27.isNotchedBarStuck(
            listsOverflowButton: true,
            listedApplicationItems: 6,
            mostListedElsewhere: nil,
            geometryLooksStuck: { true }
        ))
    }

    @Test("Without the button, a bar listing fewer items than another is stuck")
    func comparesCounts() {
        #expect(StuckOverflow27.isNotchedBarStuck(
            listsOverflowButton: false,
            listedApplicationItems: 1,
            mostListedElsewhere: 5,
            geometryLooksStuck: { false }
        ))
        #expect(!StuckOverflow27.isNotchedBarStuck(
            listsOverflowButton: false,
            listedApplicationItems: 5,
            mostListedElsewhere: 5,
            geometryLooksStuck: { true }
        ))
    }

    @Test("The only bar there is falls back on its geometry")
    func singleDisplay() {
        var asked = false
        let stuck = StuckOverflow27.isNotchedBarStuck(
            listsOverflowButton: false,
            listedApplicationItems: 5,
            mostListedElsewhere: nil,
            geometryLooksStuck: { asked = true; return true }
        )
        #expect(stuck && asked)
        #expect(!StuckOverflow27.isNotchedBarStuck(
            listsOverflowButton: false,
            listedApplicationItems: 5,
            mostListedElsewhere: nil,
            geometryLooksStuck: { false }
        ))
    }
}
