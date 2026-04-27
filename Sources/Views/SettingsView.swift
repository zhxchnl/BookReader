import SwiftUI
import AVFoundation

struct SettingsView: View {
    @AppStorage("speechRate") private var speechRate: Double = 0.5
    @AppStorage("pitchMultiplier") private var pitchMultiplier: Double = 1.0
    @AppStorage("selectedVoiceIdentifier") private var selectedVoiceIdentifier: String = "com.apple.voice.premium.zh-CN"
    @AppStorage("fontSize") private var fontSize: Double = 17
    @AppStorage("theme") private var theme: String = "white"

    var body: some View {
        NavigationStack {
            Form {
                Section("朗读设置") {
                    HStack {
                        Text("语速")
                        Slider(value: $speechRate, in: 0.1...1.0, step: 0.1)
                        Text(String(format: "%.1fx", speechRate))
                            .frame(width: 50)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("音调")
                        Slider(value: $pitchMultiplier, in: 0.5...2.0, step: 0.1)
                        Text(String(format: "%.1f", pitchMultiplier))
                            .frame(width: 50)
                            .foregroundColor(.secondary)
                    }

                    NavigationLink(destination: VoiceSelectionView(selectedVoice: $selectedVoiceIdentifier)) {
                        HStack {
                            Text("语音")
                            Spacer()
                            Text(currentVoiceName)
                                .foregroundColor(.secondary)
                        }
                    }
                }

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

    private var currentVoiceName: String {
        let voice = AVSpeechSynthesisVoice(identifier: selectedVoiceIdentifier)
        return voice?.name ?? "系统默认"
    }
}

struct VoiceSelectionView: View {
    @Binding var selectedVoice: String
    @Environment(\.dismiss) private var dismiss

    private var groupedVoices: [String: [AVSpeechSynthesisVoice]] {
        Dictionary(grouping: availableVoices) { voice in
            voice.languageMinimalIdentifier.hasPrefix("zh") ? "中文" : "英文"
        }
    }

    private var availableVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { voice in
            voice.languageMinimalIdentifier.hasPrefix("zh") || voice.languageMinimalIdentifier.hasPrefix("en")
        }.sorted { $0.languageMinimalIdentifier < $1.languageMinimalIdentifier }
    }

    var body: some View {
        List {
            ForEach(["中文", "英文"], id: \.self) { language in
                Section(language) {
                    ForEach(groupedVoices[language] ?? [], id: \.identifier) { voice in
                        Button(action: {
                            selectedVoice = voice.identifier
                            dismiss()
                        }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(voice.name)
                                        .foregroundColor(.primary)

                                    Text(voiceQualityText(voice))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                if voice.identifier == selectedVoice {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("选择语音")
        .navigationBarTitleDisplayMode(.inline)
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