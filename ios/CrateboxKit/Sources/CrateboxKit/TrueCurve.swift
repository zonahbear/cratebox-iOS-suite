import Foundation
import CryptoKit

// TrueCurve mini: heat curves for a Puffco Peak Pro / Proxy. A port of cratebox.html's TC section, which is
// itself a cut-down copy of zonahbear/truecurve web/index.html: same curve maths (monotone cubic or straight
// lines), predictive driver, heater-model learning, Lorax byte formats and safety rules. This file is the
// UI-free, Bluetooth-free part so it can be tested here; the app's TrueCurve/ folder does CoreBluetooth and
// the runner. Temperatures are °F, times are seconds. Keep names parallel with the web code.
public enum TrueCurve {
    /// targets are clamped to this range; a reading at or above `cutoffF` stops the run
    public static let minF = 350.0, maxF = 590.0, cutoffF = 600.0
    /// curves run on profile slot 4 (index 3), backed up first and restored after
    public static let slot: UInt8 = 3
    /// Proxy reports "ready" (10) for most of a heat cycle, not just "heating" (8)
    public static let heating: Set<Int> = [7, 8, 10]
    public static func cToF(_ c: Double) -> Double { c * 9 / 5 + 32 }
    public static func fToC(_ f: Double) -> Double { (f - 32) * 5 / 9 }
    static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }

    public struct Point: Codable, Equatable { public var t: Double; public var f: Double
        public init(t: Double, f: Double) { self.t = t; self.f = f } }
    /// the clipboard / saved form: {name: {points: [{t, f}], smooth}}, same as TrueCurve's tc_curves
    public struct CurveDef: Codable, Equatable { public var points: [Point]; public var smooth: Bool
        public init(points: [Point], smooth: Bool) { self.points = points; self.smooth = smooth } }

    /// TrueCurve's presets, in menu order; Quartz Banger (starts at 520 and trails off to 450) is the default
    public static let defaultName = "Quartz Banger"
    public static let presets: [(name: String, points: [(Double, Double)])] = [
        ("Quartz Banger", [(0, 520), (10, 508), (25, 485), (45, 462), (65, 450)]),
        ("Terp Ramp", [(0, 450), (20, 480), (40, 520), (55, 550)]),
        ("Hot Start, Cool Finish", [(0, 540), (15, 520), (35, 480), (55, 460)]),
        ("Wave", [(0, 470), (15, 520), (30, 480), (45, 540), (60, 505)]),
        ("Slow Climb", [(0, 430), (50, 510), (80, 560)]),
        ("Flat 500", [(0, 500), (45, 500)]),
    ]
    public static func preset(_ name: String) -> CurveDef? {
        presets.first { $0.name == name }.map { CurveDef(points: $0.points.map { Point(t: $0.0, f: $0.1) }, smooth: true) }
    }

    // ---- curve maths ----

    /// monotone cubic (Fritsch–Butland: never overshoots between points) or straight lines
    public struct Curve {
        let xs: [Double], ys: [Double], hh: [Double], d: [Double], m: [Double]
        public let smooth: Bool
        public let end: Double
        /// nil with fewer than two distinct times
        public init?(_ points: [Point], smooth: Bool) {
            var pts: [Point] = []
            for p in points.filter({ $0.t.isFinite && $0.f.isFinite }).sorted(by: { $0.t < $1.t }) where pts.last?.t != p.t { pts.append(p) }
            guard pts.count >= 2 else { return nil }
            let xs = pts.map(\.t), ys = pts.map(\.f), n = pts.count
            var hh = [Double](repeating: 0, count: n - 1), d = hh, m = [Double](repeating: 0, count: n)
            for i in 0..<(n - 1) { hh[i] = xs[i + 1] - xs[i]; d[i] = (ys[i + 1] - ys[i]) / hh[i] }
            if n > 2 {
                for i in 1..<(n - 1) where d[i - 1] * d[i] > 0 {
                    let w1 = 2 * hh[i] + hh[i - 1], w2 = hh[i] + 2 * hh[i - 1]
                    m[i] = (w1 + w2) / (w1 / d[i - 1] + w2 / d[i])
                }
            }
            self.xs = xs; self.ys = ys; self.hh = hh; self.d = d; self.m = m; self.smooth = smooth; end = xs[n - 1]
        }
        func seg(_ t: Double) -> Int { var i = 0; while i < xs.count - 2 && t > xs[i + 1] { i += 1 }; return i }
        public func at(_ t: Double) -> Double {
            let t = TrueCurve.clamp(t, 0, end), i = seg(t), s = (t - xs[i]) / hh[i]
            if !smooth { return ys[i] + s * (ys[i + 1] - ys[i]) }
            let s2 = s * s, s3 = s2 * s
            return (2 * s3 - 3 * s2 + 1) * ys[i] + (s3 - 2 * s2 + s) * hh[i] * m[i] + (-2 * s3 + 3 * s2) * ys[i + 1] + (s3 - s2) * hh[i] * m[i + 1]
        }
        public func slope(_ t: Double) -> Double {
            if t <= 0 || t >= end { return 0 }
            let i = seg(t), s = (t - xs[i]) / hh[i]
            if !smooth { return d[i] }
            let s2 = s * s
            return ((6 * s2 - 6 * s) * ys[i] + (-6 * s2 + 6 * s) * ys[i + 1]) / hh[i] + (3 * s2 - 4 * s + 1) * m[i] + (3 * s2 - 2 * s) * m[i + 1]
        }
    }

    // ---- heater model, driver, learner ----

    /// bowl temp follows the heater target as a first-order lag capped by heating power; it can only cool passively
    public struct HeaterModel: Codable, Equatable {
        public var tau: Double, heatMax: Double, coolK: Double, dead: Double, runs: Int
        public init(tau: Double = 4.0, heatMax: Double = 12, coolK: Double = 0.015, dead: Double = 0.6, runs: Int = 0) {
            self.tau = tau; self.heatMax = heatMax; self.coolK = coolK; self.dead = dead; self.runs = runs
        }
    }
    public static func plantStep(_ y: Double, _ u: Double, _ dt: Double, _ p: HeaterModel, extraCool: Double = 0) -> Double {
        let rate = u > y ? min((u - y) / p.tau, p.heatMax) : max((u - y) / p.tau, -p.coolK * (y - 70))
        return y + (rate - extraCool) * dt
    }

    /// look ahead by dead time + BLE latency and invert the lag; live correction only trims (big asks can make
    /// the firmware abort the session)
    public struct Driver {
        let c: Curve, m: HeaterModel
        var I = 0.0
        public init(_ c: Curve, _ m: HeaterModel) { self.c = c; self.m = m }
        public mutating func command(_ t: Double, _ y: Double?, _ dt: Double) -> Double {
            let tl = t + m.dead + 0.25, r = c.at(t)
            let ff = c.at(tl) + m.tau * (tl < c.end ? c.slope(tl) : 0)
            var corr = 0.0, I = self.I, unsat = true
            if let y {
                let e = r - y
                if abs(e) < 30 { I = clamp(I + 0.1 * e * dt, -12, 12) }
                let raw = 0.6 * clamp(e, -30, 30) + I
                corr = clamp(raw, -15, 20); unsat = corr == raw
            }
            let u = ff + corr, uc = clamp(u, max(minF, r - 40), min(maxF, r + 30))
            if unsat && abs(uc - u) < 0.01 { self.I = I }
            return uc
        }
    }

    /// learns tau / max heat rate / cooling from a run, like TrueCurve (stored per device)
    public struct Learner {
        public var m: HeaterModel
        public private(set) var n = 0
        var s: [(t: Double, y: Double, u: Double)] = []
        public init(_ m: HeaterModel) { self.m = m }
        public mutating func add(_ t: Double, _ y: Double?, _ u: Double) {
            guard let y else { return }
            s.append((t, y, u))
            while let f = s.first, t - f.t > 1.4 { s.removeFirst() }
            if s.count < 4 { return }
            let k = Double(s.count), mt = s.reduce(0) { $0 + $1.t } / k, my = s.reduce(0) { $0 + $1.y } / k
            var num = 0.0, den = 0.0
            for v in s { num += (v.t - mt) * (v.y - my); den += (v.t - mt) * (v.t - mt) }
            if den < 0.2 { return }
            let dy = num / den, ta = t - m.dead - 0.2
            var uD: Double? = nil
            for v in s where v.t <= ta { uD = v.u }
            let gap = (uD ?? s[0].u) - my
            if gap > 10 && dy > 1 {
                if gap / m.tau < 0.7 * m.heatMax { m.tau += 0.04 * (clamp(gap / dy, 1.5, 15) - m.tau) }
                else { m.heatMax += (dy > m.heatMax ? 0.15 : 0.03) * (clamp(dy, 3, 40) - m.heatMax) }
                n += 1
            } else if gap < -10 && dy < -0.5 && my > 150 && -gap / m.tau > 1.3 * m.coolK * (my - 70) {
                m.coolK += 0.05 * (clamp(-dy / (my - 70), 0.003, 0.06) - m.coolK); n += 1
            }
        }
    }

    /// PUFF (Beat FX): turns a HOLD's bowl temperature into an effect amount. The device holds one temperature;
    /// a draw cools the bowl and the heater fights back, so the dip below the settled temperature says how hard
    /// you're hitting it. The settled temperature jumps up to any higher reading, stays put while the bowl is
    /// falling (a pull), follows a recovery down in ~1.5 s (you've stopped, so the warble lets go) and drifts to
    /// a steady reading in ~10 s. Nothing reads until the bowl first reaches the hold temperature (the preheat
    /// climb isn't a hit). Readings ~10 a second, ±0.6°F noise in the simulator.
    public struct PuffDrop {
        /// drops under `dead` °F are noise; `full` °F of drop is the whole effect
        public var dead = 3.0, full = 40.0
        public private(set) var settled: Double? = nil, drop = 0.0, amount = 0.0, rate = 0.0
        let hold: Double
        var last: Double? = nil, lastY = 0.0
        public init(hold: Double, full: Double = 40) { self.hold = hold; self.full = max(full, dead + 1) }
        /// one reading (°F, nil = none) at time t (s); returns the amount, 0...1
        public mutating func add(_ t: Double, _ y: Double?) -> Double {
            guard let y else { return amount }
            let dt = last.map { min(max(t - $0, 0), 1) } ?? 0
            last = t
            guard var b = settled else {
                if y >= hold - 12 { settled = y; lastY = y }
                return 0
            }
            if dt > 0 { rate += ((y - lastY) / dt - rate) * (1 - exp(-dt / 0.4)) }     // °F/s, smoothed
            lastY = y
            // never above the hold temperature + a little: an overshoot isn't the new normal
            if y > b { b = min(y, hold + 10) }
            else if rate >= -1 { b += (y - b) * (1 - exp(-dt / (rate > 1 ? 1.5 : 10))) }
            settled = b
            drop = max(0, b - y)
            amount = clamp((drop - dead) / (full - dead), 0, 1)
            return amount
        }
    }

    /// the simulator's heater (the app's Simulator device and the tests): a "truth" model that differs from the
    /// driver's default, a dead time on live targets, and a device that ends its own cycle after the slot's time
    public struct SimHeater {
        public var truth = HeaterModel(tau: 3.0, heatMax: 15, coolK: 0.011, dead: 0.45)
        public var y = 74.0, u = 74.0, state = 5, slotIdx = 0
        /// a draw on the device (0 = none, 1 = a hard rip): extra cooling the heater has to fight, for PUFF
        public var airflow = 0.0
        public var slots: [(temp: Double, time: Double)] = Array(repeating: (485, 45), count: 4)
        public private(set) var clock = 0.0
        var cmds: [(at: Double, u: Double)] = [], endAt = 0.0
        public init() {}
        public mutating func advance(_ dt: Double) {
            clock += dt
            while let c = cmds.first, c.at <= clock { u = c.u; cmds.removeFirst() }
            let heating = state == 7 || state == 8
            y = plantStep(y, heating ? u : 70, dt, truth, extraCool: airflow * 12)
            if state == 7 && y >= u - 6 { state = 8; endAt = clock + slots[slotIdx].time }
            if state == 8 && clock >= endAt { state = 5 }
        }
        public mutating func start() { state = 7; u = slots[slotIdx].temp; cmds = [] }
        public mutating func stop() { state = 5 }
        public mutating func setLiveTarget(_ f: Double) { cmds.append((clock + truth.dead, clamp(f, minF, maxF))) }
    }

    /// TrueCurve's "Copy curves for Cratebox" JSON ({name: {points: [{t, f}], smooth}}); nil if it isn't that.
    /// Points are clamped like the web app's paste (t 0–110 s, f 350–590°F), names cut to 24 characters.
    public static func parseCurves(_ text: String) -> [String: CurveDef]? {
        guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func num(_ v: Any?) -> Double? {
            if let n = v as? NSNumber { return n.doubleValue }
            if let s = v as? String { return Double(s) }
            return nil
        }
        var out: [String: CurveDef] = [:]
        for (k, v) in obj {
            guard let c = v as? [String: Any], let raw = c["points"] as? [Any] else { continue }
            let pts = raw.compactMap { p -> Point? in
                guard let p = p as? [String: Any], let t = num(p["t"]), let f = num(p["f"]), t.isFinite, f.isFinite else { return nil }
                return Point(t: clamp(t, 0, 110), f: clamp(f, minF, maxF))
            }
            if pts.count >= 2 { out[String(k.prefix(24))] = CurveDef(points: pts, smooth: (c["smooth"] as? Bool) != false) }
        }
        return out
    }
}

