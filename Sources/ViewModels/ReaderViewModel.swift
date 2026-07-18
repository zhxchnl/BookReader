import Foundation
import Combine
import UIKit

@MainActor
final class ReaderViewModel: ObservableObject {
    @Published var book: Book
    @Published var chapters: [Chapter] = []
    @Published var pages: [ReaderPage] = []
    @Published var currentChapterIndex: Int = 0
    @Published var currentPageIndex: Int = 0
    @Published var currentContent: String = ""
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var ttsProgress: Double = 0
    @Published var chapterProgress: Double = 0
    @Published private(set) var isTTSPlaying = false
    @Published private(set) var isTTSPaused = false
    @Published var searchResults: [SearchResult] = []
    private var searchTask: Task<Void, Never>?

    private let parserService = BookParserService.shared
    private let ttsService = TTSService.shared
    private let database = DatabaseManager.shared
    private var cancellables = Set<AnyCancellable>()
    private var lastPageSize: CGSize = .zero
    private var lastPaginationFontSize: CGFloat = 17
    private var didLoadTTSChapters = false
    private var paginationCursor: PaginationCursor?
    private var isPaginating = false
    private let paginationBatchSize = 8
    private let chapterJumpPaginationBatchSize = 4
    private var chapterResumeProgress: [Int: Double] = [:]

    private var pendingSaveProgress: Double?
    private var saveProgressTask: Task<Void, Never>?
    private let saveProgressDebounce: TimeInterval = 0.5

    private struct CachedChapterPagination {
        let chapterIndex: Int
        let pageSize: CGSize
        let fontSize: CGFloat
        let pages: [ReaderPage]
        let paginationCursor: PaginationCursor?
    }
    private var chapterPaginationCache: [String: CachedChapterPagination] = [:]

    init(book: Book) {
        self.book = book
        setupTTSBindings()
        updateTTSNowPlayingMetadata()
    }

    private func setupTTSBindings() {
        ttsService.$currentProgress
            .receive(on: DispatchQueue.main)
            .assign(to: &$ttsProgress)

        ttsService.$isPlaying
            .receive(on: DispatchQueue.main)
            .assign(to: &$isTTSPlaying)

        ttsService.$isPaused
            .receive(on: DispatchQueue.main)
            .assign(to: &$isTTSPaused)

    }

    func loadContent() {
        isLoading = true
        errorMessage = nil
        chapterPaginationCache.removeAll()

        Task {
            do {
                if let latestBook = try database.fetchBook(byId: book.id) {
                    book = latestBook
                    updateTTSNowPlayingMetadata()
                }

                // 提前检查文件是否存在,给出更友好的提示。
                guard BookStorage.fileExists(for: book.filePath) else {
                    throw BookOpenError.fileMissing(title: book.title)
                }

                let parsedBook = try parserService.parseBook(at: book.filePath, format: book.format)
                self.chapters = parsedBook.chapters
                self.didLoadTTSChapters = false

                if book.currentProgress > 0, let chapterIndex = findChapterForProgress(book.currentProgress) {
                    currentChapterIndex = chapterIndex
                }

                updateCurrentContent()
                ensureTTSChaptersLoaded()

            } catch let error as BookOpenError {
                errorMessage = error.errorDescription
            } catch {
                errorMessage = "加载内容失败: \(error.localizedDescription)"
            }
            isLoading = false
        }
    }

    func configurePagination(for pageSize: CGSize, fontSize: Double) {
        guard !chapters.isEmpty, pageSize.width > 0, pageSize.height > 0 else { return }
        guard !isPaginating else { return }
        let paginationFontSize = CGFloat(fontSize)
        guard abs(pageSize.width - lastPageSize.width) > 1 ||
            abs(pageSize.height - lastPageSize.height) > 1 ||
            abs(paginationFontSize - lastPaginationFontSize) > 0.1 ||
            pages.isEmpty else {
            return
        }

        lastPageSize = pageSize
        lastPaginationFontSize = paginationFontSize

        if let cached = getCachedPagination(for: currentChapterIndex, pageSize: pageSize, fontSize: paginationFontSize) {
            pages = cached.pages
            paginationCursor = nil
            if book.currentProgress > 0 {
                currentPageIndex = pageIndex(forProgress: book.currentProgress)
            } else {
                currentPageIndex = firstPageIndex(forChapter: currentChapterIndex)
            }
            currentPageIndex = min(currentPageIndex, pages.count - 1)
        } else {
            resetPagination(for: pageSize)

            if book.currentProgress > 0 {
                currentPageIndex = pageIndex(forProgress: book.currentProgress)
            } else {
                currentPageIndex = firstPageIndex(forChapter: currentChapterIndex)
            }

            currentPageIndex = adjustPageIndexByPrependingIfNeeded(currentPageIndex)
        }

        currentChapterIndex = pages[safe: currentPageIndex]?.chapterIndex ?? currentChapterIndex
        updateCurrentContent()
    }

    private func totalBookCharacterCount() -> Int {
        chapters.reduce(0) { $0 + $1.content.count }
    }

    private func paginationCacheKey(for chapterIndex: Int, pageSize: CGSize, fontSize: CGFloat) -> String {
        "\(chapterIndex)_\(Int(pageSize.width))_\(Int(pageSize.height))_\(Int(fontSize * 10))"
    }

    private func getCachedPagination(for chapterIndex: Int, pageSize: CGSize, fontSize: CGFloat) -> CachedChapterPagination? {
        let key = paginationCacheKey(for: chapterIndex, pageSize: pageSize, fontSize: fontSize)
        return chapterPaginationCache[key]
    }

    private func cachePagination(_ pages: [ReaderPage], cursor: PaginationCursor?, for chapterIndex: Int, pageSize: CGSize, fontSize: CGFloat) {
        guard !pages.isEmpty else { return }
        let key = paginationCacheKey(for: chapterIndex, pageSize: pageSize, fontSize: fontSize)
        chapterPaginationCache[key] = CachedChapterPagination(
            chapterIndex: chapterIndex,
            pageSize: pageSize,
            fontSize: fontSize,
            pages: pages,
            paginationCursor: cursor
        )
    }

