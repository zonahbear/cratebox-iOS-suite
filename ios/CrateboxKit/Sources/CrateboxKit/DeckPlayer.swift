// Deck player: a line-by-line port of the web app's DeckPlayer (the WORKLET in cratebox.html), so a
// deck sounds the same on iOS. Tested sample for sample against the JS (Fixtures/dsp, made by
// ios/tools/dsp_oracle.js). Real-time safe: render() doesn't allocate or lock.
//
// With master tempo (keylock) on, the playhead still moves at the tempo rate, but the sound is rebuilt
// from 46 ms grains played at normal speed (WSOLA): each new grain is taken near the playhead, at the
// offset that best lines up with the previous grain's tail.
import Foundation

/// JS Math.round: halves go up (toward +infinity).
@inline(__always) func jsRound(_ x: Double) -> Double { (x + 0.5).rounded(.down) }

public enum DeckMessage {
    case unload
    case load(mt: Bool?, spin: Double?)          // the audio itself is given with setTrack
    case play(Bool)
    case rate(Double)
    case seek(Double, seq: Int)
    case bend(Double)
    case scratch(Bool, noCoast: Bool)
    case spin(Double)
    case jog(Double)
    case loop(on: Bool, a: Double, b: Double)
    case mt(Bool)
}

public final class DeckPlayer {
    public let sampleRate: Double
    // the track: owned by whoever loaded it, kept alive by `track`
    public private(set) var track: PCMTrack?
    var L: UnsafePointer<Float>? { track.map { UnsafePointer($0.left) } }
    var R: UnsafePointer<Float>? { track.map { UnsafePointer($0.right) } }
    public private(set) var len = 0
    public private(set) var pos = 0.0
    public private(set) var playing = false
    public private(set) var rate = 1.0
    var bend = 0.0
    public private(set) var scratching = false
    var target = 0.0, vel = 0.0
    var loopOn = false, loopIn = 0.0, loopOut = 0.0
    var amp = 0.0
    public private(set) var ended = false
    public private(set) var coast = false
    var spinA = 9 / 2.5
    public private(set) var seq = 0
    // keylock
    public private(set) var mt = false
    let H: Int, Nw: Int, S: Int, ramp: Int
    let win: UnsafeMutablePointer<Float>
    var gS = [0.0, 0.0], gK = [Int32(0), Int32(0)], gF = [UInt8(0), UInt8(0)]
    var cur = 0, ph = 0, prevS = 0.0, fresh = true
    let buf: UnsafeMutablePointer<Float>, tpl: UnsafeMutablePointer<Float>
    let bufCount: Int

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        H = Int(jsRound(0.023 * sampleRate)); Nw = 2 * H
        S = Int(jsRound(0.013 * sampleRate))
        ramp = Int(jsRound(0.002 * sampleRate))
        win = .allocate(capacity: Nw)
        for k in 0..<Nw { win[k] = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(k) / Double(Nw))) }
        bufCount = 2 * S + H + 8
        buf = .allocate(capacity: bufCount); buf.initialize(repeating: 0, count: bufCount)
        tpl = .allocate(capacity: H); tpl.initialize(repeating: 0, count: H)
        gS.reserveCapacity(2); gK.reserveCapacity(2); gF.reserveCapacity(2)
        flush()
    }
    deinit { win.deallocate(); buf.deallocate(); tpl.deallocate() }

    func flush() { gK[0] = Int32(Nw); gK[1] = Int32(Nw); ph = 0; fresh = true }

    /// The audio to play (call `handle(.load)` right after, like the JS "load" message).
    public func setTrack(_ t: PCMTrack?) { track = t; len = t?.count ?? 0 }

    public func handle(_ m: DeckMessage) {
        switch m {
        case .unload: track = nil; len = 0; playing = false; amp = 0
        case .load(let mtv, let spin):
            pos = 0; target = 0
            playing = false; loopOn = false; amp = 0; vel = 0; ended = false
            if let mtv { mt = mtv }
            if let spin, spin != 0 { spinA = 9 / spin }
            coast = false; flush()
        case .play(let v): playing = v; if v { ended = false }
        case .rate(let v): rate = v
        case .seek(let v, let s):
            seq = s; pos = max(0, min(Double(len - 2), v)); target = pos; vel = 0; coast = false; flush()
        case .bend(let v): bend = max(-0.6, min(0.6, bend + v))
        case .scratch(let v, let noCoast):
            if v { vel = coast ? vel : (playing ? rate : 0); coast = false }
            else {
                // let go mid-fling (backwards, or well off the motor speed): keep spinning and coast back
                let goal = playing ? rate : 0
                vel = max(-10, min(10, vel))
                coast = !noCoast && (vel < -0.5 || abs(vel - goal) > 1.5)
                if !coast { vel = 0 }
            }
            scratching = v; target = pos; flush()
        case .spin(let v): spinA = 9 / v
        case .jog(let v): target += v
        case .loop(let on, let a, let b): loopOn = on; loopIn = a; loopOut = b
        case .mt(let v): mt = v; flush()
        }
    }

    // source index for keylock reads: wraps inside an active loop; -1 = silence
    @inline(__always) func idx(_ p0: Double) -> Int {
        var p = p0
        if loopOn && loopOut > loopIn && p >= loopOut {
            let w = loopOut - loopIn
            p = loopIn + (p - loopIn).truncatingRemainder(dividingBy: w)
        }
        let j = Int(p)                                   // JS p | 0
        return j >= 0 && j < len ? j : -1
    }
    @inline(__always) func mono(_ p: Double) -> Double {
        let j = idx(p)
        return j < 0 ? 0 : Double(L![j]) + Double(R![j])
    }

    func startGrain(_ pos: Double, _ v: Double) {
        cur ^= 1
        let slot = cur
        if fresh {
            let s = jsRound(pos)
            gS[slot] = s; gK[slot] = 0; gF[slot] = 1; gK[slot ^ 1] = Int32(Nw)
            prevS = s; fresh = false; return
        }
        let s0 = jsRound(pos + (v - 1) * Double(H))       // keeps each grain centred on the playhead
        let nat = prevS + Double(H)                        // where the previous grain would continue
        var best = 0.0
        let Sd = Double(S)
        if nat >= s0 - Sd && nat <= s0 + Sd && abs(v - 1) < 1e-6 { best = nat - s0 }
        else {
            let base = s0 - Sd
            var te = 0.0
            for k in 0..<H { let x = mono(nat + Double(k)); tpl[k] = Float(x); te += x * x }
            if te > 1e-9 {
                let B = 2 * S + H
                for k in 0..<B { buf[k] = Float(mono(base + Double(k))) }
                @inline(__always) func score(_ o: Int, _ step: Int) -> Double {
                    var c = 0.0, e = 1e-9
                    var k = 0
                    while k < H { let y = Double(buf[o + k]); c += Double(tpl[k]) * y; e += y * y; k += step }
                    return c / e.squareRoot()
                }
                var bs = -Double.infinity
                var bo = S
                var o = 0
                while o <= 2 * S { let sc = score(o, 8); if sc > bs { bs = sc; bo = o }; o += 4 }
                let lo = max(0, bo - 4), hi = min(2 * S, bo + 4)
                bs = -Double.infinity
                var fo = bo
                for o2 in lo...hi { let sc = score(o2, 1); if sc > bs { bs = sc; fo = o2 } }
                best = Double(fo - S)
            }
        }
        let s = s0 + best
        gS[slot] = s; gK[slot] = 0; gF[slot] = 0; prevS = s
    }

    /// Renders `n` frames into oL/oR (overwritten).
    public func render(_ oL: UnsafeMutablePointer<Float>, _ oR: UnsafeMutablePointer<Float>, _ n: Int) {
        for i in 0..<n { oL[i] = 0; oR[i] = 0 }
        guard let L, let R else { return }
        if !playing && !scratching && !coast && amp == 0 { return }
        let sr = sampleRate
        var pos = self.pos, vel = self.vel, amp = self.amp
        let follow = 1 / (0.012 * sr)      // scratch: catch up with the hand in about 12 ms
        let ampStep = 1 / (0.005 * sr)     // 5 ms fades on start/stop: no clicks
        let useMT = mt && !scratching && !coast
        let spinStep = spinA / sr
        let Hh = H, rampN = ramp, NwN = Nw
        let lenD = Double(len)
        for i in 0..<n {
            var v: Double, want: Double
            if scratching {
                vel += ((target - pos) * follow - vel) * 0.02
                v = vel; want = 1
            } else if coast {
                let goal = playing ? rate : 0
                if vel < goal { vel = min(goal, vel + spinStep) } else { vel = max(goal, vel - spinStep) }
                if vel == goal { coast = false }
                v = vel; want = 1
            } else {
                want = playing ? 1 : 0
                v = playing ? rate * (1 + bend) : (amp > 0 ? rate : 0)
            }
            if want > amp { amp = min(want, amp + ampStep) } else if want < amp { amp = max(want, amp - ampStep) }
            if amp > 0.0001 && pos >= 0 && pos < lenD - 1 {
                if useMT {
                    if ph == 0 { startGrain(pos, v) }
                    var l = 0.0, r = 0.0
                    for g in 0..<2 {
                        let k = Int(gK[g])
                        if k >= NwN { continue }
                        let j = idx(gS[g] + Double(k))
                        if j >= 0 {
                            let w: Double = gF[g] != 0 && k < Hh ? (k < rampN ? Double(k) / Double(rampN) : 1) : Double(win[k])
                            l += Double(L[j]) * w; r += Double(R[j]) * w
                        }
                        gK[g] = Int32(k + 1)
                    }
                    oL[i] = Float(l * amp); oR[i] = Float(r * amp)
                    ph += 1; if ph >= Hh { ph = 0 }
                } else {
                    let i0 = Int(pos), f = pos - Double(i0)
                    let a0 = Double(L[i0]), a1 = Double(L[i0 + 1]), b0 = Double(R[i0]), b1 = Double(R[i0 + 1])
                    oL[i] = Float((a0 + (a1 - a0) * f) * amp)
                    oR[i] = Float((b0 + (b1 - b0) * f) * amp)
                }
            } else if useMT && !fresh { flush() }
            pos += v
            if loopOn && v > 0 && pos >= loopOut && loopOut > loopIn {
                let w = loopOut - loopIn
                pos -= w
                if scratching { target -= w }
            }
            if pos < 0 { pos = 0; if target < 0 { target = 0 } }
            if pos >= lenD - 1 { pos = lenD - 1; if playing { playing = false; ended = true } }
        }
        self.pos = pos; self.vel = vel; self.amp = amp
        bend *= 0.96
        if abs(bend) < 1e-5 { bend = 0 }
    }

    /// What the deck's moving at (the JS report's `speed`).
    public var speed: Double { scratching || coast ? vel : (playing ? rate * (1 + bend) : 0) }
}

/// Decoded stereo audio, 32-bit float, owned here.
public final class PCMTrack {
    public let left: UnsafeMutablePointer<Float>
    public let right: UnsafeMutablePointer<Float>
    public let count: Int
    public let sampleRate: Double
    public init(count: Int, sampleRate: Double) {
        self.count = count; self.sampleRate = sampleRate
        left = .allocate(capacity: max(count, 1)); right = .allocate(capacity: max(count, 1))
        left.initialize(repeating: 0, count: max(count, 1)); right.initialize(repeating: 0, count: max(count, 1))
    }
    public convenience init(left l: [Float], right r: [Float], sampleRate: Double) {
        self.init(count: min(l.count, r.count), sampleRate: sampleRate)
        for i in 0..<count { left[i] = l[i]; right[i] = r[i] }
    }
    deinit { left.deallocate(); right.deallocate() }
}
