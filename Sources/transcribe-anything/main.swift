import Foundation
import Speech

let usage = """
    usage: transcribe-anything [--app <bundle-id>]... [--output <path>]

    Transcribes the audio this Mac plays (labelled 相手) and the microphone (labelled 自分)
    on device, in Japanese. Press Ctrl-C to stop.

      --app <bundle-id>  Capture only this app's audio (repeatable). Default: every app.
      --output <path>    Markdown file finalized lines are appended to.
                         Default: transcript-YYYYMMDD-HHMMSS.md in the current directory.
    """

var apps: [String] = []
var outputPath: String?
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    switch argument {
    case "--app":
        guard let value = arguments.popFirst() else {
            log(usage)
            exit(2)
        }
        apps.append(value)
    case "--output":
        guard let value = arguments.popFirst() else {
            log(usage)
            exit(2)
        }
        outputPath = value
    case "-h", "--help":
        print(usage)
        exit(0)
    default:
        log("unknown argument: \(argument)\n\n\(usage)")
        exit(2)
    }
}
if outputPath == nil {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    outputPath = "transcript-\(formatter.string(from: Date())).md"
}

var interruptSource: DispatchSourceSignal?

Task { @MainActor in
    do {
        let locale = try await Transcriber.prepare(locale: Locale(identifier: "ja-JP"))
        let output = try Output(path: outputPath!)
        let startedAt = Date()

        func report(_ label: String) -> @Sendable (SpeechTranscriber.Result) -> Void {
            { result in
                let time = startedAt.addingTimeInterval(result.range.start.seconds)
                let text = String(result.text.characters)
                if result.isFinal {
                    output.final(label: label, at: time, text: text)
                } else {
                    output.volatile(label: label, at: time, text: text)
                }
            }
        }

        let system = try await Transcriber(locale: locale)
        let mic = try await Transcriber(locale: locale)
        try await system.start(onResult: report("相手"))
        try await mic.start(onResult: report("自分"))

        let tap = try ProcessTap(bundleIDs: apps)
        try tap.start { system.append($0) }
        let microphone = Microphone()
        try await microphone.start { mic.append($0) }

        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler {
            source.cancel()
            tap.stop()
            microphone.stop()
            Task {
                await system.finish()
                await mic.finish()
                output.close()
                exit(0)
            }
        }
        source.resume()
        interruptSource = source

        log("transcribing to \(outputPath!) (Ctrl-C to stop)")
    } catch {
        log("error: \(error)")
        exit(1)
    }
}

dispatchMain()
