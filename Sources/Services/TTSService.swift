import AVFoundation
import Combine
import CryptoKit
import Foundation
import MediaPlayer
import Network

@MainActor
final class TTSService: ObservableObject, @unchecked Sendable {
    static let shared = TTSService()

    @Published var isPlaying = false
    @Published var isPaused = false
    @Published var currentProgress: Double = 0
    @Published var currentChapterIndex: Int = 0
    @Published var currentSentenceIndex: Int = 0
    @Published private(set) var activeBookID: UUID?
    @Published var availableVoices: [AVSpeechSynthesisVoice] = []
    @Published var currentWordRange: NSRange?
    @Published var lastErrorMessage: String?
    @Published private(set) var isSentenceIndexLoading = false

    private var settings = TTSSettings.load()
    private let edgeProvider = EdgeTTSProvider()
    private let localProvider = LocalTTSProvider()
    private let audioPlayer = TTSAudioPlayer()
    private var _sherpaProviders: [OfflineModelType: SherpaOnnxTTSProvider] = [:]
    private let adaptiveManager = TTSModelAdaptiveManager.shared

    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.bookreader.tts.network")

    /// 当前是否具备网络（用于优先 Edge TTS）
    private(set) var isNetworkReachable = true

    private var chapters: [Chapter] = []
    private var allSentences: [String] = []
    private var sentenceChapterIndexes: [Int] = []
    private var sentenceStartCharacters: [Int] = []
    private var totalCharacters: Int = 0
    private var spokenCharacters: Int = 0
    private var shouldAutoAdvance = false

    private var prefetchTasks: [Int: Task<URL, Error>] = [:]
    private var pipelineGeneration = 0
    private var loadChaptersTaskGeneration = 0
    private var edgeRetryNotBefore: Date?

    private var nowPlayingTitle = "朗读中"
    private var nowPlayingArtist = "书阅读"

    private var progressUpdateHandler: ((Double, Int, Int) -> Void)?

    private let prefetchAhead = 5

