import SwiftUI

@main
struct CrateboxApp: App {
    @StateObject private var app = AppModel()
    @StateObject private var playlists = Playlists()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(app)
                .environmentObject(app.core)
                .environmentObject(app.core.fx)
                .environmentObject(app.library)
                .environmentObject(playlists)
                .environmentObject(Devices.shared)
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
                .onAppear { app.start(); UIApplication.shared.isIdleTimerDisabled = true }
        }
    }
}
