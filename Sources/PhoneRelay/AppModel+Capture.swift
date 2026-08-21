import AppKit
import AVFoundation
import Darwin
import Foundation
import QuartzCore

// Pure move from AppModel.swift (2026-07-05): screenshots, screen recording
// (segmented around Android's screenrecord cap, merged on save), capture
// folders, and capture cue sounds — verbatim. Session-token remote paths and
// the orphan sweep are deliberate (never delete a previous session's
// un-pulled recording); see INVARIANTS.md before changing.
extension AppModel {

    // MARK: - Capture folders

    /// Reveals the most recently saved screenshot or recording in Finder.
    func revealLastCapture() {
        guard let url = lastCaptureURL,
              FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func chooseScreenshotFolder() {
        chooseCaptureFolder(title: "Choose Screenshot Folder") { [weak self] url in
            self?.setScreenshotFolder(url)
        }
    }

    func chooseRecordingFolder() {
        chooseCaptureFolder(title: "Choose Screen Recording Folder") { [weak self] url in
            self?.setRecordingFolder(url)
        }
    }

    func resetScreenshotFolder() {
        clearCaptureFolder(pathKey: Self.screenshotFolderPathDefaultsKey, bookmarkKey: Self.screenshotFolderBookmarkDefaultsKey)
        screenshotFolderPath = nil
    }

    func resetRecordingFolder() {
        clearCaptureFolder(pathKey: Self.recordingFolderPathDefaultsKey, bookmarkKey: Self.recordingFolderBookmarkDefaultsKey)
        recordingFolderPath = nil
    }

    func setScreenshotFolder(_ url: URL) {
        storeCaptureFolder(url, pathKey: Self.screenshotFolderPathDefaultsKey, bookmarkKey: Self.screenshotFolderBookmarkDefaultsKey)
        screenshotFolderPath = url.path
    }

    func setRecordingFolder(_ url: URL) {
        storeCaptureFolder(url, pathKey: Self.recordingFolderPathDefaultsKey, bookmarkKey: Self.recordingFolderBookmarkDefaultsKey)
        recordingFolderPath = url.path
    }

    func screenshotOutputDirectory() -> URL? {
        captureFolder(pathKey: Self.screenshotFolderPathDefaultsKey, bookmarkKey: Self.screenshotFolderBookmarkDefaultsKey)
    }

    func recordingOutputDirectory() -> URL? {
        captureFolder(pathKey: Self.recordingFolderPathDefaultsKey, bookmarkKey: Self.recordingFolderBookmarkDefaultsKey)
    }

    nonisolated static func clampedRecordingMaxMinutes(_ minutes: Int) -> Int {
        min(recordingMaxMinutesRange.upperBound, max(recordingMaxMinutesRange.lowerBound, minutes))
    }

    /// Not private: the `recordingMaxMinutes` property initializer lives in
    /// AppModel.swift while this helper moved to AppModel+Capture.swift.
    nonisolated static func loadRecordingMaxMinutes() -> Int {
        guard let stored = UserDefaults.standard.object(forKey: recordingMaxMinutesDefaultsKey) as? Int else {
            return recordingMaxMinutesDefault
        }
        return clampedRecordingMaxMinutes(stored)
    }

    /// The `--time-limit` value (seconds) for `screenrecord`, derived from the
    /// configured cap. Read on the main actor and captured before the detached
    /// recording task so it stays Sendable.
    var recordingTimeLimitSeconds: Int {
        Self.clampedRecordingMaxMinutes(recordingMaxMinutes) * 60
    }

    // MARK: - Capture folder storage

    private func chooseCaptureFolder(title: String, onSelection: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            onSelection(url)
        }
    }

    private func storeCaptureFolder(_ url: URL, pathKey: String, bookmarkKey: String) {
        UserDefaults.standard.set(url.path, forKey: pathKey)
        do {
            let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        } catch {
            Logger.log("Could not store capture folder bookmark for \(url.path): \(error.localizedDescription)")
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
        }
    }

    private func clearCaptureFolder(pathKey: String, bookmarkKey: String) {
        UserDefaults.standard.removeObject(forKey: pathKey)
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }

