import Foundation
import ScreenCaptureKit
@preconcurrency import AVFoundation

final class AudioCaptureCoordinator: NSObject, @unchecked Sendable {
    typealias ContextProvider = () -> (app: AppDescriptor, window: WindowContext, intervalID: String?)?

    var onChunkFinalized: ((ArtifactMetadata) -> Void)?
    var onRunningStateChanged: ((Bool, Date?) -> Void)?

    private let outputDirectory: URL
    private let chunkSeconds: TimeInterval
    private let logger: RuntimeLog
    private let queue = DispatchQueue(label: "agent-context.audio.capture", qos: .utility)

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var currentChunkURL: URL?
    private var currentChunkStartDate: Date?
    private var currentChunkStartPTS: CMTime?
    private var rotateTimer: DispatchSourceTimer?
    private var chunkSequence = 0

    private var running = false
    private var startedAt: Date?

    var contextProvider: ContextProvider?

    init(outputDirectory: URL, chunkSeconds: TimeInterval, logger: RuntimeLog) throws {
        self.outputDirectory = outputDirectory
        self.chunkSeconds = chunkSeconds
        self.logger = logger
        super.init()

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    func startTranscript() {
        guard !running else { return }

        Task {
            do {
                try await beginCapture()
                running = true
                startedAt = Date()
                onRunningStateChanged?(true, startedAt)
                logger.info("Transcript capture started")
            } catch {
                logger.error("Failed to start transcript capture: \(error.localizedDescription)")
            }
        }
    }

    func stopTranscript() {
        guard running else { return }

        Task {
            await endCapture(finalizePartialChunk: true)
            running = false
            startedAt = nil
            onRunningStateChanged?(false, nil)
            logger.info("Transcript capture stopped")
        }
    }

    func stopTranscriptWithoutFinalizing() {
        guard running else { return }

        Task {
            await endCapture(finalizePartialChunk: false)
            running = false
            startedAt = nil
            onRunningStateChanged?(false, nil)
        }
    }

    func isRunning() -> Bool {
        running
    }

    private func beginCapture() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(domain: "AudioCaptureCoordinator", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display found for system audio capture"])
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = max(2, display.width)
        configuration.height = max(2, display.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = false
        configuration.queueDepth = 3

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()

        self.stream = stream
        scheduleRotationTimer()
    }

    private func endCapture(finalizePartialChunk: Bool) async {
        rotateTimer?.cancel()
        rotateTimer = nil

        if let stream {
            do {
                try await stream.stopCapture()
            } catch {
                logger.error("Failed to stop SCStream capture cleanly: \(error.localizedDescription)")
            }
            self.stream = nil
        }

        if finalizePartialChunk {
            finalizeCurrentChunkIfNeeded(captureDate: Date())
        } else {
            writerInput?.markAsFinished()
            writer?.cancelWriting()
            writerInput = nil
            writer = nil
            currentChunkURL = nil
            currentChunkStartDate = nil
            currentChunkStartPTS = nil
        }
    }

    private func scheduleRotationTimer() {
        rotateTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + chunkSeconds, repeating: chunkSeconds)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.finalizeCurrentChunkIfNeeded(captureDate: Date())
        }
        timer.resume()

        rotateTimer = timer
    }

    private func beginChunkIfNeeded(with sampleBuffer: CMSampleBuffer) {
        guard writer == nil, writerInput == nil else { return }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"

        let now = Date()
        let fileName = "audio-\(formatter.string(from: now))-\(chunkSequence).m4a"
        let fileURL = outputDirectory.appendingPathComponent(fileName)

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000
        ]

        do {
            let writer = try AVAssetWriter(outputURL: fileURL, fileType: .m4a)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
            input.expectsMediaDataInRealTime = true

            guard writer.canAdd(input) else {
                logger.error("AVAssetWriter cannot add audio input")
                return
            }
            writer.add(input)

            let startPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startWriting()
            writer.startSession(atSourceTime: startPTS)

            self.writer = writer
            self.writerInput = input
            self.currentChunkURL = fileURL
            self.currentChunkStartDate = now
            self.currentChunkStartPTS = startPTS
            self.chunkSequence += 1
        } catch {
            logger.error("Failed to create audio chunk writer: \(error.localizedDescription)")
        }
    }

    private func append(sampleBuffer: CMSampleBuffer) {
        beginChunkIfNeeded(with: sampleBuffer)
        guard let writerInput else { return }
        guard writerInput.isReadyForMoreMediaData else { return }
        _ = writerInput.append(sampleBuffer)
    }

    private func finalizeCurrentChunkIfNeeded(captureDate: Date) {
        guard
            let writer,
            let writerInput,
            let chunkURL = currentChunkURL,
            let chunkStartDate = currentChunkStartDate
        else {
            return
        }

        self.writer = nil
        self.writerInput = nil
        self.currentChunkURL = nil
        self.currentChunkStartDate = nil
        self.currentChunkStartPTS = nil

        writerInput.markAsFinished()

        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting {
            semaphore.signal()
        }
        semaphore.wait()

        guard writer.status == .completed else {
            logger.error("Audio chunk finalize failed: \(writer.error?.localizedDescription ?? "unknown")")
            return
        }

        guard let context = contextProvider?() else {
            return
        }

        let metadata = ArtifactMetadata(
            id: UUID().uuidString,
            kind: .audio,
            path: chunkURL.path,
            capturedAt: captureDate,
            app: context.app,
            window: context.window,
            intervalID: context.intervalID,
            captureReason: "transcript-chunk",
            sequenceInInterval: chunkSequence
        )
        onChunkFinalized?(metadata)
        logger.info("Transcript chunk finalized: \(chunkURL.lastPathComponent) \(Int(captureDate.timeIntervalSince(chunkStartDate)))s")
    }
}

extension AudioCaptureCoordinator: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio else { return }
        append(sampleBuffer: sampleBuffer)
    }
}

extension AudioCaptureCoordinator: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        logger.error("System audio stream stopped with error: \(error.localizedDescription)")
    }
}
