// AI DJ: mixes on its own on decks 1 and 2, or 1-3 with the third deck on (the suite's AI DJ mode, behind Settings →
// AI mode). It picks the next track (from the whole library, a playlist, or tracks you chose), loads it on a free
// deck, matches its loudness with TRIM, and runs the transition: the next track synced to the playing one and started
// a bar early with its fader down (beat-matched before it's heard), then the faders, EQs and COLOR moved bar by bar as
// the plan's kind says (bass swap, highs and lows, COLOR sweep, cut; Settings → AI → AI DJ turns each on or off), and
// the tempo glided from the playing track's to the new one's own, so the set moves between tempos instead of sitting
// on one. The next track comes in at its mix-in point (your CUE, else Apple's), skipping long intros. With the third
// deck on, the track after next is loaded during the transition; with the loop bridge on, a track that's too short
// to mix out of loops its last phrase until the next one is in. Apple's Music Understanding (iOS 27, AI mode's background analysis) tells it where the vocals are, so two
// vocals don't overlap, and gives energy and sound for the picks; without it AI DJ still mixes on key, tempo and
// phrases. Apple Intelligence (iOS 26+, where the model is ready) can narrow the tracks from a sentence ("vibe").
// Everything runs on the device; the decisions themselves are CrateboxKit's AutoMix (tested there).
//
// It drives the same decks and mixer you see in Performance Mode: touch the decks and it carries on around you;
// stop the playing deck, or STOP here, and it hands back. Runs from AppModel's display-link tick (main thread).
import Foundation
import CrateboxKit

/// Settings → AI → AI DJ: the moves it may make. All on by default, except the third deck and the loop bridge
enum AIDJMoves {
    static func key(_ k: AutoMix.Transition) -> String { "cb.aidj.kind." + k.rawValue }
    static let variableLength = "cb.aidj.varlen", skipIntros = "cb.aidj.intros", outro = "cb.aidj.outro",
               vocals = "cb.aidj.vocals", loopBridge = "cb.aidj.loop", thirdDeck = "cb.aidj.deck3"
    static func on(_ k: String, _ def: Bool = true) -> Bool {
        UserDefaults.standard.object(forKey: k) == nil ? def : UserDefaults.standard.bool(forKey: k)
    }
    static var kinds: [AutoMix.Transition] { AutoMix.Transition.allCases.filter { on(key($0)) } }
    static var third: Bool { on(thirdDeck, false) }
    static var bridge: Bool { on(loopBridge, false) }
    /// the planner's options; the kind used last costs a little more, so the set doesn't repeat one move
    static func planOptions(last: AutoMix.Transition?) -> AutoMix.PlanOptions {
        var o = AutoMix.PlanOptions()
        let k = kinds
        o.kinds = k.isEmpty ? [.bassSwap] : k
        o.variableLength = on(variableLength); o.skipIntros = on(skipIntros); o.outroAware = on(outro)
        if let last, o.kinds.count > 1 { o.bias[last] = 0.15 }
        return o
    }
}

final class AIDJ: ObservableObject {
    enum Source: Equatable { case library, playlist(AppModel.LibraryView), selected }
    enum Phase: Equatable { case idle, loading, playing, preparing, ready, mixing }

    unowned let app: AppModel
    @Published private(set) var phase = Phase.idle
    @Published var source: Source = .library
    /// AI DJ's own list (the Selected source), in the order picked
    @Published var selected: [String] { didSet { UserDefaults.standard.set(selected, forKey: "cb.aidj.selected") } }
    /// playlist / selected: play them in their order (else AI DJ picks the order)
    @Published var keepOrder: Bool { didSet { UserDefaults.standard.set(keepOrder, forKey: "cb.aidj.order") } }
    /// energy: -1 cool down, 0 hold, +1 build
    @Published var flow: Int { didSet { UserDefaults.standard.set(flow, forKey: "cb.aidj.flow") } }
    /// Apple Intelligence's reading of the vibe sentence (nil: every track)
    @Published var vibe: SmartFilter?
    @Published private(set) var message = ""
    /// played this session, oldest first
    @Published private(set) var history: [String] = []
    @Published private(set) var plan: AutoMix.Plan?
    /// bars into the transition (while mixing; 0 during the silent beat-matched lead-in)
    @Published private(set) var bar = 0.0
    /// what AI DJ would play next, best first, for the screen
    @Published private(set) var options: [AutoMix.Choice] = []
    @Published private(set) var trims: [Double?] = [nil, nil, nil]       // dB AI DJ set on decks 1-3
    /// the deck on air, and the one the next track goes on
    @Published private(set) var onAir = 0
    @Published private(set) var nextDeck = 1
    /// MIX NOW was pressed before the next track was ready: mix as soon as it is
    @Published private(set) var mixAsap = false

