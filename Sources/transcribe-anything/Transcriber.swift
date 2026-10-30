import AVFAudio
import Foundation
import Speech

/// One SpeechAnalyzer fed by one audio stream. `append` may be called from any audio thread.
final class Transcriber: @unchecked Sendable {
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let analyzerFormat: AVAudioFormat
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let inputStream: AsyncStream<AnalyzerInput>
    private var converter: AVAudioConverter?
    private var receivedInput = false
    private var resultsTask: Task<Void, Never>?

    init(locale: Locale) async throws {
        transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
        analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscribeError("no audio format is compatible with SpeechTranscriber")
        }
        analyzerFormat = format
        (inputStream, input) = AsyncStream.makeStream()
    }

    /// Downloads the model for `locale` if it is not installed yet.
    static func prepare(locale: Locale) async throws -> Locale {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscribeError("SpeechTranscriber does not support \(locale.identifier)")
        }
        let module = SpeechTranscriber(locale: supported, preset: .transcription)
        if await AssetInventory.status(forModules: [module]) < .installed,
            let request = try await AssetInventory.assetInstallationRequest(supporting: [module])
        {
            log("downloading speech model for \(supported.identifier)...")
            try await request.downloadAndInstall()
        }
        return supported
    }

    func start(onResult: @escaping @Sendable (SpeechTranscriber.Result) -> Void) async throws {
        resultsTask = Task { [transcriber] in
            do {
                for try await result in transcriber.results {
                    onResult(result)
                }
            } catch {
                log("transcription failed: \(error)")
            }
        }
        try await analyzer.start(inputSequence: inputStream)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: analyzerFormat)
            converter?.downmix = true
        }
        guard let converter else { return }

        let ratio = analyzerFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
        guard capacity > 0, let output = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            log("audio conversion failed: \(error?.localizedDescription ?? "unknown")")
            return
        }
        if output.frameLength > 0 {
            input.yield(AnalyzerInput(buffer: output))
            receivedInput = true
        }
    }

    /// Call after the audio source has stopped calling `append`.
    func finish() async {
        input.finish()
        // An analyzer that never received input neither finalizes nor ends its results sequence,
        // and it has nothing to report, so it is not waited for.
        guard receivedInput else {
            await analyzer.cancelAndFinishNow()
            return
        }
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            log("finalizing transcription failed: \(error)")
        }
        await resultsTask?.value
    }
}

struct TranscribeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}
