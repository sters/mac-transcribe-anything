import Foundation

/// Prints finalized lines to stdout and appends them to a Markdown file. On a terminal, the latest
/// volatile result is shown on one line at the bottom and replaced as it changes.
final class Output: @unchecked Sendable {
    private let lock = NSLock()
    private let file: FileHandle
    private let isTerminal = isatty(STDOUT_FILENO) != 0
    private var showingVolatile = false

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init(path: String) throws {
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let file = FileHandle(forWritingAtPath: path) else {
            throw TranscribeError("cannot open \(path) for writing")
        }
        file.seekToEndOfFile()
        self.file = file
    }

    func volatile(label: String, at time: Date, text: String) {
        guard isTerminal else { return }
        lock.withLock {
            let line = Self.fitToTerminal("\(Self.format(label: label, at: time, text: text)) …")
            write("\r\u{1B}[2K\u{1B}[2m\(line)\u{1B}[0m")
            showingVolatile = true
        }
    }

    func final(label: String, at time: Date, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.withLock {
            if showingVolatile {
                write("\r\u{1B}[2K")
                showingVolatile = false
            }
            guard !trimmed.isEmpty else { return }
            let line = Self.format(label: label, at: time, text: trimmed)
            write(line + "\n")
            file.write(Data("- \(line)\n".utf8))
        }
    }

    func close() {
        lock.withLock {
            if showingVolatile { write("\n") }
            try? file.close()
        }
    }

    private func write(_ string: String) {
        FileHandle.standardOutput.write(Data(string.utf8))
    }

    private static func format(label: String, at time: Date, text: String) -> String {
        "[\(timeFormatter.string(from: time))] \(label): \(text)"
    }

    /// Keeps the tail of `line` so it never wraps; a wrapped line cannot be erased with `\r`.
    /// Non-ASCII characters are counted as two columns, which is right for Japanese.
    private static func fitToTerminal(_ line: String) -> String {
        var size = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 1 else { return line }
        let limit = Int(size.ws_col) - 1
        var width = 0
        var kept = ""
        for character in line.reversed() {
            width += character.isASCII ? 1 : 2
            if width > limit { break }
            kept.insert(character, at: kept.startIndex)
        }
        return kept
    }
}
