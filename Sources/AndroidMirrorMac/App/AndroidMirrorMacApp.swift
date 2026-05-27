import SwiftUI

struct AndroidMirrorMacSwiftUIPreviewApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Android Mirror") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 257, idealWidth: 257, minHeight: 574, idealHeight: 574)
        }
        .defaultSize(width: 257, height: 574)
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
