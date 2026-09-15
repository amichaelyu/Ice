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

@Suite("ItemImages27")
struct ItemImages27Tests {
    @Test("An item on a 1x display crops to its own frame")
    func externalCrop() {
        let rect = ItemImages27.cropRect(
            itemFrame: CGRect(x: 1478, y: 2, width: 33, height: 24),
            stripFrame: CGRect(x: 0, y: 0, width: 1920, height: 30),
            scale: 1
        )
        #expect(rect == CGRect(x: 1478, y: 2, width: 33, height: 24))
    }

    @Test("An item on a 2x display left of the primary one crops in pixels")
    func builtInCrop() {
        let rect = ItemImages27.cropRect(
            itemFrame: CGRect(x: -442, y: 102.5, width: 33, height: 24),
            stripFrame: CGRect(x: -1512, y: 98, width: 1512, height: 33),
            scale: 2
        )
        #expect(rect == CGRect(x: 2140, y: 9, width: 66, height: 48))
    }

    @Test("An item on another display has no crop")
    func otherDisplay() {
        let rect = ItemImages27.cropRect(
            itemFrame: CGRect(x: 1478, y: 2, width: 33, height: 24),
            stripFrame: CGRect(x: -1512, y: 98, width: 1512, height: 33),
            scale: 2
        )
        #expect(rect == nil)
    }

    @Test("File names are stable, distinct and safe")
    func fileNames() {
        let name = ItemImages27.fileName(forTag: "eu.exelban.Stats:Item-0")
        #expect(name == ItemImages27.fileName(forTag: "eu.exelban.Stats:Item-0"))
        #expect(name != ItemImages27.fileName(forTag: "eu.exelban.Stats:Item-1"))
        #expect(name.hasSuffix(".png"))
        #expect(!name.contains("/") && !name.contains(":"))
    }
}

@Suite("PhotoSchedule27")
struct PhotoSchedule27Tests {
    @Test("An application is photographed at most once every ten minutes")
    func interval() {
        var schedule = PhotoSchedule27()
        #expect(schedule.mayPhotograph(bundleID: "ru.keepcoder.Telegram", now: 0))
        schedule.recordAttempt(bundleID: "ru.keepcoder.Telegram", now: 0)
        #expect(!schedule.mayPhotograph(bundleID: "ru.keepcoder.Telegram", now: 599))
        #expect(schedule.mayPhotograph(bundleID: "ru.keepcoder.Telegram", now: 600))
    }

    @Test("Applications are scheduled independently")
    func independent() {
        var schedule = PhotoSchedule27()
        schedule.recordAttempt(bundleID: "ru.keepcoder.Telegram", now: 0)
        #expect(schedule.mayPhotograph(bundleID: "com.caldis.Mos", now: 1))
    }
}
