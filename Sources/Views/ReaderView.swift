import SwiftUI
import AVFoundation

struct ReaderView: View {
    @EnvironmentObject var libraryViewModel: LibraryViewModel
    @StateObject private var viewModel: ReaderViewModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("fontSize") private var fontSize: Double = 17

    @State private var showingChapterList = false
    @State private var showingSearch = false
    @State private var showingTTSSettings = false
    @State private var pendingChapterProgress: Double?
    @State private var floatingControlOffset = CGSize(width: 0, height: -160)
    @State private var floatingControlDragStart: CGSize?
    @State private var isFloatingControlCollapsed = false
    @State private var isFullScreen = false
    @State private var showNavbar = true
    @State private var showBottomInfo = false
    @State private var bottomInfoTimer: Timer?
    @State private var navbarTimer: Timer?
    @State private var fixedReadingAreaHeight: CGFloat?
    @State private var ttsErrorMessage: String?
    @State private var ttsErrorVisible = false

    @ObservedObject private var ttsService = TTSService.shared

    init(book: Book) {
        _viewModel = StateObject(wrappedValue: ReaderViewModel(book: book))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                VStack(spacing: 0) {
                    readerContent

                    if viewModel.chapters.isEmpty == false && (!isFullScreen || showBottomInfo) {
                        chapterProgressBar
                    }
                }

                if viewModel.chapters.isEmpty == false {
                    floatingPlaybackControls(in: geometry.size)
                        .offset(floatingControlOffset)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    isFloatingControlCollapsed = false
                                    let start = floatingControlDragStart ?? floatingControlOffset
                                    floatingControlDragStart = start
                                    floatingControlOffset = CGSize(
                                        width: start.width + value.translation.width,
                                        height: start.height + value.translation.height
                                    )
                                }
                                .onEnded { value in
                                    let start = floatingControlDragStart ?? floatingControlOffset
                                    let proposedOffset = CGSize(
                                        width: start.width + value.translation.width,
                                        height: start.height + value.translation.height
                                    )
                                    floatingControlOffset = snappedOffset(for: proposedOffset, in: geometry.size)
                                    isFloatingControlCollapsed = shouldCollapse(at: floatingControlOffset, in: geometry.size)
                                    if isFloatingControlCollapsed {
                                        floatingControlOffset = collapsedOffset(from: floatingControlOffset, in: geometry.size)
                                    }
                                    floatingControlDragStart = nil
                                }
                        )
                        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: floatingControlOffset)
                        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isFloatingControlCollapsed)
                }
            }
        }
        .navigationTitle(viewModel.book.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar(isFullScreen && !showNavbar ? .hidden : .automatic, for: .navigationBar)
        .toolbar(isFullScreen ? .hidden : .automatic, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: {
                    viewModel.cleanup()
                    dismiss()
                }) {
                    Image(systemName: "chevron.left")
                        .font(.title3)
                }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 16) {
                    if isFullScreen {
                        Button(action: {
                            withAnimation {
                                isFullScreen = false
                                showNavbar = true
                            }
                        }) {
                            Image(systemName: "arrow.down.right.and.arrow.up.left")
                                .font(.title3)
                        }
                    } else {
                        Button(action: {
                            withAnimation {
                                isFullScreen = true
                                showNavbar = false
                            }
                        }) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.title3)
                        }
                    }

                    Button(action: { showingSearch = true }) {
                        Image(systemName: "magnifyingglass")
                            .font(.title3)
                    }

                    Button(action: { showingChapterList = true }) {
                        Image(systemName: "list.bullet")
                            .font(.title3)
                    }

                    Button(action: { showingTTSSettings = true }) {
                        Image(systemName: "speaker.wave.2")
                            .font(.title3)
                    }
                }
            }
        }
        .sheet(isPresented: $showingChapterList) {
            ChapterListView(
                chapters: viewModel.chapters,
                currentIndex: viewModel.currentChapterIndex,
                onSelect: { index in
                    showingChapterList = false
                    revealNavbar()
                    Task { @MainActor in
                        viewModel.selectChapter(index)
                    }
                }
            )
        }
        .sheet(isPresented: $showingSearch) {
            SearchSheet(
                viewModel: viewModel,
                onSelect: { result in
                    showingSearch = false
                    revealNavbar()
                    Task { @MainActor in
                        viewModel.jumpToSearchResult(result)
                    }
                }
            )
        }
        .sheet(isPresented: $showingTTSSettings) {
            TTSSettingsSheet(
                settings: viewModel.getTTSSettings(),
                onSave: { settings in
                    viewModel.updateTTSSettings(settings)
                }
            )
        }
        .onAppear {
            viewModel.loadContent()
        }
        .onDisappear {
            viewModel.cleanup()
            libraryViewModel.loadBooks()
        }
        .onChange(of: ttsService.lastErrorMessage) { _, message in
            if let message, !message.isEmpty {
                ttsErrorMessage = message
                ttsErrorVisible = true
            }
        }
        .alert("朗读提示", isPresented: $ttsErrorVisible) {
            Button("好的", role: .cancel) {
                ttsService.lastErrorMessage = nil
                ttsErrorMessage = nil
                ttsErrorVisible = false
            }
        } message: {
            Text(ttsErrorMessage ?? "")
        }
    }

    private var readerContent: some View {
        GeometryReader { geometry in
            Group {
                if viewModel.isLoading {
                    ProgressView("加载中...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage = viewModel.errorMessage {
                    ContentUnavailableView("加载失败", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                } else if viewModel.pages.isEmpty {
                    ProgressView("分页中...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TabView(selection: Binding(
                            get: { viewModel.currentPageIndex },
                            set: { viewModel.selectPage($0) }
                        )) {
                            ForEach(Array(viewModel.pages.enumerated()), id: \.element.id) { index, page in
                                VStack(alignment: .leading, spacing: 16) {
                                    Text(page.text)
                                        .font(.system(size: fontSize))
                                        .lineSpacing(8)
                                        .lineLimit(nil)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                                    HStack {
                                        Spacer()
                                        Text("第 \(page.pageInChapter + 1) 页")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(.horizontal, 20)
                                .padding(.top, 24)
                                .padding(.bottom, 12)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .tag(index)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                        .simultaneousGesture(
                            SpatialTapGesture()
                                .onEnded { value in
                                    handleReaderTap(at: value.location, in: geometry.size)
                                }
                        )
                }
            }
            .onAppear {
                let readingHeight = readingAreaHeight(in: geometry.size)
                if fixedReadingAreaHeight == nil {
                    fixedReadingAreaHeight = readingHeight
                }
                viewModel.configurePagination(for: CGSize(width: geometry.size.width, height: readingHeight), fontSize: fontSize)
            }
            .onChange(of: geometry.size) { _, newSize in
                if let existing = fixedReadingAreaHeight {
                    viewModel.configurePagination(for: CGSize(width: newSize.width, height: existing), fontSize: fontSize)
                } else {
                    let readingHeight = readingAreaHeight(in: newSize)
                    fixedReadingAreaHeight = readingHeight
                    viewModel.configurePagination(for: CGSize(width: newSize.width, height: readingHeight), fontSize: fontSize)
                }
            }
            .onChange(of: viewModel.chapters.count) { _, _ in
                if let existing = fixedReadingAreaHeight {
                    viewModel.configurePagination(for: CGSize(width: geometry.size.width, height: existing), fontSize: fontSize)
                }
            }
            .onChange(of: fontSize) { _, newFontSize in
                if let existing = fixedReadingAreaHeight {
                    viewModel.configurePagination(for: CGSize(width: geometry.size.width, height: existing), fontSize: newFontSize)
                }
            }
        }
    }

    private func readingAreaHeight(in size: CGSize) -> CGFloat {
        let bottomBarHeight: CGFloat = 40
        let topBarHeight: CGFloat = 44
        return max(1, size.height - bottomBarHeight - topBarHeight)
    }

    private func paginationSize(in size: CGSize) -> CGSize {
        if let fixedHeight = fixedReadingAreaHeight {
            return CGSize(width: size.width, height: fixedHeight)
        }
        return CGSize(width: size.width, height: max(1, size.height))
    }

    private func revealNavbar() {
        withAnimation {
            showNavbar = true
        }
    }

    private func handleReaderTap(at location: CGPoint, in size: CGSize) {
        let leftThreshold = size.width * 0.3
        let rightThreshold = size.width * 0.7

        if isFullScreen && location.x >= leftThreshold && location.x <= rightThreshold {
            toggleFullScreenUI()
            return
        }

        if location.x < leftThreshold {
            viewModel.selectPage(viewModel.currentPageIndex - 1)
            return
        }

        if location.x > rightThreshold {
            viewModel.selectPage(viewModel.currentPageIndex + 1)
        }
    }

    private func toggleFullScreenUI() {
        bottomInfoTimer?.invalidate()
        navbarTimer?.invalidate()

        let shouldShow = !showBottomInfo
        withAnimation {
            showNavbar = shouldShow
            showBottomInfo = shouldShow
        }

        if shouldShow {
            bottomInfoTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in
                withAnimation {
                    self.showNavbar = false
                    self.showBottomInfo = false
                }
            }
            navbarTimer = bottomInfoTimer
        }
    }

    private var chapterProgressBar: some View {
        VStack(spacing: 4) {
            Slider(value: Binding(
                get: { pendingChapterProgress ?? viewModel.chapterProgress },
                set: { progress in
                    pendingChapterProgress = progress
                    viewModel.seekCurrentChapterProgress(progress, syncAudio: false)
                }
            ), in: 0...1) { isEditing in
                guard !isEditing else { return }
                let progress = pendingChapterProgress ?? viewModel.chapterProgress
                pendingChapterProgress = nil
                viewModel.seekCurrentChapterProgress(progress)
            }
                .tint(.blue)

            HStack {
                Text("\(Int((pendingChapterProgress ?? viewModel.chapterProgress) * 100))%")
                    .font(.caption2)

                Spacer()

                if let chapter = viewModel.chapters[safe: viewModel.currentChapterIndex] {
                    Text(chapter.title)
                        .lineLimit(1)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .font(.caption2)
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color(UIColor.systemBackground))
    }

    @ViewBuilder
    private func floatingPlaybackControls(in size: CGSize) -> some View {
        if isFloatingControlCollapsed {
            Button {
                isFloatingControlCollapsed = false
                floatingControlOffset.width = floatingControlOffset.width < 0 ? -size.width / 2 + 64 : size.width / 2 - 64
            } label: {
                Circle()
                    .fill(Color.blue)
                    .frame(width: 8, height: 8)
                    .padding(4)
                    .background(Circle().fill(Color.blue.opacity(0.3)))
                    .padding(6)
            }
        } else {
            HStack(spacing: 10) {
                Button(action: { viewModel.selectPreviousChapter() }) {
                    Image(systemName: "backward.end.fill")
                }

                Button(action: { viewModel.toggleTTS() }) {
                    Image(systemName: viewModel.isTTSPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(.blue, in: Circle())
                }

                Button(action: { viewModel.selectNextChapter() }) {
                    Image(systemName: "forward.end.fill")
                }
            }
            .font(.title3)
            .foregroundColor(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 4)
        }
    }

    private func snappedOffset(for proposedOffset: CGSize, in size: CGSize) -> CGSize {
        let maxX = max(0, size.width / 2 - 34)
        let maxY = max(0, size.height / 2 - 110)
        let x = min(max(proposedOffset.width, -maxX), maxX)
        let y = min(max(proposedOffset.height, -maxY), maxY - 60)
        return CGSize(width: x, height: y)
    }

    private func shouldCollapse(at offset: CGSize, in size: CGSize) -> Bool {
        abs(offset.width) > size.width / 2 - 70
    }

    private func collapsedOffset(from offset: CGSize, in size: CGSize) -> CGSize {
        let x = offset.width < 0 ? -size.width / 2 + 28 : size.width / 2 - 28
        let maxY = max(0, size.height / 2 - 110)
        let y = min(max(offset.height, -maxY), maxY - 60)
        return CGSize(width: x, height: y)
    }
}

struct ChapterListView: View {
    let chapters: [Chapter]
    let currentIndex: Int
    let onSelect: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var scrollProxy: ScrollViewProxy?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                        Button(action: { onSelect(index) }) {
                            HStack {
                                Text(chapter.title)
                                    .foregroundColor(index == currentIndex ? .blue : .primary)

                                Spacer()

                                if index == currentIndex {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                        .id(index)
                    }
                }
                .onAppear {
                    scrollProxy = proxy
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        proxy.scrollTo(currentIndex, anchor: .center)
                    }
                }
            }
            .navigationTitle("目录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

struct TTSSettingsSheet: View {
    @State var settings: TTSSettings
    let onSave: (TTSSettings) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TTSSettingsFormSection(
                    settings: $settings,
                    voiceDismissOnSelect: false
                )

                OfflineModelTuningSection(settings: $settings)
            }
            .navigationTitle("朗读设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        onSave(settings)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            settings = TTSSettings.load()
        }
    }
}

struct SearchSheet: View {
    @ObservedObject var viewModel: ReaderViewModel
    let onSelect: (SearchResult) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("搜索章节内容", text: $query)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: query) { _, newValue in
                            viewModel.search(query: newValue)
                        }
                    if !query.isEmpty {
                        Button(action: {
                            query = ""
                            viewModel.searchResults = []
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(12)
                .background(Color(.systemGray6))
                .cornerRadius(10)
                .padding()

                if viewModel.searchResults.isEmpty {
                    Spacer()
                    if query.isEmpty {
                        ContentUnavailableView(
                            "输入关键词搜索",
                            systemImage: "magnifyingglass",
                            description: Text("搜索当前书籍的章节内容")
                        )
                    } else {
                        ContentUnavailableView(
                            "未找到结果",
                            systemImage: "magnifyingglass",
                            description: Text("尝试更换关键词")
                        )
                    }
                    Spacer()
                } else {
                    List {
                        ForEach(viewModel.searchResults) { result in
                            Button(action: { onSelect(result) }) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(result.chapterTitle)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(result.highlightedContext)
                                        .font(.subheadline)
                                        .lineLimit(3)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        viewModel.searchResults = []
                        dismiss()
                    }
                }
            }
        }
    }
}

extension SearchResult {
    private static let displayContextLimit = 18

    fileprivate var highlightedContext: AttributedString {
        let maxSide = Self.displayContextLimit
        let trimmedBefore: String
        let showLeadingEllipsis: Bool
        if contextBefore.count > maxSide {
            trimmedBefore = String(contextBefore.suffix(maxSide))
            showLeadingEllipsis = true
        } else {
            trimmedBefore = contextBefore
            showLeadingEllipsis = omitsBefore
        }

        let trimmedAfter: String
        let showTrailingEllipsis: Bool
        if contextAfter.count > maxSide {
            trimmedAfter = String(contextAfter.prefix(maxSide))
            showTrailingEllipsis = true
        } else {
            trimmedAfter = contextAfter
            showTrailingEllipsis = omitsAfter
        }

        var attributed = AttributedString()
        if showLeadingEllipsis {
            attributed.append(AttributedString("..."))
        }
        attributed.append(AttributedString(trimmedBefore))

        var match = AttributedString(matchText)
        match.inlinePresentationIntent = .stronglyEmphasized
        match.foregroundColor = .accentColor
        attributed.append(match)

        attributed.append(AttributedString(trimmedAfter))
        if showTrailingEllipsis {
            attributed.append(AttributedString("..."))
        }
        return attributed
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

#Preview {
    NavigationStack {
        ReaderView(book: Book(
            title: "测试书籍",
            author: "测试作者",
            format: .txt,
            filePath: "/test/path.txt"
        ))
    }
    .environmentObject(LibraryViewModel())
}