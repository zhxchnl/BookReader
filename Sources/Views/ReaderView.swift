import SwiftUI
import AVFoundation

struct ReaderView: View {
    @EnvironmentObject var libraryViewModel: LibraryViewModel
    @StateObject private var viewModel: ReaderViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var showingChapterList = false
    @State private var showingTTSSettings = false
    @State private var scrollProxy: ScrollViewProxy?

    init(book: Book) {
        _viewModel = StateObject(wrappedValue: ReaderViewModel(book: book))
    }

    var body: some View {
        VStack(spacing: 0) {
            readerContent

            if viewModel.chapters.isEmpty == false {
                ttsControlBar
            }
        }
        .navigationTitle(viewModel.book.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
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
                    viewModel.selectChapter(index)
                    showingChapterList = false
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
    }

    private var readerContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if let chapter = viewModel.chapters[safe: viewModel.currentChapterIndex] {
                        Text(chapter.title)
                            .font(.title2)
                            .fontWeight(.bold)
                            .padding(.top, 8)
                            .id("chapter-\(viewModel.currentChapterIndex)")
                    }

                    Text(viewModel.currentContent)
                        .font(.body)
                        .lineSpacing(8)
                        .padding(.bottom, 100)
                }
                .padding(.horizontal, 20)
            }
            .onAppear {
                scrollProxy = proxy
            }
            .onChange(of: viewModel.currentChapterIndex) { _, newIndex in
                withAnimation {
                    proxy.scrollTo("chapter-\(newIndex)", anchor: .top)
                }
            }
        }
    }

    private var ttsControlBar: some View {
        VStack(spacing: 0) {
            Divider()

            VStack(spacing: 12) {
                HStack(spacing: 24) {
                    Button(action: { viewModel.skipToPreviousSentence() }) {
                        Image(systemName: "backward.fill")
                            .font(.title3)
                    }

                    Button(action: { viewModel.skipToPreviousSentence() }) {
                        Image(systemName: "gobackward")
                            .font(.title2)
                    }

                    Button(action: { viewModel.toggleTTS() }) {
                        Image(systemName: viewModel.isTTSPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 44))
                    }
                    .foregroundColor(.blue)

                    Button(action: { viewModel.skipToNextSentence() }) {
                        Image(systemName: "goforward")
                            .font(.title2)
                    }

                    Button(action: { viewModel.skipToNextSentence() }) {
                        Image(systemName: "forward.fill")
                            .font(.title3)
                    }
                }
                .foregroundColor(.primary)

                VStack(spacing: 4) {
                    ProgressView(value: viewModel.ttsProgress)
                        .tint(.blue)

                    HStack {
                        Text("\(Int(viewModel.ttsProgress * 100))%")

                        Spacer()

                        if let chapter = viewModel.chapters[safe: viewModel.currentChapterIndex] {
                            Text(chapter.title)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                .padding(.horizontal, 20)
            }
            .padding(.vertical, 12)
            .background(Color(UIColor.systemBackground))
        }
    }
}

struct ChapterListView: View {
    let chapters: [Chapter]
    let currentIndex: Int
    let onSelect: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
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
                Section("语速") {
                    HStack {
                        Text("速度")
                        Slider(value: $settings.speechRate, in: 0.1...1.0, step: 0.1)
                        Text(String(format: "%.1fx", settings.speechRate))
                            .frame(width: 50)
                    }
                }

                Section("音调") {
                    HStack {
                        Text("音调")
                        Slider(value: $settings.pitchMultiplier, in: 0.5...2.0, step: 0.1)
                        Text(String(format: "%.1f", settings.pitchMultiplier))
                            .frame(width: 50)
                    }
                }

                Section("语音") {
                    Picker("选择语音", selection: $settings.selectedVoiceIdentifier) {
                        ForEach(availableVoices, id: \.identifier) { voice in
                            Text(voiceDisplayName(voice))
                                .tag(voice.identifier)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }
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

    private var availableVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { voice in
            voice.languageMinimalIdentifier.hasPrefix("zh") || voice.languageMinimalIdentifier.hasPrefix("en")
        }
    }

    private func voiceDisplayName(_ voice: AVSpeechSynthesisVoice) -> String {
        let language = voice.languageMinimalIdentifier.hasPrefix("zh") ? "中文" : "英文"
        let quality = voice.quality == .enhanced ? "高品质" : "标准"
        return "\(language) - \(voice.name) (\(quality))"
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