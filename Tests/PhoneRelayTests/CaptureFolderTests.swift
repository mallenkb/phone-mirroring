import XCTest
import AVFoundation
@testable import PhoneRelay

@MainActor
final class CaptureFolderTests: XCTestCase {
    /// Snapshot of the shared-defaults keys this suite mutates, restored in
    /// tearDown so the tests can't bleed state into other suites (or wipe a
    /// value the test-runner domain already had).
    private var savedCaptureDefaults: [String: Any] = [:]

    private static let captureDefaultsKeys = [
        AppModel.screenshotFolderPathDefaultsKey,
        AppModel.screenshotFolderBookmarkDefaultsKey,
        AppModel.recordingFolderPathDefaultsKey,
        AppModel.recordingFolderBookmarkDefaultsKey,
        AppModel.recordingMaxMinutesDefaultsKey,
        AppModel.recordingTouchSizeDefaultsKey
    ]

    override func setUp() {
        super.setUp()
        savedCaptureDefaults = [:]
        for key in Self.captureDefaultsKeys {
            if let value = UserDefaults.standard.object(forKey: key) {
                savedCaptureDefaults[key] = value
            }
        }
        clearCaptureDefaults()
    }

    override func tearDown() {
        clearCaptureDefaults()
        for (key, value) in savedCaptureDefaults {
            UserDefaults.standard.set(value, forKey: key)
        }
        unsetenv("ANDROID_MIRROR_ADB_PATH")
        super.tearDown()
    }

    func testCaptureFolderPreferencesPersistSeparateScreenshotAndRecordingPaths() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneRelayCaptureFolders-\(UUID().uuidString)", isDirectory: true)
        let screenshotFolder = base.appendingPathComponent("Screenshots", isDirectory: true)
        let recordingFolder = base.appendingPathComponent("Recordings", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let model = AppModel(startBackgroundServices: false, pairedPhones: [])

        model.setScreenshotFolder(screenshotFolder)
        model.setRecordingFolder(recordingFolder)

        XCTAssertEqual(model.screenshotFolderPath, screenshotFolder.path)
        XCTAssertEqual(model.recordingFolderPath, recordingFolder.path)
        XCTAssertEqual(UserDefaults.standard.string(forKey: AppModel.screenshotFolderPathDefaultsKey), screenshotFolder.path)
        XCTAssertEqual(UserDefaults.standard.string(forKey: AppModel.recordingFolderPathDefaultsKey), recordingFolder.path)
    }

    func testResetCaptureFolderFallsBackToDefaultDownloadsPath() {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneRelayScreenshots-\(UUID().uuidString)", isDirectory: true)
        let model = AppModel(startBackgroundServices: false, pairedPhones: [])

        model.setScreenshotFolder(folder)
        model.resetScreenshotFolder()

        XCTAssertNil(model.screenshotFolderPath)
        XCTAssertNil(model.screenshotOutputDirectory())
        XCTAssertNil(UserDefaults.standard.string(forKey: AppModel.screenshotFolderPathDefaultsKey))
    }

