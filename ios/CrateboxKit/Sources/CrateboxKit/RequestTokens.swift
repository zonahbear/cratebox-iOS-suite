// Tells a background result from a request that's been overtaken: by a newer request of the same kind, or by the
// end of the session it belongs to (Cratebox USB's eject, or reopening, even the same stick at the same URL).
// Main thread only; a background task carries its Token and asks `isCurrent` on the main thread before it changes
// anything.
public struct RequestTokens {
    public struct Token: Equatable { let session: Int, kind: String, seq: Int }
    private var session = 0
    private var seqs = [String: Int]()
    public init() {}
    /// a new stick opened, or this one ejected: everything begun before is stale
    public mutating func newSession() { session += 1 }
    /// a new request of this kind: earlier ones of the same kind are stale
    public mutating func begin(_ kind: String) -> Token {
        let s = (seqs[kind] ?? 0) + 1
        seqs[kind] = s
        return Token(session: session, kind: kind, seq: s)
    }
    public func isCurrent(_ t: Token) -> Bool { t.session == session && seqs[t.kind] == t.seq }
}
