import Foundation

final class ExportFileTransaction {
    let destination: URL
    let temporaryURL: URL
    private var committed = false

    init(destination: URL) {
        self.destination = destination
        let suffix = destination.pathExtension.isEmpty ? "tmp" : destination.pathExtension
        temporaryURL = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).\(suffix)"
        )
    }

    func commit() throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(
                destination,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destination)
        }
        committed = true
    }

    func cleanup() {
        guard !committed else { return }
        try? FileManager.default.removeItem(at: temporaryURL)
    }

    deinit {
        cleanup()
    }
}