    func testScreenshotCaptureUsesSelectedFolder() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneRelayScreenshotCapture-\(UUID().uuidString)", isDirectory: true)
        let destination = base.appendingPathComponent("Chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let fakeADB = base.appendingPathComponent("adb")
        let script = """
        #!/bin/sh
        printf 'PNGDATA'
        exit 0
        """
        try script.write(to: fakeADB, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeADB.path)
        setenv("ANDROID_MIRROR_ADB_PATH", fakeADB.path, 1)

        let result = await Task.detached {
            MediaCaptureService.captureScreenshot(serial: "TESTSERIAL", outputDirectory: destination)
        }.value

        let captureURL = try result.get()
        XCTAssertEqual(captureURL.deletingLastPathComponent(), destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: captureURL.path))
    }

    func testSettingsViewExposesSeparateCaptureFolderControls() throws {
        let source = try String(contentsOfFile: "Sources/PhoneRelay/Views/SettingsView.swift", encoding: .utf8)

        XCTAssertTrue(source.contains("Saved files"))
        XCTAssertTrue(source.contains("model.screenshotFolderPath"))
        XCTAssertTrue(source.contains("model.recordingFolderPath"))
        XCTAssertTrue(source.contains("model.chooseScreenshotFolder"))
        XCTAssertTrue(source.contains("model.chooseRecordingFolder"))
        XCTAssertTrue(source.contains("$model.screenRecordingTouchSize"))
        XCTAssertTrue(source.contains("Touch size"))
    }

    func testRecordingMaxMinutesClampsToSupportedRange() {
        XCTAssertEqual(AppModel.clampedRecordingMaxMinutes(0), AppModel.recordingMaxMinutesRange.lowerBound)
        XCTAssertEqual(AppModel.clampedRecordingMaxMinutes(-5), AppModel.recordingMaxMinutesRange.lowerBound)
        XCTAssertEqual(AppModel.clampedRecordingMaxMinutes(10), 10)
        XCTAssertEqual(AppModel.clampedRecordingMaxMinutes(9999), AppModel.recordingMaxMinutesRange.upperBound)
    }

    func testRecordingMaxMinutesPersistsAndDerivesTimeLimitSeconds() {
        let model = AppModel(startBackgroundServices: false, pairedPhones: [])

        XCTAssertEqual(model.recordingMaxMinutes, AppModel.recordingMaxMinutesDefault)
        XCTAssertEqual(model.recordingTimeLimitSeconds, AppModel.recordingMaxMinutesDefault * 60)

        model.recordingMaxMinutes = 10
        XCTAssertEqual(model.recordingMaxMinutes, 10)
        XCTAssertEqual(model.recordingTimeLimitSeconds, 600)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: AppModel.recordingMaxMinutesDefaultsKey), 10)

        // Out-of-range assignments are clamped, not stored verbatim.
        model.recordingMaxMinutes = 100_000
        XCTAssertEqual(model.recordingMaxMinutes, AppModel.recordingMaxMinutesRange.upperBound)
    }

    func testScreenRecordingTouchSizeDefaultsAndPersists() {
        XCTAssertEqual(AppModel.defaultScreenRecordingTouchSize(storedValue: nil), .max)
        XCTAssertEqual(AppModel.defaultScreenRecordingTouchSize(storedValue: "missing"), .max)
        XCTAssertEqual(AppModel.defaultScreenRecordingTouchSize(storedValue: "small"), .small)

        let model = AppModel(startBackgroundServices: false, pairedPhones: [])
        XCTAssertEqual(model.screenRecordingTouchSize, .max)

        model.screenRecordingTouchSize = .medium

        XCTAssertEqual(
            UserDefaults.standard.string(forKey: AppModel.recordingTouchSizeDefaultsKey),
            ScreenRecordingTouchSize.medium.rawValue
        )
    }

    func testRecordingLengthLabelFormatsMinutesAndHours() {
        XCTAssertEqual(SettingsView.recordingLengthLabel(minutes: 3), "3 min")
        XCTAssertEqual(SettingsView.recordingLengthLabel(minutes: 30), "30 min")
        XCTAssertEqual(SettingsView.recordingLengthLabel(minutes: 60), "1 hour")
        XCTAssertEqual(SettingsView.recordingLengthLabel(minutes: 120), "2 hours")
    }

    func testScreenRecordingCommandPassesConfigurableTimeLimit() throws {
        // Capture code moved to AppModel+Capture.swift in the pure-move split.
        let source = try String(contentsOfFile: "Sources/PhoneRelay/AppModel+Capture.swift", encoding: .utf8)
        XCTAssertTrue(source.contains("screenrecord --time-limit \\(segmentSeconds)"))
        XCTAssertTrue(source.contains("min(Self.screenRecordingSegmentSeconds, remaining)"))
        XCTAssertTrue(source.contains("mergeRecordingSegments"))
        let settings = try String(contentsOfFile: "Sources/PhoneRelay/Views/SettingsView.swift", encoding: .utf8)
        XCTAssertTrue(settings.contains("$model.recordingMaxMinutes"))
    }

    func testScreenRecordingOwnsAndroidTouchIndicators() throws {
        let captureSource = try String(contentsOfFile: "Sources/PhoneRelay/AppModel+Capture.swift", encoding: .utf8)
        let modelSource = try String(contentsOfFile: "Sources/PhoneRelay/AppModel.swift", encoding: .utf8)
        let mirrorSource = try String(contentsOfFile: "Sources/PhoneRelay/Mirror/MirrorSession.swift", encoding: .utf8)

        XCTAssertTrue(captureSource.contains("await self.enableRecordingTouchIndicators(adb: adb, serial: serial)"))
        XCTAssertTrue(captureSource.contains("guard self.isRecording else"))
        XCTAssertTrue(captureSource.contains("restoreRecordingTouchIndicatorsIfNeeded()"))
        XCTAssertTrue(captureSource.contains("renderTouchIndicators("))
        XCTAssertTrue(captureSource.contains("AVVideoCompositionCoreAnimationTool"))
        XCTAssertTrue(captureSource.contains("case recordingSaving"))
        XCTAssertTrue(captureSource.contains("Saving recording..."))
        XCTAssertTrue(captureSource.contains("touchSize: touchSize"))
        XCTAssertTrue(captureSource.contains("touchSize.recordingDiameterScale"))
        XCTAssertTrue(captureSource.contains("\"show_touches\""))
        XCTAssertTrue(captureSource.contains("showTouches ? \"1\" : \"0\""))
        XCTAssertTrue(captureSource.contains("\"pointer_location\""))
        XCTAssertTrue(modelSource.contains("restoreRecordingTouchIndicatorsIfNeeded(async: false)"))
        XCTAssertTrue(mirrorSource.contains("model?.noteScreenRecordingTouch(at: event.normalized)"))
        XCTAssertTrue(mirrorSource.contains("model?.noteScreenRecordingTouch(at: event.normalized, isMove: true)"))
        XCTAssertTrue(mirrorSource.contains("model?.noteScreenRecordingScroll(at: event.normalized)"))
        XCTAssertTrue(mirrorSource.contains("model?.screenRecordingTouchSize ?? .max"))
        XCTAssertTrue(mirrorSource.contains("view.showTouchIndicator("))
        // Ownership arbitration with Presentation Mode: whichever feature
        // releases last writes the disable, so neither breaks the other.
        XCTAssertTrue(captureSource.contains("guard !presentationModeEnabled else {"))
        XCTAssertTrue(modelSource.contains("guard !screenRecordingTouchIndicatorsEnabled else {"))
    }

    func testScreenRecordingTouchTimelineMapsAcrossMergedSegments() {
        let firstStart = Date(timeIntervalSince1970: 1_000)
        let secondStart = Date(timeIntervalSince1970: 1_010)
        let events = [
            AppModel.ScreenRecordingTouchEvent(
                normalizedX: 0.25,
                normalizedY: 0.5,
                occurredAt: firstStart.addingTimeInterval(1.2),
                intensity: 1
            ),
            // Falls in the wall-clock gap after segment 0's actual duration.
            AppModel.ScreenRecordingTouchEvent(
                normalizedX: 0.5,
                normalizedY: 0.5,
                occurredAt: firstStart.addingTimeInterval(7),
                intensity: 1
            ),
            AppModel.ScreenRecordingTouchEvent(
                normalizedX: 0.75,
                normalizedY: 0.25,
                occurredAt: secondStart.addingTimeInterval(2),
                intensity: 0.55
            )
        ]
        let starts = [
            AppModel.ScreenRecordingSegmentStart(index: 0, startedAt: firstStart),
            AppModel.ScreenRecordingSegmentStart(index: 1, startedAt: secondStart)
        ]

        let timeline = AppModel.screenRecordingTouchTimelineEvents(
            events: events,
            segmentStarts: starts,
            segmentDurations: [5, 4]
        )

        XCTAssertEqual(timeline.count, 2)
        XCTAssertEqual(timeline[0].seconds, 1.2, accuracy: 0.001)
        XCTAssertEqual(timeline[0].normalizedX, 0.25, accuracy: 0.001)
        XCTAssertEqual(timeline[1].seconds, 7, accuracy: 0.001)
        XCTAssertEqual(timeline[1].normalizedY, 0.25, accuracy: 0.001)
        XCTAssertEqual(timeline[1].intensity, 0.55, accuracy: 0.001)
    }

    func testScreenRecordingTouchOverlayRendersVisiblePixels() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneRelayOverlayTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("touch-overlay-source.mp4")
        try await Self.writeSolidVideo(to: url, size: CGSize(width: 320, height: 240), frameCount: 36)

        let before = try await Self.maxRGBNearCenter(in: url, at: 0.72)
        try await AppModel.renderTouchIndicators(in: url, events: [
            AppModel.ScreenRecordingTouchTimelineEvent(
                normalizedX: 0.5,
                normalizedY: 0.5,
                seconds: 0.50,
                intensity: 1
            )
        ])
        let after = try await Self.maxRGBNearCenter(in: url, at: 0.72)

        XCTAssertLessThan(before, 16)
        XCTAssertGreaterThan(after, 80)
    }

    private func clearCaptureDefaults() {
        for key in Self.captureDefaultsKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private static func writeSolidVideo(to url: URL, size: CGSize, frameCount: Int) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ])
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ]
        )

        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        for frameIndex in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            guard let pool = adaptor.pixelBufferPool else {
                throw NSError(domain: "CaptureFolderTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing pixel buffer pool"])
            }
            var optionalBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optionalBuffer)
            guard let buffer = optionalBuffer else {
                throw NSError(domain: "CaptureFolderTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not allocate pixel buffer"])
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let baseAddress = CVPixelBufferGetBaseAddress(buffer) {
                memset(baseAddress, 0, CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])

            let time = CMTime(value: CMTimeValue(frameIndex), timescale: 30)
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: time))
        }

        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                continuation.resume()
            }
        }
        if let error = writer.error {
            throw error
        }
    }

    private static func maxRGBNearCenter(in url: URL, at seconds: Double) async throws -> Int {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "CaptureFolderTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing video track"])
        }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: seconds, preferredTimescale: 600),
            duration: CMTime(seconds: 0.08, preferredTimescale: 600)
        )
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        guard let sample = output.copyNextSampleBuffer(),
              let buffer = CMSampleBufferGetImageBuffer(sample)
        else {
            throw NSError(domain: "CaptureFolderTests", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not read video frame"])
        }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            throw NSError(domain: "CaptureFolderTests", code: 5, userInfo: [NSLocalizedDescriptionKey: "Missing frame bytes"])
        }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        let centerX = width / 2
        let centerY = height / 2
        var maximum = 0

        for y in max(0, centerY - 32)..<min(height, centerY + 32) {
            for x in max(0, centerX - 32)..<min(width, centerX + 32) {
                let offset = y * bytesPerRow + x * 4
                maximum = max(maximum, Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
            }
        }
        return maximum
    }
}