    private func captureFolder(pathKey: String, bookmarkKey: String) -> URL? {
        if let data = UserDefaults.standard.data(forKey: bookmarkKey) {
            do {
                var stale = false
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                )
                if stale {
                    storeCaptureFolder(url, pathKey: pathKey, bookmarkKey: bookmarkKey)
                }
                return url
            } catch {
                Logger.log("Could not resolve capture folder bookmark: \(error.localizedDescription)")
            }
        }

        guard let path = UserDefaults.standard.string(forKey: pathKey), !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    // MARK: - Capture cues

    enum CaptureCueKind: Equatable {
        case screenshot
        case recordingStarted
        case recordingSaving
        case recordingStopped
    }

    struct CaptureCue: Equatable, Identifiable {
        let id = UUID()
        let kind: CaptureCueKind

        var title: String {
            switch kind {
            case .screenshot: return "Screenshot copied"
            case .recordingStarted: return "Recording started"
            case .recordingSaving: return "Saving recording..."
            case .recordingStopped: return "Recording saved"
            }
        }

        var symbolName: String {
            switch kind {
            case .screenshot: return "camera.fill"
            case .recordingStarted: return "record.circle.fill"
            case .recordingSaving: return "arrow.triangle.2.circlepath"
            case .recordingStopped: return "checkmark.circle.fill"
            }
        }

        var isPersistent: Bool {
            kind == .recordingSaving
        }
    }

    private func presentCaptureCue(_ kind: CaptureCueKind) {
        captureCue = CaptureCue(kind: kind)
        playCaptureSound(for: kind)
    }

    /// Plays a distinct cue per capture action: the real macOS shutter for
    /// screenshots, and the dedicated screen-recording start/stop chimes for
    /// recording (distinct ascending "begin" and descending "end" tones). These
    /// ship inside CoreAudio.component (not in `NSSound(named:)`'s search path),
    /// so we load them by file path, then fall back to named system sounds, then
    /// a beep. `retainedCaptureSound` keeps the player alive until playback
    /// finishes (a local NSSound would be deallocated immediately).
    private func playCaptureSound(for kind: CaptureCueKind) {
        let fileCandidates: [String]
        let namedFallbacks: [String]
        switch kind {
        case .recordingSaving:
            return
        case .screenshot:
            fileCandidates = ["Grab.aif", "Shutter.aif"]   // real screenshot shutter
            namedFallbacks = ["Tink", "Pop"]
        case .recordingStarted:
            fileCandidates = ["begin_record.caf"]           // recording-start chime
            namedFallbacks = ["Bottle", "Pop"]
        case .recordingStopped:
            fileCandidates = ["end_record.caf"]             // recording-stop chime
            namedFallbacks = ["Glass", "Submarine"]
        }

        for directory in Self.systemSoundsDirectories {
            for file in fileCandidates {
                if let sound = NSSound(contentsOfFile: directory + file, byReference: true), sound.play() {
                    retainedCaptureSound = sound
                    return
                }
            }
        }
        for name in namedFallbacks {
            if let sound = NSSound(named: NSSound.Name(name)), sound.play() {
                retainedCaptureSound = sound
                return
            }
        }
        NSSound.beep()
    }

    /// Known homes of the capture cue sounds, most likely first. Apple has
    /// relocated system sounds between releases; a miss in every directory
    /// falls through to the named-sound / beep fallbacks above, so a future
    /// move degrades the cue rather than silencing it.
    private static let systemSoundsDirectories = [
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/",
        "/System/Library/Sounds/"
    ]

    // MARK: - Screenshot & screen recording

