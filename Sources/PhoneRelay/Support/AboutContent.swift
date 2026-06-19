import Foundation

enum AboutContent {
    static let privacyPolicy = """
    Phone Relay does not run an analytics service, advertising SDK, tracking SDK, or hosted user account system. The app does not sell personal information.

    Screen mirroring video is used locally to show your Android screen on this Mac. Phone Relay does not upload mirrored screen content.

    Notification forwarding is optional and off by default. If enabled, Phone Relay reads Android notification text through adb and posts local macOS notifications.

    Screenshots and recordings are created only when you use those controls. Captures are saved to your Mac's Downloads folder.

    Phone Relay may store pairing details, device names, connection state, and preferences in local macOS app storage so reconnects and settings work.

    Permissions used by the app: Local Network for Wi-Fi discovery and reconnects, Notifications for optional phone notification forwarding, USB for adb communication, and Downloads for user-created captures.
    """

    static let supportDetails = """
    For support, include the app version and build shown above, your macOS version, Android version, connection type, and whether USB mirroring works before Wi-Fi handoff.

    If a connection or mirroring step fails, open the app log from the Help menu and include the relevant error lines when reporting the issue.

    Useful diagnostics: the selected device name, adb serial or Wi-Fi address, whether Android USB debugging or Wireless debugging is enabled, and the last action you took before the failure.
    """

    static let projectLicense = """
    Phone Relay App License

    Copyright (c) 2026 Marlon Alenya. All rights reserved.

    Phone Relay is provided as a macOS application for local Android device mirroring, pairing, capture, clipboard, keyboard, file transfer, and optional notification forwarding workflows.

    Unless a separate written license or App Store license says otherwise, you may use the distributed Phone Relay app for personal or internal device mirroring. You may not sell, sublicense, redistribute, or repackage Phone Relay, its name, icon, or original application code without written permission from the copyright owner.

    This project license applies only to Phone Relay's original application code, design, documentation, and bundled app presentation. It does not reduce, replace, or override rights granted by third-party open-source licenses.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, AND NON-INFRINGEMENT. IN NO EVENT SHALL THE COPYRIGHT OWNER BE LIABLE FOR ANY CLAIM, DAMAGE, OR OTHER LIABILITY ARISING FROM THE SOFTWARE OR ITS USE.
    """

    static let thirdPartyNotices = """
    Phone Relay includes and interoperates with scrcpy components for Android screen mirroring.

    scrcpy
    Copyright: Genymobile and scrcpy contributors
    License: Apache License 2.0
    Included material: scrcpy source material and the bundled scrcpy-server artifact used by the macOS app.

    Apache License 2.0 permits use, reproduction, modification, and distribution subject to its conditions. Required notices, copyright statements, and license text must be preserved, and significant modifications must be documented when applicable.

    The full Apache License 2.0 text for scrcpy is bundled locally with Phone Relay in About/LICENSES/scrcpy-APACHE-2.0.txt.
    """
}
