import AVFoundation
import Combine

final class TTSService: NSObject, ObservableObject {
    static let shared = TTSService()

    @Published var isPlaying = false
    @Published var isPaused = false
    @Published var currentProgress: Double = 0
    @Published var currentChapterIndex: Int = 0
    @Published var currentSentenceIndex: Int = 0
    @Published var availableVoices: [AVSpeechSynthesisVoice] = []
    @Published var currentWordRange: NSRange?

    private let synthesizer = AVSpeechSynthesizer()
    private var settings = TTSSettings.load()
    private var chapters: [Chapter] = []
    private var allSentences: [String] = []
    private var totalCharacters: Int = 0
    private var spokenCharacters: Int = 0

    private var progressUpdateHandler: ((Double, Int, Int) -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
        loadAvailableVoices()
    }

    private func loadAvailableVoices() {
        let locales: [Locale] = [
            Locale(identifier: "zh-CN"),
            Locale(identifier: "en-US"),
            Locale(identifier: "zh-TW")
        ]

        availableVoices = AVSpeechSynthesisVoice.speechVoices().filter { voice in
            locales.contains(where: { $0.identifier == voice.language || voice.language.starts(with: $0.language) })
        }.sorted { $0.language < $1.language }
    }

    func loadChapters(_ chapters: [Chapter]) {
        self.chapters = chapters
        allSentences = []
        totalCharacters = 0

        for chapter in chapters {
            let sentences = splitIntoSentences(chapter.content)
            allSentences.append(contentsOf: sentences)
            totalCharacters += chapter.content.count
        }
    }

    func speak(
        from chapterIndex: Int = 0,
        sentenceIndex: Int = 0,
        onProgressUpdate: ((Double, Int, Int) -> Void)? = nil
    ) {
        self.progressUpdateHandler = onProgressUpdate
        self.currentChapterIndex = chapterIndex
        self.currentSentenceIndex = sentenceIndex
        self.spokenCharacters = calculateCharactersBefore(chapterIndex: chapterIndex, sentenceIndex: sentenceIndex)

        guard chapterIndex < chapters.count else { return }

        if sentenceIndex < allSentences.count {
            speakSentence(at: sentenceIndex)
        }
    }

    private func speakSentence(at index: Int) {
        guard index < allSentences.count else {
            isPlaying = false
            return
        }

        let sentence = allSentences[index].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sentence.isEmpty else {
            speakSentence(at: index + 1)
            return
        }

        let utterance = AVSpeechUtterance(string: sentence)
        utterance.rate = settings.speechRate
        utterance.pitchMultiplier = settings.pitchMultiplier
        utterance.voice = voiceForCurrentSettings()

        isPlaying = true
        isPaused = false
        currentSentenceIndex = index
        currentProgress = Double(spokenCharacters) / Double(max(1, totalCharacters))

        synthesizer.speak(utterance)
    }

    private func voiceForCurrentSettings() -> AVSpeechSynthesisVoice? {
        if let voice = AVSpeechSynthesisVoice(identifier: settings.selectedVoiceIdentifier) {
            return voice
        }

        let preferredLanguage = settings.selectedVoiceIdentifier.hasPrefix("zh") ? "zh-CN" : "en-US"
        return AVSpeechSynthesisVoice.speechVoices().first { voice in
            voice.language.starts(with: preferredLanguage)
        }
    }

    func pause() {
        if synthesizer.isSpeaking {
            synthesizer.pauseSpeaking(at: .immediate)
            isPaused = true
            isPlaying = false
        }
    }

    func resume() {
        if isPaused {
            synthesizer.continueSpeaking()
            isPaused = false
            isPlaying = true
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isPlaying = false
        isPaused = false
        currentProgress = 0
    }

    func skipToNextSentence() {
        synthesizer.stopSpeaking(at: .immediate)
        speakSentence(at: currentSentenceIndex + 1)
    }

    func skipToPreviousSentence() {
        synthesizer.stopSpeaking(at: .immediate)
        let newIndex = max(0, currentSentenceIndex - 1)
        speakSentence(at: newIndex)
    }

    func skipToChapter(_ index: Int) {
        guard index < chapters.count else { return }
        synthesizer.stopSpeaking(at: .immediate)
        speak(chapterIndex: index, sentenceIndex: findFirstSentenceIndex(for: index))
    }

    func seekToProgress(_ progress: Double) {
        let targetCharacters = Int(progress * Double(totalCharacters))
        let (targetChapter, targetSentence) = findChapterAndSentence(for: targetCharacters)

        synthesizer.stopSpeaking(at: .immediate)
        speak(chapterIndex: targetChapter, sentenceIndex: targetSentence)
    }

    private func findFirstSentenceIndex(for chapterIndex: Int) -> Int {
        var count = 0
        for i in 0..<chapterIndex {
            count += splitIntoSentences(chapters[i].content).count
        }
        return count
    }

    private func calculateCharactersBefore(chapterIndex: Int, sentenceIndex: Int) -> Int {
        var count = 0
        for i in 0..<chapterIndex {
            count += chapters[i].content.count
        }
        count += findSentenceStartIndex(sentenceIndex)
        return count
    }

    private func findSentenceStartIndex(_ sentenceIndex: Int) -> Int {
        var count = 0
        for i in 0..<min(sentenceIndex, allSentences.count) {
            count += allSentences[i].count
        }
        return count
    }

    private func findChapterAndSentence(for characterIndex: Int) -> (Int, Int) {
        var accumulated = 0
        for (chapterIndex, chapter) in chapters.enumerated() {
            let chapterSentences = splitIntoSentences(chapter.content)
            for (sentenceIndex, sentence) in chapterSentences.enumerated() {
                accumulated += sentence.count
                if accumulated >= characterIndex {
                    let globalSentenceIndex = findFirstSentenceIndex(for: chapterIndex) + sentenceIndex
                    return (chapterIndex, globalSentenceIndex)
                }
            }
        }
        return (0, 0)
    }

    private func splitIntoSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { substring, _, _, _ in
            if let sentence = substring?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty {
                sentences.append(sentence)
            }
        }

        if sentences.isEmpty {
            let components = text.components(separatedBy: CharacterSet.newlines)
            for component in components {
                let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    sentences.append(trimmed)
                }
            }
        }

        return sentences
    }

    func updateSettings(_ newSettings: TTSSettings) {
        settings = newSettings
        settings.save()
    }

    func getCurrentSettings() -> TTSSettings {
        return settings
    }
}

extension TTSService: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        spokenCharacters += utterance.speechString.count
        currentProgress = Double(spokenCharacters) / Double(max(1, totalCharacters))

        speakSentence(at: currentSentenceIndex + 1)

        let (chapter, sentence) = findChapterAndSentence(for: spokenCharacters)
        progressUpdateHandler?(currentProgress, chapter, sentence)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        if !isPaused {
            isPlaying = false
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        isPaused = true
        isPlaying = false
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        isPaused = false
        isPlaying = true
    }
}