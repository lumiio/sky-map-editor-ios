import Foundation

enum Log {
    private static let queue = DispatchQueue(label: "sky.log")
    private static var url: URL? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        return documents.appendingPathComponent("boot.log")
    }

    static func line(_ text: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = "[\(stamp)] \(text)\n"
        print(entry, terminator: "")
        queue.async {
            guard let url else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(entry.utf8))
                try? handle.close()
            } else {
                try? entry.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}