    private var waitingFor: (deck: Int, id: String)?
    private var nextId: String?
    private var lastLevels: AutoMix.Levels?
    private var lastRate = 0.0
    private var lastKind: AutoMix.Transition?
    private var skipped = Set<String>()        // picks that wouldn't load or plan, this session
    /// third deck: the track after next, loaded while the transition runs
    private var useThird = false
    private var preload: (deck: Int, id: String)?
    /// loop bridge: the on-air deck loops `len` beats from beat `from`; `wraps` counts the passes so the transition's
    /// beat count keeps going up
    private var bridge: (from: Double, len: Double)?
    private var wraps = 0, lastRaw = 0.0
    /// beats the next track runs silently, beat-matched, before its fader opens
    static let leadInBeats = 4.0

    var running: Bool { phase != .idle }
    var deckSet: [Int] { useThird ? [0, 1, 2] : [0, 1] }

    init(app: AppModel) {
        self.app = app
        let u = UserDefaults.standard
        selected = u.stringArray(forKey: "cb.aidj.selected") ?? []
        keepOrder = u.bool(forKey: "cb.aidj.order")
        flow = u.object(forKey: "cb.aidj.flow") == nil ? 0 : u.integer(forKey: "cb.aidj.flow")
        app.core.onUserMixer = { [weak self] n, i in self?.userMoved(n, i) }
    }

    // ---- hybrid (Jonah, 2026-11-13): your hands win ----
    /// controls you've moved during this transition ("fader/1", "low/0", …): AI DJ stops moving them until it ends
    private var held = Set<String>()
    private func userMoved(_ n: String, _ i: Int) {
        guard phase == .mixing, ["fader", "low", "mid", "hi", "cfx"].contains(n), i == onAir || i == nextDeck else { return }
        if held.insert("\(n)/\(i)").inserted {
            say("Deck \(i + 1) \(n == "fader" ? "fader" : n.uppercased()): yours until this mix ends")
        }
    }
    private func put(_ m: inout MixerState, _ n: String, _ i: Int, _ v: Double) {
        guard !held.contains("\(n)/\(i)") else { return }
        switch n {
        case "fader": m.fader[i] = v
        case "low": m.low[i] = v
        case "mid": m.mid[i] = v
        case "hi": m.hi[i] = v
        case "cfx": m.cfx[i] = v
        default: break
        }
    }

    private var core: Core { app.core }
    private func deck(_ i: Int) -> DeckModel { core.decks[i] }
    private func say(_ s: String) { message = s }
    /// a deck for the next track: one of AI DJ's that isn't on air (nor `not`), a stopped one first
    private func freeDeck(not: Int? = nil) -> Int {
        let c = deckSet.filter { $0 != onAir && $0 != not }
        return c.first { !deck($0).playing } ?? c.first ?? (onAir == 0 ? 1 : 0)
    }
    /// the on-air deck's beat, counting on through the loop bridge's passes
    func beatNow() -> Double {
        let A = deck(onAir)
        let raw = A.beatAt(A.now())
        guard let b = bridge else { return raw }
        return raw + Double(wraps) * b.len
    }

