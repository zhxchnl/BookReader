import Foundation

/// 离线神经 TTS（sherpa-onnx / Kokoro）输入清洗：去掉 emoji 等词表不支持的字符。
enum TTSTextSanitizer {
    /// 供 Kokoro / VITS 等离线模型使用。
    static func sanitizedForOfflineNeuralTTS(_ text: String) -> String {
        var scalars: [UnicodeScalar] = []
        scalars.reserveCapacity(text.unicodeScalars.count)

        for scalar in text.unicodeScalars {
            if shouldDrop(scalar) { continue }
            scalars.append(normalized(scalar))
        }

        let collapsed = String(String.UnicodeScalarView(scalars))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed
    }

    private static func shouldDrop(_ scalar: UnicodeScalar) -> Bool {
        if scalar.properties.isEmoji || scalar.properties.isEmojiPresentation {
            return true
        }
        switch scalar.value {
        case 0x200D, 0xFE0F: // ZWJ、variation selector
            return true
        case 0xFFFC: // object replacement
            return true
        // 装饰性标记符号：TTS 模型词表通常不包含这些字符，会导致 OOV
        // 整段文本全为 OOV 时 C 库返回 null 指针，引发崩溃
        case 0x203B: // ※ REFERENCE MARK（常见于中文书籍注释）
            return true
        case 0x2020, 0x2021: // †‡ DAGGER / DOUBLE DAGGER
            return true
        case 0x2600...0x26FF: // Miscellaneous Symbols（☀☁♠♣ 等）
            return true
        case 0x2700...0x27BF: // Dingbats（✂✈✉ 等）
            return true
        case 0x1F300...0x1FFFF: // Emoji / misc supplementary（防止 isEmoji 漏网）
            return true
        default:
            break
        }
        let category = scalar.properties.generalCategory
        if category == .otherSymbol || category == .privateUse {
            return true
        }
        return false
    }

    /// 将全角标点等映射为模型 tokens.txt 中常见的 ASCII 形式。
    private static func normalized(_ scalar: UnicodeScalar) -> UnicodeScalar {
        switch scalar.value {
        case 0xFF1F: return UnicodeScalar(0x3F)! // ？ → ?
        case 0xFF01: return UnicodeScalar(0x21)! // ！ → !
        case 0xFF0C: return UnicodeScalar(0x2C)! // ， → ,
        case 0xFF0E, 0x3002: return UnicodeScalar(0x2E)! // ．/。 → .
        default:
            return scalar
        }
    }
}