/// The Puffco Lorax protocol's bytes, same as TrueCurve's PuffcoBle: frames are [seq lo, seq hi, op, payload],
/// replies [seq lo, seq hi, status, data]. Ops: 0 seed, 1 unlock, 16 read, 17 write. Temperatures on the wire
/// are °C, as float32 (Peak Pro) or int32 tenths (Proxy, "i10").
public enum Lorax {
    public static let service = "e276967f-ea8a-478a-a92e-d78f5dd15dd5", serviceLegacy = "06caf9c0-74d3-454f-9be9-e30cd999c17a"
    public static let cmd = "60133d5c-5727-4f2c-9697-d842c5292a3c", reply = "8dc5ec05-8f7d-45ad-99db-3fbde65dbd9c", version = "05434bca-cc7f-4ef6-bbb3-b1c520b9800c"
    static let key: [UInt8] = [0x64, 0xc6, 0x45, 0x62, 0x56, 0xf2, 0x6f, 0x5b, 0x1c, 0xa1, 0x27, 0x37, 0xa5, 0xdd, 0x71, 0xfb]
    public enum Path {
        public static let mode = "/p/app/mc", state = "/p/app/stat/id", temp = "/p/app/htr/temp", tempAlt = "/p/htr/temp"
        public static let live = "/p/app/thc/temp", slot = "/p/app/hcs", soc = "/p/bat/soc"
        public static func pTemp(_ s: UInt8) -> String { "/u/app/hc/\(s)/temp" }
        public static func pTime(_ s: UInt8) -> String { "/u/app/hc/\(s)/time" }
    }
    public enum Fmt { case f32, i10 }

