import SwiftUI

struct AndroidMirrorMacSwiftUIPreviewApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Android device") {
            RootView()
                .environmentObject(model)
                .frame(
                    minWidth: AppModel.minimumConnectionWindowSize.width,
                    idealWidth: AppModel.defaultConnectionWindowSize.width,
                    minHeight: AppModel.minimumConnectionWindowSize.height,
                    idealHeight: AppModel.defaultConnectionWindowSize.height
                )
        }
        .defaultSize(
            width: AppModel.defaultConnectionWindowSize.width,
            height: AppModel.defaultConnectionWindowSize.height
        )
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Scan for Android Devices") { model.scanADBDevices() }
                    .keyboardShortcut("r", modifiers: [.command])
                Button(model.isMirroring ? "Stop Mirroring" : "Start Mirroring") {
                    model.isMirroring ? model.stopMirroring() : model.startMirroring()
                }
                .keyboardShortcut("m", modifiers: [.command])
            }
        }
    }
}
