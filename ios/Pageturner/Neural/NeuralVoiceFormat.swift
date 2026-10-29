import Foundation

/// Turns a Piper voice as published (an `.onnx` model and its `.onnx.json`) into what the
/// on-device engine (sherpa-onnx) loads: the model with a few facts about the voice written
/// into it, and a `tokens.txt`. Sherpa's own converted voices differ from Piper's originals in
/// just these two things, so converting here lets the app download the original files — the
/// same ones the web app uses — with nothing to unpack. Pure Foundation, checked on Linux
/// (ios/Checks/bookmaster).
enum NeuralVoiceFormat {
    enum Failure: Error, LocalizedError, Equatable {
        /// The `.onnx.json` isn't a Piper voice config.
        case unreadableConfig
        /// A voice that needs a phonemizer other than espeak-ng (pinyin, Thai…).
        case unsupportedPhonemizer(String)

        var errorDescription: String? {
            switch self {
            case .unreadableConfig: return "The voice’s settings file couldn’t be read."
            case let .unsupportedPhonemizer(kind): return "This voice needs a “\(kind)” text converter that isn’t built in."
            }
        }
    }

    /// What the engine needs to know about a voice, read from its `.onnx.json`.
    struct Config: Equatable {
        var sampleRate: Int
        /// The espeak-ng voice that turns text into phonemes: "en-us".
        var espeakVoice: String
        var speakers: Int
        var noiseScale: Float
        var noiseW: Float
        var lengthScale: Float
        /// A multi-speaker voice's names for its speakers, by their id — empty for most.
        var speakerNames: [String]
        /// `phoneme_id_map`, flattened: the symbol and its (first) id.
        var tokens: [(symbol: String, id: Int)]

        static func == (a: Config, b: Config) -> Bool {
            a.sampleRate == b.sampleRate && a.espeakVoice == b.espeakVoice && a.speakers == b.speakers
                && a.noiseScale == b.noiseScale && a.noiseW == b.noiseW && a.lengthScale == b.lengthScale
                && a.speakerNames == b.speakerNames
                && a.tokens.map(\.symbol) == b.tokens.map(\.symbol) && a.tokens.map(\.id) == b.tokens.map(\.id)
        }
    }

    /// Read a Piper `.onnx.json`.
    static func parse(config data: Data) throws -> Config {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw Failure.unreadableConfig }
        // older voices have no phoneme_type: they are espeak
        let kind = root["phoneme_type"] as? String ?? "espeak"
        guard kind == "espeak" else { throw Failure.unsupportedPhonemizer(kind) }

        guard let audio = root["audio"] as? [String: Any], var sampleRate = (audio["sample_rate"] as? NSNumber)?.intValue,
              let map = root["phoneme_id_map"] as? [String: Any], !map.isEmpty
        else { throw Failure.unreadableConfig }
        // a typo in one voice's config; sherpa's own converter corrects it the same way
        if sampleRate == 22_500 { sampleRate = 22_050 }

        var voice = (root["lang_code"] as? String) ?? ((root["espeak"] as? [String: Any])?["voice"] as? String) ?? ""
        if voice == "pt-PT" { voice = "pt" }
        guard !voice.isEmpty else { throw Failure.unreadableConfig }

        let inference = root["inference"] as? [String: Any]
        func number(_ key: String, _ fallback: Float) -> Float {
            (inference?[key] as? NSNumber).map { $0.floatValue } ?? fallback
        }

        // a multi-speaker voice names its speakers in `speaker_id_map`; order is by id
        let speakerNames = (root["speaker_id_map"] as? [String: Any] ?? [:])
            .compactMap { name, value -> (name: String, id: Int)? in
                (value as? NSNumber)?.intValue.map { (name, $0) }
            }
            .sorted { $0.id != $1.id ? $0.id < $1.id : $0.name < $1.name }
            .map(\.name)

        // the map is unordered in Swift; by id then symbol is as good an order as any
        let tokens: [(symbol: String, id: Int)] = map.compactMap { symbol, value in
            if symbol == "\n" { return nil }
            if let ids = value as? [Any], let first = (ids.first as? NSNumber)?.intValue { return (symbol, first) }
            if let id = (value as? NSNumber)?.intValue { return (symbol, id) }
            return nil
        }
        .sorted { $0.id != $1.id ? $0.id < $1.id : $0.symbol < $1.symbol }
        guard !tokens.isEmpty else { throw Failure.unreadableConfig }