    // ---- the tracks it can play ----
    func poolTracks() -> [LibTrack] {
        var list: [LibTrack]
        switch source {
        case .library: list = app.library.tracks
        case .playlist(let v): list = LibraryPane.build(v, app.library, app.playlists, Devices.shared, query: "", sort: LibraryPane.storedSort(v)).compactMap { $0.t }
        case .selected: list = selected.compactMap { app.library.track($0) }
        }
        var seen = Set<String>()
        list = list.filter { seen.insert($0.id).inserted && ($0.info.bpm ?? 0) > 0 && $0.info.duration > 60 }
        if let f = vibe { list = list.filter { f.matches(title: $0.info.title, artist: $0.info.artist, bpm: $0.info.bpm, key: $0.info.key, duration: $0.info.duration) } }
        return list
    }
    var sourceName: String {
        switch source {
        case .library: return "Library"
        case .playlist(let v): return app.browseSources().first { $0.view == v }?.name ?? "Playlist"
        case .selected: return "Selected tracks"
        }
    }
    /// your CUE point for a track (Cratebox's, else rekordbox's)
    private func cue(of id: String, _ info: TrackInfo) -> Double? { core.cues.load(id)?.cue ?? info.rbCues?.cue }
    /// a library track as AutoMix sees it: Apple's loudness and shares only (`full`: its vocals, drums and mix
    /// points too, read from disk, so only for the few being planned)
    private func item(_ t: LibTrack, full: Bool = false) -> AutoMix.Track {
        let i = t.info
        if full, let f = AppleMusic.shared.features(t), AIMode.on {
            var x = AutoMix.Track(id: t.id, bpm: i.bpm ?? 0, firstBeat: i.firstBeat ?? 0, duration: i.duration, key: i.key, features: f)
            if !AIDJMoves.on(AIDJMoves.vocals) { x.vocals = nil }
            x.setCue(cue(of: t.id, i))
            return x
        }
        var x = AutoMix.Track(id: t.id, bpm: i.bpm ?? 0, firstBeat: i.firstBeat ?? 0, duration: i.duration, key: i.key)
        if let l = AppleMusic.shared.lite(t.id) {
            x.shares = l.shares
            x.energy = AutoMix.energy(lufs: l.lufs, drumShare: l.shares?[1])
        }
        if full { x.setCue(cue(of: t.id, i)) }
        return x
    }
    /// a loaded deck as AutoMix sees it: the deck's own grid (yours, Apple's, rekordbox's or Cratebox's, in that
    /// order), your CUE as the mix-in point
    private func item(deck d: DeckModel) -> AutoMix.Track? {
        guard d.loaded, let a = d.ana, let t = d.track else { return nil }
        let f = app.library.track(t.id).flatMap { AppleMusic.shared.features($0) }
        var x = AutoMix.Track(id: t.id, bpm: a.bpm, firstBeat: a.firstBeat, duration: d.duration, key: a.key, features: AIMode.on ? f : nil)
        if !AIDJMoves.on(AIDJMoves.vocals) { x.vocals = nil }
        x.setCue(cue(of: t.id, t))
        return x
    }

