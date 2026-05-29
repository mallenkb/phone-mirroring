import SwiftUI

struct AndroidMirrorMacSwiftUIPreviewApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Android Mirroring") {
            RootView()
                .environmentObject(model)
                .frame(
                    minWidth: AppModel.onboardingWindowSize.width,
                    idealWidth: AppModel.onboardingWindowSize.width,
                    maxWidth: AppModel.onboardingWindowSize.width,
                    minHeight: AppModel.onboardingWindowSize.height,
                    idealHeight: AppModel.onboardingWindowSize.height,
                    maxHeight: AppModel.onboardingWindowSize.height
                )
        }
        .defaultSize(
            width: AppModel.onboardingWindowSize.width,
            height: AppModel.onboardingWindowSize.height
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
