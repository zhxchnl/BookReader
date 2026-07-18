import Foundation

/// Kokoro v1.1-zh 常用中文说话人（sid 见 sherpa-onnx 文档）
enum KokoroSpeakerOption: Int, CaseIterable, Identifiable {
    case zf001 = 3
    case zf006 = 8
    case zf018 = 12
    case zf026 = 18
    case zf039 = 24
    case zm009 = 58
    case zm021 = 70
    case zm031 = 80

    var id: Int { rawValue }

    var sid: Int { rawValue }

    var displayName: String {
        switch self {
        case .zf001: return "zf_001（女声）"
        case .zf006: return "zf_006（女声）"
        case .zf018: return "zf_018（女声）"
        case .zf026: return "zf_026（女声）"
        case .zf039: return "zf_039（女声）"
        case .zm009: return "zm_009（男声）"
        case .zm021: return "zm_021（男声）"
        case .zm031: return "zm_031（男声）"
        }
    }

    static func resolved(sid: Int) -> KokoroSpeakerOption {
        KokoroSpeakerOption(rawValue: sid) ?? .zf001
    }
}

extension TTSSettings {
    /// 用于音频缓存键，区分离线模型微调参数
    var offlineTuningCacheTag: String {
        "k\(kokoroSpeakerId)|n\(matchaNoiseScale)|ls\(matchaLengthScale)"
    }
}
