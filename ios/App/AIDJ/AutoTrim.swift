// Auto trim (Settings → Audio): every track loaded on a deck gets the TRIM that brings it to one loudness, so a quiet
// old master and a loud new one come in at the same level. Measured with ITU-R BS.1770 (CrateboxKit Loudness) on the
// audio the deck already decoded for its analysis; nothing else is read. AI DJ always does this, with or without
// the setting. Turning a TRIM knob afterwards still works: auto trim only sets it when a track loads.
import Foundation

enum AutoTrim {
    static let key = "cb.autoTrim", targetKey = "cb.autoTrim.target"
    static var on: Bool { UserDefaults.standard.bool(forKey: key) }
    /// LUFS every track is brought to (-9 by default: most club masters are louder, so they're turned down a little,
    /// which leaves room to bring quiet ones up)
    static var target: Double {
        let v = UserDefaults.standard.double(forKey: targetKey)
        return v < 0 ? v : -9
    }
    static let targets: [Double] = [-14, -12, -10, -9, -8]
}
