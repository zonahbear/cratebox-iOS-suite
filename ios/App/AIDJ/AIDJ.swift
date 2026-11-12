// AI DJ: mixes on its own on decks 1 and 2 (the suite's AI DJ mode, behind Settings → AI mode). It picks the next
// track (from the whole library, a playlist, or tracks you chose), loads it on the free deck, matches its loudness
// with TRIM, and runs the transition: the next track synced to the playing one (beat-matched, SYNC's beat lock) and
// started on the bar its plan says, the faders and LOW EQs moved bar by bar (for now the 32-bar bass swap), and the
// tempo glided from the playing track's to the new one's own, so the set moves between tempos instead of sitting on
// one. Apple's Music Understanding (iOS 27, AI mode's background analysis) tells it where the vocals are, so two
// vocals don't overlap, and gives energy and sound for the picks; without it AI DJ still mixes on key, tempo and
// phrases. Apple Intelligence (iOS 26+, where the model is ready) can narrow the tracks from a sentence ("vibe").
// Everything runs on the device; the decisions themselves are CrateboxKit's AutoMix (tested there).
//
// It drives the same decks and mixer you see in Performance Mode: touch the decks and it carries on around you;
// stop the playing deck, or STOP here, and it hands back. Runs from AppModel's display-link tick (main thread).
import Foundation
import CrateboxKit

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
    /// bars into the transition (while mixing)
    @Published private(set) var bar = 0.0
    /// what AI DJ would play next, best first, for the screen
    @Published private(set) var options: [AutoMix.Choice] = []
    @Published private(set) var trims: [Double?] = [nil, nil]       // dB AI DJ set on decks 1 and 2

    /// the deck on air (0 or 1); the other one is the next
    private(set) var onAir = 0
    private var waitingFor: (deck: Int, id: String)?
    private var nextId: String?
    private var lastLevels: AutoMix.Levels?
    private var lastRate = 0.0
    private var skipped = Set<String>()        // picks that wouldn't load or plan, this session

    var running: Bool { phase != .idle }

    init(app: AppModel) {
        self.app = app
        let u = UserDefaults.standard
        selected = u.stringArray(forKey: "cb.aidj.selected") ?? []
        keepOrder = u.bool(forKey: "cb.aidj.order")
        flow = u.object(forKey: "cb.aidj.flow") == nil ? 0 : u.integer(forKey: "cb.aidj.flow")
    }

    private var core: Core { app.core }
    private func deck(_ i: Int) -> DeckModel { core.decks[i] }
    private func say(_ s: String) { message = s }

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
    /// a library track as AutoMix sees it: Apple's loudness and shares only (`full`: its vocals and drums too, read
    /// from disk, so only for the few being planned)
    private func item(_ t: LibTrack, full: Bool = false) -> AutoMix.Track {
        let i = t.info
        if full, let f = AppleMusic.shared.features(t), AIMode.on {
            return AutoMix.Track(id: t.id, bpm: i.bpm ?? 0, firstBeat: i.firstBeat ?? 0, duration: i.duration, key: i.key, features: f)
        }
        var x = AutoMix.Track(id: t.id, bpm: i.bpm ?? 0, firstBeat: i.firstBeat ?? 0, duration: i.duration, key: i.key)
        if let l = AppleMusic.shared.lite(t.id) {
            x.shares = l.shares
            x.energy = AutoMix.energy(lufs: l.lufs, drumShare: l.shares?[1])
        }
        return x
    }
    /// a loaded deck as AutoMix sees it: the deck's own grid (rekordbox's, Apple's or Cratebox's, whichever it uses)
    private func item(deck d: DeckModel) -> AutoMix.Track? {
        guard d.loaded, let a = d.ana, let t = d.track else { return nil }
        let f = app.library.track(t.id).flatMap { AppleMusic.shared.features($0) }
        return AutoMix.Track(id: t.id, bpm: a.bpm, firstBeat: a.firstBeat, duration: d.duration, key: a.key, features: AIMode.on ? f : nil)
    }

    // ---- start / stop ----
    func start(fresh: Bool = true) {
        guard !running else { return }
        guard AIMode.on else { say("Turn on AI mode first (Settings → AI mode)"); return }
        app.setDecks(2)                                    // AI DJ mixes on two decks
        history = []; options = []; plan = nil
        if fresh { skipped = [] }
        for i in 0..<2 { deck(i).setSync(false); if !deck(i).mt { deck(i).setMT(true) } }
        // a deck already playing: AI DJ takes over from it
        if let d = [deck(0), deck(1)].filter({ $0.playing && $0.loaded }).max(by: { $0.startedAt < $1.startedAt }), let id = d.track?.id {
            onAir = d.i
            history = [id]
            prepareAir(d, start: false)
            phase = .playing
            say("Taking over from deck \(d.i + 1)")
            prepareNext()
            return
        }
        let pool = poolTracks().filter { !skipped.contains($0.id) }
        guard let first = firstPick(pool) else { say(pool.isEmpty ? "No analysed tracks in \(sourceName)" : "Nothing to play"); return }
        onAir = 0
        deck(1).setPlaying(false)
        load(first, on: 0)
        phase = .loading
        say("Loading \(first.info.title)")
    }
    func stop(_ why: String = "Stopped: the decks are yours") {
        guard running else { return }
        // mid-transition: leave both decks where they are, but don't leave a bass cut or a half-moved tempo stuck
        if phase == .mixing {
            var m = core.mixer
            m.low[onAir] = 0.5; m.low[1 - onAir] = 0.5
            core.mixer = m
        }
        phase = .idle; plan = nil; waitingFor = nil; nextId = nil; lastLevels = nil
        say(why)
    }
    /// pick another next track (not while the transition runs)
    func skipNext() {
        guard running, phase != .mixing, phase != .loading else { return }
        if let n = nextId { skipped.insert(n) }
        deck(1 - onAir).setSync(false)
        prepareNext()
    }
    /// start the transition at the next bar instead of the next good phrase
    func mixNow() {
        guard phase == .ready, let a = item(deck: deck(onAir)), let b = item(deck: deck(1 - onAir)) else { return }
        let A = deck(onAir)
        if let p = AutoMix.plan(from: a, aRate: A.rate(), to: b, after: A.beatAt(A.now()) + 1, step: 4, maxShift: 0.12) {
            plan = p
            cue(p)
            say("Mixing in at the next bar")
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

    /// TRIM so the track plays at the target loudness (Settings → Sound → Auto trim's target), measured the same
    /// way for every track so the two decks compare
    private func matchLoudness(_ d: DeckModel) {
        let i = d.i
        app.autoTrim(d) { [weak self] g in self?.trims[i] = g }
    }

    // ---- the next track ----
    private func prepareNext() {
        let A = deck(onAir), nb = 1 - onAir
        guard let a = item(deck: A) else { return }
        let pool = poolTracks()
        var played = Set(history).union(skipped)
        if let id = A.track?.id { played.insert(id) }
        var o = AutoMix.PickOptions()
        o.flow = flow; o.played = played
        o.after = A.beatAt(A.now()) + 32
        let byId = Dictionary(pool.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
        var pick: LibTrack?
        if source != .library && keepOrder {
            // in order: the next one after the last played that hasn't been played
            pick = pool.first { !played.contains($0.id) }
            options = pick.map { t in AutoMix.choose(after: a, aRate: A.rate(), pool: [item(t)], o, deep: 1) { id in byId[id].map { self.item($0, full: true) } } } ?? []
        } else {
            options = Array(AutoMix.choose(after: a, aRate: A.rate(), pool: pool.map { item($0) }, o, deep: 12) { id in byId[id].map { self.item($0, full: true) } }.prefix(6))
            pick = options.first.flatMap { byId[$0.track.id] }
        }
        guard let t = pick else {
            say(pool.count <= played.count ? "That was the last track in \(sourceName): AI DJ stops when it ends" : "Nothing in \(sourceName) fits within ±10% of this tempo: AI DJ stops when this track ends")
            phase = .playing
            nextId = nil
            return
        }
        nextId = t.id
        deck(nb).setSync(false)
        if deck(nb).playing { deck(nb).setPlaying(false) }
        load(t, on: nb)
        phase = .preparing
        say("Next: \(t.info.title)")
    }

    /// the next deck is loaded: plan the transition on the decks' real grids and cue the next track
    private func planLoaded() {
        let A = deck(onAir), B = deck(1 - onAir)
        guard let a = item(deck: A), let b = item(deck: B) else { return }
        prepareAir(B, start: false)
        var m = core.mixer
        m.fader[B.i] = 0; m.low[B.i] = 0
        core.mixer = m
        guard let p = AutoMix.plan(from: a, aRate: A.rate(), to: b, after: A.beatAt(A.now()) + 8, maxShift: 0.12) else {
            if let id = B.track?.id { skipped.insert(id) }
            say("No room to mix \(B.track?.title ?? "that") in: picking another")
            prepareNext()
            return
        }
        plan = p
        cue(p)
        phase = .ready
        let inBars = Int(((p.outStart - A.beatAt(A.now())) / 4).rounded(.up))
        say("\(B.track?.title ?? "Next") in \(max(0, inBars)) bars · \(p.kind.name), \(p.bars) bars")
    }
    private func cue(_ p: AutoMix.Plan) {
        let B = deck(1 - onAir)
        B.setSync(false)
        B.seek(B.timeOfBeat(p.inStart))
    }

    // ---- every frame ----
    func tick() {
        guard running else { return }
        let A = deck(onAir), B = deck(1 - onAir)
        // loads finishing
        if let w = waitingFor {
            let d = deck(w.deck)
            if d.loaded, d.track?.id == w.id {
                waitingFor = nil
                if phase == .loading {
                    onAir = w.deck
                    history = [w.id]
                    prepareAir(d, start: true)
                    phase = .playing
                    prepareNext()
                } else if phase == .preparing { planLoaded() }
                return
            }
            if !d.loading && d.track?.id != w.id {
                // the load failed (or something else was loaded there): try another
                waitingFor = nil
                skipped.insert(w.id)
                if phase == .loading { phase = .idle; start(fresh: false) } else { prepareNext() }
                return
            }
        }
        guard phase != .loading else { return }
        // the playing deck stopped or ran out without a transition: hand back
        if !A.playing && phase != .mixing {
            stop(A.loaded && A.now() >= A.duration - 0.2 ? "The set ran out: no next track could be mixed in" : "Stopped: deck \(A.i + 1) was stopped")
            return
        }
        guard let p = plan else { return }
        let beat = A.beatAt(A.now())
        switch phase {
        case .ready:
            if beat > p.outStart + 2 {
                // missed the start (a jump, a long load): plan again from here
                planLoaded()
                return
            }
            if beat >= p.outStart - 0.02 { begin(p, beat) }
        case .mixing:
            if !A.playing || !B.playing { finish(); return }
            let x = max(0, (beat - p.outStart) / 4)
            if x >= Double(p.bars) { finish(); return }
            // the screen follows in quarter bars (redrawing it 60 times a second would be waste)
            let q = (x * 4).rounded(.down) / 4
            if q != bar { bar = q }
            drive(p, x)
        default: break
        }
    }

    /// the transition's first beat: B synced to A on the matching beat of its own phrase, then playing
    private func begin(_ p: AutoMix.Plan, _ beat: Double) {
        let A = deck(onAir), B = deck(1 - onAir)
        A.setSync(false)
        let x = max(0, beat - p.outStart)
        B.seek(B.timeOfBeat(p.inStart + x * p.mult))
        B.setSync(true)                                   // follows A: tempo and beat lock (½× / 2× when the plan says)
        B.setPlaying(true)
        lastLevels = nil; lastRate = A.rate()
        phase = .mixing
        bar = x / 4
        say("Mixing \(B.track?.title ?? "") in · \(p.kind.name)")
        drive(p, bar)
    }

    /// faders, basses and tempo for where the transition is
    private func drive(_ p: AutoMix.Plan, _ x: Double) {
        let A = deck(onAir), B = deck(1 - onAir)
        let l = p.kind.levels(atBar: x, of: p.bars)
        if l != lastLevels {
            var m = core.mixer
            m.fader[A.i] = l.outFader; m.low[A.i] = l.outLow
            m.fader[B.i] = l.inFader; m.low[B.i] = l.inLow
            core.mixer = m                                 // one engine message for all four
            lastLevels = l
        }
        // the tempo glides on A (the master); B follows through SYNC. WIDE range: pitch = rate − 1
        let r = AutoMix.rate(atBar: x, p)
        if abs(r - lastRate) > 2e-5 { A.setPitch((r - 1) * 100 / A.range); lastRate = r }
    }

    /// the transition's end: A stopped and reset, B on its own at its own tempo, then the next pick
    private func finish() {
        let A = deck(onAir), B = deck(1 - onAir)
        guard let p = plan else { return }
        let l = p.kind.levels(atBar: Double(p.bars), of: p.bars)
        var m = core.mixer
        m.fader[A.i] = 0; m.low[A.i] = 0.5
        m.fader[B.i] = max(l.inFader, 1); m.low[B.i] = 0.5
        core.mixer = m
        if A.playing { A.setPlaying(false) }
        A.setPitch(0)
        B.setSync(false)                                   // back to its own fader: 0 on WIDE = its own tempo
        B.setPitch(0)
        if let id = B.track?.id { history.append(id) }
        onAir = B.i
        plan = nil; bar = 0
        phase = .playing
        prepareNext()
    }
}
