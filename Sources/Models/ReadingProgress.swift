import Foundation

/// 离线 TTS 模型类型枚举
enum OfflineModelType: String, Codable, CaseIterable, Identifiable {
    case kokoroZH = "kokoro-zh"
    case matchaZH = "matcha-zh"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .kokoroZH: return "Kokoro 中文（高品质）"
        case .matchaZH: return "Matcha 中文（flow-matching）"
        }
    }

    /// 预估模型文件大小（MB），用于下载/存储提示
    var estimatedSizeMB: Double {
        switch self {
        case .kokoroZH: return 380
        case .matchaZH: return 240
        }
    }

    /// 预期 RTF 范围（越小越快）
    var expectedRTF: String {
        switch self {
        case .kokoroZH: return "< 1.5"
        case .matchaZH: return "< 1.2"
        }
    }

    /// huggingface 模型 ID
    var huggingfaceModelId: String {
        switch self {
        case .kokoroZH: return "k2-fsa/sherpa-onnx-kokoro-zh"
        case .matchaZH: return "k2-fsa/matcha-icefall-zh-baker"
        }
    }
}

struct ReadingProgress: Codable {
    let bookId: UUID
    var characterIndex: Int
    var chapterIndex: Int
    var lastUpdated: Date

    init(bookId: UUID, characterIndex: Int = 0, chapterIndex: Int = 0, lastUpdated: Date = Date()) {
        self.bookId = bookId
        self.characterIndex = characterIndex
        self.chapterIndex = chapterIndex
        self.lastUpdated = lastUpdated
    }
}

enum TTSLanguage: String, CaseIterable, Identifiable, Codable {
    case chinese = "zh-CN"
    case english = "en-US"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chinese: return "中文"
        case .english: return "英文"
        }
    }

    var defaultVoiceName: String {
        "系统默认\(displayName)"
    }

    var languagePrefix: String {
        rawValue.split(separator: "-").first.map(String.init)?.lowercased() ?? rawValue.lowercased()
    }

    static func language(for identifier: String) -> TTSLanguage {
        TTSLanguage(rawValue: identifier) ?? .chinese
    }
}

struct TTSSettings: Codable {
    var speechRate: Float
    var pitchMultiplier: Float
    var selectedVoiceIdentifier: String
    var preferredLanguageIdentifier: String
    var isNeuralVoiceEnabled: Bool
    var modelSelection: TTSModelSelection
    var offlineModelType: OfflineModelType
    var kokoroSpeakerId: Int
    var matchaNoiseScale: Float
    var matchaLengthScale: Float

    static let defaultVoiceIdentifier = "zh-CN"
    static let speechRateKey = "TTS_SpeechRate"
    static let pitchMultiplierKey = "TTS_PitchMultiplier"
    static let voiceIdentifierKey = "TTS_VoiceIdentifier"
    static let preferredLanguageKey = "TTS_PreferredLanguage"
    static let defaultKokoroSpeakerId = 3
    static let defaultMatchaNoiseScale: Float = 0.667
    static let defaultMatchaLengthScale: Float = 1.0

    static let `default` = TTSSettings(
        speechRate: 0.5,
        pitchMultiplier: 1.0,
        selectedVoiceIdentifier: defaultVoiceIdentifier,
        preferredLanguageIdentifier: TTSLanguage.chinese.rawValue,
        isNeuralVoiceEnabled: true,
        modelSelection: .autoEdge,
        offlineModelType: .kokoroZH,
        kokoroSpeakerId: TTSSettings.defaultKokoroSpeakerId,
        matchaNoiseScale: TTSSettings.defaultMatchaNoiseScale,
        matchaLengthScale: TTSSettings.defaultMatchaLengthScale
    )

    private static let legacySpeechRateKey = "speechRate"
    private static let legacyPitchMultiplierKey = "pitchMultiplier"
    private static let legacyVoiceIdentifierKey = "selectedVoiceIdentifier"

    private static let offlineModelTypeKey = "TTS_OfflineModelType"
    private static let modelSelectionKey = "TTS_ModelSelection"
    private static let kokoroSpeakerIdKey = "TTS_KokoroSpeakerId"
    private static let matchaNoiseScaleKey = "TTS_MatchaNoiseScale"
    private static let matchaLengthScaleKey = "TTS_MatchaLengthScale"

