import SwiftUI
import CrateboxKit

/// The controller's browser on a phone, like a CDJ's browse screen: it comes up over the decks when the
/// browse knob turns (or the knob is pressed), and goes after 8 seconds of quiet or a LOAD. Turn: move
/// through the tracks. Press: move through the playlists instead (press again to go back to the tracks).
/// It opens on the list and track you were on last.
struct BrowserOverlay: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var library: Library
    @EnvironmentObject var devices: Devices
    @EnvironmentObject var core: Core

    var body: some View {
        let sources = app.browseSources(), tracks = app.browseTracks()
        let ref = core.decks.filter { $0.playing && $0.loaded }.sorted { $0.startedAt > $1.startedAt }.first?.keyNow() ?? -1
        HStack(spacing: 6) {
            // the playlists
            VStack(alignment: .leading, spacing: 0) {
                heading("PLAYLISTS", on: app.browseFocusTree)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(sources.enumerated()), id: \.element.id) { k, s in
                                if k == 0 || sources[k - 1].group != s.group {
                                    HStack {
                                        Text(s.group.uppercased()).font(.system(size: 9, weight: .heavy)).tracking(1).foregroundStyle(Theme.dim).lineLimit(1)
                                        Spacer()
                                        if let dv = s.deviceId, let d = devices.list.first(where: { $0.id == dv }) {
                                            Button { devices.eject(d); app.showBrowser() } label: {
                                                Label("EJECT", systemImage: "eject.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.muted)
                                            }.buttonStyle(.plain)
                                        }
                                    }
                                    .padding(.top, k == 0 ? 0 : 8).padding(.horizontal, 6)
                                }
                                let cur = s.view == app.view, cursor = app.browseFocusTree && s.view == (app.treeCursor ?? app.view)
                                Text(s.name).font(.system(size: 13, weight: cur ? .bold : .regular)).lineLimit(1)
                                    .padding(.leading, 8 + CGFloat(s.depth) * 12).frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(cursor ? Theme.loop.opacity(0.35) : cur ? Theme.raise : .clear))
                                    .contentShape(Rectangle())
                                    .onTapGesture { app.view = s.view; app.browseFocusTree = false; app.treeCursor = nil; app.showBrowser() }
                                    .id(s.id)
                            }
                        }
                    }
                    .onAppear { proxy.scrollTo(LibraryPane.key(app.view), anchor: .center) }
                    .onChange(of: app.treeCursor ?? app.view) { _, v in withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(LibraryPane.key(v), anchor: .center) } }
                }
            }
            .frame(width: 220)
            // the tracks in the list
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    heading("\(app.browseTitle.uppercased()) · \(tracks.count)", on: !app.browseFocusTree)
                    Spacer()
                    Button { app.hideBrowser() } label: { Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).frame(width: 30, height: 24) }.buttonStyle(.plain)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(tracks, id: \.id) { t in row(t, ref) }
                        }
                    }
                    .overlay { if tracks.isEmpty { Text("No tracks here. Press the browse knob to pick another list.").font(.caption).foregroundStyle(Theme.muted) } }
                    .onAppear { if let s = app.selection { proxy.scrollTo(s, anchor: .center) } }
                    .onChange(of: app.selection) { _, s in if let s { withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(s, anchor: .center) } } }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bg.opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line2))
    }

    func heading(_ s: String, on: Bool) -> some View {
        Text(s).font(.system(size: 10, weight: .heavy)).tracking(1).lineLimit(1)
            .foregroundStyle(on ? Theme.loop : Theme.muted).padding(.vertical, 4).padding(.horizontal, 6)
    }

    func row(_ t: LibTrack, _ ref: Int) -> some View {
        let sel = app.selection == t.id
        let deckOn = core.decks.firstIndex { $0.track === t.info }
        let decks = core.four ? [app.midi.side[0], app.midi.side[1]] : [0, 1]
        return HStack(spacing: 8) {
            if let d = deckOn { Text("\(d + 1)").font(.system(size: 10, weight: .heavy)).foregroundStyle(Color.black).frame(width: 16, height: 16).background(RoundedRectangle(cornerRadius: 3).fill(Theme.deck[d])) }
            else { Color.clear.frame(width: 16, height: 16) }
            VStack(alignment: .leading, spacing: 0) {
                Text(t.info.title).font(.system(size: 13, weight: sel ? .bold : .medium)).lineLimit(1)
                Text(t.info.artist).font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text((t.info.bpm ?? 0) > 0 ? String(format: "%.1f", t.info.bpm!) : (t.analysed ? "?" : "…")).font(.system(size: 12, design: .monospaced)).frame(width: 46, alignment: .trailing)
            if let c = Keys.camelot(t.info.key) {
                let match = ref >= 0 && Keys.mixes(t.info.key, ref)
                Text(c.label).font(.system(size: 12, weight: match ? .heavy : .semibold, design: .monospaced)).foregroundStyle(Theme.keyColor(c.num, c.letter))
                    .frame(width: 34).background(RoundedRectangle(cornerRadius: 3).stroke(match ? Theme.ok : .clear))
            } else { Text("").frame(width: 34) }
            Text(t.info.duration > 0 ? String(format: "%d:%02d", Int(t.info.duration) / 60, Int(t.info.duration) % 60) : "").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted).frame(width: 38, alignment: .trailing)
            if sel {
                ForEach(decks, id: \.self) { d in
                    Button { app.load(t, deck: d); app.hideBrowser() } label: {
                        Text("LOAD \(d + 1)").font(.system(size: 10, weight: .bold)).frame(width: 54, height: 24).foregroundStyle(Color.black)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.deck[d]))
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 6).frame(minHeight: 34)
        .background(RoundedRectangle(cornerRadius: 5).fill(sel ? (app.browseFocusTree ? Theme.raise : Theme.loop.opacity(0.3)) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { app.selection = t.id; app.browseFocusTree = false; app.showBrowser() }
        .contextMenu {
            // add to a playlist: your own, or (editing on) one on the stick the track is on
            Menu("Add to my playlist") {
                ForEach(app.playlists.lists.filter { !$0.folder }) { p in Button(app.playlists.path(p)) { app.playlists.add([t], to: p.id); app.status("Added to \(p.name)") } }
            }
            if devices.editable, let d = devices.list.first(where: { $0.id == t.device }) {
                Menu("Add to \(d.name) playlist") {
                    ForEach(d.tree.filter { !$0.folder }, id: \.id) { n in Button(n.name) { devices.add([t], to: n.id, in: d) } }
                }
            }
        }
        .id(t.id)
    }
}
