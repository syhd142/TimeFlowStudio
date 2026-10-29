import Foundation

enum XMPDocument {
    private static let managedAttributes: [(String, (Adjustment) -> String)] = [
        ("crs:Exposure2012", { format($0.exposureEV) }),
        ("crs:Temperature", { String(Int($0.temperature.rounded())) }),
        ("crs:Tint", { String(Int($0.tint.rounded())) }),
        ("crs:Contrast2012", { String(Int($0.contrast.rounded())) }),
        ("crs:Saturation", { String(Int($0.saturation.rounded())) })
    ]

    static func sidecarURL(for imageURL: URL) -> URL {
        imageURL.deletingPathExtension().appendingPathExtension("xmp")
    }

    static func adjustment(for imageURL: URL) -> Adjustment? {
        adjustment(at: sidecarURL(for: imageURL))
    }

    static func adjustment(at url: URL) -> Adjustment? {
        guard let data = try? Data(contentsOf: url),
              let xml = String(data: data, encoding: .utf8),
              (try? XMLDocument(data: data)) != nil else { return nil }

        var result = Adjustment.neutral
        var found = false
        if let value = numericAttribute("crs:Exposure2012", in: xml) {
            result.exposureEV = value
            found = true
        }
        if let value = numericAttribute("crs:Temperature", in: xml) {
            result.temperature = value
            found = true
        }
        if let value = numericAttribute("crs:Tint", in: xml) {
            result.tint = value
            found = true
        }
        if let value = numericAttribute("crs:Contrast2012", in: xml) {
            result.contrast = value
            found = true
        }
        if let value = numericAttribute("crs:Saturation", in: xml) {
            result.saturation = value
            found = true
        }
        return found ? result : nil
    }

    static func mergedData(
        existingData: Data?,
        adjustment: Adjustment,
        sourceFile: String
    ) throws -> Data {
        var xml: String
        if let existingData {
            guard (try? XMLDocument(data: existingData)) != nil,
                  let existingXML = String(data: existingData, encoding: .utf8) else {
                throw TimeFlowError.xmpFailed("The existing XMP is not valid XML and was left unchanged.")
            }
            xml = existingXML
        } else {
            xml = XMPWriter.document(for: adjustment, sourceFile: sourceFile)
        }

        xml = try ensureNamespace(
            prefix: "crs",
            uri: "http://ns.adobe.com/camera-raw-settings/1.0/",
            in: xml
        )
        xml = try ensureNamespace(prefix: "dc", uri: "http://purl.org/dc/elements/1.1/", in: xml)
        for (name, value) in managedAttributes {
            xml = try replacingAttribute(name, value: value(adjustment), in: xml)
        }
        xml = try replacingAttribute("dc:source", value: escape(sourceFile), in: xml)
        return Data(xml.utf8)
    }

    static func backupExistingSidecar(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let directory = url.deletingLastPathComponent().appendingPathComponent(
            ".timeflow-xmp-backups",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let backupName = "\(url.deletingPathExtension().lastPathComponent)-\(formatter.string(from: Date())).xmp"
        try FileManager.default.copyItem(at: url, to: directory.appendingPathComponent(backupName))
    }

    private static func numericAttribute(_ name: String, in xml: String) -> Double? {
        guard let value = attribute(name, in: xml) else { return nil }
        return Double(value)
    }

    private static func attribute(_ name: String, in xml: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        guard let regex = try? NSRegularExpression(pattern: "\\b\(escaped)\\s*=\\s*[\"']([^\"']*)[\"']"),
              let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              let range = Range(match.range(at: 1), in: xml) else { return nil }
        return String(xml[range])
    }

    private static func replacingAttribute(_ name: String, value: String, in xml: String) throws -> String {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let regex = try NSRegularExpression(pattern: "\\b\(escapedName)\\s*=\\s*[\"'][^\"']*[\"']")
        let fullRange = NSRange(xml.startIndex..., in: xml)
        if regex.firstMatch(in: xml, range: fullRange) != nil {
            return regex.stringByReplacingMatches(
                in: xml,
                range: fullRange,
                withTemplate: "\(name)=\"\(value)\""
            )
        }
        return try insertingIntoDescription("\(name)=\"\(value)\"", in: xml)
    }

    private static func ensureNamespace(prefix: String, uri: String, in xml: String) throws -> String {
        if xml.range(of: "xmlns:\(prefix)=") != nil { return xml }
        return try insertingIntoDescription("xmlns:\(prefix)=\"\(uri)\"", in: xml)
    }

    private static func insertingIntoDescription(_ text: String, in xml: String) throws -> String {
        guard let description = xml.range(of: "<rdf:Description") else {
            throw TimeFlowError.xmpFailed("The existing XMP has no rdf:Description element.")
        }
        guard let close = xml[description.lowerBound...].firstIndex(of: ">") else {
            throw TimeFlowError.xmpFailed("The existing XMP description is incomplete.")
        }
        let insertion = xml.index(before: close)
        let target = xml[insertion] == "/" ? insertion : close
        var result = xml
        result.insert(contentsOf: "\n    \(text)", at: target)
        return result
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func format(_ value: Double) -> String {
        String(format: "%+.4f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