        return Config(
            sampleRate: sampleRate,
            espeakVoice: voice,
            speakers: max((root["num_speakers"] as? NSNumber)?.intValue ?? 1, 1),
            noiseScale: number("noise_scale", 0.667),
            noiseW: number("noise_w", 0.8),
            lengthScale: max(number("length_scale", 1), 0.1),
            speakerNames: speakerNames,
            tokens: tokens)
    }

    /// `tokens.txt`: one "symbol id" line per phoneme.
    static func tokensFile(_ config: Config) -> String {
        config.tokens.map { "\($0.symbol) \($0.id)\n" }.joined()
    }

    /// The facts sherpa-onnx reads out of the model file, as its own conversion script writes them.
    static func metadata(for config: Config, languageName: String) -> [(key: String, value: String)] {
        [
            ("model_type", "vits"),
            ("comment", "piper"),   // it takes the model for a Piper one by this
            ("language", languageName),
            ("voice", config.espeakVoice),
            ("version", "1"),
            ("has_espeak", "1"),
            ("has_g2pw", "0"),
            ("n_speakers", String(config.speakers)),
            ("sample_rate", String(config.sampleRate)),
        ]
    }

    /// The bytes to put on the end of a `.onnx` file so that it carries `pairs` as its metadata.
    /// An ONNX model is a protobuf message, and protobuf lets a repeated field turn up
    /// again after the rest: `metadata_props` is field 14, each entry a message of
    /// (1: key, 2: value). So the 60 MB model is left as it is and a few dozen bytes follow it.
    static func metadataBytes(_ pairs: [(key: String, value: String)]) -> Data {
        var out = Data()
        for (key, value) in pairs {
            var entry = Data([0x0A])
            entry.append(contentsOf: varint(key.utf8.count))
            entry.append(contentsOf: Array(key.utf8))
            entry.append(0x12)
            entry.append(contentsOf: varint(value.utf8.count))
            entry.append(contentsOf: Array(value.utf8))
            out.append(0x72)   // field 14, length-delimited
            out.append(contentsOf: varint(entry.count))
            out.append(entry)
        }
        return out
    }

    static func varint(_ value: Int) -> [UInt8] {
        var n = UInt64(max(value, 0))
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(n & 0x7F)
            n >>= 7
            if n != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while n != 0
        return bytes
    }

    /// What was written for an installed voice.
    struct Installed: Codable, Equatable {
        var key: String
        var sampleRate: Int
        var speakers: Int
        var noiseScale: Float
        var noiseW: Float
        var lengthScale: Float
        /// A multi-speaker voice's names for its speakers, by id — voices installed before
        /// these were kept decode as an empty list, and a row reads "Speaker N".
        var speakerNames: [String]
        var installedAt: Date

        init(key: String, sampleRate: Int, speakers: Int, noiseScale: Float, noiseW: Float,
             lengthScale: Float, speakerNames: [String] = [], installedAt: Date) {
            self.key = key
            self.sampleRate = sampleRate
            self.speakers = speakers
            self.noiseScale = noiseScale
            self.noiseW = noiseW
            self.lengthScale = lengthScale
            self.speakerNames = speakerNames
            self.installedAt = installedAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            key = try container.decode(String.self, forKey: .key)
            sampleRate = try container.decode(Int.self, forKey: .sampleRate)
            speakers = try container.decode(Int.self, forKey: .speakers)
            noiseScale = try container.decode(Float.self, forKey: .noiseScale)
            noiseW = try container.decode(Float.self, forKey: .noiseW)
            lengthScale = try container.decode(Float.self, forKey: .lengthScale)
            speakerNames = try container.decodeIfPresent([String].self, forKey: .speakerNames) ?? []
            installedAt = try container.decode(Date.self, forKey: .installedAt)
        }

        /// What to call its `sid` speaker in a list.
        func speakerName(_ sid: Int) -> String {
            speakerNames.indices.contains(sid) ? speakerNames[sid] : "Speaker \(sid + 1)"
        }
    }

    static let modelFile = "model.onnx"
    static let tokensFileName = "tokens.txt"
    static let infoFile = "voice.json"

    /// Make `directory` hold a ready voice: the downloaded model moved in with its metadata
    /// appended, the tokens, and `voice.json`. The model file is taken, not copied.
    static func install(
        key: String, languageName: String, model: URL, config configData: Data, into directory: URL,
        now: Date = Date()
    ) throws -> Installed {
        let config = try parse(config: configData)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let target = directory.appendingPathComponent(modelFile)
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.moveItem(at: model, to: target)
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: metadataBytes(metadata(for: config, languageName: languageName)))

        try Data(tokensFile(config).utf8).write(to: directory.appendingPathComponent(tokensFileName), options: .atomic)

        let info = Installed(
            key: key, sampleRate: config.sampleRate, speakers: config.speakers,
            noiseScale: config.noiseScale, noiseW: config.noiseW, lengthScale: config.lengthScale,
            speakerNames: config.speakerNames, installedAt: now)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(info).write(to: directory.appendingPathComponent(infoFile), options: .atomic)
        return info
    }
}