    func save() {
        UserDefaults.standard.set(speechRate, forKey: Self.speechRateKey)
        UserDefaults.standard.set(pitchMultiplier, forKey: Self.pitchMultiplierKey)
        UserDefaults.standard.set(selectedVoiceIdentifier, forKey: Self.voiceIdentifierKey)
        UserDefaults.standard.set(preferredLanguageIdentifier, forKey: Self.preferredLanguageKey)
        UserDefaults.standard.set(modelSelection.rawValue, forKey: Self.modelSelectionKey)
        UserDefaults.standard.set(offlineModelType.rawValue, forKey: Self.offlineModelTypeKey)
        UserDefaults.standard.set(kokoroSpeakerId, forKey: Self.kokoroSpeakerIdKey)
        UserDefaults.standard.set(matchaNoiseScale, forKey: Self.matchaNoiseScaleKey)
        UserDefaults.standard.set(matchaLengthScale, forKey: Self.matchaLengthScaleKey)

        UserDefaults.standard.set(speechRate, forKey: Self.legacySpeechRateKey)
        UserDefaults.standard.set(pitchMultiplier, forKey: Self.legacyPitchMultiplierKey)
        UserDefaults.standard.set(selectedVoiceIdentifier, forKey: Self.legacyVoiceIdentifierKey)
    }

    static func load() -> TTSSettings {
        let defaults = UserDefaults.standard
        let modelType = defaults.string(forKey: offlineModelTypeKey)
            .flatMap { OfflineModelType(rawValue: $0) }
            ?? .kokoroZH
        let modelSelection: TTSModelSelection
        if let raw = defaults.string(forKey: modelSelectionKey),
           let selection = TTSModelSelection(rawValue: raw) {
            modelSelection = selection
        } else {
            modelSelection = .autoEdge
        }
        let syncedOfflineType = modelSelection.offlineModelType ?? modelType
        return TTSSettings(
            speechRate: floatValue(forKey: speechRateKey, legacyKey: legacySpeechRateKey, defaultValue: 0.5),
            pitchMultiplier: floatValue(forKey: pitchMultiplierKey, legacyKey: legacyPitchMultiplierKey, defaultValue: 1.0),
            selectedVoiceIdentifier: defaults.string(forKey: voiceIdentifierKey)
                ?? defaults.string(forKey: legacyVoiceIdentifierKey)
                ?? defaultVoiceIdentifier,
            preferredLanguageIdentifier: defaults.string(forKey: preferredLanguageKey)
                ?? inferredLanguageIdentifier(from: defaults.string(forKey: voiceIdentifierKey) ?? defaults.string(forKey: legacyVoiceIdentifierKey))
                ?? TTSLanguage.chinese.rawValue,
            isNeuralVoiceEnabled: true,
            modelSelection: modelSelection,
            offlineModelType: syncedOfflineType,
            kokoroSpeakerId: intValue(
                forKey: kokoroSpeakerIdKey,
                defaultValue: TTSSettings.defaultKokoroSpeakerId
            ),
            matchaNoiseScale: floatValue(forKey: matchaNoiseScaleKey, defaultValue: TTSSettings.defaultMatchaNoiseScale),
            matchaLengthScale: floatValue(forKey: matchaLengthScaleKey, defaultValue: TTSSettings.defaultMatchaLengthScale)
        )
    }

    private static func intValue(forKey key: String, defaultValue: Int) -> Int {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: key) != nil {
            return defaults.integer(forKey: key)
        }
        return defaultValue
    }

    private static func floatValue(forKey key: String, defaultValue: Float) -> Float {
        floatValue(forKey: key, legacyKey: key + "_unused", defaultValue: defaultValue)
    }

    private static func floatValue(forKey key: String, legacyKey: String, defaultValue: Float) -> Float {
        let defaults = UserDefaults.standard

        if let value = defaults.object(forKey: key) as? Float {
            return value
        }

        if let value = defaults.object(forKey: key) as? Double {
            return Float(value)
        }

        if let value = defaults.object(forKey: legacyKey) as? Float {
            return value
        }

        if let value = defaults.object(forKey: legacyKey) as? Double {
            return Float(value)
        }

        return defaultValue
    }

    private static func inferredLanguageIdentifier(from voiceIdentifier: String?) -> String? {
        guard let voiceIdentifier else { return nil }

        if voiceIdentifier.localizedCaseInsensitiveContains("zh") {
            return TTSLanguage.chinese.rawValue
        }

        if voiceIdentifier.localizedCaseInsensitiveContains("en") {
            return TTSLanguage.english.rawValue
        }

        return nil
    }
}