// The recorder's ring between the audio thread (one writer: the engine's record tap) and the writer thread (one
// reader). The audio thread never waits: it copies the block in, then publishes how far it got with a try-lock;
// a block that finds the ring full is dropped and counted, never written over unread audio. When the tap is gone
// (the engine says so, Engine.tapChanges), `finish` publishes whatever the last blocks couldn't.
import Foundation
import os

public final class RecordRing {
    public let capacity: Int
    let L: UnsafeMutablePointer<Float>, R: UnsafeMutablePointer<Float>
    // on the heap: a lock needs an address that never moves, which a Swift stored property doesn't promise
    let lock: UnsafeMutablePointer<os_unfair_lock> = { let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1); p.initialize(to: os_unfair_lock()); return p }()
    // shared, under the lock
    var w = 0, r = 0, dropped = 0
    // the audio thread's own
    var tapW = 0, tapR = 0, tapDropped = 0
    // the reader's own
    var rd = 0

    public init(capacity: Int) {
        self.capacity = capacity
        L = .allocate(capacity: capacity); R = .allocate(capacity: capacity)
        L.initialize(repeating: 0, count: capacity); R.initialize(repeating: 0, count: capacity)
    }
    deinit { L.deallocate(); R.deallocate(); lock.deallocate() }

    /// empty it for a new recording (only while no tap is installed and the reader is stopped)
    public func reset() {
        os_unfair_lock_lock(lock)
        w = 0; r = 0; dropped = 0; tapW = 0; tapR = 0; tapDropped = 0; rd = 0
        os_unfair_lock_unlock(lock)
    }

    /// audio thread: one block. `publish: false` stands for a try-lock that failed (tests).
    public func write(_ l: UnsafePointer<Float>, _ r: UnsafePointer<Float>, _ n: Int, publish: Bool = true) {
        var wi = tapW
        // one slot stays empty so a full ring can't look like an empty one; when it looks full, see how far the
        // reader has really got (the last publish may be a block old)
        if n > capacity - 1 - (wi - tapR + capacity) % capacity && publish && os_unfair_lock_trylock(lock) { tapR = self.r; os_unfair_lock_unlock(lock) }
        if n <= capacity - 1 - (wi - tapR + capacity) % capacity {
            for j in 0..<n { L[wi] = l[j]; R[wi] = r[j]; wi += 1; if wi == capacity { wi = 0 } }
            tapW = wi
        } else { tapDropped += n }
        if publish && os_unfair_lock_trylock(lock) {
            w = tapW; tapR = self.r; dropped += tapDropped; tapDropped = 0
            os_unfair_lock_unlock(lock)
        }
    }

    /// any thread, once the tap is gone: publish what the audio thread wrote last but couldn't publish
    public func finish() {
        os_unfair_lock_lock(lock)
        w = tapW; dropped += tapDropped; tapDropped = 0
        os_unfair_lock_unlock(lock)
    }

    /// reader: copies up to `max` frames out, returns how many
    public func read(into l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, max: Int) -> Int {
        os_unfair_lock_lock(lock); let wi = w; os_unfair_lock_unlock(lock)
        let m = min(max, (wi - rd + capacity) % capacity)
        for j in 0..<m { let k = (rd + j) % capacity; l[j] = L[k]; r[j] = R[k] }
        rd = (rd + m) % capacity
        os_unfair_lock_lock(lock); self.r = rd; os_unfair_lock_unlock(lock)     // that much room again for the tap
        return m
    }

    /// frames dropped because the reader fell behind (published ones)
    public var droppedFrames: Int { os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }; return dropped }
}
