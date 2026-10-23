import Testing
@testable import IceMacOS27Core

@Suite("WritePacer27")
struct WritePacer27Tests {
    let hidden: Set<String> = ["com.example.a", "com.example.b"]
    let shown: Set<String> = []

    func pacer() -> WritePacer27<Set<String>> {
        WritePacer27(minimumSpacing: 0.7)
    }

    @Test("The first write happens at once")
    func firstImmediate() {
        var pacer = pacer()
        #expect(pacer.request(hidden, at: 10) == .writeNow)
        #expect(pacer.pending == nil)
    }

    @Test("A second request inside the spacing is held until it ends")
    func secondDeferred() {
        var pacer = pacer()
        _ = pacer.request(hidden, at: 10)
        pacer.didApply(hidden, wrote: true, at: 10)
        // Measured 2026-10-23: writes 0.39 s apart blacked the whole bar out.
        #expect(pacer.request(shown, at: 10.39) == .deferred(until: 10.7))
        #expect(pacer.pending == shown)
        #expect(pacer.takeDue(at: 10.5) == nil)
    }

    @Test("A third request inside the spacing replaces the second")
    func thirdReplaces() {
        var pacer = pacer()
        _ = pacer.request(shown, at: 10)
        pacer.didApply(shown, wrote: true, at: 10)
        #expect(pacer.request(hidden, at: 10.2) == .deferred(until: 10.7))
        let alwaysHidden: Set<String> = ["com.example.b"]
        #expect(pacer.request(alwaysHidden, at: 10.4) == .deferred(until: 10.7))
        #expect(pacer.pending == alwaysHidden)
    }

    @Test("The trailing write happens once, with the last request")
    func trailingOnce() {
        var pacer = pacer()
        _ = pacer.request(hidden, at: 10)
        pacer.didApply(hidden, wrote: true, at: 10)
        _ = pacer.request(shown, at: 10.1)
        _ = pacer.request(["com.example.a"], at: 10.3)
        #expect(pacer.takeDue(at: 10.71) == ["com.example.a"])
        #expect(pacer.takeDue(at: 10.8) == nil)
        pacer.didApply(["com.example.a"], wrote: true, at: 10.71)
        // The trailing write starts a spacing of its own.
        #expect(pacer.request(hidden, at: 11.0) == .deferred(until: 10.71 + 0.7))
    }

    @Test("Returning to the state already written leaves nothing held")
    func returnToWritten() {
        var pacer = pacer()
        _ = pacer.request(hidden, at: 10)
        pacer.didApply(hidden, wrote: true, at: 10)
        #expect(pacer.request(shown, at: 10.2) == .deferred(until: 10.7))
        #expect(pacer.request(hidden, at: 10.4) == .dropped)
        #expect(pacer.pending == nil)
        #expect(pacer.takeDue(at: 11) == nil)
    }

    @Test("An apply that wrote nothing starts no spacing")
    func noWriteNoSpacing() {
        var pacer = pacer()
        _ = pacer.request(hidden, at: 10)
        pacer.didApply(hidden, wrote: false, at: 10)
        #expect(pacer.request(shown, at: 10.1) == .writeNow)
    }

    @Test("Outside the spacing a request is written, even the same one again")
    func outsideWindow() {
        var pacer = pacer()
        _ = pacer.request(hidden, at: 10)
        pacer.didApply(hidden, wrote: true, at: 10)
        #expect(pacer.request(hidden, at: 10.71) == .writeNow)
    }
}
