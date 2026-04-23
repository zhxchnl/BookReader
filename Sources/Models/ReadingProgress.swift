import Foundation

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

struct TTSSettings: Codable {
    var speechRate: Float
    var pitchMultiplier: Float
    var selectedVoiceIdentifier: String
    var isNeuralVoiceEnabled: Bool

    static let `default` = TTSSettings(
        speechRate: 0.5,
        pitchMultiplier: 1.0,
        selectedVoiceIdentifier: "com.apple.voice.premium.zh-CN",
        isNeuralVoiceEnabled: true
    )

    private static let speechRateKey = "TTS_SpeechRate"
    private static let pitchMultiplierKey = "TTS_PitchMultiplier"
    private static let voiceIdentifierKey = "TTS_VoiceIdentifier"

    func save() {
        UserDefaults.standard.set(speechRate, forKey: Self.speechRateKey)
        UserDefaults.standard.set(pitchMultiplier, forKey: Self.pitchMultiplierKey)
        UserDefaults.standard.set(selectedVoiceIdentifier, forKey: Self.voiceIdentifierKey)
    }

    static func load() -> TTSSettings {
        let defaults = UserDefaults.standard
        return TTSSettings(
            speechRate: defaults.object(forKey: speechRateKey) as? Float ?? 0.5,
            pitchMultiplier: defaults.object(forKey: pitchMultiplierKey) as? Float ?? 1.0,
            selectedVoiceIdentifier: defaults.string(forKey: voiceIdentifierKey) ?? "com.apple.voice.premium.zh-CN",
            isNeuralVoiceEnabled: true
        )
    }
}