import CoreGraphics
import Testing
@testable import IceMacOS27Core

@Suite("DropSection27")
struct DropSection27Tests {
    /// An item 20 points wide whose centre lies at the given x.
    private func item(at midX: CGFloat) -> CGRect {
        CGRect(x: midX - 10, y: 0, width: 20, height: 24)
    }

    /// Always hidden at 100–150, hidden at 200–300, visible at 400–500.
    private let full = DropSection27.Runs(
        visible: [CGRect(x: 400, y: 0, width: 20, height: 24), CGRect(x: 480, y: 0, width: 20, height: 24)],
        hidden: [CGRect(x: 200, y: 0, width: 20, height: 24), CGRect(x: 280, y: 0, width: 20, height: 24)],
        alwaysHidden: [CGRect(x: 100, y: 0, width: 20, height: 24), CGRect(x: 130, y: 0, width: 20, height: 24)]
    )

    @Test("A drop inside the hidden run hides a visible application")
    func insideHiddenRun() {
        #expect(DropSection27.section(dropped: item(at: 250), runs: full, current: .visible) == .hidden)
    }

    @Test("A drop between the hidden run and the visible run is hidden")
    func betweenHiddenAndVisible() {
        #expect(DropSection27.section(dropped: item(at: 350), runs: full, current: .visible) == .hidden)
    }

    @Test("A drop right of the hidden run, among the visible items, is visible")
    func rightOfHiddenRun() {
        #expect(DropSection27.section(dropped: item(at: 450), runs: full, current: .hidden) == .visible)
        #expect(DropSection27.section(dropped: item(at: 600), runs: full, current: .alwaysHidden) == .visible)
    }

    @Test("A drop within or left of the always-hidden run is always hidden")
    func alwaysHiddenRun() {
        #expect(DropSection27.section(dropped: item(at: 125), runs: full, current: .visible) == .alwaysHidden)
        #expect(DropSection27.section(dropped: item(at: 40), runs: full, current: .hidden) == .alwaysHidden)
    }

    @Test("A drop between the always-hidden and hidden runs is hidden")
    func betweenAlwaysHiddenAndHidden() {
        #expect(DropSection27.section(dropped: item(at: 175), runs: full, current: .alwaysHidden) == .hidden)
    }

    @Test("Interleaved runs: the hidden span wins over the visible one")
    func interleaved() {
        let runs = DropSection27.Runs(
            visible: [CGRect(x: 250, y: 0, width: 20, height: 24), CGRect(x: 400, y: 0, width: 20, height: 24)],
            hidden: [CGRect(x: 200, y: 0, width: 20, height: 24), CGRect(x: 300, y: 0, width: 20, height: 24)]
        )
        #expect(DropSection27.section(dropped: item(at: 260), runs: runs, current: .visible) == .hidden)
        #expect(DropSection27.section(dropped: item(at: 360), runs: runs, current: .hidden) == .visible)
    }

    @Test("Nothing changes when the drop lands in the application's own section")
    func unchanged() {
        #expect(DropSection27.section(dropped: item(at: 250), runs: full, current: .hidden) == nil)
        #expect(DropSection27.section(dropped: item(at: 450), runs: full, current: .visible) == nil)
    }

    @Test("Unknown frames give no answer")
    func unknownFrames() {
        #expect(DropSection27.section(dropped: nil, runs: full, current: .visible) == nil)
        #expect(DropSection27.section(dropped: .null, runs: full, current: .visible) == nil)
        #expect(DropSection27.section(dropped: .zero, runs: full, current: .visible) == nil)
        #expect(DropSection27.section(dropped: item(at: 250), runs: .init(), current: .visible) == nil)
    }

    @Test("No hidden items drawn: left of the visible run is hidden, within it visible")
    func emptyHiddenRun() {
        let runs = DropSection27.Runs(visible: full.visible)
        #expect(DropSection27.section(dropped: item(at: 380), runs: runs, current: .visible) == .hidden)
        #expect(DropSection27.section(dropped: item(at: 450), runs: runs, current: .hidden) == .visible)
    }