    private func preloadPreviousChapterPagination() {
        let prevChapterIndex = currentChapterIndex - 1
        guard prevChapterIndex >= 0 else { return }
        guard getCachedPagination(for: prevChapterIndex, pageSize: lastPageSize, fontSize: lastPaginationFontSize) == nil else { return }

        let chapterSnapshot = chapters[prevChapterIndex]
        let globalStart = globalCharacterStart(forChapter: prevChapterIndex, localOffset: 0)
        let pageSize = lastPageSize
        let fontSize = lastPaginationFontSize

        Task.detached(priority: .userInitiated) { [weak self] in
            let pages = Self.generateFullChapterPagination(
                chapterContent: chapterSnapshot.content,
                chapterIndex: prevChapterIndex,
                chapterTitle: chapterSnapshot.title,
                globalStart: globalStart,
                pageSize: pageSize,
                fontSize: fontSize
            )
            await self?.cachePaginationAsync(
                pages: pages,
                chapterIndex: prevChapterIndex,
                pageSize: pageSize,
                fontSize: fontSize
            )
        }
    }

    private func generateFullChapterPagination(for chapterIndex: Int) -> [ReaderPage] {
        guard chapters.indices.contains(chapterIndex) else { return [] }
        let chapter = chapters[chapterIndex]
        return Self.generateFullChapterPagination(
            chapterContent: chapter.content,
            chapterIndex: chapterIndex,
            chapterTitle: chapter.title,
            globalStart: globalCharacterStart(forChapter: chapterIndex, localOffset: 0),
            pageSize: lastPageSize,
            fontSize: lastPaginationFontSize
        )
    }

    /// 后台可调用的纯函数：分页单章并产出 ReaderPage 数组。
    /// 不引用 self，可在 Task.detached 里跑，把文字测量这种重活从主线程拿开。
    nonisolated private static func generateFullChapterPagination(
        chapterContent: String,
        chapterIndex: Int,
        chapterTitle: String,
        globalStart: Int,
        pageSize: CGSize,
        fontSize: CGFloat
    ) -> [ReaderPage] {
        guard pageSize.width > 0, pageSize.height > 0, fontSize > 0 else { return [] }
        guard let metrics = paginationMetrics(for: pageSize, fontSize: fontSize) else { return [] }

        var resultPages: [ReaderPage] = []
        var localOffset = 0
        var pageInChapter = 0

        while localOffset < chapterContent.count {
            let startIndex = chapterContent.index(chapterContent.startIndex, offsetBy: localOffset, limitedBy: chapterContent.endIndex) ?? chapterContent.endIndex
            guard startIndex < chapterContent.endIndex else { break }

            let linesPerPage = max(4, Int(metrics.fullPageHeight / metrics.lineHeight))
            let maxLength = max(metrics.charactersPerLine * min(linesPerPage, metrics.defaultLinesPerPage), metrics.charactersPerLine)
            let remainingLength = chapterContent.distance(from: startIndex, to: chapterContent.endIndex)
            let consumed = fittedSplitLength(in: chapterContent, from: startIndex, before: min(maxLength, remainingLength), metrics: metrics)

            let pageEnd = chapterContent.index(startIndex, offsetBy: consumed, limitedBy: chapterContent.endIndex) ?? chapterContent.endIndex
            let pageText = String(chapterContent[startIndex..<pageEnd])

            resultPages.append(ReaderPage(
                chapterIndex: chapterIndex,
                pageInChapter: pageInChapter,
                title: pageInChapter == 0 ? chapterTitle : nil,
                text: pageText,
                globalCharacterStart: globalStart + localOffset
            ))

            localOffset += consumed
            pageInChapter += 1

            if resultPages.count > 500 { break }
        }

        return resultPages
    }

    /// 与 TTSService 一致：避免 `progress * total` 直接转 Int 导致少 1 个字、翻页/朗读错位。
    private func globalCharacterIndexFromBookProgress(_ progress: Double) -> Int {
        let total = totalBookCharacterCount()
        guard total > 0 else { return 0 }
        let bounded = min(max(progress, 0), 1)
        let idx = Int((bounded * Double(total)).rounded(.toNearestOrAwayFromZero))
        return min(max(idx, 0), total)
    }

    private func findChapterForProgress(_ progress: Double) -> Int? {
        guard !chapters.isEmpty else { return nil }
        let targetCharacters = globalCharacterIndexFromBookProgress(progress)

        var accumulated = 0
        for (index, chapter) in chapters.enumerated() {
            accumulated += chapter.content.count
            if accumulated > targetCharacters {
                return index
            }
        }
        return chapters.indices.last
    }

    func selectChapter(_ index: Int) {
        guard index >= 0, index < chapters.count else { return }
        let targetProgress: Double
        if index == currentChapterIndex {
            targetProgress = progressForCurrentPage()
        } else if let resumeProgress = chapterResumeProgress[index] {
            targetProgress = resumeProgress
        } else {
            targetProgress = progressForChapter(index)
        }

        let previousChapterIndex = currentChapterIndex
        currentChapterIndex = index

        let needsPreviousChapterPages = previousChapterIndex == index + 1

        if let cached = getCachedPagination(for: index, pageSize: lastPageSize, fontSize: lastPaginationFontSize) {
            pages = cached.pages
            paginationCursor = nil
            currentPageIndex = pageIndex(forProgress: targetProgress)
            currentPageIndex = min(currentPageIndex, pages.count - 1)

            if needsPreviousChapterPages, let prevCached = getCachedPagination(for: index - 1, pageSize: lastPageSize, fontSize: lastPaginationFontSize) {
                let insertCount = min(prevCached.pages.count, 8)
                if insertCount > 0 {
                    let pagesToInsert = Array(prevCached.pages.suffix(insertCount))
                    pages.insert(contentsOf: pagesToInsert, at: 0)
                    currentPageIndex += insertCount
                }
            }
        } else {
            resetPagination(
                for: lastPageSize,
                startingAt: targetProgress,
                batchSize: chapterJumpPaginationBatchSize
            )
            currentPageIndex = pageIndex(forProgress: targetProgress)
            currentPageIndex = adjustPageIndexByPrependingIfNeeded(currentPageIndex)
        }

        currentChapterIndex = pages[safe: currentPageIndex]?.chapterIndex ?? index
        updateCurrentContent()
        saveProgress()
        preloadPreviousChapterPagination()
    }

