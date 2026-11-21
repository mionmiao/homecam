import SwiftUI

@main
struct HomeCamCameraApp: App {
    @StateObject private var model = CameraAppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            PhoneDisguiseView().environmentObject(model)
                .onChange(of: scenePhase) { phase in
                    model.scenePhaseChanged(phase)
                }
        }
    }
}