    init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.isNetworkReachable = path.status == .satisfied
            }
        }
        pathMonitor.start(queue: monitorQueue)

        audioPlayer.onPlaybackFinished = { [weak self] in
            Task { @MainActor in
                self?.handleSentencePlaybackFinished()
            }
        }

        loadAvailableVoices()
        setupRemoteTransportControls()
        setupInterruptionHandling()
    }

    private func loadAvailableVoices() {
        #if targetEnvironment(simulator)
        // iOS Simulator (especially newer runtimes) may print internal decode errors
        // when enumerating system voices/locales. We keep simulator voice list empty and
        // rely on default language voices to avoid noisy false-positive logs in tests.
        availableVoices = []
        return
        #endif

        availableVoices = AVSpeechSynthesisVoice.speechVoices().filter { voice in
            TTSService.isSupportedVoiceLanguage(voice.languageMinimalIdentifier)
        }.sorted { $0.languageMinimalIdentifier < $1.languageMinimalIdentifier }
    }

    private func setupInterruptionHandling() {
        #if os(iOS)
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleAudioInterruption(notification)
            }
        }
        #endif
    }

    private func handleAudioInterruption(_ notification: Notification) {
        #if os(iOS)
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            if isPlaying {
                audioPlayer.pause()
                isPaused = true
                isPlaying = false
                shouldAutoAdvance = false
                updateNowPlayingInfo()
            }
        case .ended:
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume), isPaused {
                shouldAutoAdvance = true
                audioPlayer.resume()
                isPaused = false
                isPlaying = true
                updateNowPlayingInfo()
            }
        @unknown default:
            break
        }
        #endif
    }

    func loadChapters(_ chapters: [Chapter], for bookID: UUID) {
        loadChaptersTaskGeneration += 1
        let taskGeneration = loadChaptersTaskGeneration

        activeBookID = bookID
        self.chapters = chapters
        allSentences = []
        sentenceChapterIndexes = []
        sentenceStartCharacters = []
        totalCharacters = 0
        isSentenceIndexLoading = true

        let contents = chapters.map(\.content)
        let fingerprint = SentenceIndexBuilder.fingerprint(chapterContents: contents)
        let indexURL = sentenceIndexFileURL(for: bookID)

        Task {
            let index: SentenceIndex = await Task.detached(priority: .userInitiated) {
                if let cached = SentenceIndexBuilder.loadCached(bookID: bookID, fileURL: indexURL, expectedFingerprint: fingerprint) {
                    return cached
                }
                let split = SentenceIndexBuilder.split(chapterContents: contents)
                let built = SentenceIndex(
                    bookID: bookID,
                    fingerprint: fingerprint,
                    sentences: split.sentences,
                    chapterIndexes: split.chapterIndexes,
                    startCharacters: split.startCharacters,
                    totalCharacters: split.totalCharacters
                )
                SentenceIndexBuilder.save(built, to: indexURL)
                return built
            }.value

            guard taskGeneration == loadChaptersTaskGeneration else { return }
            applyLoadedSentenceIndex(expectedBookID: bookID, index: index)
        }
    }

    /// 进入阅读页后预热：合成首条非空句（若尚无缓存），加速稍后点击朗读。
    func warmupIfNeeded() {
        guard !allSentences.isEmpty else { return }
        let warmupText = allSentences.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? "。"
        let provider = pickPrimaryProvider()
        let offlineModel = primaryOfflineModel()
        let url = cacheURL(for: warmupText, provider: provider, offlineModel: offlineModel)
        guard FileManager.default.fileExists(atPath: url.path) == false else { return }
        Task(priority: .background) { [weak self] in
            guard let self else { return }
            _ = try? await provider.synthesizeToFile(text: warmupText, settings: self.settings, outputURL: url)
        }
    }

    private func primaryOfflineModel() -> OfflineModelType? {
        switch settings.modelSelection {
        case .autoLocal, .autoOnline:
            return localModelFallbackOrder().first { sherpaProvider(for: $0) != nil }
        case .autoEdge:
            return .matchaZH
        case .kokoro, .matcha:
            return settings.modelSelection.offlineModelType
        case .edge, .system:
            return nil
        }
    }

    /// AUTO 模式下从当前活跃本地模型起依次降级；固定本地模型仅返回该模型。
    private func localModelFallbackOrder() -> [OfflineModelType] {
        let priority = TTSModelSelection.localModelPriority
        switch settings.modelSelection {
        case .autoLocal, .autoOnline:
            guard let startIdx = priority.firstIndex(of: settings.offlineModelType) else {
                return priority
            }
            return Array(priority[startIdx...])
        case .autoEdge:
            return [.matchaZH]
        case .kokoro, .matcha:
            if let model = settings.modelSelection.offlineModelType {
                return [model]
            }
            return priority
        case .edge, .system:
            return []
        }
    }

    private func applyLoadedSentenceIndex(expectedBookID: UUID, index: SentenceIndex) {
        guard activeBookID == expectedBookID else { return }
        allSentences = index.sentences
        sentenceChapterIndexes = index.chapterIndexes
        sentenceStartCharacters = index.startCharacters
        totalCharacters = index.totalCharacters
        isSentenceIndexLoading = false
        warmupIfNeeded()
        warmupMatchaIfNeeded()
    }

    /// AUTO_EDGE 模式下预初始化 Matcha 模型（后台进行），缩短 Edge 超时后切换延迟。
    private func warmupMatchaIfNeeded() {
        guard settings.modelSelection == .autoEdge else { return }
        guard SherpaOnnxTTSProvider.isModelDownloaded(modelId: OfflineModelType.matchaZH.rawValue) else { return }
        guard sherpaProvider(for: .matchaZH) != nil else { return }

        Task(priority: .background) { [weak self] in
            guard let self else { return }
            let warmupText = "你好"
            let url = self.cacheDirectory().appendingPathComponent("matcha_warmup.wav")
            if FileManager.default.fileExists(atPath: url.path) { return }
            _ = try? await self.synthesizeSpecificLocalModel(text: warmupText, model: .matchaZH)
        }
    }

    private func sentenceIndexFileURL(for bookID: UUID) -> URL {
        let dir = cacheDirectory().appendingPathComponent("idx", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(bookID.uuidString).json")
    }

    func speak(
        from chapterIndex: Int = 0,
        sentenceIndex: Int = 0,
        onProgressUpdate: ((Double, Int, Int) -> Void)? = nil
    ) {
        shouldAutoAdvance = true
        progressUpdateHandler = onProgressUpdate
        currentChapterIndex = chapterIndex
        currentSentenceIndex = sentenceIndex
        spokenCharacters = calculateCharactersBefore(chapterIndex: chapterIndex, sentenceIndex: sentenceIndex)

        guard chapterIndex < chapters.count, !allSentences.isEmpty else {
            shouldAutoAdvance = false
            return
        }

        if sentenceIndex < allSentences.count {
            beginSpeaking(fromSentence: sentenceIndex)
        } else {
            shouldAutoAdvance = false
        }
    }

    func speak(
        fromProgress progress: Double,
        onProgressUpdate: ((Double, Int, Int) -> Void)? = nil
    ) {
        let index = globalCharacterIndex(forProgress: progress)
        speak(fromGlobalCharacterIndex: index, onProgressUpdate: onProgressUpdate)
    }

    func speak(
        fromGlobalCharacterIndex characterIndex: Int,
        onProgressUpdate: ((Double, Int, Int) -> Void)? = nil
    ) {
        guard totalCharacters > 0 else {
            shouldAutoAdvance = false
            return
        }
        let targetCharacters = min(max(characterIndex, 0), totalCharacters)
        let (targetChapter, targetSentence) = findChapterAndSentence(for: targetCharacters)

        shouldAutoAdvance = false
        cancelPipelineAndPlayback()
        speak(from: targetChapter, sentenceIndex: targetSentence, onProgressUpdate: onProgressUpdate)
    }

    func speak(
        fromVisibleGlobalCharacterIndex characterIndex: Int,
        onProgressUpdate: ((Double, Int, Int) -> Void)? = nil
    ) {
        guard totalCharacters > 0 else {
            shouldAutoAdvance = false
            return
        }
        let targetCharacters = min(max(characterIndex, 0), totalCharacters)
        let (targetChapter, targetSentence) = findChapterAndSentenceStartingAtOrAfter(for: targetCharacters)

        shouldAutoAdvance = false
        cancelPipelineAndPlayback()
        speak(from: targetChapter, sentenceIndex: targetSentence, onProgressUpdate: onProgressUpdate)
    }

    func pause() {
        guard isPlaying || audioPlayer.isPlaying else { return }
        shouldAutoAdvance = false
        audioPlayer.pause()
        isPaused = true
        isPlaying = false
        updateNowPlayingInfo()
    }

    func resume() {
        guard isPaused else { return }
        shouldAutoAdvance = true
        audioPlayer.resume()
        isPaused = false
        isPlaying = true
        updateNowPlayingInfo()
    }

    func stop() {
        pipelineGeneration += 1
        loadChaptersTaskGeneration += 1
        shouldAutoAdvance = false
        cancelPipelineAndPlayback()
        progressUpdateHandler = nil
        activeBookID = nil
        isPlaying = false
        isPaused = false
        currentProgress = 0
        isSentenceIndexLoading = false
        clearNowPlayingInfo()
        lastErrorMessage = nil
        audioPlayer.deactivateSessionIfIdle()
    }

    func skipToNextSentence() {
        let next = min(currentSentenceIndex + 1, max(0, allSentences.count - 1))
        shouldAutoAdvance = true
        cancelPipelineAndPlayback()
        beginSpeaking(fromSentence: next)
    }

    func skipToPreviousSentence() {
        let prev = max(0, currentSentenceIndex - 1)
        shouldAutoAdvance = true
        cancelPipelineAndPlayback()
        beginSpeaking(fromSentence: prev)
    }

    func skipToChapter(_ index: Int) {
        guard index < chapters.count else { return }
        let sentenceIndex = findFirstSentenceIndex(for: index)
        shouldAutoAdvance = true
        cancelPipelineAndPlayback()
        speak(from: index, sentenceIndex: sentenceIndex, onProgressUpdate: progressUpdateHandler)
    }

    func seekToProgress(_ progress: Double) {
        let targetCharacters = globalCharacterIndex(forProgress: progress)
        let (targetChapter, targetSentence) = findChapterAndSentence(for: targetCharacters)

        shouldAutoAdvance = true
        cancelPipelineAndPlayback()
        speak(from: targetChapter, sentenceIndex: targetSentence, onProgressUpdate: progressUpdateHandler)
    }

    func findFirstSentenceIndex(for chapterIndex: Int) -> Int {
        sentenceChapterIndexes.firstIndex(of: chapterIndex) ?? 0
    }

    func updateSettings(_ newSettings: TTSSettings) {
        settings = newSettings
        settings.save()
        _sherpaProviders.removeAll()
    }

    func getCurrentSettings() -> TTSSettings {
        settings
    }

    func updateNowPlayingMetadata(title: String, author: String) {
        nowPlayingTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "朗读中" : title
        nowPlayingArtist = author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "书阅读" : author
        if isPlaying || isPaused {
            updateNowPlayingInfo()
        }
    }

    // MARK: - Private pipeline

    private func beginSpeaking(fromSentence index: Int) {
        lastErrorMessage = nil
        pipelineGeneration += 1
        let generation = pipelineGeneration

        cancelPrefetchTasksOnly()
        audioPlayer.stopSilently()

        guard index < allSentences.count else {
            finishPlayback()
            return
        }

        shouldAutoAdvance = true
        currentSentenceIndex = index
        currentChapterIndex = sentenceChapterIndexes[safe: index] ?? currentChapterIndex
        spokenCharacters = findSentenceStartIndex(index)
        currentProgress = Double(spokenCharacters) / Double(max(1, totalCharacters))
        isPlaying = true
        isPaused = false
        updateNowPlayingInfo()

        prefetchAround(index)
        Task { await self.playSentence(at: index, generation: generation) }
    }

    private func playSentence(at index: Int, generation: Int) async {
        guard generation == pipelineGeneration, shouldAutoAdvance else { return }
        guard index < allSentences.count else {
            finishPlayback()
            return
        }

        let trimmed = allSentences[index].trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            advancePastEmptySentences(from: index, generation: generation)
            return
        }

        do {
            let startTime = Date()
            let url = try await synthesizeSentenceWithFallback(at: index)
            let duration = Date().timeIntervalSince(startTime)
            guard generation == pipelineGeneration, shouldAutoAdvance else { return }

            currentSentenceIndex = index
            currentChapterIndex = sentenceChapterIndexes[safe: index] ?? currentChapterIndex
            spokenCharacters = findSentenceStartIndex(index)
            currentProgress = Double(spokenCharacters) / Double(max(1, totalCharacters))
            updateNowPlayingInfo()

            // 更新 adaptive manager 并在需要时自动切换模型
            let audioDuration = audioPlayer.currentAudioDuration
            if let recommendation = adaptiveManager.recordSynthesis(duration: duration, audioDuration: audioDuration) {
                handleModelSwitch(recommendation)
            }

            try audioPlayer.play(url: url)
            isPlaying = true
            isPaused = false
            prefetchAround(index + 1)
        } catch {
            lastErrorMessage = error.localizedDescription
            if isNetworkReachable == false {
                lastErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            finishPlayback()
        }
    }

    private func handleSentencePlaybackFinished() {
        guard shouldAutoAdvance, !isPaused else {
            isPlaying = false
            updateNowPlayingInfo()
            return
        }

        let idx = currentSentenceIndex
        let next = idx + 1

        spokenCharacters = sentenceStartCharacters[safe: next] ?? totalCharacters
        currentProgress = Double(spokenCharacters) / Double(max(1, totalCharacters))

        let (chapter, sentenceIdx) = findChapterAndSentence(for: spokenCharacters)
        currentChapterIndex = chapter
        progressUpdateHandler?(currentProgress, chapter, sentenceIdx)
        updateNowPlayingInfo()

        if next >= allSentences.count {
            finishPlayback()
            return
        }

        currentSentenceIndex = next
        let gen = pipelineGeneration
        prefetchAround(next)
        Task { await self.playSentence(at: next, generation: gen) }
    }

    /// 跳过空句子（无需播放音频）
    private func advancePastEmptySentences(from index: Int, generation: Int) {
        guard generation == pipelineGeneration else { return }
        var next = index
        while next < allSentences.count,
              allSentences[next].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            next += 1
        }
        guard next < allSentences.count else {
            finishPlayback()
            return
        }
        currentSentenceIndex = next
        spokenCharacters = findSentenceStartIndex(next)
        currentProgress = Double(spokenCharacters) / Double(max(1, totalCharacters))
        let (chapter, sentenceIdx) = findChapterAndSentence(for: spokenCharacters)
        currentChapterIndex = chapter
        progressUpdateHandler?(currentProgress, chapter, sentenceIdx)
        updateNowPlayingInfo()
        prefetchAround(next)
        Task { await self.playSentence(at: next, generation: generation) }
    }

    private func finishPlayback() {
        isPlaying = false
        isPaused = false
        shouldAutoAdvance = false
        cancelPrefetchTasksOnly()
        audioPlayer.stopSilently()
        currentProgress = totalCharacters > 0 ? 1 : currentProgress
        updateNowPlayingInfo()
        audioPlayer.deactivateSessionIfIdle()
    }

    private func cancelPipelineAndPlayback() {
        cancelPrefetchTasksOnly()
        audioPlayer.stopSilently()
    }

    private func cancelPrefetchTasksOnly() {
        for (_, task) in prefetchTasks {
            task.cancel()
        }
        prefetchTasks.removeAll()
    }

    private func prefetchAround(_ startIndex: Int) {
        let upper = min(allSentences.count, startIndex + prefetchAhead)
        for i in startIndex..<upper {
            if prefetchTasks[i] == nil {
                prefetchTasks[i] = makeSynthesisTask(at: i)
            }
        }
    }

    private func makeSynthesisTask(at index: Int) -> Task<URL, Error> {
        Task {
            let text = allSentences[index]
            return try await synthesizeWithModelSelection(text: text)
        }
    }

    private func synthesizeSentenceWithFallback(at index: Int) async throws -> URL {
        if let task = prefetchTasks.removeValue(forKey: index) {
            do {
                return try await task.value
            } catch {
                return try await synthesizeWithModelSelection(text: allSentences[index])
            }
        }
        return try await synthesizeWithModelSelection(text: allSentences[index])
    }

    private func synthesizeWithModelSelection(text: String) async throws -> URL {
        switch settings.modelSelection {
        case .autoLocal:
            return try await synthesizeLocalChain(text: text, includeEdge: false)
        case .autoOnline:
            return try await synthesizeLocalChain(text: text, includeEdge: true)
        case .autoEdge:
            return try await synthesizeEdgeThenMatcha(text: text)
        case .kokoro, .matcha:
            guard let model = settings.modelSelection.offlineModelType else {
                return try await synthesizeSystemOnly(text: text)
            }
            return try await synthesizeSpecificLocalModel(text: text, model: model)
        case .edge:
            return try await synthesizeEdgeOnly(text: text)
        case .system:
            return try await synthesizeSystemOnly(text: text)
        }
    }

    /// 优先 Edge TTS，超时或失败时降级为 Matcha 本地模型，系统 TTS 兜底。
    /// 整个 fallback 链跑在 detached 任务上，避免阻塞调用方 actor（包括 @MainActor），
    /// 保证朗读提示弹窗始终能正常显示与点击。
    private func synthesizeEdgeThenMatcha(text: String) async throws -> URL {
        let edgeProviderRef = edgeProvider
        let settingsRef = settings
        let networkReachable = isNetworkReachable
        let edgeRetryNotBeforeRef = edgeRetryNotBefore

        return try await Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { throw TTSEngineError.synthesisFailed("TTSService 已释放") }

            let shouldTryEdge = networkReachable
                && (edgeRetryNotBeforeRef.map { Date() >= $0 } ?? true)

            var lastEdgeError: String?

            if shouldTryEdge {
                do {
                    let url = await self.cacheURL(for: text, provider: edgeProviderRef)
                    return try await edgeProviderRef.synthesizeToFile(text: text, settings: settingsRef, outputURL: url)
                } catch {
                    lastEdgeError = error.localizedDescription
                }
            }

            // 降级：Matcha 本地模型
            if let provider = await self.sherpaProvider(for: .matchaZH) {
                let url = await self.cacheURL(for: text, provider: provider, offlineModel: .matchaZH)
                do {
                    return try await provider.synthesizeToFile(text: text, settings: settingsRef, outputURL: url)
                } catch {
                    let matchaError = error.localizedDescription
                    // 拼接错误信息（Edge 失败 + Matcha 失败）
                    let summary: String
                    if let edgeErr = lastEdgeError {
                        summary = "Edge TTS 与 Matcha 均不可用（\(edgeErr) / \(matchaError)），已尝试系统语音"
                    } else {
                        summary = "Matcha 朗读失败（\(matchaError)），已尝试系统语音"
                    }
                    await self.publishError(summary)
                }
            } else if let edgeErr = lastEdgeError {
                await self.publishError("Edge TTS 不可用（\(edgeErr)），且 Matcha 模型未就绪")
            } else {
                await self.publishError("无网络连接，且 Matcha 模型未就绪")
            }

            // 最终兜底：系统 TTS
            return try await self.runSystemOnlyFallback(text: text, settings: settingsRef)
        }.value
    }

    /// 跨 actor 安全地发布错误信息到 @MainActor 上的 @Published 属性。
    @MainActor
    private func publishError(_ message: String) {
        lastErrorMessage = message
    }

    /// detached 任务中调用：执行系统 TTS 合成。
    nonisolated private func runSystemOnlyFallback(text: String, settings: TTSSettings) async throws -> URL {
        let url = await cacheURL(for: text, provider: localProvider)
        return try await localProvider.synthesizeToFile(text: text, settings: settings, outputURL: url)
    }

    /// 按品质顺序尝试本地模型，可选 Edge，最后系统 TTS 兜底。
    /// 整个 fallback 链跑在 detached 任务上，避免阻塞 @MainActor。
    private func synthesizeLocalChain(text: String, includeEdge: Bool) async throws -> URL {
        let models = localModelFallbackOrder()
        let settingsRef = settings
        let edgeProviderRef = edgeProvider
        let networkReachable = isNetworkReachable
        let edgeRetryNotBeforeRef = edgeRetryNotBefore

        return try await Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { throw TTSEngineError.synthesisFailed("TTSService 已释放") }

            for model in models {
                if let provider = await self.sherpaProvider(for: model) {
                    let url = await self.cacheURL(for: text, provider: provider, offlineModel: model)
                    do {
                        return try await provider.synthesizeToFile(text: text, settings: settingsRef, outputURL: url)
                    } catch {
                        await self.publishError("\(model.displayName) 不可用，尝试下一模型：\(error.localizedDescription)")
                    }
                }
            }

            let shouldTryEdge = includeEdge && networkReachable
                && (edgeRetryNotBeforeRef.map { Date() >= $0 } ?? true)
            if shouldTryEdge {
                do {
                    let url = await self.cacheURL(for: text, provider: edgeProviderRef)
                    let result = try await edgeProviderRef.synthesizeToFile(text: text, settings: settingsRef, outputURL: url)
                    await self.clearEdgeRetry()
                    return result
                } catch {
                    await self.publishError("Edge TTS 不可用，尝试系统语音：\(error.localizedDescription)")
                    await self.markEdgeRetry()
                }
            }

            return try await self.runSystemOnlyFallback(text: text, settings: settingsRef)
        }.value
    }

    @MainActor
    private func clearEdgeRetry() {
        edgeRetryNotBefore = nil
    }

    @MainActor
    private func markEdgeRetry() {
        edgeRetryNotBefore = Date().addingTimeInterval(90)
    }

    private func synthesizeSpecificLocalModel(text: String, model: OfflineModelType) async throws -> URL {
        let settingsRef = settings
        let modelId = model.rawValue
        let modelName = model.displayName
        let isDownloaded = SherpaOnnxTTSProvider.isModelDownloaded(modelId: modelId)

        return try await Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { throw TTSEngineError.synthesisFailed("TTSService 已释放") }

            guard isDownloaded else {
                let hint = "请在设置中下载 \(modelName) 模型"
                await self.publishError("\(modelName) 未就绪：\(hint)")
                return try await self.runSystemOnlyFallback(text: text, settings: settingsRef)
            }
            if let provider = await self.sherpaProvider(for: model) {
                let url = await self.cacheURL(for: text, provider: provider, offlineModel: model)
                do {
                    return try await provider.synthesizeToFile(text: text, settings: settingsRef, outputURL: url)
                } catch {
                    await self.publishError("\(modelName) 朗读失败，尝试系统语音：\(error.localizedDescription)")
                }
            } else {
                await self.publishError("\(modelName) 初始化失败，尝试系统语音")
            }
            return try await self.runSystemOnlyFallback(text: text, settings: settingsRef)
        }.value
    }

    private func synthesizeEdgeOnly(text: String) async throws -> URL {
        let settingsRef = settings
        let edgeProviderRef = edgeProvider
        let networkReachable = isNetworkReachable
        let edgeRetryNotBeforeRef = edgeRetryNotBefore

        return try await Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { throw TTSEngineError.synthesisFailed("TTSService 已释放") }

            let shouldTry = networkReachable
                && (edgeRetryNotBeforeRef.map { Date() >= $0 } ?? true)
            if shouldTry {
                do {
                    let url = await self.cacheURL(for: text, provider: edgeProviderRef)
                    let result = try await edgeProviderRef.synthesizeToFile(text: text, settings: settingsRef, outputURL: url)
                    await self.clearEdgeRetry()
                    return result
                } catch {
                    await self.publishError("Edge TTS 朗读失败，尝试系统语音：\(error.localizedDescription)")
                    await self.markEdgeRetry()
                }
            } else {
                await self.publishError("无网络连接，已切换系统语音")
            }
            return try await self.runSystemOnlyFallback(text: text, settings: settingsRef)
        }.value
    }

    private func synthesizeSystemOnly(text: String) async throws -> URL {
        let url = cacheURL(for: text, provider: localProvider)
        return try await localProvider.synthesizeToFile(text: text, settings: settings, outputURL: url)
    }

    private func pickPrimaryProvider() -> TTSProvider {
        switch settings.modelSelection {
        case .autoLocal, .autoOnline:
            for model in localModelFallbackOrder() {
                if let provider = sherpaProvider(for: model) {
                    return provider
                }
            }
            if settings.modelSelection == .autoOnline, shouldTryEdgeProvider {
                return edgeProvider
            }
            return localProvider
        case .autoEdge:
            if shouldTryEdgeProvider {
                return edgeProvider
            }
            if let provider = sherpaProvider(for: .matchaZH) {
                return provider
            }
            return localProvider
        case .kokoro, .matcha:
            if let model = settings.modelSelection.offlineModelType,
               let provider = sherpaProvider(for: model) {
                return provider
            }
            return localProvider
        case .edge:
            return shouldTryEdgeProvider ? edgeProvider : localProvider
        case .system:
            return localProvider
        }
    }

    private func sherpaProvider(for modelType: OfflineModelType) -> SherpaOnnxTTSProvider? {
        guard SherpaOnnxTTSProvider.isRuntimeSupported else { return nil }
        let modelId = modelType.rawValue
        guard SherpaOnnxTTSProvider.isModelDownloaded(modelId: modelId) else { return nil }

        if _sherpaProviders[modelType] == nil {
            let modelDir = SherpaOnnxTTSProvider.resolveModelDir(for: modelId)
            var modelSettings = settings
            modelSettings.offlineModelType = modelType
            _sherpaProviders[modelType] = SherpaOnnxTTSProvider(modelDir: modelDir, settings: modelSettings)
        }
        return _sherpaProviders[modelType]
    }

    private func handleModelSwitch(_ recommendation: TTSModelAdaptiveManager.ModelSwitchRecommendation) {
        guard settings.modelSelection.isAutoMode else { return }

        let direction: TTSModelAdaptiveManager.ModelSwitchDirection =
            recommendation == .degrade ? .degrade : .promote
        let nextModel = adaptiveManager.recommendedModel(current: settings.offlineModelType, direction: direction)

        guard nextModel != settings.offlineModelType else { return }

        _sherpaProviders.removeAll()
        settings.offlineModelType = nextModel
        settings.save()
    }

    private var shouldTryEdgeProvider: Bool {
        guard isNetworkReachable else { return false }
        if let retryAt = edgeRetryNotBefore {
            return Date() >= retryAt
        }
        return true
    }

    private func cacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("BookReaderTTS", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        pruneOldAudioCachesIfNeeded(root: dir)
        return dir
    }

    /// 跨会话复用：同文本 + 声音 + 语速 + 音调 + 合成管线 + 本地模型 → 同一缓存文件。
    private func stableAudioKey(text: String, provider: TTSProvider, offlineModel: OfflineModelType? = nil) -> String {
        var tag = provider.kind.cacheKeyTag
        if let offlineModel {
            tag += "|\(offlineModel.rawValue)"
        }
        if provider.kind == .sherpaOnnxOffline {
            tag += "|\(settings.offlineTuningCacheTag)"
        }
        let raw = "\(text)|\(settings.selectedVoiceIdentifier)|\(settings.speechRate)|\(settings.pitchMultiplier)|\(tag)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func cacheURL(for text: String, provider: TTSProvider, offlineModel: OfflineModelType? = nil) -> URL {
        let ext: String
        switch provider.kind {
        case .edgeOnline:
            ext = "mp3"
        case .sherpaOnnxOffline:
            ext = "wav"
        case .systemOfflineFile:
            ext = "caf"
        }
        let key = stableAudioKey(text: text, provider: provider, offlineModel: offlineModel)
        return cacheDirectory().appendingPathComponent("\(key).\(ext)")
    }

    /// 音频缓存仅限制顶层 mp3/caf，避免 idx 等子目录；过多时删除最旧的一批。
    private func pruneOldAudioCachesIfNeeded(root: URL) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let audioURLs = urls.filter {
            let ext = $0.pathExtension.lowercased()
            return ext == "mp3" || ext == "caf" || ext == "wav"
        }
        guard audioURLs.count > 600 else { return }

        let dated = audioURLs.compactMap { url -> (URL, Date)? in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            guard let date = values?.contentModificationDate else { return nil }
            return (url, date)
        }
        let sorted = dated.sorted { $0.1 < $1.1 }
        for (url, _) in sorted.prefix(200) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func globalCharacterIndex(forProgress progress: Double) -> Int {
        let bounded = min(max(progress, 0), 1)
        guard totalCharacters > 0 else { return 0 }
        let raw = bounded * Double(totalCharacters)
        let rounded = Int(raw.rounded(.toNearestOrAwayFromZero))
        return min(max(rounded, 0), totalCharacters)
    }

    private func calculateCharactersBefore(chapterIndex _: Int, sentenceIndex: Int) -> Int {
        findSentenceStartIndex(sentenceIndex)
    }

    private func findSentenceStartIndex(_ sentenceIndex: Int) -> Int {
        sentenceStartCharacters[safe: sentenceIndex] ?? totalCharacters
    }

    private func findChapterAndSentence(for characterIndex: Int) -> (Int, Int) {
        guard !sentenceStartCharacters.isEmpty else { return (0, 0) }
        let sentenceIndex = sentenceStartCharacters.lastIndex { $0 <= characterIndex } ?? 0
        return (sentenceChapterIndexes[safe: sentenceIndex] ?? 0, sentenceIndex)
    }

    private func findChapterAndSentenceStartingAtOrAfter(for characterIndex: Int) -> (Int, Int) {
        guard !sentenceStartCharacters.isEmpty else { return (0, 0) }
        let sentenceIndex = sentenceStartCharacters.firstIndex { $0 >= characterIndex }
            ?? sentenceStartCharacters.indices.last
            ?? 0
        return (sentenceChapterIndexes[safe: sentenceIndex] ?? 0, sentenceIndex)
    }

    // MARK: - Now playing & remote commands

    private func updateNowPlayingInfo() {
        #if os(iOS)
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: nowPlayingTitle,
            MPMediaItemPropertyArtist: nowPlayingArtist,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]
        if totalCharacters > 0 {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentProgress * 100.0
            info[MPMediaItemPropertyPlaybackDuration] = 100.0
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #endif
    }

    private func clearNowPlayingInfo() {
        #if os(iOS)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #endif
    }

    private func setupRemoteTransportControls() {
        #if os(iOS)
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true

        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.resume()
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.pause()
            }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.isPlaying {
                    self.pause()
                } else if self.isPaused {
                    self.resume()
                }
            }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.skipToNextSentence()
            }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.skipToPreviousSentence()
            }
            return .success
        }
        #endif
    }

    private static func isSupportedVoiceLanguage(_ languageIdentifier: String) -> Bool {
        let languageIdentifier = languageIdentifier.lowercased()
        return languageIdentifier.hasPrefix("zh") || languageIdentifier.hasPrefix("en")
    }
}

