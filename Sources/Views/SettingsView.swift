import SwiftUI
import AVFoundation

struct SettingsView: View {
    @AppStorage("fontSize") private var fontSize: Double = 17
    @AppStorage("theme") private var theme: String = "white"
    @State private var ttsSettings = TTSSettings.load()

    var body: some View {
        NavigationStack {
            Form {
                TTSSettingsFormSection(settings: $ttsSettings, onChange: saveTTSSettings)

                OfflineModelTuningSection(settings: $ttsSettings, onChange: saveTTSSettings)

                Section("阅读设置") {
                    HStack {
                        Text("字体大小")
                        Slider(value: $fontSize, in: 12...28, step: 1)
                        Text("\(Int(fontSize))pt")
                            .frame(width: 50)
                            .foregroundColor(.secondary)
                    }

                    Picker("主题", selection: $theme) {
                        Text("白色").tag("white")
                        Text("浅灰色").tag("lightGray")
                        Text("深色").tag("dark")
                        Text("护眼绿").tag("sepia")
                    }
                }

                Section("关于") {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("支持的格式")
                        Spacer()
                        Text("TXT, EPUB, PDF")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("设置")
        }
    }

    private func saveTTSSettings() {
        ttsSettings.save()
        TTSService.shared.updateSettings(ttsSettings)
    }
}

struct VoiceSelectionView: View {
    @Binding var selectedVoice: String
    let preferredLanguage: String
    var dismissOnSelect: Bool = true
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var ttsService = TTSService.shared

    private var currentLanguage: TTSLanguage {
        TTSLanguage.language(for: preferredLanguage)
    }

    private var edgeVoices: [EdgeVoiceOption] {
        EdgeVoiceCatalog.voices(for: currentLanguage)
    }

    private var availableVoices: [AVSpeechSynthesisVoice] {
        ttsService.availableVoices.filter { voice in
            voice.languageMinimalIdentifier.hasPrefix(currentLanguage.languagePrefix)
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(edgeVoices) { voice in
                    voiceRow(
                        title: voice.displayName,
                        subtitle: voice.subtitle,
                        identifier: voice.identifier
                    )
                }
            } header: {
                Text("Edge TTS（在线）")
            } footer: {
                Text("使用 Edge 或 AUTO（Edge 优先）模式时生效")
            }

            Section("默认") {
                voiceRow(
                    title: currentLanguage.defaultVoiceName,
                    subtitle: "Edge 模式下使用 \(EdgeVoiceCatalog.voices(for: currentLanguage).first?.displayName ?? "默认") 语音",
                    identifier: currentLanguage.rawValue
                )
            }

            Section("系统 TTS") {
                ForEach(availableVoices, id: \.identifier) { voice in
                    voiceRow(
                        title: voice.name,
                        subtitle: voiceQualityText(voice),
                        identifier: voice.identifier
                    )
                }
            }
        }
        .navigationTitle("选择语音")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func voiceRow(title: String, subtitle: String, identifier: String) -> some View {
        Button(action: {
            selectedVoice = identifier
            if dismissOnSelect {
                dismiss()
            }
        }) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundColor(.primary)

                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if selectedVoice == identifier {
                    Image(systemName: "checkmark")
                        .foregroundColor(.blue)
                }
            }
        }
    }

    private func voiceQualityText(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .enhanced:
            return "高品质神经网络"
        case .premium:
            return "高级神经网络"
        default:
            return "标准"
        }
    }
}

#Preview {
    SettingsView()
}