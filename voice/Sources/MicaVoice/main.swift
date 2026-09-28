import AVFoundation
import Darwin
import Foundation
import FluidAudio

private struct HelperMessage: Encodable, Sendable {
    let type: String
    let message: String?
    let text: String?
    let confirmedText: String?
    let progress: Double?

    init(
        type: String,
        message: String? = nil,
        text: String? = nil,
        confirmedText: String? = nil,
        progress: Double? = nil
    ) {
        self.type = type
        self.message = message
        self.text = text
        self.confirmedText = confirmedText
        self.progress = progress
    }
}

private final class DownloadProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPhase = ""
    private var lastFraction = -1.0

    func shouldEmit(_ progress: DownloadProgress) -> Bool {
        let phase: String
        switch progress.phase {
        case .listing:
            phase = "listing"
        case .downloading(let completedFiles, let totalFiles):
            phase = "downloading:\(completedFiles):\(totalFiles)"
        case .compiling(let modelName):
            phase = "compiling:\(modelName)"
        }

        lock.lock()
        defer { lock.unlock() }
        guard phase != lastPhase || progress.fractionCompleted - lastFraction >= 0.005 else {
            return false
        }
        lastPhase = phase
        lastFraction = progress.fractionCompleted
        return true
    }
}

@main
private struct MicaVoiceCLI {
    private static let outputQueue = DispatchQueue(label: "com.megasoft78.mica.voice-output")

    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            fail("Expected stream")
        }

        switch command {
        case "stream":
            await transcribeStream()
        default:
            fail("Unknown voice helper command: \(command)")
        }
    }

    private static func transcribeStream() async {
        let preparationStartedAt = ProcessInfo.processInfo.systemUptime
        do {
            let cacheDirectory = modelCacheDirectory()
            let modelsAlreadyDownloaded = AsrModels.modelsExist(
                at: cacheDirectory,
                version: .ultra
            )
            emit(HelperMessage(
                type: "status",
                message: modelsAlreadyDownloaded
                    ? "Loading the cached speech model…"
                    : "Checking for the speech model…"
            ))

            let progressThrottle = DownloadProgressThrottle()
            let models = try await AsrModels.downloadAndLoad(
                to: cacheDirectory,
                version: .ultra,
                progressHandler: { progress in
                    guard progressThrottle.shouldEmit(progress) else { return }
                    let status: String
                    switch progress.phase {
                    case .listing:
                        status = modelsAlreadyDownloaded
                            ? "Checking the cached speech model…"
                            : "Checking speech model files…"
                    case .downloading:
                        status = modelsAlreadyDownloaded
                            ? "Loading the cached speech model…"
                            : "Downloading speech model files…"
                    case .compiling(let name):
                        status = "Preparing \(name)…"
                    }
                    let progressFraction: Double?
                    if modelsAlreadyDownloaded, case .downloading = progress.phase {
                        progressFraction = nil
                    } else {
                        progressFraction = progress.fractionCompleted
                    }
                    emit(HelperMessage(
                        type: "status",
                        message: status,
                        progress: progressFraction
                    ))
                }
            )

            // FluidAudio 0.17.4's `hypothesisChunkSeconds` is currently not
            // used by SlidingWindowAsrManager's processing loop. The default
            // 11s chunk plus 2s right context therefore delays the first live
            // result until 13s of audio. A shorter 5s window with 1s lookahead
            // yields an initial update after about 6s while retaining context.
            let streamingConfig = SlidingWindowAsrConfig(
                chunkSeconds: 5.0,
                hypothesisChunkSeconds: 1.0,
                leftContextSeconds: 2.0,
                rightContextSeconds: 1.0,
                minContextForConfirmation: 6.0,
                confirmationThreshold: 0.80
            )
            let manager = SlidingWindowAsrManager(config: streamingConfig)
            try await manager.loadModels(models)
            let updates = await manager.transcriptionUpdates
            try await manager.startStreaming(source: .microphone)
            let recognitionStartedAt = ProcessInfo.processInfo.systemUptime
            emit(HelperMessage(type: "diagnostic", message: resourceSample(
                stage: "model_ready",
                elapsed: recognitionStartedAt - preparationStartedAt
            )))
            emit(HelperMessage(type: "ready", message: "Listening — speak now"))

            let updateTask = Task {
                var firstTranscriptReported = false
                for await _ in updates {
                    if Task.isCancelled { break }
                    let confirmed = await manager.confirmedTranscript
                    let volatile = await manager.volatileTranscript
                    let text = [confirmed, volatile]
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                    if !firstTranscriptReported && !text.isEmpty {
                        firstTranscriptReported = true
                        emit(HelperMessage(type: "diagnostic", message: resourceSample(
                            stage: "first_transcript",
                            elapsed: ProcessInfo.processInfo.systemUptime - recognitionStartedAt
                        )))
                    }
                    emit(HelperMessage(
                        type: "transcript",
                        text: text,
                        confirmedText: confirmed
                    ))
                }
            }

            let audioFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )!
            var sampleCount: UInt64 = 0
            while let packet = try readAudioPacket() {
                switch packet {
                case .finish:
                    let transcript = try await manager.finish()
                    updateTask.cancel()
                    await updateTask.value
                    emit(HelperMessage(type: "diagnostic", message: resourceSample(
                        stage: "recognition_finished",
                        elapsed: ProcessInfo.processInfo.systemUptime - recognitionStartedAt,
                        audioSeconds: Double(sampleCount) / audioFormat.sampleRate
                    )))
                    emit(HelperMessage(type: "result", text: transcript))
                    await manager.cleanup()
                    return
                case .cancel:
                    updateTask.cancel()
                    await manager.cancel()
                    await manager.cleanup()
                    return
                case .samples(let samples):
                    sampleCount += UInt64(samples.count)
                    guard sampleCount <= 16_000 * 600 else {
                        throw VoiceHelperError.recordingTooLong
                    }
                    guard let buffer = AVAudioPCMBuffer(
                        pcmFormat: audioFormat,
                        frameCapacity: AVAudioFrameCount(samples.count)
                    ) else {
                        throw VoiceHelperError.invalidAudioBuffer
                    }
                    buffer.frameLength = AVAudioFrameCount(samples.count)
                    samples.withUnsafeBufferPointer { source in
                        buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
                    }
                    await manager.streamAudio(buffer)
                }
            }

            let transcript = try await manager.finish()
            updateTask.cancel()
            await updateTask.value
            emit(HelperMessage(type: "diagnostic", message: resourceSample(
                stage: "recognition_finished",
                elapsed: ProcessInfo.processInfo.systemUptime - recognitionStartedAt,
                audioSeconds: Double(sampleCount) / audioFormat.sampleRate
            )))
            emit(HelperMessage(type: "result", text: transcript))
            await manager.cleanup()
        } catch {
            fail("Speech recognition failed: \(error.localizedDescription)")
        }
    }

    private static func resourceSample(
        stage: String,
        elapsed: TimeInterval,
        audioSeconds: Double? = nil
    ) -> String {
        var usage = rusage()
        let status = getrusage(RUSAGE_SELF, &usage)
        let peakRSSMiB = status == 0 ? Double(usage.ru_maxrss) / (1024.0 * 1024.0) : -1
        let audio = audioSeconds.map { String(format: " audio_seconds=%.2f", $0) } ?? ""
        return String(format: "stage=%@ elapsed_seconds=%.2f peak_rss_mib=%.1f%@",
            stage, elapsed, peakRSSMiB, audio)
    }

    private static func modelCacheDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["MICA_VOICE_MODEL_CACHE"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return AsrModels.defaultCacheDirectory(for: .ultra)
    }

    private enum AudioPacket {
        case samples([Float])
        case finish
        case cancel
    }

    private enum VoiceHelperError: LocalizedError {
        case truncatedAudioPacket
        case invalidAudioBuffer
        case recordingTooLong
        case audioReadFailed

        var errorDescription: String? {
            switch self {
            case .truncatedAudioPacket: return "The audio stream ended mid-packet"
            case .invalidAudioBuffer: return "Could not create an audio buffer"
            case .recordingTooLong: return "Dictation is limited to 10 minutes per recording"
            case .audioReadFailed: return "Could not read the audio stream"
            }
        }
    }

    private static func readAudioPacket() throws -> AudioPacket? {
        guard let header = try readExactly(4) else { return nil }
        let bytes = [UInt8](header)
        let frameCount = UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
        if frameCount == 0 { return .finish }
        if frameCount == UInt32.max { return .cancel }
        guard frameCount <= 160_000 else { throw VoiceHelperError.invalidAudioBuffer }
        guard let payload = try readExactly(Int(frameCount) * MemoryLayout<Float>.size) else {
            throw VoiceHelperError.truncatedAudioPacket
        }
        var samples = [Float](repeating: 0, count: Int(frameCount))
        samples.withUnsafeMutableBytes { destination in
            _ = payload.copyBytes(to: destination)
        }
        return .samples(samples)
    }

    private static func readExactly(_ byteCount: Int) throws -> Data? {
        guard byteCount > 0 else { return Data() }
        var data = Data(count: byteCount)
        var offset = 0
        while offset < byteCount {
            let count = data.withUnsafeMutableBytes { bytes in
                Darwin.read(
                    STDIN_FILENO,
                    bytes.baseAddress!.advanced(by: offset),
                    byteCount - offset
                )
            }
            if count == 0 {
                if offset == 0 { return nil }
                throw VoiceHelperError.truncatedAudioPacket
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw VoiceHelperError.audioReadFailed
            }
            offset += count
        }
        return data
    }

    private static func emit(_ message: HelperMessage) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        var line = data
        line.append(0x0a)
        outputQueue.sync { FileHandle.standardOutput.write(line) }
    }

    private static func fail(_ message: String) -> Never {
        emit(HelperMessage(type: "error", message: message))
        exit(1)
    }
}
