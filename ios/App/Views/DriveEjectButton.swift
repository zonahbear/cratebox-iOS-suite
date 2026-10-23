import SwiftUI

/// The top bar's EJECT (DriveWatch.swift does the work): shown while a USB drive Cratebox knows is plugged in.
/// With none, it's + USB, which adds a stick in Files (iOS tells apps nothing about drives until one is picked).
/// 44 × 44 pt to touch (Apple's minimum) but drawn 30 pt tall like the bar's other buttons, and it takes up only
/// 30 pt of the bar's height, so the bars keep their sizes.
struct DriveEjectButton: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var watch = DriveWatch.shared
    @State private var picking = false

    var body: some View {
        ZStack {
            if watch.drives.count > 1 {
                Menu {
                    ForEach(watch.drives) { d in Button { watch.eject(d) } label: { Label("Eject \(d.name)", systemImage: "eject") } }
                } label: { face(eject: true) }
            } else if let d = watch.drives.first {
                Button { watch.eject(d) } label: { face(eject: true) }.buttonStyle(.plain).accessibilityLabel("Eject \(d.name)")
            } else {
                Button { picking = true } label: { face(eject: false) }.buttonStyle(.plain).accessibilityLabel("Add a USB drive")
            }
        }
        // on the ZStack, which stays put when the button changes (the alert outlives the EJECT that raised it)
        .alert(watch.notice?.title ?? "", isPresented: Binding(get: { watch.notice != nil }, set: { if !$0 { watch.notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(watch.notice?.message ?? "") }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { r in
            switch r {
            case .success(let u): _ = app.library.addFolder(u); watch.check()
            case .failure(let e): app.status("Couldn't open that: \(e.localizedDescription)")
            }
        }
    }

    func face(eject: Bool) -> some View {
        HStack(spacing: 4) {
            if eject {
                if watch.ejecting != nil { ProgressView().controlSize(.small) } else { Image(systemName: "eject.fill").font(.system(size: 14, weight: .semibold)) }
            } else {
                Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                Text("USB").font(.system(size: 12, weight: .semibold))
            }
        }
        .foregroundStyle(Theme.fg)
        .frame(minWidth: 44).padding(.horizontal, eject ? 0 : 8).frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.raise))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line2, lineWidth: 1))
        .frame(height: 44).contentShape(Rectangle())
        .padding(.vertical, -7)
    }
}
