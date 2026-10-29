import Foundation

enum ProjectRecoveryStore {
    static func defaultURL() throws -> URL {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = applicationSupport.appendingPathComponent(
            "TimeFlow Studio",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("Autosave Recovery.timeflow")
    }

    static func save(_ project: TimeFlowProject, to url: URL? = nil) throws {
        let destination = try url ?? defaultURL()
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(project).write(to: destination, options: .atomic)
    }

    static func load(from url: URL? = nil) throws -> TimeFlowProject? {
        let source = try url ?? defaultURL()
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TimeFlowProject.self, from: Data(contentsOf: source))
    }
}
