import Foundation

// Checks for the neural voices: the bundled catalogue, the download URLs, and the conversion of a
// Piper voice into what sherpa-onnx loads (tokens.txt and the metadata written onto the model).
// The fixtures are the real lessac-low config and sherpa-onnx's own converted tokens.txt for it.

private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

@MainActor
func runNeuralChecks() {
    section("Neural voices: the catalogue")
    let root = harness + "/../../Pageturner/Neural/NeuralVoices.json"
    guard let data = FileManager.default.contents(atPath: root), let catalog = try? NeuralCatalog.decode(data) else {
        check("the bundled catalogue decodes", false, root)
        return
    }
    let voices = catalog.voices
    check("the bundled catalogue decodes", voices.count >= 150, "\(voices.count)")
    check("pinned to a commit", catalog.revision.count == 40 && catalog.revision.allSatisfy(\.isHexDigit), catalog.revision)
    check("keys are unique", Set(voices.map(\.key)).count == voices.count)
    check("a key is language-name-quality", voices.allSatisfy { $0.key == "\($0.lang)-\($0.name)-\($0.quality.rawValue)" },
          voices.first { $0.key != "\($0.lang)-\($0.name)-\($0.quality.rawValue)" }?.key ?? "")
    check("every file has a size and an MD5", voices.allSatisfy {
        $0.onnx.size > 1_000_000 && $0.config.size > 0 && $0.onnx.md5.count == 32 && $0.config.md5.count == 32
            && $0.onnx.md5.allSatisfy(\.isHexDigit) && $0.config.md5.allSatisfy(\.isHexDigit)
    })
    check("a model is a .onnx and its settings a .onnx.json", voices.allSatisfy {
        $0.onnx.path.hasSuffix(".onnx") && $0.config.path == $0.onnx.path + ".json"
    })
    check("languages look like xx_YY", voices.allSatisfy { $0.lang.count == 5 && $0.lang.dropFirst(2).first == "_" }, voices.first { $0.lang.count != 5 }?.lang ?? "")
    check("the voices Piper needs another phonemizer for are not offered",
          catalog.voice(withKey: "zh_CN-xiao_ya-medium") == nil && catalog.voice(withKey: "ja_JP-hi_fi_captain-medium") == nil)
    check("English has plenty", voices.filter { SpeechVoices.baseLanguage($0.lang) == "en" }.count >= 20)

    guard let lessac = catalog.voice(withKey: "en_US-lessac-low") else {
        check("en_US-lessac-low is in the catalogue", false)
        return
    }
    check("identifier round trip", lessac.id == "piper:en_US-lessac-low" && NeuralVoice.key(fromID: lessac.id) == "en_US-lessac-low"
          && catalog.voice(withID: lessac.id)?.key == lessac.key)
    check("a speaker variant rides in the identifier", lessac.id(withSpeaker: 3) == "piper:en_US-lessac-low@3"
          && NeuralVoice.key(fromID: "piper:en_US-lessac-low@3") == "en_US-lessac-low"
          && NeuralVoice.speaker(fromID: "piper:en_US-lessac-low@3") == 3
          && catalog.voice(withID: "piper:en_US-lessac-low@3")?.key == lessac.key)
    check("speaker zero is the voice itself", lessac.id(withSpeaker: 0) == lessac.id
          && NeuralVoice.speaker(fromID: lessac.id) == nil)
    check("a bad speaker part is no speaker", NeuralVoice.speaker(fromID: "piper:en_US-lessac-low@x") == nil
          && NeuralVoice.key(fromID: "piper:en_US-lessac-low@x") == "en_US-lessac-low")
    check("a system voice's identifier is not a neural one", NeuralVoice.key(fromID: "com.apple.voice.premium.en-US.Zoe") == nil
          && NeuralVoice.speaker(fromID: "com.apple.voice.premium.en-US.Zoe") == nil
          && catalog.voice(withID: "com.apple.voice.premium.en-US.Zoe") == nil)
    check("the catalogue's checksum for it is the real one (matches the file Piper published)",
          lessac.onnx.md5 == "31883a7506589feadf3c3474fd8ef658" && lessac.config.md5 == "64876daa19dd042b368cd64fa379a75f" && lessac.onnx.size == 63_201_294)
    check("download URL", catalog.url(for: lessac.onnx)?.absoluteString
          == "https://huggingface.co/rhasspy/piper-voices/resolve/\(catalog.revision)/en/en_US/lessac/low/en_US-lessac-low.onnx",
          catalog.url(for: lessac.onnx)?.absoluteString ?? "nil")
    let odd = NeuralCatalog(repo: "https://example.org/a/b", revision: "abc", voices: [])
    check("a path is encoded part by part", odd.url(for: NeuralFile(path: "x y/z#1/m?.onnx", size: 1, md5: ""))?.absoluteString
          == "https://example.org/a/b/resolve/abc/x%20y/z%231/m%3F.onnx", odd.url(for: NeuralFile(path: "x y/z#1/m?.onnx", size: 1, md5: ""))?.absoluteString ?? "nil")
    check("display names", lessac.displayName == "Lessac"
          && NeuralVoice(key: "k", name: "southern_english_female", lang: "en_GB", langName: "English", country: "", quality: .low, speakers: 1, onnx: lessac.onnx, config: lessac.config).displayName == "Southern English Female")
    check("language is a BCP-47 tag", lessac.language == "en-US")
    check("the saved-voices line", NeuralVoiceSummary.text(count: 0, bytes: 0) == "None" && NeuralVoiceSummary.text(count: 1, bytes: 63_201_294) == "1 · 63 MB"
          && NeuralVoiceSummary.text(count: 3, bytes: 190_000_000) == "3 · 190 MB", NeuralVoiceSummary.text(count: 3, bytes: 190_000_000))
    check("quality order", NeuralVoice.Quality.xLow < .low && NeuralVoice.Quality.low < .medium && NeuralVoice.Quality.medium < .high)
    check("size labels", NeuralVoice.sizeLabel(63_201_294) == "63 MB" && NeuralVoice.sizeLabel(24_300_000) == "24 MB" && NeuralVoice.sizeLabel(5_022) == "0.0 MB",
          "\(NeuralVoice.sizeLabel(63_201_294)) \(NeuralVoice.sizeLabel(24_300_000)) \(NeuralVoice.sizeLabel(5_022))")

    section("Neural voices: the list")
    func languageName(_ base: String) -> String { voices.first { SpeechVoices.baseLanguage($0.lang) == base }?.langName ?? base }
    func countryName(_ region: String) -> String? { voices.first { SpeechVoices.region($0.lang) == region }?.country }
    let groups = SpeechVoices.groups(voices, preferred: ["en-US", "de-DE"], languageName: languageName, regionName: countryName)
    check("the device's languages first", groups.prefix(2).map(\.title) == ["English", "German"], "\(groups.prefix(3).map(\.title))")
    let english = groups[0].voices
    check("the device's own locale first inside a language", english.prefix { $0.lang == "en_US" }.count > 5 && english.first?.lang == "en_US", "\(english.prefix(3).map(\.key))")
    let us = english.filter { $0.lang == "en_US" }
    check("better models before smaller ones in a locale", zip(us, us.dropFirst()).allSatisfy { $0.quality >= $1.quality }, "\(us.map { $0.quality.rawValue })")
    check("search by name", SpeechVoices.groups(voices, query: "kathleen", preferred: [], languageName: languageName).flatMap(\.voices).map(\.key) == ["en_US-kathleen-low"])
    check("search by country", SpeechVoices.groups(voices, query: "wales", preferred: [], languageName: languageName, regionName: countryName)
            .flatMap(\.voices).allSatisfy { $0.lang == "cy_GB" } )
    check("search by quality", SpeechVoices.groups(voices, query: "x-low", preferred: [], languageName: languageName).flatMap(\.voices).allSatisfy { $0.quality == .xLow })
    check("search by language", Set(SpeechVoices.groups(voices, query: "german", preferred: [], languageName: languageName).flatMap(\.voices).map { SpeechVoices.baseLanguage($0.lang) }) == ["de"])

    section("Neural voices: conversion")
    let configData = FileManager.default.contents(atPath: harness + "/Fixtures/en_US-lessac-low.onnx.json") ?? Data()
    let sherpaTokens = String(data: FileManager.default.contents(atPath: harness + "/Fixtures/sherpa-lessac-low-tokens.txt") ?? Data(), encoding: .utf8) ?? ""
    guard let config = try? NeuralVoiceFormat.parse(config: configData) else {
        check("the real config parses", false)
        return
    }
    check("the real config parses", config.sampleRate == 16_000 && config.espeakVoice == "en-us" && config.speakers == 1
          && config.noiseScale == 0.667 && config.noiseW == 0.8 && config.lengthScale == 1, "\(config.sampleRate) \(config.espeakVoice)")
    check("tokens.txt is what sherpa-onnx's own converter wrote for the same voice, to the byte",
          NeuralVoiceFormat.tokensFile(config) == sherpaTokens, "\(NeuralVoiceFormat.tokensFile(config).count) vs \(sherpaTokens.count)")
    let meta = NeuralVoiceFormat.metadata(for: config, languageName: "English")
    check("the metadata sherpa reads", meta.map(\.key) == ["model_type", "comment", "language", "voice", "version", "has_espeak", "has_g2pw", "n_speakers", "sample_rate"]
          && meta.first { $0.key == "voice" }?.value == "en-us" && meta.first { $0.key == "sample_rate" }?.value == "16000")
    check("…written as protobuf entries (bytes from the Python prototype that sherpa-onnx loaded and spoke with)",
          hex(NeuralVoiceFormat.metadataBytes(meta))
          == "72120a0a6d6f64656c5f7479706512047669747372100a07636f6d6d656e741205706970657272130a086c616e67756167651207456e676c697368720e0a05766f6963651205656e2d7573720c0a0776657273696f6e120131720f0a0a6861735f65737065616b120131720d0a086861735f67327077120130720f0a0a6e5f737065616b65727312013172140a0b73616d706c655f7261746512053136303030",
          hex(NeuralVoiceFormat.metadataBytes(meta)))
    check("varints", NeuralVoiceFormat.varint(0) == [0] && NeuralVoiceFormat.varint(127) == [0x7F] && NeuralVoiceFormat.varint(128) == [0x80, 0x01]
          && NeuralVoiceFormat.varint(300) == [0xAC, 0x02] && NeuralVoiceFormat.varint(16_384) == [0x80, 0x80, 0x01])
    check("a long value gets a two-byte length", NeuralVoiceFormat.metadataBytes([("k", String(repeating: "x", count: 200))]).prefix(5)
          == Data([0x72, 0xCE, 0x01, 0x0A, 0x01]), hex(NeuralVoiceFormat.metadataBytes([("k", String(repeating: "x", count: 200))]).prefix(5)))

    func parsed(_ json: String) -> Result<NeuralVoiceFormat.Config, NeuralVoiceFormat.Failure> {
        do { return .success(try NeuralVoiceFormat.parse(config: Data(json.utf8))) }
        catch let failure as NeuralVoiceFormat.Failure { return .failure(failure) }
        catch { return .failure(.unreadableConfig) }
    }
    let base = #"{"audio":{"sample_rate":22050},"espeak":{"voice":"de"},"num_speakers":2,"phoneme_id_map":{"_":[0],"a":[7],"\n":[9]}}"#

    check("a multi-speaker voice's names are kept in id order", {
        let multi = base.replacingOccurrences(of: "\"num_speakers\"", with: "\"speaker_id_map\":{\"bryce\":1,\"adam\":0,\"carl\":2},\"num_speakers\":3,\"old_num\"")
        guard case let .success(c) = parsed(multi) else { return false }
        return c.speakers == 3 && c.speakerNames == ["adam", "bryce", "carl"]
    }())
    check("a single-speaker voice names none", {
        guard case let .success(c) = parsed(base) else { return false }
        return c.speakerNames.isEmpty
    }())
    check("voice.json written before speaker names existed still decodes, with none", {
        let legacy = #"{"key":"k","sampleRate":22050,"speakers":2,"noiseScale":0.5,"noiseW":0.6,"lengthScale":1,"installedAt":1700000000}"#
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        guard let info = try? dec.decode(NeuralVoiceFormat.Installed.self, from: Data(legacy.utf8)) else { return false }
        return info.speakers == 2 && info.speakerNames.isEmpty && info.speakerName(1) == "Speaker 2"
    }())
    check("a named speaker is named", NeuralVoiceFormat.Installed(
        key: "k", sampleRate: 1, speakers: 3, noiseScale: 0, noiseW: 0, lengthScale: 1,
        speakerNames: ["a", "b"], installedAt: Date()).speakerName(1) == "b")

    if case let .success(c) = parsed(base) {
        check("a small config", c.sampleRate == 22_050 && c.espeakVoice == "de" && c.speakers == 2 && c.tokens.map(\.symbol) == ["_", "a"] && c.tokens.map(\.id) == [0, 7])
        check("…defaults for the sound shaping", c.noiseScale == 0.667 && c.noiseW == 0.8 && c.lengthScale == 1)
    } else { check("a small config", false) }
    check("a voice's own length scale is kept", { if case let .success(c) = parsed(base.replacingOccurrences(of: "\"num_speakers\"", with: "\"inference\":{\"length_scale\":1.2,\"noise_scale\":0.5,\"noise_w\":0.6},\"num_speakers\"")) { return c.lengthScale == 1.2 && c.noiseScale == 0.5 && c.noiseW == 0.6 }; return false }())
    check("a plain id is as good as a list of one", { if case let .success(c) = parsed(base.replacingOccurrences(of: "[7]", with: "7")) { return c.tokens.last?.id == 7 }; return false }())
    check("the typo'd 22500 Hz is 22050", { if case let .success(c) = parsed(base.replacingOccurrences(of: "22050", with: "22500")) { return c.sampleRate == 22_050 }; return false }())
    check("lang_code outranks espeak.voice", { if case let .success(c) = parsed(base.replacingOccurrences(of: "\"audio\"", with: "\"lang_code\":\"fr-be\",\"audio\"")) { return c.espeakVoice == "fr-be" }; return false }())
    check("pt-PT is spoken as pt", { if case let .success(c) = parsed(base.replacingOccurrences(of: "\"de\"", with: "\"pt-PT\"")) { return c.espeakVoice == "pt" }; return false }())
    check("another phonemizer is refused", parsed(base.replacingOccurrences(of: "{\"audio\"", with: "{\"phoneme_type\":\"pinyin\",\"audio\"")) == .failure(.unsupportedPhonemizer("pinyin")))
    check("espeak by name is fine", { if case .success = parsed(base.replacingOccurrences(of: "{\"audio\"", with: "{\"phoneme_type\":\"espeak\",\"audio\"")) { return true }; return false }())
    check("junk is refused", parsed("not json") == .failure(.unreadableConfig) && parsed("[]") == .failure(.unreadableConfig)
          && parsed(#"{"audio":{"sample_rate":22050},"espeak":{"voice":"de"},"phoneme_id_map":{}}"#) == .failure(.unreadableConfig)
          && parsed(#"{"audio":{},"espeak":{"voice":"de"},"phoneme_id_map":{"a":[1]}}"#) == .failure(.unreadableConfig)
          && parsed(#"{"audio":{"sample_rate":22050},"phoneme_id_map":{"a":[1]}}"#) == .failure(.unreadableConfig))

    section("Neural voices: installing")
    let fm = FileManager.default
    let scratch = fm.temporaryDirectory.appendingPathComponent("neural-check-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: scratch) }
    try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
    let model = scratch.appendingPathComponent("download.tmp")
    let original = Data((0..<4_096).map { UInt8($0 % 251) })
    try? original.write(to: model)
    let target = scratch.appendingPathComponent("voice")
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    check("a bad config stops before the model is touched", {
        _ = try? NeuralVoiceFormat.install(key: "k", languageName: "English", model: model, config: Data("nope".utf8), into: target, now: now)
        return fm.fileExists(atPath: model.path) && !fm.fileExists(atPath: target.appendingPathComponent("model.onnx").path)
    }())

    let installed = try? NeuralVoiceFormat.install(key: lessac.key, languageName: "English", model: model, config: configData, into: target, now: now)
    check("install reports the voice", installed?.key == lessac.key && installed?.sampleRate == 16_000 && installed?.speakers == 1)
    let written = fm.contents(atPath: target.appendingPathComponent("model.onnx").path) ?? Data()
    check("the model is the download with the metadata on its end", written == original + NeuralVoiceFormat.metadataBytes(meta), "\(written.count)")
    check("the download was moved, not copied", !fm.fileExists(atPath: model.path))
    check("tokens.txt is written", String(data: fm.contents(atPath: target.appendingPathComponent("tokens.txt").path) ?? Data(), encoding: .utf8) == sherpaTokens)
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
    check("voice.json reads back", (try? dec.decode(NeuralVoiceFormat.Installed.self, from: fm.contents(atPath: target.appendingPathComponent("voice.json").path) ?? Data()))
          == installed)

    // installing again over an old install replaces it
    try? original.write(to: model)
    _ = try? NeuralVoiceFormat.install(key: lessac.key, languageName: "English", model: model, config: configData, into: target, now: now)
    check("installing over an old copy replaces it", (fm.contents(atPath: target.appendingPathComponent("model.onnx").path) ?? Data()).count == original.count + NeuralVoiceFormat.metadataBytes(meta).count)

    // Optional, by hand: convert a real downloaded voice here, then load it with sherpa-onnx.
    //   PIPER_RAW_ONNX=… PIPER_RAW_JSON=… PIPER_OUT_DIR=… .build/debug/bmcheck   (see README)
    let env = ProcessInfo.processInfo.environment
    if let rawModel = env["PIPER_RAW_ONNX"], let rawConfig = env["PIPER_RAW_JSON"], let out = env["PIPER_OUT_DIR"] {
        let copy = scratch.appendingPathComponent("real.onnx")
        try? fm.removeItem(at: copy)
        try? fm.copyItem(atPath: rawModel, toPath: copy.path)
        let done = try? NeuralVoiceFormat.install(
            key: "manual", languageName: env["PIPER_LANGUAGE_NAME"] ?? "English", model: copy,
            config: fm.contents(atPath: rawConfig) ?? Data(), into: URL(fileURLWithPath: out))
        check("a real downloaded voice converted into \(out)", done != nil)
    }
}
