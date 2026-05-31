import Foundation

/// Append-only debug log — shared across all TouchStrip files.
func tsDebugLog(_ s: String) {
    guard let data = s.data(using: .utf8) else { return }
    if let fh = FileHandle(forWritingAtPath: "/tmp/ts-debug.txt") {
        fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
    } else {
        try? data.write(to: URL(fileURLWithPath: "/tmp/ts-debug.txt"))
    }
}