    public static func frame(seq: UInt16, op: UInt8, _ payload: [UInt8]) -> [UInt8] { [UInt8(seq & 0xff), UInt8(seq >> 8), op] + payload }
    public static func readPayload(_ path: String, max: UInt16) -> [UInt8] { [0, 0, UInt8(max & 0xff), UInt8(max >> 8)] + Array(path.utf8) }
    public static func writePayload(_ path: String, _ bytes: [UInt8]) -> [UInt8] { [0, 0, 0] + Array(path.utf8) + [0] + bytes }
    /// unlock token: the first 16 bytes of SHA-256(key + the 16-byte seed)
    public static func token(seed: [UInt8]) -> [UInt8] { Array(Array(SHA256.hash(data: Data(key + seed.prefix(16)))).prefix(16)) }

    static func u32(_ b: [UInt8]) -> UInt32 { UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24 }
    static func le(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 24)] }
    public static func f32(_ b: [UInt8]) -> Double { Double(Float(bitPattern: u32(b))) }
    public static func i32(_ b: [UInt8]) -> Int { Int(Int32(bitPattern: u32(b))) }
    public static func f32Bytes(_ v: Double) -> [UInt8] { le(Float(v).bitPattern) }

    /// a °C reading: float unless the device is known to be i10 or the float is implausible
    public static func decodeC(_ b: [UInt8]?, fmt: Fmt?) -> Double? {
        guard let b, b.count >= 4 else { return nil }
        let f = f32(b)
        if fmt != .i10 && f.isFinite && f > -80 && f < 520 && !(f != 0 && abs(f) < 1e-3) { return f }
        let i = i32(b)
        return abs(i) <= 6000 ? Double(i) / 10 : nil
    }
    public static func encodeC(_ c: Double, _ fmt: Fmt) -> [UInt8] { fmt == .i10 ? le(UInt32(bitPattern: Int32((c * 10).rounded()))) : f32Bytes(c) }
    /// what a profile temperature reads back as
    public static func decodeAs(_ b: [UInt8], _ fmt: Fmt) -> Double { fmt == .i10 ? Double(i32(b)) / 10 : f32(b) }
    /// slot 0's profile temperature tells the format (a profile is 100–350 °C)
    public static func detectFormat(_ b: [UInt8]?, isProxy: Bool) -> Fmt {
        if let b, b.count >= 4 {
            let f = f32(b), i = i32(b)
            if f.isFinite && f >= 100 && f <= 350 { return .f32 }
            if i >= 1000 && i <= 3600 { return .i10 }
        }
        return isProxy ? .i10 : .f32
    }
    /// the live target (/p/app/thc/temp) can be in a different format from the profiles
    public static func detectLiveFormat(_ b: [UInt8]?) -> Fmt? {
        guard let b, b.count >= 4 else { return nil }
        let f = f32(b), i = i32(b)
        if f.isFinite && f >= 150 && f <= 400 { return .f32 }
        if i >= 1500 && i <= 4000 { return .i10 }
        return nil
    }

    /// /p/bat/soc: float on Peak Pro, integer (sometimes tenths/hundredths of a percent) on Proxy
    public struct SocDecoder {
        var scale = 0
        public init() {}
        public mutating func decode(_ b: [UInt8]?) -> Int? {
            guard let b, !b.isEmpty else { return nil }
            if b.count >= 4 {
                let f = f32(b)
                if f.isFinite && f >= 1e-3 && f < 1 { return Int((f * 100).rounded()) }
                if f.isFinite && f >= 1 && f <= 100 { return Int(f.rounded()) }
            }
            let i = b.count >= 4 ? i32(b) : b.count >= 2 ? Int(UInt16(b[0]) | UInt16(b[1]) << 8) : Int(b[0])
            if i < 0 || i > 10000 { return nil }
            if i > 1000 { scale = 100 } else if i > 100 && scale != 100 { scale = 10 }
            return Int((Double(i) / Double(max(scale, 1))).rounded())
        }
    }
}
