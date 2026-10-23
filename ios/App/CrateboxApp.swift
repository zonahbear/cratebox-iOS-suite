import SwiftUI

@main
struct CrateboxApp: App {
    @StateObject private var app = AppModel()
    // personal/heat: the watch mic's Bluetooth link has to be up before a message from the watch arrives
    init() { _ = WatchMicReceiver.shared }
    var body: some Scene {
        WindowGroup {
            SuiteRoot()
                .modifier(ScreenFrame())
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
                .onAppear { app.start(); UIApplication.shared.isIdleTimerDisabled = true; ScreenOverride.writeMetrics() }
        }
    }
}
