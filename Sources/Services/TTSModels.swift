import AVFoundation
import Foundation

/// 朗读引擎选择（含 AUTO 策略与固定模型）
enum TTSModelSelection: String, Codable, CaseIterable, Identifiable {
    case autoLocal = "auto-local"
    case autoOnline = "auto-online"
    case autoEdge = "auto-edge"
    case kokoro = "kokoro-zh"
    case matcha = "matcha-zh"
    case edge = "edge"
    case system = "system"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .autoLocal: return "AUTO（本地模型）"
        case .autoOnline: return "AUTO（可联网）"
        case .autoEdge: return "AUTO（Edge 优先）"
        case .kokoro: return "Kokoro"
        case .matcha: return "Matcha"
        case .edge: return "Edge TTS"
        case .system: return "系统 TTS"
        }
    }

    var detailDescription: String {
        switch self {
        case .autoLocal:
            return "优先最佳本地模型，不可用时系统 TTS 兜底"
        case .autoOnline:
            return "优先最佳本地模型，不可用时使用 Edge TTS，系统 TTS 兜底"
        case .autoEdge:
            return "优先 Edge 在线语音，超时或不可用时降级为 Matcha 本地模型，系统 TTS 兜底"
        case .kokoro, .matcha:
            return "仅使用 \(displayName) 本地模型，失败时系统 TTS 兜底"
        case .edge:
            return "仅使用 Edge 在线语音，失败时系统 TTS 兜底"
        case .system:
            return "仅使用 iOS 系统语音"
        }
    }

    var isAutoMode: Bool {
        self == .autoLocal || self == .autoOnline || self == .autoEdge
    }

    /// 本地模型优先级（品质从高到低）。Matcha 故意不在此列：仅在用户手动选择或 Edge 兜底时参与。
    static let localModelPriority: [OfflineModelType] = [
        .kokoroZH,
    ]

    var isFixedLocalModel: Bool {
        offlineModelType != nil
    }

    var offlineModelType: OfflineModelType? {
        OfflineModelType(rawValue: rawValue)
    }

    static func from(offlineModelType: OfflineModelType) -> TTSModelSelection {
        switch offlineModelType {
        case .kokoroZH: return .kokoro
        case .matchaZH: return .matcha
        }
    }
}

enum TTSProviderKind {
    case edgeOnline
    case systemOfflineFile
    case sherpaOnnxOffline

    /// 用于稳定 TTS 音频缓存文件名（哈希盐）
    var cacheKeyTag: String {
        switch self {
        case .edgeOnline: return "edgeOnline"
        case .systemOfflineFile: return "systemOfflineFile"
        case .sherpaOnnxOffline: return "sherpaOnnx"
        }
    }
}

enum TTSEngineError: LocalizedError {
    case emptyText
    case synthesisFailed(String)
    case networkUnavailable
    case cacheWriteFailed(Error)

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "朗读文本为空"
        case .synthesisFailed(let reason):
            return "语音合成失败：\(reason)"
        case .networkUnavailable:
            return "无网络连接，已切换离线语音（离线模式下后台播放可能不稳定）"
        case .cacheWriteFailed(let error):
            return "缓存音频失败：\(error.localizedDescription)"
        }
    }
}

/// Edge TTS 常用语音选项
struct EdgeVoiceOption: Identifiable, Hashable {
    let id: String
    let displayName: String
    let subtitle: String

    var identifier: String { id }
}

enum EdgeVoiceCatalog {
    static let chineseVoices: [EdgeVoiceOption] = [
        EdgeVoiceOption(id: "zh-CN-XiaoxiaoNeural", displayName: "晓晓", subtitle: "女声 · 温暖，适合小说"),
        EdgeVoiceOption(id: "zh-CN-XiaoyiNeural", displayName: "晓伊", subtitle: "女声 · 活泼"),
        EdgeVoiceOption(id: "zh-CN-YunxiNeural", displayName: "云希", subtitle: "男声 · 阳光"),
        EdgeVoiceOption(id: "zh-CN-YunjianNeural", displayName: "云健", subtitle: "男声 · 热情"),
        EdgeVoiceOption(id: "zh-CN-YunxiaNeural", displayName: "云夏", subtitle: "男声 · 可爱"),
        EdgeVoiceOption(id: "zh-CN-YunyangNeural", displayName: "云扬", subtitle: "男声 · 专业"),
        EdgeVoiceOption(id: "zh-CN-liaoning-XiaobeiNeural", displayName: "晓北", subtitle: "女声 · 辽宁方言"),
        EdgeVoiceOption(id: "zh-CN-shaanxi-XiaoniNeural", displayName: "晓妮", subtitle: "女声 · 陕西方言"),
    ]

