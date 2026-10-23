// Watch mic (personal/heat only): what the watch app and the phone send each other over UDP while the watch is in
// a CallKit call (the one time watchOS lets a third-party app open its own network connection, TN3135).
// All little-endian. The voice goes as 16-bit mono at 24 kHz, 240 samples (10 ms) a packet.
import Foundation
import os

enum WatchMic {
    static let service = "_cbwatchmic._udp"
    static let port: UInt16 = 47123
    static let rate = 24000.0
    static let packetSamples = 240
}

enum WatchMicPacket {
    /// watch → phone: the voice. gain 0...2 is the watch crown, applied on the phone with a ramp so it never clicks
    case audio(seq: UInt32, gain: Float, muted: Bool, samples: [Int16])
    /// watch → phone, echoed back unchanged as .pong: round-trip time of the link
    case ping(id: UInt32, sent: Double)
    case pong(id: UInt32, sent: Double)
    /// phone → watch: how the phone's jitter buffer is doing
    case stats(bufferedMs: Float, underruns: UInt32, lost: UInt32)

    func encode() -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func f32(_ v: Float) { u32(v.bitPattern) }
        func f64(_ v: Double) { withUnsafeBytes(of: v.bitPattern.littleEndian) { d.append(contentsOf: $0) } }
        switch self {
        case let .audio(seq, gain, muted, samples):
            d.append(contentsOf: [UInt8(1), muted ? 1 : 0, 0, 0]); u32(seq); f32(gain)
            d.reserveCapacity(12 + samples.count * 2)
            for s in samples { withUnsafeBytes(of: s.littleEndian) { d.append(contentsOf: $0) } }
        case let .ping(id, sent): d.append(contentsOf: [UInt8(2), 0, 0, 0]); u32(id); f64(sent)
        case let .pong(id, sent): d.append(contentsOf: [UInt8(3), 0, 0, 0]); u32(id); f64(sent)
        case let .stats(ms, under, lost): d.append(contentsOf: [UInt8(4), 0, 0, 0]); f32(ms); u32(under); u32(lost)
        }
        return d
    }

    static func decode(_ d: Data) -> WatchMicPacket? {
        guard d.count >= 4 else { return nil }
        return d.withUnsafeBytes { (b: UnsafeRawBufferPointer) -> WatchMicPacket? in
            func u32(_ o: Int) -> UInt32 { UInt32(littleEndian: b.loadUnaligned(fromByteOffset: o, as: UInt32.self)) }
            func f32(_ o: Int) -> Float { Float(bitPattern: u32(o)) }
            func f64(_ o: Int) -> Double { Double(bitPattern: UInt64(littleEndian: b.loadUnaligned(fromByteOffset: o, as: UInt64.self))) }
            switch b[0] {
            case 1:
                guard b.count >= 12 else { return nil }
                let n = (b.count - 12) / 2
                var s = [Int16](repeating: 0, count: n)
                for i in 0..<n { s[i] = Int16(littleEndian: b.loadUnaligned(fromByteOffset: 12 + 2 * i, as: Int16.self)) }
                return .audio(seq: u32(4), gain: f32(8), muted: b[1] != 0, samples: s)
            case 2: return b.count >= 16 ? .ping(id: u32(4), sent: f64(8)) : nil
            case 3: return b.count >= 16 ? .pong(id: u32(4), sent: f64(8)) : nil
            case 4: return b.count >= 16 ? .stats(bufferedMs: f32(4), underruns: u32(8), lost: u32(12)) : nil
            default: return nil
            }
        }
    }
}

/// Fixed-size float FIFO shared by a real-time audio thread and a normal one. Nothing allocates after init; the
/// audio side uses the try… calls, which give up (return nil) rather than wait if the other side holds the lock.
final class FloatRing {
    let capacity: Int
    private let buf: UnsafeMutablePointer<Float>
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var r = 0, n = 0

    init(capacity: Int) {
        self.capacity = capacity
        buf = .allocate(capacity: capacity); buf.initialize(repeating: 0, count: capacity)
        lock = .allocate(capacity: 1); lock.initialize(to: os_unfair_lock())
    }
    deinit { buf.deallocate(); lock.deallocate() }

    var count: Int { os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }; return n }

    /// adds k samples; when full, the oldest are dropped
    func write(_ src: UnsafePointer<Float>, _ k: Int) { os_unfair_lock_lock(lock); put(src, k); os_unfair_lock_unlock(lock) }
    func tryWrite(_ src: UnsafePointer<Float>, _ k: Int) -> Bool {
        guard os_unfair_lock_trylock(lock) else { return false }
        put(src, k); os_unfair_lock_unlock(lock); return true
    }
    /// up to k samples into dst; returns how many
    func read(_ dst: UnsafeMutablePointer<Float>, _ k: Int) -> Int { os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }; return take(dst, k) }
    func tryRead(_ dst: UnsafeMutablePointer<Float>, _ k: Int) -> Int? {
        guard os_unfair_lock_trylock(lock) else { return nil }
        defer { os_unfair_lock_unlock(lock) }
        return take(dst, k)
    }
    /// count, or nil if busy (audio thread)
    func tryCount() -> Int? {
        guard os_unfair_lock_trylock(lock) else { return nil }
        defer { os_unfair_lock_unlock(lock) }
        return n
    }
    /// throws away the oldest samples so at most `keep` remain
    func trim(to keep: Int) { os_unfair_lock_lock(lock); if n > keep { r = (r + n - keep) % capacity; n = keep }; os_unfair_lock_unlock(lock) }
    func clear() { os_unfair_lock_lock(lock); r = 0; n = 0; os_unfair_lock_unlock(lock) }

    private func put(_ src: UnsafePointer<Float>, _ k0: Int) {
        var k = k0, s = src
        if k > capacity { s += k - capacity; k = capacity }
        let over = n + k - capacity
        if over > 0 { r = (r + over) % capacity; n -= over }
        var w = (r + n) % capacity
        for i in 0..<k { buf[w] = s[i]; w += 1; if w == capacity { w = 0 } }
        n += k
    }
    private func take(_ dst: UnsafeMutablePointer<Float>, _ k: Int) -> Int {
        let m = min(k, n)
        for i in 0..<m { dst[i] = buf[r]; r += 1; if r == capacity { r = 0 } }
        n -= m
        return m
    }
}
