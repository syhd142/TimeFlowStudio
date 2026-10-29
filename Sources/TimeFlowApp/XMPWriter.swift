import Foundation

enum XMPWriter {
    static func export(
        project: TimeFlowProject,
        corrections: [Double],
        to directory: URL
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for (index, frame) in project.frames.enumerated() {
            var adjustment = project.keyframes.isEmpty
                ? (frame.sourceAdjustment ?? .neutral)
                : AdjustmentEngine.adjustment(at: index, keyframes: project.keyframes)
            if corrections.indices.contains(index) {
                adjustment.exposureEV += corrections[index]
            }
            let destination = directory
                .appendingPathComponent(frame.url.deletingPathExtension().lastPathComponent)
                .appendingPathExtension("xmp")
            let sourceSidecar = XMPDocument.sidecarURL(for: frame.url)
            let baseURL = FileManager.default.fileExists(atPath: destination.path)
                ? destination
                : sourceSidecar
            let existingData = try? Data(contentsOf: baseURL)
            try XMPDocument.backupExistingSidecar(destination)
            let data = try XMPDocument.mergedData(
                existingData: existingData,
                adjustment: adjustment,
                sourceFile: frame.url.lastPathComponent
            )
            try data.write(to: destination, options: .atomic)
        }
    }

    static func document(for adjustment: Adjustment, sourceFile: String) -> String {
        let escapedName = sourceFile
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <?xpacket begin="\u{feff}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="TimeFlow Studio 1.0">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about=""
              xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
              xmlns:dc="http://purl.org/dc/elements/1.1/"
              crs:ProcessVersion="11.0"
              crs:Exposure2012="\(format(adjustment.exposureEV))"
              crs:Temperature="\(Int(adjustment.temperature.rounded()))"
              crs:Tint="\(Int(adjustment.tint.rounded()))"
              crs:Contrast2012="\(Int(adjustment.contrast.rounded()))"
              crs:Saturation="\(Int(adjustment.saturation.rounded()))"
              dc:source="\(escapedName)" />
          </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
    }

    private static func format(_ value: Double) -> String {
        String(format: "%+.4f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