    func selectPreviousChapter() {
        let wasPlaying = isTTSPlaying
        let wasPaused = isTTSPaused
        selectChapter(max(0, currentChapterIndex - 1))
        syncTTSAfterManualNavigation(wasPlaying: wasPlaying, wasPaused: wasPaused)
    }

    func selectNextChapter() {
        let wasPlaying = isTTSPlaying
        let wasPaused = isTTSPaused
        selectChapter(min(chapters.count - 1, currentChapterIndex + 1))
        syncTTSAfterManualNavigation(wasPlaying: wasPlaying, wasPaused: wasPaused)
    }

    func selectPage(_ index: Int) {
        if index >= pages.count {
            let nextChapterIndex = currentChapterIndex + 1
            if nextChapterIndex < chapters.count {
                selectChapter(nextChapterIndex)
            }
            return
        }
        isPaginating = true
        defer { isPaginating = false }

        let shouldRestartTTS = isTTSPlaying
        let shouldResetPausedTTS = isTTSPaused

        let adjusted = adjustPageIndexByPrependingIfNeeded(index)
        currentPageIndex = adjusted
        currentChapterIndex = pages[adjusted].chapterIndex
        updateCurrentContent()
        saveProgress()
        loadMorePagesIfNeeded(currentIndex: adjusted)

        if shouldRestartTTS {
            startTTSFromCurrentPage()
        } else if shouldResetPausedTTS {
            ttsService.stop()
            ttsProgress = progressForCurrentPage()
        }
    }

    private func syncTTSAfterManualNavigation(wasPlaying: Bool, wasPaused: Bool) {
        if wasPlaying {
            startTTSFromCurrentPage()
        } else if wasPaused {
            ttsService.stop()
            ttsProgress = progressForCurrentPage()
        }
    }

    private func updateCurrentContent() {
        guard currentChapterIndex < chapters.count else { return }
        currentContent = chapters[currentChapterIndex].content
        chapterProgress = chapterProgressForCurrentPage()
    }

    private func saveProgress(_ explicitProgress: Double? = nil) {
        guard !chapters.isEmpty else { return }

        let progress = explicitProgress ?? progressForCurrentPage()
        let boundedProgress = min(max(progress, 0), 1)
        cacheChapterResumeProgress(boundedProgress)

        pendingSaveProgress = boundedProgress
        scheduleSaveProgress()
    }

