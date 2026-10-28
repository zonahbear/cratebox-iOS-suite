import XCTest
@testable import CrateboxKit

/// Cratebox USB's late results: reads that finish out of order, or after an eject and a reopen of the same stick
final class RequestTokensTests: XCTestCase {
    func testNewerRequestsAndNewSessionsMakeOldResultsStale() {
        var t = RequestTokens()
        let a = t.begin("reload"), b = t.begin("reload"), s = t.begin("scan")
        XCTAssertFalse(t.isCurrent(a)); XCTAssertTrue(t.isCurrent(b)); XCTAssertTrue(t.isCurrent(s))
        t.newSession()                                          // eject, then the same URL opened again
        let c = t.begin("reload")
        XCTAssertFalse(t.isCurrent(b)); XCTAssertFalse(t.isCurrent(s)); XCTAssertTrue(t.isCurrent(c))
    }
    /// two background reloads, the first finishing last (held back by a semaphore): only the second is applied
    func testOutOfOrderCompletionKeepsTheNewest() {
        var tokens = RequestTokens()
        var applied = [String]()
        let main = DispatchQueue(label: "main-stand-in")
        let firstMayFinish = DispatchSemaphore(value: 0), done = DispatchGroup()
        func reload(_ name: String, wait: DispatchSemaphore?) {
            let tok = main.sync { tokens.begin("reload") }
            done.enter()
            DispatchQueue.global().async {
                wait?.wait()
                main.async { if tokens.isCurrent(tok) { applied.append(name) }; done.leave() }
            }
        }
        reload("old", wait: firstMayFinish)
        reload("new", wait: nil)
        main.sync {}                                             // let "new" land first...
        Thread.sleep(forTimeInterval: 0.05)
        firstMayFinish.signal()                                  // ...then "old"
        XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
        main.sync {}
        XCTAssertEqual(applied, ["new"])
    }
}
