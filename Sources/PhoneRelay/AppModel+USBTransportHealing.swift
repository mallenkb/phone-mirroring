import Foundation

/// Repairs a lost USB transport without the user pressing Fix Connection.
///
/// macOS can show a paired phone on the cable while the adb daemon lists no
/// USB transport for it: the daemon dropped the device after a failed read
/// during a USB reset or re-enumeration and does not pick it up again on its
/// own (observed 2026-10-04 with the libusb backend; the user pressed Fix
/// Connection ten times). The check is exact: the phone's USB serial in the
/// IORegistry against the USB rows in `adb devices`.
///
/// Repairs are escalated and never interrupt a live mirror (INVARIANTS.md
/// rule 1): first `adb reconnect offline`, then, only while no mirror,
/// mirror session, launch, or pairing exists, the guarded daemon restart.
extension AppModel {
    /// Delays before each check of one repair episode. The first one lets a
    /// freshly plugged phone finish its USB mode negotiation.
    nonisolated static let usbTransportHealCheckDelays: [TimeInterval] = [3, 4, 10, 30]

    /// USB serials adb lists over a cable, in any state (`device`,
    /// `unauthorized`, `offline`). An unauthorized row is still a transport.
    nonisolated static func adbUSBSerials(in output: String) -> Set<String> {
        var serials: Set<String> = []
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2,
                  !fields[0].lowercased().hasPrefix("list"),
                  !isWirelessADBTarget(fields[0]),
                  fields.dropFirst(2).contains(where: { $0.hasPrefix("usb:") })
            else { continue }
            serials.insert(fields[0])
        }
        return serials
    }

    /// `"USB Serial Number" = "RFCT10ZLTAJ"` entries from `ioreg -p IOUSB -l`.
    nonisolated static func usbSerialNumbers(inIORegOutput output: String) -> Set<String> {
        var serials: Set<String> = []
        for line in output.split(whereSeparator: \.isNewline) where line.contains("\"USB Serial Number\"") {
            guard let value = quotedValueAfterEquals(String(line)), !value.isEmpty else { continue }
            serials.insert(value)
        }
        return serials
    }

    /// Paired phones macOS sees on USB that adb has no USB transport for.
    nonisolated static func usbPhonesMissingFromADB(
        macUSBSerials: Set<String>,
        adbUSBSerials: Set<String>,
        pairedUSBSerials: Set<String>
    ) -> Set<String> {
        macUSBSerials.intersection(pairedUSBSerials).subtracting(adbUSBSerials)
    }

    nonisolated static func currentMacUSBSerialNumbers() async -> Set<String> {
        await Task.detached(priority: .utility) {
            usbSerialNumbers(inIORegOutput: Tooling.run(
                "ioreg",
                arguments: ["-p", "IOUSB", "-r", "-c", "IOUSBHostDevice", "-l", "-w", "0"],
                timeout: 2
            ))
        }.value
    }

    var pairedUSBSerials: Set<String> {
        Set(pairedPhones.compactMap(\.resolvedUSBSerial).filter { !Self.isWirelessADBTarget($0) })
    }

    /// Called with every device-list refresh. A paired phone's USB transport
    /// disappearing is either an unplug or a lost transport; the check tells
    /// them apart.
    func observeUSBTransportPresence(adbOutput: String) {
        let present = Self.adbUSBSerials(in: adbOutput)
        let previous = connectionCoordinator.lastADBUSBSerials
        connectionCoordinator.lastADBUSBSerials = present
        let vanished = previous.subtracting(present).intersection(pairedUSBSerials)
        if !vanished.isEmpty {
            scheduleUSBTransportHealthCheck(reason: "usb transport vanished")
        }
        // An authorized cable connection is the one chance to grant Phone
        // Relay Helper its adb-only permission.
        let authorizedUSB = Set(Self.authorizedADBDevices(in: adbOutput).filter(\.isUSB).map(\.serial))
        for serial in present.subtracting(previous).intersection(authorizedUSB) {
            grantHelperPermissionIfNeeded(usbSerial: serial)
        }
    }

    /// Starts one repair episode unless one is already running.
    func scheduleUSBTransportHealthCheck(reason: String) {
        guard backgroundServicesEnabled,
              connectionCoordinator.usbTransportHealTask == nil,
              !pairedUSBSerials.isEmpty
        else { return }
        let adb = self.adb
        connectionCoordinator.usbTransportHealTask = Task { [weak self] in
            defer { self?.connectionCoordinator.usbTransportHealTask = nil }
            for (attempt, delay) in Self.usbTransportHealCheckDelays.enumerated() {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                let macSerials = await Self.currentMacUSBSerialNumbers()
                let output = await Task.detached {
                    adb.run(["devices", "-l"], timeout: Self.adbDeviceListTimeout)
                }.value
                guard !Task.isCancelled else { return }
                let missing = Self.usbPhonesMissingFromADB(
                    macUSBSerials: macSerials,
                    adbUSBSerials: Self.adbUSBSerials(in: output),
                    pairedUSBSerials: self.pairedUSBSerials
                )
                guard !missing.isEmpty else {
                    if attempt > 0 {
                        Logger.log("USB transport repair: adb sees the phone on USB again")
                        self.applyDevicePresence(output)
                    }
                    return
                }
                let names = missing.sorted().joined(separator: ",")
                let mirrorOrPairingActive = self.isMirroring
                    || self.mirrorSession != nil
                    || self.mirrorLaunchTask != nil
                    || self.isPairing
                if attempt == 1, !mirrorOrPairingActive {
                    Logger.log("USB transport repair (\(reason)): macOS sees \(names) on USB but adb does not; restarting the app-owned adb server")
                    self.recoverADBDaemonIfSafe(reason: "usb transport missing")
                } else {
                    Logger.log("USB transport repair (\(reason)) attempt \(attempt + 1): macOS sees \(names) on USB but adb does not; reconnecting offline transports\(mirrorOrPairingActive ? " (mirror active, server restart deferred)" : "")")
                    _ = await Task.detached {
                        adb.run(["reconnect", "offline"], timeout: 3)
                    }.value
                }
            }
            self?.noteConnectionStall(
                .usbNotReady,
                detail: "macOS sees the phone on USB but adb never listed it. Unplug and replug the cable."
            )
        }
    }
}