    static let englishVoices: [EdgeVoiceOption] = [
        EdgeVoiceOption(id: "en-US-JennyNeural", displayName: "Jenny", subtitle: "Female · Friendly"),
        EdgeVoiceOption(id: "en-US-GuyNeural", displayName: "Guy", subtitle: "Male · Passion"),
        EdgeVoiceOption(id: "en-US-AriaNeural", displayName: "Aria", subtitle: "Female · Confident"),
        EdgeVoiceOption(id: "en-US-AndrewNeural", displayName: "Andrew", subtitle: "Male · Warm"),
        EdgeVoiceOption(id: "en-US-EmmaNeural", displayName: "Emma", subtitle: "Female · Cheerful"),
        EdgeVoiceOption(id: "en-US-BrianNeural", displayName: "Brian", subtitle: "Male · Casual"),
        EdgeVoiceOption(id: "en-GB-SoniaNeural", displayName: "Sonia", subtitle: "Female · British"),
        EdgeVoiceOption(id: "en-GB-RyanNeural", displayName: "Ryan", subtitle: "Male · British"),
    ]

    static func voices(for language: TTSLanguage) -> [EdgeVoiceOption] {
        switch language {
        case .chinese: return chineseVoices
        case .english: return englishVoices
        }
    }

    static func defaultVoiceIdentifier(for language: TTSLanguage) -> String {
        voices(for: language).first?.id ?? "zh-CN-XiaoxiaoNeural"
    }

    static func option(for identifier: String) -> EdgeVoiceOption? {
        (chineseVoices + englishVoices).first { $0.id == identifier }
    }

    static func isEdgeVoice(_ identifier: String) -> Bool {
        identifier.contains("Neural") && identifier.contains("-")
    }
}

enum TTSVoiceDisplay {
    static func name(
        for identifier: String,
        language: TTSLanguage,
        systemVoices: [AVSpeechSynthesisVoice] = []
    ) -> String {
        if identifier == language.rawValue {
            return language.defaultVoiceName
        }
        if let edge = EdgeVoiceCatalog.option(for: identifier) {
            return "Edge · \(edge.displayName)"
        }
        if let voice = systemVoices.first(where: { $0.identifier == identifier }) {
            return voice.name
        }
        return language.defaultVoiceName
    }
}

/// 将 TTSSettings 映射为 Microsoft Edge 神经语音名称
enum EdgeVoiceResolver {
    static func neuralVoiceIdentifier(for settings: TTSSettings) -> String {
        let raw = settings.selectedVoiceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if EdgeVoiceCatalog.isEdgeVoice(raw) {
            return raw
        }
        let lang = TTSLanguage.language(for: settings.preferredLanguageIdentifier)
        return EdgeVoiceCatalog.defaultVoiceIdentifier(for: lang)
    }

    /// Edge TTS rate: e.g. "+10%", "-20%"
    static func edgeRateString(speechRate: Float) -> String {
        let centered = Double(speechRate) - 0.5
        let percent = centered * 200.0
        if percent >= 0 {
            return String(format: "+%.0f%%", percent)
        }
        return String(format: "%.0f%%", percent)
    }

    /// Edge pitch: e.g. "+2Hz", "-10Hz"
    static func edgePitchString(pitchMultiplier: Float) -> String {
        let deltaHz = (Double(pitchMultiplier) - 1.0) * 80.0
        if deltaHz >= 0 {
            return String(format: "+%.0fHz", deltaHz)
        }
        return String(format: "%.0fHz", deltaHz)
    }
}

/// 文本 → 本地音频文件，由 `AVAudioPlayer` 播放以实现后台朗读。
/// **线程模型**：协议本身不限 actor；具体实现决定在哪个线程跑。
/// 耗时实现（如 Edge/Kokoro）应避免占用 @MainActor，否则会阻塞 UI alert 等。
protocol TTSProvider: AnyObject, Sendable {
    var kind: TTSProviderKind { get }

    func synthesizeToFile(text: String, settings: TTSSettings, outputURL: URL) async throws -> URL
}
