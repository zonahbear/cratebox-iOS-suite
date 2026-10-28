import XCTest
@testable import CrateboxKit

/// The recorder's ring: the audio thread never waits, nothing unread is written over, and the tail that the last
/// block couldn't publish still reaches the file.
final class RecordRingTests: XCTestCase {
    func block(_ v: Float, _ n: Int) -> [Float] { [Float](repeating: v, count: n) }
    func drain(_ ring: RecordRing) -> [Float] {
        let l = UnsafeMutablePointer<Float>.allocate(capacity: 4096), r = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
        defer { l.deallocate(); r.deallocate() }
        var out = [Float]()
        while true { let m = ring.read(into: l, r, max: 4096); if m == 0 { break }; out += Array(UnsafeBufferPointer(start: l, count: m)) }
        return out
    }
    /// the last block's try-lock fails, then the tap is removed: finish() hands its frames over
    func testTheLastBlockReachesTheReaderAfterAFailedTryLock() {
        let ring = RecordRing(capacity: 1024)
        let a = block(1, 128), b = block(2, 128)
        ring.write(a, a, 128)
        ring.write(b, b, 128, publish: false)          // the try-lock failed on the final block
        XCTAssertEqual(drain(ring).count, 128, "before finish only the published block is visible")
        ring.finish()
        let tail = drain(ring)
        XCTAssertEqual(tail.count, 128)
        XCTAssertEqual(tail.first, 2)
        XCTAssertEqual(ring.droppedFrames, 0)
    }
    /// a reader that falls behind: blocks that don't fit are dropped and counted, the unread audio is kept
    func testAFullRingDropsAndCountsInsteadOfOverwriting() {
        let ring = RecordRing(capacity: 512)
        for k in 0..<5 { let x = block(Float(k + 1), 128); ring.write(x, x, 128) }     // room for 3 blocks (511 frames)
        let got = drain(ring)
        XCTAssertEqual(got.count, 384)
        XCTAssertEqual(Array(Set(got)).sorted(), [1, 2, 3])
        XCTAssertEqual(ring.droppedFrames, 256)
        let y = block(9, 128); ring.write(y, y, 128)      // room again once read
        XCTAssertEqual(drain(ring), y)
    }
}