    // ---- start / stop ----
    func start(fresh: Bool = true) {
        guard !running else { return }
        guard AIMode.on else { say("Turn on AI mode first (Settings → AI)"); return }
        useThird = AIDJMoves.third
        app.setDecks(useThird ? 3 : 2)                     // AI DJ mixes on two decks (three with the third deck on)
        history = []; options = []; plan = nil; mixAsap = false; preload = nil; bridge = nil; lastKind = nil
        if fresh { skipped = [] }
        for i in deckSet { deck(i).setSync(false); if !deck(i).mt { deck(i).setMT(true) } }
        // a deck already playing: AI DJ takes over from it
        if let d = deckSet.map({ deck($0) }).filter({ $0.playing && $0.loaded }).max(by: { $0.startedAt < $1.startedAt }), let id = d.track?.id {
            onAir = d.i
            nextDeck = freeDeck()
            history = [id]
            prepareAir(d, start: false)
            phase = .playing
            say("Taking over from deck \(d.i + 1)")
            prepareNext()
            return
        }
        let pool = poolTracks().filter { !skipped.contains($0.id) }
        guard let first = firstPick(pool) else { say(pool.isEmpty ? "No tracks with a beat grid in \(sourceName)" : "Nothing to play"); return }
        onAir = 0; nextDeck = 1
        for i in deckSet where i != 0 { deck(i).setPlaying(false) }
        load(first, on: 0)
        phase = .loading
        say("Loading \(first.info.title)")
    }
    func stop(_ why: String = "Stopped: the decks are yours") {
        guard running else { return }
        // mid-transition: leave the decks where they are, but don't leave a bass cut, a filter or a loop stuck
        if phase == .mixing {
            var m = core.mixer
            for i in deckSet { m.low[i] = 0.5; m.mid[i] = 0.5; m.hi[i] = 0.5; m.cfx[i] = 0.5 }
            core.mixer = m
        }
        endBridge()
        phase = .idle; plan = nil; waitingFor = nil; nextId = nil; lastLevels = nil; mixAsap = false; preload = nil
        say(why)
    }
    /// pick another next track (not while the transition runs)
    func skipNext() {
        guard running, phase != .mixing, phase != .loading else { return }
        if let n = nextId { skipped.insert(n) }
        deck(nextDeck).setSync(false)
        mixAsap = false
        endBridge()
        prepareNext()
    }
    /// start the transition now: on the next bar after the beat-matched lead-in, at most two bars away. Pressed
    /// while the next track is still loading, it mixes as soon as it's ready
    func mixNow() {
        switch phase {
        case .idle, .loading: return
        case .mixing: say("Already mixing"); return
        case .preparing: mixAsap = true; say("Mixing in as soon as the next track is ready"); return
        case .playing: say(nextId == nil ? "There's no next track to mix in" : "Mixing in as soon as the next track is ready"); mixAsap = nextId != nil; return
        case .ready: break
        }
        mixAsap = false
        let A = deck(onAir), B = deck(nextDeck)
        guard var a = item(deck: A), let b = item(deck: B) else { return }
        if let br = bridge { a.duration = a.time(ofBeat: br.from + br.len * 8) + 0.3 }
        var o = AIDJMoves.planOptions(last: lastKind)
        o.within = 8
        if let p = AutoMix.plan(from: a, aRate: A.rate(), to: b, after: beatNow() + Self.leadInBeats + 0.5, step: 4, maxShift: 0.12, options: o) {
            plan = p
            cue(p)
            let bars = max(1, Int(((p.outStart - beatNow()) / 4).rounded(.up)))
            say("Mixing in \(bars == 1 ? "on the next bar" : "in \(bars) bars") · \(p.kind.name), \(p.bars) bars")
        } else if let br = bridge, beatNow() > br.from {
            say("Can't mix now: try again in a moment")
        } else {
            say("Can't mix now: not enough of \(A.track?.title ?? "this track") is left for a transition")
        }
    }

    private func firstPick(_ pool: [LibTrack]) -> LibTrack? {
        if source != .library && keepOrder { return pool.first }
        // the opener: the calmest of the analysed tracks when building (else one from the middle), so there's
        // somewhere to go; among equals, any
        let items = pool.map { ($0, item($0).energy) }
        if flow > 0, items.contains(where: { $0.1 != nil }) {
            let known = items.filter { $0.1 != nil }.sorted { $0.1! < $1.1! }
            return known.prefix(max(1, known.count / 5)).randomElement()?.0
        }
        if flow < 0, items.contains(where: { $0.1 != nil }) {
            let known = items.filter { $0.1 != nil }.sorted { $0.1! > $1.1! }
            return known.prefix(max(1, known.count / 5)).randomElement()?.0
        }
        return pool.randomElement()
    }

    private func load(_ t: LibTrack, on i: Int) {
        var m = core.mixer
        m.fader[i] = 0; m.low[i] = 0                        // in silent, its bass cut, until its transition
        core.mixer = m
        waitingFor = (i, t.id)
        app.load(t, deck: i)
    }

    /// a deck that's (going) on air: its loudness matched, EQ flat, fader up, WIDE range, master tempo on
    private func prepareAir(_ d: DeckModel, start: Bool) {
        var m = core.mixer
        m.fader[d.i] = 1; m.low[d.i] = 0.5; m.mid[d.i] = 0.5; m.hi[d.i] = 0.5; m.cfx[d.i] = 0.5
        m.xfader = 0.5
        core.mixer = m
        d.setRange(RANGES.count - 1)
        if !d.mt { d.setMT(true) }
        matchLoudness(d)
        if start && !d.playing { d.setPlaying(true) }
    }