    private func scheduleSaveProgress() {
        saveProgressTask?.cancel()
        let progress = pendingSaveProgress
        guard let progress else { return }

        let bookId = book.id
        let debounce = saveProgressDebounce
        saveProgressTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(debounce * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                guard self.book.id == bookId else { return }
                // 只在还是最新一次待写时落盘，避免中间又被新进度覆盖。
                if self.pendingSaveProgress == progress {
                    self.pendingSaveProgress = nil
                }
                do {
                    try self.database.updateProgress(bookId: bookId, progress: progress)
                } catch {
                    print("Save progress failed: \(error)")
                }
                self.book.currentProgress = progress
                self.book.lastReadDate = Date()
            }
        }
    }

    private func flushSaveProgress() {
        saveProgressTask?.cancel()
        saveProgressTask = nil
        guard let progress = pendingSaveProgress else { return }
        pendingSaveProgress = nil
        writeProgressImmediately(progress: progress)
    }

    private func writeProgressImmediately(progress: Double) {
        do {
            try database.updateProgress(bookId: book.id, progress: progress)
            book.currentProgress = progress
            book.lastReadDate = Date()
        } catch {
            print("Save progress failed: \(error)")
        }
    }

    private func cacheChapterResumeProgress(_ progress: Double) {
        guard let chapterIndex = findChapterForProgress(progress) else { return }
        chapterResumeProgress[chapterIndex] = progress
    }

    private func progressForCurrentChapter() -> Double {
        let totalCharacters = chapters.reduce(0) { $0 + $1.content.count }
        let charactersBeforeCurrentChapter = chapters.prefix(currentChapterIndex).reduce(0) { $0 + $1.content.count }
        return Double(charactersBeforeCurrentChapter) / Double(max(1, totalCharacters))
    }

    private func progressForCurrentPage() -> Double {
        guard let page = pages[safe: currentPageIndex] else {
            return progressForCurrentChapter()
        }

        let totalCharacters = chapters.reduce(0) { $0 + $1.content.count }
        return Double(page.globalCharacterStart) / Double(max(1, totalCharacters))
    }

    private func chapterProgressForCurrentPage() -> Double {
        guard let page = pages[safe: currentPageIndex],
              chapters.indices.contains(page.chapterIndex) else {
            return 0
        }

        let chapter = chapters[page.chapterIndex]
        guard chapter.content.isEmpty == false else { return 0 }

        let chapterStart = chapters.prefix(page.chapterIndex).reduce(0) { $0 + $1.content.count }
        let localCharacter = max(0, page.globalCharacterStart - chapterStart)
        return min(max(Double(localCharacter) / Double(chapter.content.count), 0), 1)
    }

    private func sentenceAlignedGlobalProgress(forChapterProgress progress: Double, chapterIndex: Int) -> Double {
        guard chapters.indices.contains(chapterIndex) else {
            return progressForCurrentPage()
        }

        let chapter = chapters[chapterIndex]
        guard chapter.content.isEmpty == false else {
            return progressForChapter(chapterIndex)
        }

        let totalCharacters = chapters.reduce(0) { $0 + $1.content.count }
        let chapterStart = chapters.prefix(chapterIndex).reduce(0) { $0 + $1.content.count }
        let targetLocalCharacter = min(
            Int(min(max(progress, 0), 1) * Double(chapter.content.count)),
            max(0, chapter.content.count - 1)
        )
        var alignedLocalCharacter = targetLocalCharacter

        chapter.content.enumerateSubstrings(in: chapter.content.startIndex..., options: .bySentences) { _, sentenceRange, _, stop in
            let sentenceStart = chapter.content.distance(from: chapter.content.startIndex, to: sentenceRange.lowerBound)
            let sentenceEnd = chapter.content.distance(from: chapter.content.startIndex, to: sentenceRange.upperBound)

            if targetLocalCharacter >= sentenceStart, targetLocalCharacter < sentenceEnd {
                alignedLocalCharacter = sentenceStart
                stop = true
            }
        }

        return Double(chapterStart + alignedLocalCharacter) / Double(max(1, totalCharacters))
    }

    private func firstPageIndex(forChapter chapterIndex: Int) -> Int {
        pages.firstIndex { $0.chapterIndex == chapterIndex } ?? 0
    }

    private func pageIndex(forProgress progress: Double) -> Int {
        guard !pages.isEmpty else { return 0 }

        let targetCharacter = globalCharacterIndexFromBookProgress(progress)
        let pageIndex = pages.lastIndex { $0.globalCharacterStart <= targetCharacter } ?? 0

        return min(pageIndex, pages.count - 1)
    }

    private func ensurePageLoaded(forProgress progress: Double) {
        guard !pages.isEmpty else { return }

        let targetCharacter = globalCharacterIndexFromBookProgress(min(max(progress, 0), 1))

        while let lastPage = pages.last,
              lastPage.globalCharacterStart <= targetCharacter,
              paginationCursor != nil {
            appendNextPageBatch(for: lastPageSize)
        }
    }

    func seekCurrentChapterProgress(_ progress: Double, syncAudio: Bool = true) {
        guard chapters.indices.contains(currentChapterIndex) else { return }

        let wasPlaying = isTTSPlaying
        let wasPaused = isTTSPaused
        let globalProgress = sentenceAlignedGlobalProgress(forChapterProgress: progress, chapterIndex: currentChapterIndex)

        if lastPageSize.width > 0, lastPageSize.height > 0 {
            resetPagination(for: lastPageSize, startingAt: globalProgress)
        }

        let resolvedIndex = pageIndex(forProgress: globalProgress)
        currentPageIndex = adjustPageIndexByPrependingIfNeeded(resolvedIndex)
        currentChapterIndex = pages[safe: currentPageIndex]?.chapterIndex ?? currentChapterIndex
        updateCurrentContent()
        chapterProgress = min(max(progress, 0), 1)
        ttsProgress = globalProgress
        saveProgress(globalProgress)

        guard syncAudio else { return }

        if wasPlaying {
            startTTS(from: globalProgress)
        } else if wasPaused {
            ttsService.stop()
        }
    }

    private func resetPagination(for pageSize: CGSize, startingAt progress: Double? = nil, batchSize: Int? = nil) {
        guard pageSize.width > 0, pageSize.height > 0 else { return }

        pages = []
        paginationCursor = makePaginationCursor(startingAt: progress ?? book.currentProgress)
        appendNextPageBatch(for: pageSize, limit: batchSize)
    }

    private func loadMorePagesIfNeeded(currentIndex: Int) {
        if currentIndex >= pages.count - 6 {
            appendNextPageBatch(for: lastPageSize)
        }
        if currentIndex >= pages.count - 4 {
            preloadNextChapterPagination()
        }
        if currentIndex < 6 {
            // 接近 pages 开头时提前预分上一章，避免滑动到边界时主线程被 `prependPreviousPageBatch` 阻塞。
            preloadPreviousChapterPagination()
        }
    }

    private func preloadNextChapterPagination() {
        let nextChapterIndex = currentChapterIndex + 1
        guard nextChapterIndex < chapters.count else { return }
        guard getCachedPagination(for: nextChapterIndex, pageSize: lastPageSize, fontSize: lastPaginationFontSize) == nil else { return }

        let chapterSnapshot = chapters[nextChapterIndex]
        let globalStart = globalCharacterStart(forChapter: nextChapterIndex, localOffset: 0)
        let pageSize = lastPageSize
        let fontSize = lastPaginationFontSize

        Task.detached(priority: .userInitiated) { [weak self] in
            let pages = Self.generateFullChapterPagination(
                chapterContent: chapterSnapshot.content,
                chapterIndex: nextChapterIndex,
                chapterTitle: chapterSnapshot.title,
                globalStart: globalStart,
                pageSize: pageSize,
                fontSize: fontSize
            )
            await self?.cachePaginationAsync(
                pages: pages,
                chapterIndex: nextChapterIndex,
                pageSize: pageSize,
                fontSize: fontSize
            )
        }
    }

    private func cachePaginationAsync(pages: [ReaderPage], chapterIndex: Int, pageSize: CGSize, fontSize: CGFloat) async {
        guard !pages.isEmpty else { return }
        cachePagination(pages, cursor: nil, for: chapterIndex, pageSize: pageSize, fontSize: fontSize)
    }

    /// 在索引靠近列表开头时向前补页，否则 TabView 无法翻到当前窗口之前的正文（例如章节跳转后）。
    private func adjustPageIndexByPrependingIfNeeded(_ index: Int) -> Int {
        guard index < 12, lastPageSize.width > 0, lastPageSize.height > 0, pages.isEmpty == false else {
            return index
        }
        let added = prependPreviousPageBatch(for: lastPageSize)
        return index + added
    }

    /// 在「当前第一页」之前再生成一批页面；返回插入的页数（用于整体上移 `currentPageIndex`）。
    private func prependPreviousPageBatch(for pageSize: CGSize) -> Int {
        guard pageSize.width > 0, pageSize.height > 0, let firstPage = pages.first,
              firstPage.globalCharacterStart > 0 else { return 0 }

        var batch: [ReaderPage] = []
        var remaining = paginationBatchSize
        var chapterIndex = firstPage.chapterIndex
        var hitUncachedChapter = false

        while chapterIndex >= 0, remaining > 0 {
            // 缓存命中时才能从缓存取页；缓存未命中时立刻在后台预分，避免主线程同步算整章卡住滑动。
            guard getCachedPagination(for: chapterIndex, pageSize: pageSize, fontSize: lastPaginationFontSize) != nil else {
                hitUncachedChapter = true
                break
            }
            let chapterPages = canonicalChapterPages(for: chapterIndex)
            let eligiblePages: [ReaderPage]

            if chapterIndex == firstPage.chapterIndex {
                eligiblePages = chapterPages.filter { $0.globalCharacterStart < firstPage.globalCharacterStart }
            } else {
                eligiblePages = chapterPages
            }

            if eligiblePages.isEmpty == false {
                let slice = Array(eligiblePages.suffix(remaining))
                if batch.isEmpty {
                    batch = slice
                } else {
                    batch.insert(contentsOf: slice, at: 0)
                }
                remaining -= slice.count
            }

            chapterIndex -= 1
        }

        if hitUncachedChapter {
            preloadPreviousChapterPagination()
        }

        guard batch.isEmpty == false else { return 0 }
        pages.insert(contentsOf: batch, at: 0)
        return batch.count
    }

    private func canonicalChapterPages(for chapterIndex: Int) -> [ReaderPage] {
        guard chapters.indices.contains(chapterIndex), lastPageSize.width > 0, lastPageSize.height > 0 else { return [] }

        if let cached = getCachedPagination(for: chapterIndex, pageSize: lastPageSize, fontSize: lastPaginationFontSize) {
            return cached.pages
        }

        let generated = generateFullChapterPagination(for: chapterIndex)
        if generated.isEmpty == false {
            cachePagination(generated, cursor: nil, for: chapterIndex, pageSize: lastPageSize, fontSize: lastPaginationFontSize)
        }
        return generated
    }

    private func estimatedPageNumberInChapter(chapterIndex: Int, localCharacterStart: Int, metrics: PaginationMetrics) -> Int {
        guard chapters.indices.contains(chapterIndex), localCharacterStart > 0 else { return 0 }

        let linesPerPage = max(4, Int(metrics.fullPageHeight / metrics.lineHeight))
        let maxLength = max(metrics.charactersPerLine * min(linesPerPage, metrics.defaultLinesPerPage), metrics.charactersPerLine)
        return max(0, localCharacterStart / max(1, maxLength))
    }

    private func globalCharacterStart(forChapter chapterIndex: Int, localOffset: Int) -> Int {
        chapters.prefix(chapterIndex).reduce(0) { $0 + $1.content.count } + localOffset
    }

    private func chapterLocalFromGlobal(_ globalChar: Int) -> (chapterIndex: Int, localOffset: Int) {
        let clamped = max(0, globalChar)
        guard chapters.isEmpty == false else { return (0, 0) }

        var accumulated = 0
        for (index, chapter) in chapters.enumerated() {
            let nextAccumulated = accumulated + chapter.content.count
            if clamped < nextAccumulated || index == chapters.count - 1 {
                return (index, min(max(0, clamped - accumulated), chapter.content.count))
            }
            accumulated = nextAccumulated
        }
        return (chapters.count - 1, chapters.last?.content.count ?? 0)
    }

    private func preferredSplitBackward(in text: String, endIndex: String.Index, maxLength: Int) -> Int {
        guard maxLength > 0 else { return 1 }
        let endOffset = text.distance(from: text.startIndex, to: endIndex)
        guard endOffset > 0 else { return 0 }

        if endOffset <= maxLength {
            return endOffset
        }

        let windowStart = endOffset - maxLength
        let searchEnd = min(windowStart + 80, endOffset - 1)

        // Backward pagination should prefer a split point close to the page start,
        // so the generated page stays close to full height instead of becoming underfilled.
        for o in windowStart...searchEnd {
            let i = text.index(text.startIndex, offsetBy: o)
            if let scalar = text[i].unicodeScalars.first,
               CharacterSet.whitespacesAndNewlines.contains(scalar) || "，。！？；：,.!?;:".contains(text[i]) {
                return endOffset - (o + 1)
            }
        }

        return maxLength
    }

    private func appendNextPageBatch(for pageSize: CGSize, limit: Int? = nil) {
        guard let metrics = paginationMetrics(for: pageSize), var cursor = paginationCursor else { return }

        let targetBatchSize = limit ?? paginationBatchSize
        var appendedPages: [ReaderPage] = []

        while appendedPages.count < targetBatchSize, cursor.chapterIndex < chapters.count {
            let chapter = chapters[cursor.chapterIndex]

            if chapter.content.isEmpty {
                appendedPages.append(ReaderPage(
                    chapterIndex: cursor.chapterIndex,
                    pageInChapter: 0,
                    title: chapter.title,
                    text: "",
                    globalCharacterStart: cursor.globalCharacterStart
                ))
                cursor.chapterIndex += 1
                cursor.localOffset = 0
                cursor.pageInChapter = 0
                continue
            }

            let localStart = chapter.content.index(chapter.content.startIndex, offsetBy: cursor.localOffset, limitedBy: chapter.content.endIndex) ?? chapter.content.endIndex

            if localStart >= chapter.content.endIndex {
                cursor.chapterIndex += 1
                cursor.localOffset = 0
                cursor.pageInChapter = 0
                continue
            }

            let linesPerPage = max(4, Int(metrics.fullPageHeight / metrics.lineHeight))
            let maxLength = max(metrics.charactersPerLine * min(linesPerPage, metrics.defaultLinesPerPage), metrics.charactersPerLine)
            let remainingLength = chapter.content.distance(from: localStart, to: chapter.content.endIndex)
            let consumed = fittedSplitLength(
                in: chapter.content,
                from: localStart,
                before: min(maxLength, remainingLength),
                metrics: metrics
            )
            let pageEnd = chapter.content.index(localStart, offsetBy: consumed, limitedBy: chapter.content.endIndex) ?? chapter.content.endIndex
            let pageText = String(chapter.content[localStart..<pageEnd])

            appendedPages.append(ReaderPage(
                chapterIndex: cursor.chapterIndex,
                pageInChapter: cursor.pageInChapter,
                title: nil,
                text: pageText,
                globalCharacterStart: cursor.globalCharacterStart
            ))

            cursor.localOffset += consumed
            cursor.globalCharacterStart += consumed
            cursor.pageInChapter += 1
        }

        pages.append(contentsOf: appendedPages)
        paginationCursor = cursor.chapterIndex < chapters.count ? cursor : nil
    }

    private func makePaginationCursor(startingAt progress: Double) -> PaginationCursor {
        guard !chapters.isEmpty else {
            return PaginationCursor(chapterIndex: 0, localOffset: 0, pageInChapter: 0, globalCharacterStart: 0)
        }

        let targetCharacter = globalCharacterIndexFromBookProgress(progress)
        var accumulated = 0

        for (index, chapter) in chapters.enumerated() {
            let nextAccumulated = accumulated + chapter.content.count
            if targetCharacter < nextAccumulated || index == chapters.count - 1 {
                let localOffset = min(max(0, targetCharacter - accumulated), chapter.content.count)
                return PaginationCursor(
                    chapterIndex: index,
                    localOffset: localOffset,
                    pageInChapter: 0,
                    globalCharacterStart: accumulated + localOffset
                )
            }
            accumulated = nextAccumulated
        }

        return PaginationCursor(chapterIndex: 0, localOffset: 0, pageInChapter: 0, globalCharacterStart: 0)
    }

    private func progressForChapter(_ chapterIndex: Int) -> Double {
        let charactersBeforeChapter = chapters.prefix(chapterIndex).reduce(0) { $0 + $1.content.count }
        return Double(charactersBeforeChapter) / Double(max(1, totalBookCharacterCount()))
    }

    private func paginationMetrics(for pageSize: CGSize) -> PaginationMetrics? {
        Self.paginationMetrics(for: pageSize, fontSize: lastPaginationFontSize)
    }

    nonisolated private static func paginationMetrics(for pageSize: CGSize, fontSize: CGFloat) -> PaginationMetrics? {
        guard pageSize.width > 0, pageSize.height > 0, fontSize > 0 else { return nil }

        let horizontalPadding: CGFloat = 40
        let verticalPadding: CGFloat = 24 + 12
        let footerSpacing: CGFloat = 16
        let textWidth = max(1, pageSize.width - horizontalPadding)
        let bodyFont = UIFont.systemFont(ofSize: fontSize)
        let footerFont = UIFont.preferredFont(forTextStyle: .caption2)
        let lineSpacing: CGFloat = 8
        let lineHeight = bodyFont.lineHeight + lineSpacing
        let reservedHeight = verticalPadding + footerSpacing + footerFont.lineHeight + lineHeight
        let fullPageHeight = max(120, pageSize.height - reservedHeight)
        let averageCharacterWidth = max(8, bodyFont.pointSize * 1.08)
        let charactersPerLine = max(8, Int(textWidth / averageCharacterWidth))
        let defaultLinesPerPage = max(4, Int(fullPageHeight / lineHeight))

        return PaginationMetrics(
            fullPageHeight: fullPageHeight,
            lineHeight: lineHeight,
            textWidth: textWidth,
            bodyFont: bodyFont,
            lineSpacing: lineSpacing,
            charactersPerLine: charactersPerLine,
            defaultLinesPerPage: defaultLinesPerPage
        )
    }

    private func fittedSplitLength(in text: String, from startIndex: String.Index, before maxLength: Int, metrics: PaginationMetrics) -> Int {
        Self.fittedSplitLength(in: text, from: startIndex, before: maxLength, metrics: metrics)
    }

    nonisolated private static func fittedSplitLength(in text: String, from startIndex: String.Index, before maxLength: Int, metrics: PaginationMetrics) -> Int {
        guard maxLength > 0 else { return 1 }

        let remainingLength = text.distance(from: startIndex, to: text.endIndex)
        let upperBound = min(maxLength, remainingLength)
        guard upperBound > 0 else { return 0 }

        if measuredTextHeight(in: text, from: startIndex, length: upperBound, metrics: metrics) <= metrics.fullPageHeight {
            if upperBound == remainingLength {
                return remainingLength
            }
            return preferredSplitLength(in: text, from: startIndex, before: upperBound)
        }

        var low = 1
        var high = upperBound
        var fitted = 1

        while low <= high {
            let mid = (low + high) / 2
            if measuredTextHeight(in: text, from: startIndex, length: mid, metrics: metrics) <= metrics.fullPageHeight {
                fitted = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        guard fitted < remainingLength else { return remainingLength }
        return max(1, preferredSplitLength(in: text, from: startIndex, before: fitted))
    }

    private func fittedSplitLengthBackward(in text: String, endIndex: String.Index, maxLength: Int, metrics: PaginationMetrics) -> Int {
        guard maxLength > 0 else { return 1 }
        let endOffset = text.distance(from: text.startIndex, to: endIndex)
        let upperBound = min(maxLength, endOffset)
        guard upperBound > 0 else { return 0 }

        if textHeightBefore(in: text, endIndex: endIndex, length: upperBound, metrics: metrics) <= metrics.fullPageHeight {
            return preferredSplitBackward(in: text, endIndex: endIndex, maxLength: upperBound)
        }

        var low = 1
        var high = upperBound
        var fitted = 1

        while low <= high {
            let mid = (low + high) / 2
            if textHeightBefore(in: text, endIndex: endIndex, length: mid, metrics: metrics) <= metrics.fullPageHeight {
                fitted = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        return max(1, preferredSplitBackward(in: text, endIndex: endIndex, maxLength: fitted))
    }

    private func textHeight(in text: String, from startIndex: String.Index, length: Int, metrics: PaginationMetrics) -> CGFloat {
        Self.measuredTextHeight(in: text, from: startIndex, length: length, metrics: metrics)
    }

    nonisolated private static func measuredTextHeight(in text: String, from startIndex: String.Index, length: Int, metrics: PaginationMetrics) -> CGFloat {
        let endIndex = text.index(startIndex, offsetBy: length, limitedBy: text.endIndex) ?? text.endIndex
        return measuredTextHeightSlice(String(text[startIndex..<endIndex]), metrics: metrics)
    }

    private func textHeightBefore(in text: String, endIndex: String.Index, length: Int, metrics: PaginationMetrics) -> CGFloat {
        let startOffset = max(0, text.distance(from: text.startIndex, to: endIndex) - length)
        let startIndex = text.index(text.startIndex, offsetBy: startOffset, limitedBy: endIndex) ?? text.startIndex
        return measuredTextHeight(String(text[startIndex..<endIndex]), metrics: metrics)
    }

    private func measuredTextHeight(_ text: String, metrics: PaginationMetrics) -> CGFloat {
        Self.measuredTextHeightSlice(text, metrics: metrics)
    }

    nonisolated private static func measuredTextHeightSlice(_ text: String, metrics: PaginationMetrics) -> CGFloat {
        guard text.isEmpty == false else { return 0 }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = metrics.lineSpacing

        let attributedText = NSAttributedString(
            string: text,
            attributes: [
                .font: metrics.bodyFont,
                .paragraphStyle: paragraphStyle
            ]
        )
        let size = attributedText.boundingRect(
            with: CGSize(width: metrics.textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )

        return ceil(size.height)
    }

    private func preferredSplitLength(in text: String, from startIndex: String.Index, before maxLength: Int) -> Int {
        Self.preferredSplitLength(in: text, from: startIndex, before: maxLength)
    }

    nonisolated private static func preferredSplitLength(in text: String, from startIndex: String.Index, before maxLength: Int) -> Int {
        guard maxLength > 0 else { return 1 }

        let remainingLength = text.distance(from: startIndex, to: text.endIndex)
        guard maxLength < remainingLength else { return remainingLength }

        let searchStart = max(1, maxLength - 80)
        let prefixEnd = text.index(startIndex, offsetBy: maxLength, limitedBy: text.endIndex) ?? text.endIndex
        let prefix = Array(text[startIndex..<prefixEnd])

        for index in stride(from: prefix.count - 1, through: searchStart, by: -1) {
            if let scalar = prefix[index].unicodeScalars.first,
               CharacterSet.whitespacesAndNewlines.contains(scalar) || "，。！？；：,.!?;:".contains(prefix[index]) {
                return index + 1
            }
        }

        return maxLength
    }

    func toggleTTS() {
        if ttsService.isPlaying {
            ttsService.pause()
        } else if ttsService.isPaused, ttsService.activeBookID == book.id {
            ttsService.resume()
        } else {
            startTTSFromCurrentPage()
        }
    }

    private func startTTSFromCurrentPage() {
        ensureTTSChaptersLoaded()
        updateTTSNowPlayingMetadata()
        let total = totalBookCharacterCount()
        guard total > 0, let page = pages[safe: currentPageIndex] else {
            startTTS(from: progressForCurrentPage())
            return
        }

        let progress = Double(page.globalCharacterStart) / Double(total)
        ttsProgress = progress
        saveProgress(progress)

        ttsService.speak(fromVisibleGlobalCharacterIndex: page.globalCharacterStart) { [weak self] progress, chapter, _ in
            Task { @MainActor in
                self?.handleTTSProgress(progress, chapter: chapter)
            }
        }
    }

    private func startTTS(from progress: Double) {
        ensureTTSChaptersLoaded()
        updateTTSNowPlayingMetadata()

        ttsProgress = progress
        saveProgress(progress)

        ttsService.speak(fromProgress: progress) { [weak self] progress, chapter, _ in
            Task { @MainActor in
                self?.handleTTSProgress(progress, chapter: chapter)
            }
        }
    }

    private func handleTTSProgress(_ progress: Double, chapter: Int) {
        ensurePageLoaded(forProgress: progress)
        currentChapterIndex = chapter
        let resolved = pageIndex(forProgress: progress)
        currentPageIndex = adjustPageIndexByPrependingIfNeeded(resolved)
        updateCurrentContent()
        ttsProgress = progress
        chapterProgress = chapterProgressForCurrentPage()
        saveProgress(progress)
        loadMorePagesIfNeeded(currentIndex: currentPageIndex)
    }

    func stopTTS() {
        ttsService.stop()
    }

    func skipToNextSentence() {
        ensureTTSChaptersLoaded()
        ttsService.skipToNextSentence()
    }

    func skipToPreviousSentence() {
        ensureTTSChaptersLoaded()
        ttsService.skipToPreviousSentence()
    }

    func seekTTS(to progress: Double) {
        ensureTTSChaptersLoaded()
        ttsService.seekToProgress(progress)
    }

    private func ensureTTSChaptersLoaded() {
        if didLoadTTSChapters, ttsService.activeBookID == book.id {
            ttsService.warmupIfNeeded()
            return
        }
        ttsService.loadChapters(chapters, for: book.id)
        didLoadTTSChapters = true
    }

    private func updateTTSNowPlayingMetadata() {
        ttsService.updateNowPlayingMetadata(title: book.title, author: book.author)
    }

    func updateTTSSettings(_ settings: TTSSettings) {
        ttsService.updateSettings(settings)
    }

    func getTTSSettings() -> TTSSettings {
        return ttsService.getCurrentSettings()
    }

    func search(query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            searchResults = []
            return
        }
        searchTask = Task<Void, Never> { @MainActor in
            let escapedQuery = NSRegularExpression.escapedPattern(for: trimmed)
            guard let regex = try? NSRegularExpression(pattern: escapedQuery, options: [.caseInsensitive]) else {
                searchResults = []
                return
            }

            var results: [SearchResult] = []
            var globalCharOffset = 0

            for (index, chapter) in chapters.enumerated() {
                guard !Task.isCancelled else { break }

                let nsContent = chapter.content as NSString
                let range = NSRange(location: 0, length: nsContent.length)

                regex.enumerateMatches(in: chapter.content, range: range) { match, _, _ in
                    guard let match else { return }
                    let matchRange = match.range
                    let matchText = nsContent.substring(with: matchRange)

                    let contextStart = Self.contextStart(
                        forMatchAt: matchRange.location,
                        in: nsContent,
                        maxBefore: 30
                    )
                    let beforeLen = matchRange.location - contextStart
                    let beforeRange = NSRange(location: contextStart, length: beforeLen)
                    let contextBefore = beforeLen > 0 ? nsContent.substring(with: beforeRange) : ""

                    let afterStart = matchRange.location + matchRange.length
                    let afterLen = min(30, nsContent.length - afterStart)
                    let afterRange = NSRange(location: afterStart, length: afterLen)
                    let contextAfter = afterLen > 0 ? nsContent.substring(with: afterRange) : ""

                    results.append(SearchResult(
                        chapterIndex: index,
                        chapterTitle: chapter.title,
                        matchText: matchText,
                        contextBefore: contextBefore,
                        contextAfter: contextAfter,
                        omitsBefore: contextStart > 0,
                        omitsAfter: afterStart + afterLen < nsContent.length,
                        globalCharacterStart: globalCharOffset + matchRange.location
                    ))
                }

                globalCharOffset += chapter.content.count
                if results.count >= 200 { break }
            }

            if !Task.isCancelled {
                searchResults = results
            }
        }
    }

    func jumpToSearchResult(_ result: SearchResult) {
        let total = totalBookCharacterCount()
        guard total > 0 else { return }
        let targetProgress = Double(result.globalCharacterStart) / Double(total)

        let wasPlaying = isTTSPlaying
        let wasPaused = isTTSPaused

        currentChapterIndex = result.chapterIndex

        if lastPageSize.width > 0, lastPageSize.height > 0 {
            resetPagination(for: lastPageSize, startingAt: targetProgress, batchSize: chapterJumpPaginationBatchSize)
        }

        let resolvedIndex = pageIndex(forProgress: targetProgress)
        currentPageIndex = adjustPageIndexByPrependingIfNeeded(resolvedIndex)
        currentChapterIndex = pages[safe: currentPageIndex]?.chapterIndex ?? result.chapterIndex
        updateCurrentContent()
        chapterProgress = chapterProgressForCurrentPage()
        saveProgress(targetProgress)

        syncTTSAfterManualNavigation(wasPlaying: wasPlaying, wasPaused: wasPaused)
    }

    func cleanup(stopPlayback: Bool = false) {
        let activeTTSProgress = (isTTSPlaying || isTTSPaused) && ttsProgress > 0 ? ttsProgress : nil
        if let activeTTSProgress {
            // 退出时强制把最新进度同步落盘，避免被节流任务丢失。
            pendingSaveProgress = activeTTSProgress
            flushSaveProgress()
        } else {
            flushSaveProgress()
        }

        if stopPlayback {
            ttsService.stop()
        }
    }

    private static func paragraphStart(in content: NSString, before index: Int) -> Int {
        guard index > 0 else { return 0 }
        let prefix = content.substring(with: NSRange(location: 0, length: index)) as NSString
        let doubleNewline = prefix.range(of: "\n\n", options: .backwards)
        if doubleNewline.location != NSNotFound {
            return doubleNewline.location + doubleNewline.length
        }
        let singleNewline = prefix.range(of: "\n", options: .backwards)
        if singleNewline.location != NSNotFound {
            return singleNewline.location + singleNewline.length
        }
        return 0
    }

    private static func contextStart(forMatchAt location: Int, in content: NSString, maxBefore: Int) -> Int {
        let paragraphStart = paragraphStart(in: content, before: location)
        return max(paragraphStart, location - maxBefore)
    }
}

struct ReaderPage: Identifiable, Equatable {
    let chapterIndex: Int
    let pageInChapter: Int
    let title: String?
    let text: String
    let globalCharacterStart: Int

    var id: String { "\(chapterIndex):\(pageInChapter):\(globalCharacterStart)" }
}

private struct PaginationCursor {
    var chapterIndex: Int
    var localOffset: Int
    var pageInChapter: Int
    var globalCharacterStart: Int
}

private struct PaginationMetrics {
    let fullPageHeight: CGFloat
    let lineHeight: CGFloat
    let textWidth: CGFloat
    let bodyFont: UIFont
    let lineSpacing: CGFloat
    let charactersPerLine: Int
    let defaultLinesPerPage: Int
}

enum BookOpenError: LocalizedError {
    case fileMissing(title: String)

    var errorDescription: String? {
        switch self {
        case .fileMissing(let title):
            return "找不到《\(title)》的文件,可能已被清理。请返回书架重新导入。"
        }
    }
}
