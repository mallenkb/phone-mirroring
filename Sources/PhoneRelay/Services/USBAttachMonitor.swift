import Foundation
import IOKit
import IOKit.usb

/// Kernel-event USB attach watcher. Fires the callback the moment macOS
/// enumerates a new USB device, so the device watcher can run its `adb
/// devices` scan immediately instead of waiting out the current poll
/// interval. Costs nothing at idle — IOKit pushes events; nothing polls.
final class USBAttachMonitor: @unchecked Sendable {
    private let onAttach: @Sendable () -> Void
    private let queue = DispatchQueue(label: "phonerelay.usb-attach-monitor", qos: .utility)
    private var notificationPort: IONotificationPortRef?
    private var attachIterator: io_iterator_t = 0
    /// IOKit holds a raw pointer to us for the callback, so we self-retain
    /// from `start()` until `stop()`. Owners must call `stop()` — deinit
    /// can't run while the self-retain is live.
    private var retainedSelf: Unmanaged<USBAttachMonitor>?

    init(onAttach: @escaping @Sendable () -> Void) {
        self.onAttach = onAttach
    }

    func start() {
        guard notificationPort == nil else { return }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            Logger.log("USB attach monitor: could not create IONotificationPort")
            return
        }
        IONotificationPortSetDispatchQueue(port, queue)
        notificationPort = port

        let matching = IOServiceMatching("IOUSBHostDevice")
        let retained = Unmanaged.passRetained(self)
        retainedSelf = retained
        let status = IOServiceAddMatchingNotification(
            port,
            kIOFirstMatchNotification,
            matching,
            { context, iterator in
                guard let context else { return }
                Unmanaged<USBAttachMonitor>.fromOpaque(context)
                    .takeUnretainedValue()
                    .drain(iterator: iterator, notify: true)
            },
            retained.toOpaque(),
            &attachIterator
        )
        guard status == KERN_SUCCESS else {
            Logger.log("USB attach monitor: IOServiceAddMatchingNotification failed status=\(status)")
            stop()
            return
        }
        // Draining the iterator once arms the notification; the devices
        // already present at start don't count as fresh attaches.
        drain(iterator: attachIterator, notify: false)
        Logger.log("USB attach monitor armed")
    }

    func stop() {
        if attachIterator != 0 {
            IOObjectRelease(attachIterator)
            attachIterator = 0
        }
        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
            self.notificationPort = nil
        }
        retainedSelf?.release()
        retainedSelf = nil
    }

    private func drain(iterator: io_iterator_t, notify: Bool) {
        var sawDevice = false
        var service = IOIteratorNext(iterator)
        while service != 0 {
            sawDevice = true
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        if notify && sawDevice {
            onAttach()
        }
    }
}
