import Testing
@testable import IceMacOS27Core

@Suite("ItemOrder27")
struct ItemOrder27Tests {
    @Test("The key matches MenuBarAgent's")
    func key() {
        #expect(ItemOrder27.key(bundleID: "eu.exelban.Stats", title: "RAM_mini") == "status:eu.exelban.Stats::RAM_mini")
    }

    @Test("An item between two neighbours goes halfway")
    func between() {
        #expect(ItemOrder27.position(left: 370, right: 330) == 350)
    }

    @Test("An item at either end goes just past its one neighbour")
    func ends() {
        #expect(ItemOrder27.position(left: 370, right: nil) == 369)
        #expect(ItemOrder27.position(left: nil, right: 330) == 331)
        #expect(ItemOrder27.position(left: 0.5, right: nil) == 0)
        #expect(ItemOrder27.position(left: nil, right: nil) == nil)
    }

    @Test("Neighbours without a saved position are passed over")
    func skipsUnsaved() {
        let positions = ["b": 400.0, "d": 300]
        #expect(ItemOrder27.position(leftNeighbours: ["a", "b"], rightNeighbours: ["c", "d"], in: positions) == 350)
        #expect(ItemOrder27.position(leftNeighbours: ["a"], rightNeighbours: ["c"], in: positions) == nil)
    }
}
