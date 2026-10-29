import Foundation

/// A file in the voices repository: where it is, how big, and its MD5 (checked after the
/// download, so a cut-off or tampered file is never installed).
struct NeuralFile: Codable, Hashable {
    var path: String
    var size: Int64
    var md5: String
}

/// A neural voice — a Piper model — that can be downloaded and spoken on the device.
/// The same set the web app offers; see ios/scripts/make-neural-catalog.py.
struct NeuralVoice: LanguageListed, Codable, Hashable {
    enum Quality: String, Codable, Comparable {
        case xLow = "x_low", low, medium, high

        static func < (a: Quality, b: Quality) -> Bool { a.rank < b.rank }

        var rank: Int {
            switch self {
            case .xLow: return 0
            case .low: return 1
            case .medium: return 2
            case .high: return 3
            }
        }

        var label: String {
            switch self {
            case .xLow: return "X-Low"
            case .low: return "Low"
            case .medium: return "Medium"
            case .high: return "High"
            }
        }
    }

    /// "en_US-lessac-low".
    var key: String
    /// "lessac".
    var name: String
    /// "en_US".
    var lang: String
    /// "English".
    var langName: String
    /// "United States".
    var country: String
    var quality: Quality
    var speakers: Int
    var onnx: NeuralFile
    var config: NeuralFile

    /// What is saved as the reader's voice, and what Readium is told it is: "piper:en_US-lessac-low".
    /// A speaker of a multi-speaker voice goes after an "@": "piper:en_US-vctk-medium@42".
    static let idPrefix = "piper:"
    var id: String { Self.idPrefix + key }

    /// The identifier of this voice's `sid` speaker — itself when it is alone.
    func id(withSpeaker sid: Int) -> String {
        sid > 0 ? "\(id)@\(sid)" : id
    }

    /// The key from a saved voice identifier — nil for anything that isn't a neural voice's.
    /// A speaker suffix ("@3") is not part of it.
    static func key(fromID id: String) -> String? {
        guard id.hasPrefix(idPrefix) else { return nil }
        let rest = id.dropFirst(idPrefix.count)
        return String(rest.split(separator: "@", maxSplits: 1).first ?? rest)
    }

    /// The speaker a saved identifier names ("piper:key@3" → 3); nil for the voice itself.
    static func speaker(fromID id: String) -> Int? {
        guard id.hasPrefix(idPrefix),
              let part = id.dropFirst(idPrefix.count).split(separator: "@", maxSplits: 1).dropFirst().first
        else { return nil }
        return Int(part)
    }

    // MARK: LanguageListed

    /// "Lessac", "Southern English Female".
    var displayName: String {
        name.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// BCP-47: "en-US".
    var language: String { lang.replacingOccurrences(of: "_", with: "-") }
    var listRank: Int { quality.rank }
    var searchTerms: [String] { [quality.label] }

    /// What a download costs, in bytes.
    var downloadBytes: Int64 { onnx.size + config.size }

    /// "63 MB".
    var sizeLabel: String { Self.sizeLabel(downloadBytes) }

    static func sizeLabel(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_000_000
        return mb >= 10 ? "\(Int(mb.rounded())) MB" : String(format: "%.1f MB", mb)
    }
}

/// The voices that can be downloaded, as bundled with the app.
struct NeuralCatalog: Codable {
    /// The voices repository, e.g. https://huggingface.co/rhasspy/piper-voices.
    var repo: String
    /// The commit every path is read at, so the URLs and checksums stay true.
    var revision: String
    var voices: [NeuralVoice]

    static func decode(_ data: Data) throws -> NeuralCatalog {
        try JSONDecoder().decode(NeuralCatalog.self, from: data)
    }

    /// Where to fetch one of a voice's files.
    func url(for file: NeuralFile) -> URL? {
        var parts = URLComponents(string: repo)
        guard parts != nil else { return nil }
        parts?.percentEncodedPath += "/resolve/\(revision)/" + file.path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? String($0) }
            .joined(separator: "/")
        return parts?.url
    }

    func voice(withKey key: String) -> NeuralVoice? {
        voices.first { $0.key == key }
    }

    func voice(withID id: String) -> NeuralVoice? {
        NeuralVoice.key(fromID: id).flatMap(voice(withKey:))
    }
}

/// The words for how many voices are saved on the phone and what they take.
enum NeuralVoiceSummary {
    /// "None", "1 · 63 MB", "3 · 190 MB".
    static func text(count: Int, bytes: Int64) -> String {
        count == 0 ? "None" : "\(count) · \(NeuralVoice.sizeLabel(bytes))"
    }
}