    /// TRIM so the track plays at the target loudness (Settings → Audio → Auto trim's target), measured the same
    /// way for every track so the decks compare
    private func matchLoudness(_ d: DeckModel) {
        let i = d.i
        app.autoTrim(d) { [weak self] g in if i < 3 { self?.trims[i] = g } }
    }

    // ---- the next track ----
    private func pick(after a: AutoMix.Track, rate: Double, from beat: Double, played: Set<String>) -> LibTrack? {
        let pool = poolTracks()
        var o = AutoMix.PickOptions()
        o.flow = flow; o.played = played; o.after = beat
        o.plan = AIDJMoves.planOptions(last: lastKind)
        let byId = Dictionary(pool.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
        if source != .library && keepOrder {
            // in order: the next one after the last played that hasn't been played
            let t = pool.first { !played.contains($0.id) }
            options = t.map { t in AutoMix.choose(after: a, aRate: rate, pool: [item(t)], o, deep: 1) { id in byId[id].map { self.item($0, full: true) } } } ?? []
            return t
        }
        options = Array(AutoMix.choose(after: a, aRate: rate, pool: pool.map { item($0) }, o, deep: 12) { id in byId[id].map { self.item($0, full: true) } }.prefix(6))
        return options.first.flatMap { byId[$0.track.id] }
    }
    private func prepareNext() {
        let A = deck(onAir)
        nextDeck = freeDeck()
        let nb = nextDeck
        guard let a = item(deck: A) else { return }
        var played = Set(history).union(skipped)
        if let id = A.track?.id { played.insert(id) }
        guard let t = pick(after: a, rate: A.rate(), from: beatNow() + 32, played: played) else {
            let pool = poolTracks()
            say(pool.count <= played.count ? "That was the last track in \(sourceName): AI DJ stops when it ends" : "Nothing in \(sourceName) fits within ±10% of this tempo: AI DJ stops when this track ends")
            phase = .playing
            nextId = nil; mixAsap = false
            return
        }
        nextId = t.id
        deck(nb).setSync(false)
        if deck(nb).playing { deck(nb).setPlaying(false) }
        load(t, on: nb)
        phase = .preparing
        say("Next: \(t.info.title)")
    }

    /// the next deck is loaded: plan the transition on the decks' real grids and cue the next track. No room left
    /// in the playing track: the loop bridge (when on) loops its last phrase so there is
    private func planLoaded() {
        let A = deck(onAir), B = deck(nextDeck)
        guard var a = item(deck: A), let b = item(deck: B) else { return }
        prepareAir(B, start: false)
        var m = core.mixer
        m.fader[B.i] = 0; m.low[B.i] = 0
        core.mixer = m
        let now = beatNow()
        if let br = bridge { a.duration = a.time(ofBeat: br.from + br.len * 8) + 0.3 }
        var p = AutoMix.plan(from: a, aRate: A.rate(), to: b, after: now + 8, maxShift: 0.12, options: AIDJMoves.planOptions(last: lastKind))
        if p == nil, bridge == nil, AIDJMoves.bridge, let br = startBridge(A, a, now) {
            a.duration = a.time(ofBeat: br.from + br.len * 8) + 0.3
            p = AutoMix.plan(from: a, aRate: A.rate(), to: b, after: max(now + 8, br.from), maxShift: 0.12, options: AIDJMoves.planOptions(last: lastKind))
        }
        guard let p else {
            endBridge()
            if let id = B.track?.id { skipped.insert(id) }
            say("No room to mix \(B.track?.title ?? "that") in: picking another")
            prepareNext()
            return
        }
        plan = p
        cue(p)
        phase = .ready
        let inBars = Int(((p.outStart - now) / 4).rounded(.up))
        say("\(B.track?.title ?? "Next") in \(max(0, inBars)) bars · \(p.kind.name), \(p.bars) bars" + (bridge != nil ? " · looping the outro to bridge" : ""))
        if mixAsap { mixNow() }
    }
    private func cue(_ p: AutoMix.Plan) {
        let B = deck(nextDeck)
        B.setSync(false)
        B.seek(max(0, B.timeOfBeat(p.inStart - leadIn(p) * p.mult)))
    }
    /// how many beats the next track can run silently before the transition: up to `leadIn`, as far as its start allows
    private func leadIn(_ p: AutoMix.Plan) -> Double {
        let B = deck(nextDeck)
        let room = (p.inStart - B.beatAt(0)) / max(0.25, p.mult)
        return max(0, min(Self.leadInBeats, room.rounded(.down)))
    }

    // ---- loop bridge ----
    /// loops the last whole 8 bars (else 4) before the playing track ends, from at least a beat ahead
    private func startBridge(_ A: DeckModel, _ a: AutoMix.Track, _ now: Double) -> (from: Double, len: Double)? {
        for len in [32.0, 16] {
            let from = ((a.lastBeat - len) / len).rounded(.down) * len
            if from >= now + 1 {
                A.setLoop(fromBeat: from, beats: len)
                bridge = (from, len); wraps = 0; lastRaw = A.beatAt(A.now())
                return bridge
            }
        }
        return nil
    }
    private func endBridge() {
        guard bridge != nil else { return }
        deck(onAir).exitLoop()
        bridge = nil; wraps = 0
    }

    // ---- third deck: the track after next, loaded during the transition ----
    private func preloadFollowing(_ p: AutoMix.Plan) {
        guard useThird, preload == nil else { return }
        let B = deck(nextDeck)
        guard let b = item(deck: B) else { return }
        let c = freeDeck(not: nextDeck)
        guard c != nextDeck, c != onAir else { return }
        var played = Set(history).union(skipped)
        for i in [onAir, nextDeck] { if let id = deck(i).track?.id { played.insert(id) } }
        // where B will be once the transition is over, plus a phrase
        let after = p.inStart + Double(p.bars * 4) * p.mult + 32
        guard let t = pick(after: b, rate: 1, from: after, played: played) else { return }
        if deck(c).playing { deck(c).setPlaying(false) }
        deck(c).setSync(false)
        preload = (c, t.id)
        load(t, on: c)
    }

    // ---- every frame ----
    func tick() {
        guard running else { return }
        let A = deck(onAir), B = deck(nextDeck)
        // loads finishing
        if let w = waitingFor {
            let d = deck(w.deck)
            if d.loaded, d.track?.id == w.id {
                waitingFor = nil
                if phase == .loading {
                    onAir = w.deck
                    nextDeck = freeDeck()
                    history = [w.id]
                    prepareAir(d, start: true)
                    phase = .playing
                    prepareNext()
                    return
                } else if phase == .preparing { planLoaded(); return }
                // a preload finishing while the transition runs: nothing to do until it ends
            } else if !d.loading && d.track?.id != w.id {
                // the load failed (or something else was loaded there): try another
                waitingFor = nil
                skipped.insert(w.id)
                if preload?.id == w.id { preload = nil }
                else if phase == .loading { phase = .idle; start(fresh: false); return }
                else if phase != .mixing { prepareNext(); return }
            }
        }
        guard phase != .loading else { return }
        // the playing deck stopped or ran out without a transition: hand back
        if !A.playing && phase != .mixing {
            stop(A.loaded && A.now() >= A.duration - 0.2 ? "The set ran out: no next track could be mixed in" : "Stopped: deck \(A.i + 1) was stopped")
            return
        }
        // the loop bridge: count the passes so the beat keeps going up
        if let br = bridge {
            let raw = A.beatAt(A.now())
            if raw < lastRaw - br.len / 2 { wraps += 1 }
            lastRaw = raw
        }
        guard let p = plan else { return }
        let beat = beatNow()
        switch phase {
        case .ready:
            if beat > p.outStart + 2 {
                // missed the start (a jump, a long load): plan again from here
                planLoaded()
                return
            }
            if beat >= p.outStart - leadIn(p) - 0.02 { begin(p, beat) }
        case .mixing:
            if !A.playing || !B.playing { finish(); return }
            let x = (beat - p.outStart) / 4
            if x >= Double(p.bars) { finish(); return }
            // the screen follows in quarter bars (redrawing it 60 times a second would be waste)
            let q = (max(0, x) * 4).rounded(.down) / 4
            if q != bar { bar = q }
            drive(p, max(0, x))
        default: break
        }
    }

    /// the lead-in's first beat: B synced to A on the matching beat of its own phrase and playing, its fader still
    /// down, so it's beat-matched before it's heard
    private func begin(_ p: AutoMix.Plan, _ beat: Double) {
        let A = deck(onAir), B = deck(nextDeck)
        A.setSync(false)
        let x = beat - p.outStart                          // negative during the lead-in
        B.seek(max(0, B.timeOfBeat(p.inStart + x * p.mult)))
        B.setSync(true)                                   // follows A: tempo and beat lock (½× / 2× when the plan says)
        B.setPlaying(true)
        lastLevels = nil; lastRate = A.rate()
        phase = .mixing
        bar = 0
        say("Mixing \(B.track?.title ?? "") in · \(p.kind.name), \(p.bars) bars")
        drive(p, max(0, x / 4))
        preloadFollowing(p)
    }

    /// faders, EQs, COLOR and tempo for where the transition is. Only what the kind moves is written, so your own
    /// moves on the rest stay
    private func drive(_ p: AutoMix.Plan, _ x: Double) {
        let A = deck(onAir), B = deck(nextDeck)
        let l = p.kind.levels(atBar: x, of: p.bars)
        if l != lastLevels {
            var m = core.mixer
            put(&m, "fader", A.i, l.outFader); put(&m, "low", A.i, l.outLow)
            put(&m, "fader", B.i, l.inFader); put(&m, "low", B.i, l.inLow)
            switch p.kind {
            case .eqHandoff:
                put(&m, "mid", A.i, l.outMid); put(&m, "hi", A.i, l.outHi); put(&m, "mid", B.i, l.inMid); put(&m, "hi", B.i, l.inHi)
            case .colorSweep: put(&m, "cfx", A.i, l.outCfx); put(&m, "cfx", B.i, l.inCfx)
            case .bassSwap, .cut: break
            }
            core.mixer = m                                 // one engine message for all of them
            lastLevels = l
        }
        // the tempo glides on A (the master); B follows through SYNC. WIDE range: pitch = rate − 1
        let r = AutoMix.rate(atBar: x, p)
        if abs(r - lastRate) > 2e-5 { A.setPitch((r - 1) * 100 / A.range); lastRate = r }
    }

    /// the transition's end: A stopped and reset, B on its own at its own tempo, then the next pick (already loaded
    /// on the third deck when that's on)
    private func finish() {
        let A = deck(onAir), B = deck(nextDeck)
        guard let p = plan else { return }
        var m = core.mixer
        m.fader[A.i] = 0
        put(&m, "fader", B.i, 1)
        m.low[A.i] = 0.5; m.mid[A.i] = 0.5; m.hi[A.i] = 0.5; m.cfx[A.i] = 0.5
        for n in ["low", "mid", "hi", "cfx"] { put(&m, n, B.i, 0.5) }       // what you set on the new track stays
        core.mixer = m
        held = []
        endBridge()
        if A.playing { A.setPlaying(false) }
        A.setPitch(0)
        B.setSync(false)                                   // back to its own fader: 0 on WIDE = its own tempo
        B.setPitch(0)
        if let id = B.track?.id { history.append(id) }
        lastKind = p.kind
        onAir = B.i
        plan = nil; bar = 0
        if let pl = preload, deck(pl.deck).track?.id == pl.id || waitingFor?.id == pl.id {
            // the third deck already has the next one
            preload = nil
            nextDeck = pl.deck; nextId = pl.id
            phase = .preparing
            say("Next: \(deck(pl.deck).track?.title ?? "loading…")")
            if deck(pl.deck).loaded && waitingFor == nil { planLoaded() }
            return
        }
        preload = nil
        phase = .playing
        prepareNext()
    }
}
