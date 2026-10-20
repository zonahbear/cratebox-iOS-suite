import SwiftUI

@main
struct CrateboxApp: App {
    @StateObject private var app = AppModel()
    var body: some Scene {
        WindowGroup {
            SuiteRoot()
                .environmentObject(app)
                .environmentObject(app.core)
                .environmentObject(app.core.fx)
                .environmentObject(app.library)
                .environmentObject(app.playlists)
                .environmentObject(Devices.shared)
                .environmentObject(app.recorder)
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
                .onAppear { app.start(); UIApplication.shared.isIdleTimerDisabled = true }
        }
    }
}
