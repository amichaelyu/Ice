import CoreGraphics
import Foundation
import Testing
@testable import IceMacOS27Core

@Suite("Temporary allowances")
struct TemporaryAllowance27Tests {
    let layout: [String: MacOS27Section] = [
        "ru.keepcoder.Telegram": .hidden,
        "com.caldis.Mos": .alwaysHidden,
    ]

    @Test("A temporarily shown application leaves the concealed set")
    func removed() {
        let sets = ConcealmentPlanner27.concealedSets(layout: layout, state: .allHidden, temporarilyShown: ["ru.keepcoder.Telegram"])
        #expect(sets == [["com.caldis.Mos"]])
    }

    @Test("Showing the only concealed application needs no assertion")
    func nothingLeft() {
        let sets = ConcealmentPlanner27.concealedSets(layout: layout, state: .hiddenRevealed, temporarilyShown: ["com.caldis.Mos"])
        #expect(sets.isEmpty)
    }

    @Test("Without temporary allowances the sets are unchanged")
    func unchanged() {
        let plain = ConcealmentPlanner27.concealedSets(layout: layout, state: .allHidden)
        #expect(ConcealmentPlanner27.concealedSets(layout: layout, state: .allHidden, temporarilyShown: []) == plain)
    }
}
