import SwiftUI
import AVFoundation

/// 设置页与阅读页朗读设置共用的表单区块
struct TTSSettingsFormSection: View {
    @Binding var settings: TTSSettings
    var onChange: (() -> Void)?
    var voiceDismissOnSelect: Bool = true

    @ObservedObject private var ttsService = TTSService.shared

    var body: some View {
        Section("朗读设置") {
            HStack {
                Text("语速")
                Slider(value: speechRateBinding, in: 0.1...1.0, step: 0.1)
                Text(String(format: "%.1fx", Double(settings.speechRate)))
                    .frame(width: 50)
                    .foregroundColor(.secondary)
            }

            HStack {
                Text("音调")
                Slider(value: pitchMultiplierBinding, in: 0.5...2.0, step: 0.1)
                Text(String(format: "%.1f", Double(settings.pitchMultiplier)))
                    .frame(width: 50)
                    .foregroundColor(.secondary)
            }

            Picker("朗读语言", selection: preferredLanguageBinding) {
                ForEach(TTSLanguage.allCases) { language in
                    Text(language.displayName)
                        .tag(language.rawValue)
                }
            }

            NavigationLink {
                VoiceSelectionView(
                    selectedVoice: selectedVoiceBinding,
                    preferredLanguage: settings.preferredLanguageIdentifier,
                    dismissOnSelect: voiceDismissOnSelect
                )
            } label: {
                HStack {
                    Text("语音")
                    Spacer()
                    Text(currentVoiceName)
                        .foregroundColor(.secondary)
                }
            }

            Picker("朗读模型", selection: modelSelectionBinding) {
                Text(TTSModelSelection.autoEdge.displayName)
                    .tag(TTSModelSelection.autoEdge)
                Text(TTSModelSelection.kokoro.displayName)
                    .tag(TTSModelSelection.kokoro)
                Text(TTSModelSelection.matcha.displayName)
                    .tag(TTSModelSelection.matcha)
                Text(TTSModelSelection.edge.displayName)
                    .tag(TTSModelSelection.edge)
                Text(TTSModelSelection.system.displayName)
                    .tag(TTSModelSelection.system)
            }

            if settings.modelSelection.offlineModelType != nil || settings.modelSelection.isAutoMode {
                Button("下载离线模型") {
                    downloadModel()
                }
                .disabled(isModelDownloaded)

                if isModelDownloaded {
                    Label("模型已就绪", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                } else {
                    Label("未下载（\(settings.offlineModelType.estimatedSizeMB, specifier: "%.0f")MB）", systemImage: "arrow.down.circle")
                        .foregroundColor(.orange)
                        .font(.caption)
                }
            }

            Text(settings.modelSelection.detailDescription)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var currentVoiceName: String {
        TTSVoiceDisplay.name(
            for: settings.selectedVoiceIdentifier,
            language: TTSLanguage.language(for: settings.preferredLanguageIdentifier),
            systemVoices: ttsService.availableVoices
        )
    }

    private var isModelDownloaded: Bool {
        SherpaOnnxTTSProvider.isModelDownloaded(
            modelId: SherpaOnnxTTSProvider.activeModelId(for: settings)
        )
    }

    private func notifyChange() {
        onChange?()
    }

    private func downloadModel() {
        let model = settings.offlineModelType
        Task {
            do {
                try await SherpaOnnxModelDownloader.shared.download(model: model) { progress in
                    print("Download progress: \(progress)")
                }
            } catch {
                print("Model download failed: \(error.localizedDescription)")
            }
        }
    }

    private var speechRateBinding: Binding<Double> {
        Binding(
            get: { Double(settings.speechRate) },
            set: { value in
                settings.speechRate = Float(value)
                notifyChange()
            }
        )
    }

    private var pitchMultiplierBinding: Binding<Double> {
        Binding(
            get: { Double(settings.pitchMultiplier) },
            set: { value in
                settings.pitchMultiplier = Float(value)
                notifyChange()
            }
        )
    }

    private var preferredLanguageBinding: Binding<String> {
        Binding(
            get: { settings.preferredLanguageIdentifier },
            set: { value in
                settings.preferredLanguageIdentifier = value
                let language = TTSLanguage.language(for: value)
                if EdgeVoiceCatalog.isEdgeVoice(settings.selectedVoiceIdentifier) {
                    settings.selectedVoiceIdentifier = EdgeVoiceCatalog.defaultVoiceIdentifier(for: language)
                } else {
                    settings.selectedVoiceIdentifier = value
                }
                notifyChange()
            }
        )
    }

    private var selectedVoiceBinding: Binding<String> {
        Binding(
            get: { settings.selectedVoiceIdentifier },
            set: { value in
                settings.selectedVoiceIdentifier = value
                notifyChange()
            }
        )
    }

    private var modelSelectionBinding: Binding<TTSModelSelection> {
        Binding(
            get: { settings.modelSelection },
            set: { value in
                settings.modelSelection = value
                if let offline = value.offlineModelType {
                    settings.offlineModelType = offline
                } else if value.isAutoMode {
                    settings.offlineModelType = .kokoroZH
                }
                notifyChange()
            }
        )
    }
}
