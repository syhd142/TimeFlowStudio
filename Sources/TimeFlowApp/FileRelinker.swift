import Foundation

struct FileRelinkResult: Equatable {
    var project: TimeFlowProject
    var relinkedCount: Int
    var remainingMissingCount: Int
    var ambiguousCount: Int
}

enum FileRelinker {
    static func missingFrameCount(in project: TimeFlowProject) -> Int {
        project.frames.reduce(into: 0) { count, frame in
            if !FileManager.default.fileExists(atPath: frame.url.path) {
                count += 1
            }
        }
    }

    static func relink(
        project: TimeFlowProject,
        to newRoot: URL,
        maximumEntries: Int = 100_000
    ) throws -> FileRelinkResult {
        var updated = project
        let missingIndices = project.frames.indices.filter {
            !FileManager.default.fileExists(atPath: project.frames[$0].url.path)
        }
        guard !missingIndices.isEmpty else {
            return FileRelinkResult(
                project: project,
                relinkedCount: 0,
                remainingMissingCount: 0,
                ambiguousCount: 0
            )
        }

        let inventory = try imageInventory(at: newRoot, maximumEntries: maximumEntries)
        let byName = Dictionary(grouping: inventory) { $0.lastPathComponent.lowercased() }
        var relinked = 0
        var ambiguous = 0

        for index in missingIndices {
            try Task.checkCancellation()
            let oldURL = project.frames[index].url
            var replacement: URL?

            if let oldRoot = project.sourceDirectory,
               let relativePath = relativePath(of: oldURL, under: oldRoot) {
                let directCandidate = newRoot.appendingPathComponent(relativePath)
                if FileManager.default.fileExists(atPath: directCandidate.path),
                   ImageSequenceLoader.isSupportedImage(directCandidate) {
                    replacement = directCandidate
                }
            }

            if replacement == nil {
                let matches = byName[oldURL.lastPathComponent.lowercased()] ?? []
                if matches.count == 1 {
                    replacement = matches[0]
                } else if matches.count > 1 {
                    ambiguous += 1
                }
            }

            guard let replacement else { continue }
            updated.frames[index].url = replacement
            if let records = try? ImageSequenceLoader.load(from: [replacement]),
               let refreshed = records.first {
                updated.frames[index].metadata = refreshed.metadata
                updated.frames[index].sourceAdjustment = refreshed.sourceAdjustment
            }
            relinked += 1
        }

        let remainingMissingCount = missingFrameCount(in: updated)
        if relinked > 0, remainingMissingCount == 0 {
            updated.sourceDirectory = newRoot
        }
        return FileRelinkResult(
            project: updated,
            relinkedCount: relinked,
            remainingMissingCount: remainingMissingCount,
            ambiguousCount: ambiguous
        )
    }

    private static func imageInventory(at root: URL, maximumEntries: Int) throws -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw TimeFlowError.relinkFailed("The selected folder could not be read.")
        }

        var images: [URL] = []
        var examined = 0
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            examined += 1
            if examined > maximumEntries {
                throw TimeFlowError.relinkFailed(
                    "The folder contains more than \(maximumEntries) entries. Choose a more specific folder."
                )
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true,
                  values?.isHidden != true,
                  ImageSequenceLoader.isSupportedImage(url) else { continue }
            images.append(url.standardizedFileURL)
        }
        return images
    }

    private static func relativePath(of file: URL, under root: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard filePath.hasPrefix(prefix) else { return nil }
        return String(filePath.dropFirst(prefix.count))
    }
}
