import Foundation
import Combine

@MainActor
final class ReaderViewModel: ObservableObject {
    @Published var book: Book
    @Published var chapters: [Chapter] = []
    @Published var currentChapterIndex: Int = 0
    @Published var currentContent: String = ""
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var ttsProgress: Double = 0

    private let parserService = BookParserService.shared
    private let ttsService = TTSService.shared
    private let database = DatabaseManager.shared
    private var cancellables = Set<AnyCancellable>()

    var isTTSPlaying: Bool { ttsService.isPlaying }
    var isTTSPaused: Bool { ttsService.isPaused }

    init(book: Book) {
        self.book = book
        setupTTSBindings()
    }

    private func setupTTSBindings() {
        ttsService.$currentProgress
            .receive(on: DispatchQueue.main)
            .assign(to: &$ttsProgress)

        ttsService.$currentChapterIndex
            .receive(on: DispatchQueue.main)
            .assign(to: &$currentChapterIndex)
    }

    func loadContent() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let parsedBook = try parserService.parseBook(at: book.filePath, format: book.format)
                self.chapters = parsedBook.chapters

                if book.currentProgress > 0, let chapterIndex = findChapterForProgress(book.currentProgress) {
                    currentChapterIndex = chapterIndex
                }

                updateCurrentContent()

                ttsService.loadChapters(chapters)

                if book.currentProgress > 0 {
                    let sentenceIndex = ttsService.findFirstSentenceIndex(for: currentChapterIndex)
                    ttsService.speak(from: currentChapterIndex, sentenceIndex: sentenceIndex)
                }

            } catch {
                errorMessage = "加载内容失败: \(error.localizedDescription)"
            }
            isLoading = false
        }
    }

    private func findChapterForProgress(_ progress: Double) -> Int? {
        guard !chapters.isEmpty else { return nil }
        let totalCharacters = chapters.reduce(0) { $0 + $1.content.count }
        let targetCharacters = Int(progress * Double(totalCharacters))

        var accumulated = 0
        for (index, chapter) in chapters.enumerated() {
            accumulated += chapter.content.count
            if Double(accumulated) >= progress * Double(totalCharacters) {
                return index
            }
        }
        return nil
    }

    func selectChapter(_ index: Int) {
        guard index >= 0, index < chapters.count else { return }
        currentChapterIndex = index
        updateCurrentContent()
        saveProgress()
    }

    private func updateCurrentContent() {
        guard currentChapterIndex < chapters.count else { return }
        currentContent = chapters[currentChapterIndex].content
    }

    private func saveProgress() {
        guard !chapters.isEmpty else { return }

        let totalCharacters = chapters.reduce(0) { $0 + $1.content.count }
        let charactersBeforeCurrentChapter = chapters.prefix(currentChapterIndex).reduce(0) { $0 + $1.content.count }
        let progress = Double(charactersBeforeCurrentChapter) / Double(max(1, totalCharacters))

        do {
            try database.updateProgress(bookId: book.id, progress: progress)
        } catch {
            print("Save progress failed: \(error)")
        }
    }

    func toggleTTS() {
        if ttsService.isPlaying {
            ttsService.pause()
        } else if ttsService.isPaused {
            ttsService.resume()
        } else {
            let sentenceIndex = ttsService.findFirstSentenceIndex(for: currentChapterIndex)
            ttsService.speak(from: currentChapterIndex, sentenceIndex: sentenceIndex) { [weak self] progress, chapter, _ in
                Task { @MainActor in
                    self?.currentChapterIndex = chapter
                    self?.ttsProgress = progress
                }
            }
        }
    }

    func stopTTS() {
        ttsService.stop()
    }

    func skipToNextSentence() {
        ttsService.skipToNextSentence()
    }

    func skipToPreviousSentence() {
        ttsService.skipToPreviousSentence()
    }

    func seekTTS(to progress: Double) {
        ttsService.seekToProgress(progress)
    }

    func updateTTSSettings(_ settings: TTSSettings) {
        ttsService.updateSettings(settings)
    }

    func getTTSSettings() -> TTSSettings {
        return ttsService.getCurrentSettings()
    }

    func cleanup() {
        ttsService.stop()
        saveProgress()
    }
}