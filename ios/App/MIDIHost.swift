// CoreMIDI: finds the controller (a chosen one, else the first Pioneer/AlphaTheta, else any), feeds its
// messages to the controller engine on the main thread, and sends lights, init and keep-alive back.
import CoreMIDI
import Foundation
import CrateboxKit

final class MIDIHost {
    private var client = MIDIClientRef()
    private var inPort = MIDIPortRef()
    private var outPort = MIDIPortRef()
    private var source: MIDIEndpointRef = 0
    private var dest: MIDIEndpointRef = 0
    private(set) var deviceName = ""
    private(set) var available: [String] = []
    var preferred = UserDefaults.standard.string(forKey: "cb.midiIn") ?? "" { didSet { UserDefaults.standard.set(preferred, forKey: "cb.midiIn"); bind() } }
    var onMessage: ([UInt8]) -> Void = { _ in }
    var onChange: (String) -> Void = { _ in }

    func start() {
        MIDIClientCreateWithBlock("Cratebox" as CFString, &client) { [weak self] note in
            if note.pointee.messageID == .msgSetupChanged { DispatchQueue.main.async { self?.bind() } }
        }
        MIDIInputPortCreateWithProtocol(client, "in" as CFString, ._1_0, &inPort) { [weak self] list, _ in
            let msgs = MIDIHost.decode(list)
            if msgs.isEmpty { return }
            DispatchQueue.main.async { for m in msgs { self?.onMessage(m) } }
        }
        MIDIOutputPortCreate(client, "out" as CFString, &outPort)
        bind()
    }

    static func name(_ e: MIDIEndpointRef) -> String {
        var s: Unmanaged<CFString>?
        if MIDIObjectGetStringProperty(e, kMIDIPropertyDisplayName, &s) == noErr, let v = s?.takeRetainedValue() { return v as String }
        if MIDIObjectGetStringProperty(e, kMIDIPropertyName, &s) == noErr, let v = s?.takeRetainedValue() { return v as String }
        return "MIDI device"
    }

    func bind() {
        if source != 0 { MIDIPortDisconnectSource(inPort, source); source = 0 }
        let srcs = (0..<MIDIGetNumberOfSources()).map { MIDIGetSource($0) }
        available = srcs.map(MIDIHost.name)
        let pick = srcs.first { MIDIHost.name($0) == preferred }
            ?? srcs.first { let n = MIDIHost.name($0); return Profiles.pioneerish.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)) != nil }
            ?? srcs.first
        guard let src = pick else { deviceName = ""; dest = 0; onChange(""); return }
        source = src
        MIDIPortConnectSource(inPort, src, nil)
        deviceName = MIDIHost.name(src)
        // the output with the same (or a matching) name
        let dsts = (0..<MIDIGetNumberOfDestinations()).map { MIDIGetDestination($0) }
        let base = deviceName.replacingOccurrences(of: "\\s*(MIDI|IN|OUT|\\d+)\\s*$", with: "", options: [.regularExpression, .caseInsensitive])
        dest = dsts.first { MIDIHost.name($0) == deviceName } ?? dsts.first { !base.isEmpty && MIDIHost.name($0).hasPrefix(base) } ?? 0
        onChange(deviceName)
    }

    func send(_ bytes: [UInt8]) {
        guard dest != 0, !bytes.isEmpty else { return }
        if bytes[0] == 0xf0 {
            // system exclusive (init, keep-alive). CoreMIDI moves `data` along as it sends, so the buffer to free
            // is kept in the refcon, not taken from `data`.
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes.count)
            buf.initialize(from: bytes, count: bytes.count)
            let req = UnsafeMutablePointer<MIDISysexSendRequest>.allocate(capacity: 1)
            req.initialize(to: MIDISysexSendRequest(destination: dest, data: UnsafePointer(buf), bytesToSend: UInt32(bytes.count), complete: false, reserved: (0, 0, 0),
                                                     completionProc: { r in
                                                         r.pointee.completionRefCon?.assumingMemoryBound(to: UInt8.self).deallocate()
                                                         r.deallocate()
                                                     }, completionRefCon: UnsafeMutableRawPointer(buf)))
            if MIDISendSysex(req) != noErr { buf.deallocate(); req.deallocate() }
            return
        }
        var list = MIDIPacketList()
        let p = MIDIPacketListInit(&list)
        _ = MIDIPacketListAdd(&list, MemoryLayout<MIDIPacketList>.size, p, 0, bytes.count, bytes)
        MIDISend(outPort, dest, &list)
    }

    /// MIDI 1.0 channel voice messages out of a UMP event list
    static func decode(_ list: UnsafePointer<MIDIEventList>) -> [[UInt8]] {
        var out = [[UInt8]]()
        for pkt in list.unsafeSequence() {
            let n = Int(pkt.pointee.wordCount)
            withUnsafeBytes(of: pkt.pointee.words) { raw in
                let words = raw.bindMemory(to: UInt32.self)
                for k in 0..<min(n, words.count) where (words[k] >> 28) == 0x2 {     // MIDI 1.0 channel voice
                    let w = words[k]
                    out.append([UInt8((w >> 16) & 0xff), UInt8((w >> 8) & 0x7f), UInt8(w & 0x7f)])
                }
            }
        }
        return out
    }
}