// MARK: - Sentence index cache (on-disk)

private struct SentenceIndex: Codable {
    let bookID: UUID
    let fingerprint: String
    let sentences: [String]
    let chapterIndexes: [Int]
    let startCharacters: [Int]
    let totalCharacters: Int
}

private enum SentenceIndexBuilder {
    static func fingerprint(chapterContents: [String]) -> String {
        let totalCharCount = chapterContents.reduce(0) { $0 + $1.count }
        let chapterCount = chapterContents.count
        let prefix = chapterContents.first.map { String($0.prefix(200)) } ?? ""
        return "\(totalCharCount)|\(chapterCount)|\(prefix)"
    }

    static func loadCached(bookID: UUID, fileURL: URL, expectedFingerprint: String) -> SentenceIndex? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        guard let decoded = try? JSONDecoder().decode(SentenceIndex.self, from: data) else { return nil }
        guard decoded.bookID == bookID, decoded.fingerprint == expectedFingerprint else { return nil }
        return decoded
    }

    static func save(_ index: SentenceIndex, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    static func split(chapterContents: [String]) -> (
        sentences: [String],
        chapterIndexes: [Int],
        startCharacters: [Int],
        totalCharacters: Int
    ) {
        var allSentences: [String] = []
        var sentenceChapterIndexes: [Int] = []
        var sentenceStartCharacters: [Int] = []
        var totalCharacters = 0
        var globalCharacterStart = 0

        for (chapterIndex, content) in chapterContents.enumerated() {
            var chapterSentences: [(text: String, start: Int)] = []
            content.enumerateSubstrings(in: content.startIndex..., options: .bySentences) { substring, sentenceRange, _, _ in
                guard let sentence = substring?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty else { return }
                let localStart = content.distance(from: content.startIndex, to: sentenceRange.lowerBound)
                chapterSentences.append((sentence, localStart))
            }

            if chapterSentences.isEmpty {
                chapterSentences = fallbackSentencesWithOffsets(in: content)
            }

            allSentences.append(contentsOf: chapterSentences.map(\.text))
            sentenceChapterIndexes.append(contentsOf: Array(repeating: chapterIndex, count: chapterSentences.count))
            sentenceStartCharacters.append(contentsOf: chapterSentences.map { globalCharacterStart + $0.start })
            totalCharacters += content.count
            globalCharacterStart += content.count
        }

        return (allSentences, sentenceChapterIndexes, sentenceStartCharacters, totalCharacters)
    }

    private static func fallbackSentencesWithOffsets(in text: String) -> [(text: String, start: Int)] {
        var result: [(text: String, start: Int)] = []
        var searchStart = text.startIndex

        for component in text.components(separatedBy: CharacterSet.newlines) {
            let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let range = text.range(of: trimmed, range: searchStart..<text.endIndex)
            let localStart = range.map { text.distance(from: text.startIndex, to: $0.lowerBound) }
                ?? text.distance(from: text.startIndex, to: searchStart)
            result.append((trimmed, localStart))

            if let upperBound = range?.upperBound {
                searchStart = upperBound
            }
        }

        return result
    }
}

extension AVSpeechSynthesisVoice {
    var languageMinimalIdentifier: String {
        language.lowercased()
    }
}
