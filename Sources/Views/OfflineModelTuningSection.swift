import SwiftUI

/// Edge / Kokoro / Matcha 模型参数（设置页与阅读页朗读设置共用）
struct OfflineModelTuningSection: View {
    @Binding var settings: TTSSettings
    var onChange: (() -> Void)?

    private var currentLanguage: TTSLanguage {
        TTSLanguage.language(for: settings.preferredLanguageIdentifier)
    }

    private var edgeVoices: [EdgeVoiceOption] {
        EdgeVoiceCatalog.voices(for: currentLanguage)
    }

    var body: some View {
        Section {
            Picker("音色", selection: edgeVoiceBinding) {
                ForEach(edgeVoices) { voice in
                    Text(voice.displayName)
                        .tag(voice.id)
                }
            }

            if let selected = EdgeVoiceCatalog.option(for: resolvedEdgeVoiceId) {
                Text(selected.subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("Edge TTS")
        } footer: {
            Text("仅在朗读模型为 Edge TTS 或 AUTO（Edge 优先）时生效。也可在上方「语音」中选择。")
        }

        Section("Kokoro") {
            Picker("中文音色", selection: kokoroSpeakerBinding) {
                ForEach(KokoroSpeakerOption.allCases) { speaker in
                    Text(speaker.displayName)
                        .tag(speaker.sid)
                }
            }

            Text("请选择 zf/zm 中文音色，避免英文音色念中文。")
                .font(.caption)
                .foregroundColor(.secondary)
        }

        Section("Matcha") {
            HStack {
                Text("噪声强度")
                Slider(value: matchaNoiseScaleBinding, in: 0.0...1.5, step: 0.05)
                Text(String(format: "%.2f", Double(settings.matchaNoiseScale)))
                    .frame(width: 44)
                    .foregroundColor(.secondary)
            }

            HStack {
                Text("长度缩放")
                Slider(value: matchaLengthScaleBinding, in: 0.5...2.0, step: 0.05)
                Text(String(format: "%.2f", Double(settings.matchaLengthScale)))
                    .frame(width: 44)
                    .foregroundColor(.secondary)
            }

            Text("noiseScale 控制韵律多样性（默认 0.667）；lengthScale < 1 变慢，> 1 变快（默认 1.0）。仅在朗读模型选 Matcha 时生效。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var resolvedEdgeVoiceId: String {
        let raw = settings.selectedVoiceIdentifier
        if let option = EdgeVoiceCatalog.option(for: raw),
           edgeVoices.contains(where: { $0.id == option.id }) {
            return option.id
        }
        return EdgeVoiceCatalog.defaultVoiceIdentifier(for: currentLanguage)
    }

    private var edgeVoiceBinding: Binding<String> {
        Binding(
            get: { resolvedEdgeVoiceId },
            set: { value in
                settings.selectedVoiceIdentifier = value
                onChange?()
            }
        )
    }

    private var kokoroSpeakerBinding: Binding<Int> {
        Binding(
            get: { settings.kokoroSpeakerId },
            set: { value in
                settings.kokoroSpeakerId = value
                onChange?()
            }
        )
    }

    private var matchaNoiseScaleBinding: Binding<Double> {
        Binding(
            get: { Double(settings.matchaNoiseScale) },
            set: { value in
                settings.matchaNoiseScale = Float(value)
                onChange?()
            }
        )
    }

    private var matchaLengthScaleBinding: Binding<Double> {
        Binding(
            get: { Double(settings.matchaLengthScale) },
            set: { value in
                settings.matchaLengthScale = Float(value)
                onChange?()
            }
        )
    }
}