    @Test("No visible items drawn: right of the hidden run is visible")
    func emptyVisibleRun() {
        let runs = DropSection27.Runs(hidden: full.hidden)
        #expect(DropSection27.section(dropped: item(at: 350), runs: runs, current: .hidden) == .visible)
        #expect(DropSection27.section(dropped: item(at: 150), runs: runs, current: .visible) == .hidden)
    }

    @Test("No always-hidden items drawn: left of the hidden run is only hidden")
    func emptyAlwaysHiddenRun() {
        let runs = DropSection27.Runs(visible: full.visible, hidden: full.hidden)
        #expect(DropSection27.section(dropped: item(at: 40), runs: runs, current: .visible) == .hidden)
    }

    @Test("Only always-hidden items drawn: right of them is hidden")
    func onlyAlwaysHiddenRun() {
        let runs = DropSection27.Runs(alwaysHidden: full.alwaysHidden)
        #expect(DropSection27.section(dropped: item(at: 300), runs: runs, current: .visible) == .hidden)
        #expect(DropSection27.section(dropped: item(at: 120), runs: runs, current: .visible) == .alwaysHidden)
    }

    @Test("An item put back where it was picked up says nothing")
    func putBack() {
        let result = DropSection27.section(
            dropped: item(at: 352),
            picked: item(at: 350),
            runs: full,
            current: .visible,
            hiddenRevealed: true
        )
        #expect(result == nil)
    }

    @Test("A moved item is judged by the rule")
    func moved() {
        let result = DropSection27.section(
            dropped: item(at: 250),
            picked: item(at: 450),
            runs: full,
            current: .visible,
            hiddenRevealed: true
        )
        #expect(result == .hidden)
    }

    @Test("Hidden section not revealed: a drop only reorders")
    func notRevealed() {
        let runs = DropSection27.Runs(visible: full.visible)
        // The leftmost visible place, which used to read as hiding.
        #expect(DropSection27.section(dropped: item(at: 380), picked: item(at: 460), runs: runs, current: .visible, hiddenRevealed: false) == nil)
        #expect(DropSection27.section(dropped: item(at: 450), picked: nil, runs: runs, current: .hidden, hiddenRevealed: false) == nil)
    }

    @Test("No always-hidden items drawn: an always-hidden application left of the rest stays")
    func alwaysHiddenStaysWithoutRun() {
        let runs = DropSection27.Runs(visible: full.visible, hidden: full.hidden)
        #expect(DropSection27.section(dropped: item(at: 150), runs: runs, current: .alwaysHidden) == nil)
        #expect(DropSection27.section(dropped: item(at: 250), runs: runs, current: .alwaysHidden) == .hidden)
        #expect(DropSection27.section(dropped: item(at: 450), runs: runs, current: .alwaysHidden) == .visible)
        // Only the visible run drawn: left of it is still the application's own place.
        let visibleOnly = DropSection27.Runs(visible: full.visible)
        #expect(DropSection27.section(dropped: item(at: 350), runs: visibleOnly, current: .alwaysHidden) == nil)
        // A hidden application left of everything is still hidden, not always hidden.
        #expect(DropSection27.section(dropped: item(at: 150), runs: runs, current: .hidden) == nil)
    }

    @Test("An item folded behind the overflow button is judged at the button")
    func foldedItemAtButton() {
        let button = CGRect(x: 80, y: 0, width: 18, height: 24)
        let folded = CGRect(x: 82, y: 0, width: 20, height: 24)
        #expect(DropSection27.judgedFrame(folded, overflowButton: button) == button)
        #expect(DropSection27.judgedFrame(item(at: 250), overflowButton: button) == item(at: 250))
        #expect(DropSection27.judgedFrame(folded, overflowButton: nil) == folded)
        // Folded always-hidden items mark the run at the button, so a drop there is always hidden.
        let runs = DropSection27.Runs(visible: full.visible, hidden: full.hidden, alwaysHidden: [button])
        #expect(DropSection27.section(dropped: button, runs: runs, current: .hidden) == .alwaysHidden)
    }

    @Test("The nearest of an application's items is the one dropped")
    func nearest() {
        let frames = [item(at: 100), item(at: 300), item(at: 420)]
        #expect(DropSection27.nearest(to: CGPoint(x: 330, y: 12), in: frames) == item(at: 300))
        #expect(DropSection27.nearest(to: CGPoint(x: 0, y: 12), in: []) == nil)
    }
}