    func takeScreenshot() {
        let serial = selectedDevice.adbSerial
        let outputDirectory = screenshotOutputDirectory()
        presentCaptureCue(.screenshot)
        Task {
            let result = await Task.detached { () -> Result<URL, MediaCaptureService.ScreenshotError> in
                let didAccess = outputDirectory?.startAccessingSecurityScopedResource() ?? false
                defer {
                    if didAccess {
                        outputDirectory?.stopAccessingSecurityScopedResource()
                    }
                }
                return MediaCaptureService.captureScreenshot(serial: serial, outputDirectory: outputDirectory)
            }.value

            switch result {
            case .success(let url):
                Logger.log("Saved screenshot: \(url.path)")
                self.lastCaptureURL = url
                self.copyScreenshotToClipboard(at: url)
            case .failure(.adbMissing):
                self.reportError("Screenshot failed", "adb wasn’t found. Install Android platform-tools and try again.")
            case .failure(.emptyOutput):
                self.reportError("Screenshot failed", "The phone returned an empty image. Make sure the screen is on and try again.")
            case .failure(.commandFailed(let message)):
                Logger.log("Screenshot failed: \(message)")
                self.reportError("Screenshot failed", Self.mirrorFailureMessage(for: NSError(domain: "screenshot", code: 0, userInfo: [NSLocalizedDescriptionKey: message])))
            }
        }
    }

