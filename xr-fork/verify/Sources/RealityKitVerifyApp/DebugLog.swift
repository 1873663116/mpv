import Foundation

enum DebugLog {
    private static let url = URL(fileURLWithPath: "/tmp/realitykit-verify.log")

    static func reset() {
        try? "".write(to: url, atomically: true, encoding: .utf8)
    }

    static func write(_ message: String) {
        let line = "[\(Date())] \(message)\n"
        guard let data = line.data(using: .utf8) else {
            return
        }

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        guard let handle = try? FileHandle(forWritingTo: url) else {
            return
        }
        defer {
            try? handle.close()
        }
        _ = try? handle.seekToEnd()
        _ = try? handle.write(contentsOf: data)
    }
}
