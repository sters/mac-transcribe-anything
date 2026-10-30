import AVFAudio

/// Voice processing (echo cancellation) is deliberately left off: enabling it stops the process
/// tap from receiving any audio. Use headphones so the speaker output is not transcribed twice.
final class Microphone {
    private let engine = AVAudioEngine()

    func start(_ handler: @escaping (AVAudioPCMBuffer) -> Void) async throws {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw TranscribeError("microphone access was denied")
        }

        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 4096, format: input.outputFormat(forBus: 0)) { buffer, _ in
            handler(buffer)
        }
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