    /// Puts a freshly captured screenshot on the clipboard as well as on disk,
    /// matching what macOS' own screenshot tool does when its target is set to
    /// the clipboard: paste straight into a message instead of going hunting in
    /// Finder. The file is still written, so Reveal in Finder and the capture
    /// folder preference keep working.
    ///
    /// Only the PNG data goes on the pasteboard — deliberately not the file URL.
    /// An item carrying both makes some apps attach the file rather than inline
    /// the image, which is the opposite of what "copy to clipboard" is for.
    /// - Parameter pasteboard: injectable so tests never clobber the user's own
    ///   clipboard.
    @discardableResult
    func copyScreenshotToClipboard(
        at url: URL,
        pasteboard: NSPasteboard = .general
    ) -> Bool {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            Logger.log("Screenshot clipboard copy skipped: could not read \(url.lastPathComponent)")
            return false
        }
        let item = NSPasteboardItem()
        item.setData(data, forType: .png)
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            Logger.log("Screenshot clipboard copy failed for \(url.lastPathComponent)")
            return false
        }
        Logger.log("Copied screenshot to clipboard: \(url.lastPathComponent)")
        return true
    }

    func toggleScreenRecording() {
        if isRecording {
            isRecording = false
            DiagnosticsService.shared.capture(.recordingStopped)
            stopScreenRecordingCleanup()
        } else {
            startScreenRecording()
        }
    }

    private func startScreenRecording() {
        isRecording = true
        DiagnosticsService.shared.capture(.recordingStarted)
        presentCaptureCue(.recordingStarted)
        screenRecordingRemotePaths = []
        screenRecordingSessionToken = String(UUID().uuidString.prefix(8)).lowercased()
        resetScreenRecordingTouchTimeline()
        let adb = self.adb
        let serial = selectedDevice.adbSerial
        let timeLimitSeconds = recordingTimeLimitSeconds
        // Sweep segments orphaned by crashed sessions — their session-scoped
        // names mean nothing else ever deletes them. Age-gated (>24h) so a
        // just-recorded file that hasn't been pulled yet is never touched.
        Task.detached(priority: .utility) {
            _ = adb.run(Self.adbDeviceArguments(serial: serial) + [
                "shell",
                "find /sdcard -maxdepth 1 -name 'phonerelay-record-*.mp4' -mtime +0 -delete 2>/dev/null"
            ], timeout: 10)
        }
        Task { [weak self] in
            let alreadyRunning = await Task.detached {
                Self.androidScreenRecordingIsRunning(adb: adb, serial: serial)
            }.value

            guard let self else { return }
            if alreadyRunning {
                _ = await Task.detached {
                    adb.run(Self.adbDeviceArguments(serial: serial) + [
                        "shell",
                        "pkill -2 screenrecord >/dev/null 2>&1"
                    ])
                }.value
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }

            self.isRecording = true
            await self.enableRecordingTouchIndicators(adb: adb, serial: serial)
            guard self.isRecording else {
                self.restoreRecordingTouchIndicatorsIfNeeded()
                return
            }
            self.startScreenRecordingMonitor(totalLimitSeconds: timeLimitSeconds)
        }
    }

    /// Not private: the mirror lifecycle in AppModel.swift stops recording
    /// when a session ends/switches transports (pure-move split).
    func stopScreenRecordingCleanup() {
        presentCaptureCue(.recordingSaving)
        restoreRecordingTouchIndicatorsIfNeeded()
        screenRecordingMonitorTask?.cancel()
        screenRecordingMonitorTask = nil
        let remotePaths = screenRecordingRemotePaths.isEmpty
            ? ["/sdcard/phonerelay-record-\(screenRecordingSessionToken)-0.mp4"]
            : screenRecordingRemotePaths
        screenRecordingRemotePaths = []
        let touchEvents = screenRecordingTouchEvents
        let segmentStarts = screenRecordingSegmentStarts
        let touchSize = screenRecordingTouchSize
        resetScreenRecordingTouchTimeline()
        let adb = self.adb
        let serial = selectedDevice.adbSerial
        let outputDirectory = recordingOutputDirectory()
        Task { [weak self] in
            await Task.detached {
                _ = adb.run(Self.adbDeviceArguments(serial: serial) + [
                    "shell",
                    "pkill -2 screenrecord >/dev/null 2>&1"
                ])
            }.value
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let result = await Task.detached { () async -> Result<URL, RecordingError> in
                let didAccess = outputDirectory?.startAccessingSecurityScopedResource() ?? false
                defer {
                    if didAccess {
                        outputDirectory?.stopAccessingSecurityScopedResource()
                    }
                }
                do {
                    let directory = try MediaCaptureService.outputDirectory(outputDirectory)
                    let url = directory.appendingPathComponent(MediaCaptureService.filename(
                        kind: "Screen-Recording",
                        extension: "mp4"
                    ))
                    var pulledSegments: [URL] = []
                    var pullOutput = ""
                    for (index, remotePath) in remotePaths.enumerated() {
                        let destination = remotePaths.count == 1
                            ? url
                            : directory.appendingPathComponent("PhoneRelay-recording-segment-\(index).mp4")
                        pullOutput += adb.run(Self.adbDeviceArguments(serial: serial) + [
                            "pull", remotePath,
                            destination.path
                        ], timeout: 120)
                        if FileManager.default.fileExists(atPath: destination.path) {
                            pulledSegments.append(destination)
                        }
                    }

                    _ = adb.run(Self.adbDeviceArguments(serial: serial) + [
                        "shell",
                        "rm -f \(remotePaths.joined(separator: " ")) >/dev/null 2>&1"
                    ])
                    guard !pulledSegments.isEmpty else {
                        return .failure(.pullFailed(Self.oneLine(pullOutput)))
                    }
                    let touchTimelineEvents = await Self.touchTimelineEvents(
                        events: touchEvents,
                        segmentStarts: segmentStarts,
                        segmentURLs: pulledSegments
                    )
                    if pulledSegments.count > 1 {
                        try await Self.mergeRecordingSegments(pulledSegments, into: url)
                        for segment in pulledSegments {
                            try? FileManager.default.removeItem(at: segment)
                        }
                    }
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        return .failure(.pullFailed(Self.oneLine(pullOutput)))
                    }
                    if !touchTimelineEvents.isEmpty {
                        do {
                            try await Self.renderTouchIndicators(
                                in: url,
                                events: touchTimelineEvents,
                                touchSize: touchSize
                            )
                        } catch {
                            Logger.log("Recording touch indicator overlay failed: \(error.localizedDescription)")
                        }
                    }
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        return .failure(.runtime("The recording was not left at the expected save path after touch overlay processing."))
                    }
                    return .success(url)
                } catch {
                    return .failure(.runtime(error.localizedDescription))
                }
            }.value

            switch result {
            case .success(let url):
                Logger.log("Saved screen recording: \(url.path)")
                self?.lastCaptureURL = url
                self?.presentCaptureCue(.recordingStopped)
                DiagnosticsService.shared.capture(.recordingSaved)
            case .failure(.pullFailed(let message)):
                Logger.log("Screen recording pull failed: \(message)")
                DiagnosticsService.shared.capture(.recordingFailed, properties: [
                    "failure_reason": DiagnosticsService.failureReason(for: message).rawValue
                ])
                self?.captureCue = nil
                self?.reportError("Recording didn’t save", "Couldn’t copy the recording off the phone. Keep it connected until the save finishes.")
            case .failure(.runtime(let message)):
                Logger.log("Screen recording save failed: \(message)")
                DiagnosticsService.shared.capture(.recordingFailed, properties: [
                    "failure_reason": DiagnosticsService.failureReason(for: message).rawValue
                ])
                self?.captureCue = nil
                self?.reportError("Recording didn’t save", Self.mirrorFailureMessage(for: NSError(domain: "recording", code: 0, userInfo: [NSLocalizedDescriptionKey: message])))
            }
        }
    }

    private func startScreenRecordingMonitor(totalLimitSeconds: Int? = nil) {
        screenRecordingMonitorTask?.cancel()
        let adb = self.adb
        let serial = selectedDevice.adbSerial
        let sessionToken = screenRecordingSessionToken
        screenRecordingMonitorTask = Task { [weak self] in
            let startedAt = Date()
            let maxEndDate = totalLimitSeconds.map { startedAt.addingTimeInterval(TimeInterval($0)) }
            var segmentIndex = 0
            while !Task.isCancelled {
                guard let self, self.isRecording else { return }
                let remaining = maxEndDate.map { max(1, Int($0.timeIntervalSinceNow.rounded(.down))) }
                    ?? Self.screenRecordingSegmentSeconds
                if remaining <= 1 {
                    self.isRecording = false
                    self.screenRecordingMonitorTask = nil
                    self.stopScreenRecordingCleanup()
                    return
                }
                let segmentSeconds = min(Self.screenRecordingSegmentSeconds, remaining)
                let remotePath = "/sdcard/phonerelay-record-\(sessionToken)-\(segmentIndex).mp4"
                self.screenRecordingRemotePaths.append(remotePath)
                let output = await Task.detached {
                    adb.run(Self.adbDeviceArguments(serial: serial) + [
                        "shell",
                        "rm -f \(remotePath); screenrecord --time-limit \(segmentSeconds) \(remotePath) >/dev/null 2>&1 & echo started"
                    ])
                }.value
                guard output.lowercased().contains("started") else {
                    self.isRecording = false
                    self.screenRecordingMonitorTask = nil
                    self.resetScreenRecordingTouchTimeline()
                    self.restoreRecordingTouchIndicatorsIfNeeded()
                    return
                }
                self.noteScreenRecordingSegmentStarted(index: segmentIndex)

                var waitedSeconds = 0
                while !Task.isCancelled && waitedSeconds < segmentSeconds {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    waitedSeconds += 5
                    guard self.isRecording else { return }
                    let running = await Task.detached {
                        Self.androidScreenRecordingIsRunning(adb: adb, serial: serial)
                    }.value
                    if !running {
                        break
                    }
                }
                segmentIndex += 1
            }
        }
    }

    func noteScreenRecordingTouch(at normalized: CGPoint, isMove: Bool = false, now: Date = Date()) {
        guard isRecording else { return }
        if isMove {
            if let lastScreenRecordingTouchMoveAt,
               now.timeIntervalSince(lastScreenRecordingTouchMoveAt) < 0.06 {
                return
            }
            lastScreenRecordingTouchMoveAt = now
        }

        screenRecordingTouchEvents.append(ScreenRecordingTouchEvent(
            normalizedX: min(1, max(0, Double(normalized.x))),
            normalizedY: min(1, max(0, Double(normalized.y))),
            occurredAt: now,
            intensity: isMove ? 0.7 : 1
        ))
    }

    func noteScreenRecordingScroll(at normalized: CGPoint, now: Date = Date()) {
        guard isRecording else { return }
        if let lastScreenRecordingScrollAt,
           now.timeIntervalSince(lastScreenRecordingScrollAt) < 0.10 {
            return
        }
        lastScreenRecordingScrollAt = now
        screenRecordingTouchEvents.append(ScreenRecordingTouchEvent(
            normalizedX: min(1, max(0, Double(normalized.x))),
            normalizedY: min(1, max(0, Double(normalized.y))),
            occurredAt: now,
            intensity: 0.92
        ))
    }

    private func resetScreenRecordingTouchTimeline() {
        screenRecordingTouchEvents = []
        screenRecordingSegmentStarts = []
        lastScreenRecordingTouchMoveAt = nil
        lastScreenRecordingScrollAt = nil
    }

    private func noteScreenRecordingSegmentStarted(index: Int, at date: Date = Date()) {
        screenRecordingSegmentStarts.append(ScreenRecordingSegmentStart(index: index, startedAt: date))
    }

    nonisolated private static func mergeRecordingSegments(_ segmentURLs: [URL], into outputURL: URL) async throws {
        try? FileManager.default.removeItem(at: outputURL)
        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw RecordingError.runtime("Could not prepare video track.")
        }
        let compositionAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )
        var cursor = CMTime.zero
        for segmentURL in segmentURLs {
            let asset = AVURLAsset(url: segmentURL)
            let range = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
            if let videoTrack = try await asset.loadTracks(withMediaType: .video).first {
                try compositionVideoTrack.insertTimeRange(range, of: videoTrack, at: cursor)
            }
            if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first,
               let compositionAudioTrack {
                try compositionAudioTrack.insertTimeRange(range, of: audioTrack, at: cursor)
            }
            cursor = CMTimeAdd(cursor, range.duration)
        }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw RecordingError.runtime("Could not prepare recording export.")
        }
        export.outputURL = outputURL
        export.outputFileType = .mp4
        await withCheckedContinuation { continuation in
            export.exportAsynchronously {
                continuation.resume()
            }
        }
        if let error = export.error {
            throw RecordingError.runtime(error.localizedDescription)
        }
        guard export.status == .completed else {
            throw RecordingError.runtime("Recording export ended with status \(export.status.rawValue).")
        }
    }

    nonisolated static func screenRecordingTouchTimelineEvents(
        events: [ScreenRecordingTouchEvent],
        segmentStarts: [ScreenRecordingSegmentStart],
        segmentDurations: [Double]
    ) -> [ScreenRecordingTouchTimelineEvent] {
        guard !events.isEmpty, !segmentStarts.isEmpty, !segmentDurations.isEmpty else { return [] }

        let orderedSegments = segmentStarts
            .filter { $0.index >= 0 && $0.index < segmentDurations.count }
            .sorted { $0.index < $1.index }
        guard !orderedSegments.isEmpty else { return [] }

        var mapped: [ScreenRecordingTouchTimelineEvent] = []
        var videoCursor = 0.0
        for segment in orderedSegments {
            let duration = segmentDurations[segment.index]
            guard duration.isFinite, duration > 0 else { continue }
            let segmentStart = segment.startedAt
            let segmentEnd = segmentStart.addingTimeInterval(duration)
            for event in events where event.occurredAt >= segmentStart && event.occurredAt <= segmentEnd {
                let secondsIntoSegment = event.occurredAt.timeIntervalSince(segmentStart)
                mapped.append(ScreenRecordingTouchTimelineEvent(
                    normalizedX: event.normalizedX,
                    normalizedY: event.normalizedY,
                    seconds: videoCursor + min(duration, max(0, secondsIntoSegment)),
                    intensity: event.intensity
                ))
            }
            videoCursor += duration
        }

        return mapped.sorted { $0.seconds < $1.seconds }
    }

    nonisolated private static func touchTimelineEvents(
        events: [ScreenRecordingTouchEvent],
        segmentStarts: [ScreenRecordingSegmentStart],
        segmentURLs: [URL]
    ) async -> [ScreenRecordingTouchTimelineEvent] {
        guard !events.isEmpty, !segmentStarts.isEmpty, !segmentURLs.isEmpty else { return [] }
        var durations: [Double] = []
        for segmentURL in segmentURLs {
            let asset = AVURLAsset(url: segmentURL)
            guard let duration = try? await asset.load(.duration).seconds,
                  duration.isFinite,
                  duration > 0
            else {
                durations.append(0)
                continue
            }
            durations.append(duration)
        }
        return screenRecordingTouchTimelineEvents(
            events: events,
            segmentStarts: segmentStarts,
            segmentDurations: durations
        )
    }

    nonisolated static func renderTouchIndicators(
        in videoURL: URL,
        events: [ScreenRecordingTouchTimelineEvent],
        touchSize: ScreenRecordingTouchSize = .max
    ) async throws {
        guard !events.isEmpty else { return }
        let outputURL = videoURL
            .deletingLastPathComponent()
            .appendingPathComponent(".PhoneRelay-touch-overlay-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: outputURL)
        var installedOverlay = false
        defer {
            if !installedOverlay {
                try? FileManager.default.removeItem(at: outputURL)
            }
        }

        do {
            let asset = AVURLAsset(url: videoURL)
            let duration = try await asset.load(.duration)
            guard let sourceVideoTrack = try await asset.loadTracks(withMediaType: .video).first else {
                throw RecordingError.runtime("Could not load recording video track.")
            }

            let composition = AVMutableComposition()
            guard let videoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw RecordingError.runtime("Could not prepare touch overlay video track.")
            }
            try videoTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: sourceVideoTrack,
                at: .zero
            )

            if let sourceAudioTrack = try await asset.loadTracks(withMediaType: .audio).first,
               let audioTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
               ) {
                try audioTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: duration),
                    of: sourceAudioTrack,
                    at: .zero
                )
            }

            let naturalSize = try await sourceVideoTrack.load(.naturalSize)
            let preferredTransform = try await sourceVideoTrack.load(.preferredTransform)
            let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
            let renderSize = CGSize(
                width: max(1, abs(transformedRect.width)),
                height: max(1, abs(transformedRect.height))
            )
            let normalizedTransform = preferredTransform.concatenating(CGAffineTransform(
                translationX: transformedRect.minX < 0 ? -transformedRect.minX : 0,
                y: transformedRect.minY < 0 ? -transformedRect.minY : 0
            ))

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            layerInstruction.setTransform(normalizedTransform, at: .zero)
            instruction.layerInstructions = [layerInstruction]

            let videoComposition = AVMutableVideoComposition()
            videoComposition.renderSize = renderSize
            videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
            videoComposition.instructions = [instruction]

            let parentLayer = CALayer()
            let videoLayer = CALayer()
            let overlayLayer = CALayer()
            let frame = CGRect(origin: .zero, size: renderSize)
            parentLayer.frame = frame
            videoLayer.frame = frame
            overlayLayer.frame = frame
            parentLayer.addSublayer(videoLayer)
            parentLayer.addSublayer(overlayLayer)

            addTouchIndicatorLayers(events, to: overlayLayer, renderSize: renderSize, touchSize: touchSize)
            videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
                postProcessingAsVideoLayer: videoLayer,
                in: parentLayer
            )

            guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
                throw RecordingError.runtime("Could not prepare touch overlay export.")
            }
            export.outputURL = outputURL
            export.outputFileType = .mp4
            export.videoComposition = videoComposition
            await withCheckedContinuation { continuation in
                export.exportAsynchronously {
                    continuation.resume()
                }
            }
            if let error = export.error {
                throw RecordingError.runtime(error.localizedDescription)
            }
            guard export.status == .completed else {
                throw RecordingError.runtime("Touch overlay export ended with status \(export.status.rawValue).")
            }
        }

        try replaceRecording(at: videoURL, withOverlayAt: outputURL)
        installedOverlay = true
    }

    nonisolated private static func replaceRecording(at videoURL: URL, withOverlayAt overlayURL: URL) throws {
        let result = overlayURL.path.withCString { sourcePath in
            videoURL.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            let message = String(cString: strerror(errno))
            throw RecordingError.runtime("Could not replace recording with touch overlay: \(message)")
        }
        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            throw RecordingError.runtime("Touch overlay export did not create the final recording.")
        }
    }

    nonisolated private static func addTouchIndicatorLayers(
        _ events: [ScreenRecordingTouchTimelineEvent],
        to overlayLayer: CALayer,
        renderSize: CGSize,
        touchSize: ScreenRecordingTouchSize
    ) {
        for event in events {
            let diameter = max(
                touchSize.minimumDiameter,
                min(renderSize.width, renderSize.height) * touchSize.recordingDiameterScale
            )
            let dot = CALayer()
            dot.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            dot.position = CGPoint(
                x: event.normalizedX * renderSize.width,
                y: (1 - event.normalizedY) * renderSize.height
            )
            dot.cornerRadius = diameter / 2
            dot.backgroundColor = NSColor.white.withAlphaComponent(0.38 * event.intensity).cgColor
            dot.borderColor = NSColor.white.withAlphaComponent(0.95 * event.intensity).cgColor
            dot.borderWidth = max(2, diameter * 0.07)
            dot.opacity = 0
            overlayLayer.addSublayer(dot)

            let beginTime = AVCoreAnimationBeginTimeAtZero + event.seconds
            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [0, min(1, 0.95 * event.intensity), min(0.72, 0.62 * event.intensity), 0]
            opacity.keyTimes = [0, 0.16, 0.46, 1]

            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = [0.34, 0.82, 1.18, 1.62]
            scale.keyTimes = [0, 0.18, 0.48, 1]

            let group = CAAnimationGroup()
            group.animations = [opacity, scale]
            group.beginTime = beginTime
            group.duration = event.intensity >= 0.9 ? 0.62 : 0.42
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.isRemovedOnCompletion = false
            group.fillMode = .both
            dot.add(group, forKey: "touch-indicator")
        }
    }

    nonisolated private static func androidScreenRecordingIsRunning(adb: ADBController, serial: String?) -> Bool {
        let output = adb.run(Self.adbDeviceArguments(serial: serial) + [
            "shell",
            "if pgrep -x screenrecord >/dev/null 2>&1; then echo running; else echo stopped; fi"
        ])
        return output.lowercased().contains("running")
    }

    private func enableRecordingTouchIndicators(adb: ADBController, serial: String?) async {
        screenRecordingTouchIndicatorsEnabled = true
        screenRecordingTouchIndicatorSerial = serial
        let output = await Task.detached(priority: .utility) {
            Self.setAndroidTouchIndicators(adb: adb, serial: serial, showTouches: true)
        }.value
        if output.isEmpty {
            Logger.log("Recording enabled Android touch indicators")
        } else {
            Logger.log("Recording enabled Android touch indicators: \(output)")
        }
    }

    /// Not private: shutdown in AppModel.swift may need synchronous cleanup.
    func restoreRecordingTouchIndicatorsIfNeeded(async: Bool = true) {
        guard screenRecordingTouchIndicatorsEnabled else { return }
        let serial = screenRecordingTouchIndicatorSerial
        screenRecordingTouchIndicatorsEnabled = false
        screenRecordingTouchIndicatorSerial = nil
        // Ownership arbitration: Presentation Mode shares these Android
        // settings. Whichever feature releases LAST writes the disable —
        // turning touches off here while Presentation Mode is still on would
        // silently break it (its toggle would lie).
        guard !presentationModeEnabled else {
            Logger.log("Recording released touch indicators; Presentation Mode still owns them")
            return
        }
        let adb = self.adb

        let restore = {
            let output = Self.setAndroidTouchIndicators(adb: adb, serial: serial, showTouches: false)
            if output.isEmpty {
                Logger.log("Recording disabled Android touch indicators")
            } else {
                Logger.log("Recording disabled Android touch indicators: \(output)")
            }
        }
        if async {
            Task.detached(priority: .utility) {
                restore()
            }
        } else {
            restore()
        }
    }

    nonisolated private static func setAndroidTouchIndicators(
        adb: ADBController,
        serial: String?,
        showTouches: Bool
    ) -> String {
        let showOutput = adb.run(Self.adbDeviceArguments(serial: serial) + [
            "shell",
            "settings",
            "put",
            "system",
            "show_touches",
            showTouches ? "1" : "0"
        ], timeout: 2)
        let pointerOutput = adb.run(Self.adbDeviceArguments(serial: serial) + [
            "shell",
            "settings",
            "put",
            "system",
            "pointer_location",
            "0"
        ], timeout: 2)
        return Self.oneLine([showOutput, pointerOutput].joined(separator: " "))
    }

    private enum RecordingError: Error {
        case pullFailed(String)
        case runtime(String)
    }
}
