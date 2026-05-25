import SwiftUI

@main
struct AndroidMirrorMacApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Android Mirror") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 300, idealWidth: 514, minHeight: 560, idealHeight: 1147)
        }
        .defaultSize(width: 514, height: 1147)
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
