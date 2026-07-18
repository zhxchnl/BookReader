import Foundation
import SwiftEdgeTTS

/// Edge TTS 在线合成提供者。
/// 不再标 @MainActor：WebSocket 通讯 + URLSession 数据 IO 都不应该占用主 actor，
/// 否则 UI（包括朗读提示弹窗）会被深度 await 链阻塞而无法响应。
final class EdgeTTSProvider: TTSProvider, @unchecked Sendable {
    var kind: TTSProviderKind { .edgeOnline }

    private let service: EdgeTTSService

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        let session = URLSession(configuration: config)
        self.service = EdgeTTSService(session: session)
    }

    func synthesizeToFile(text: String, settings: TTSSettings, outputURL: URL) async throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TTSEngineError.emptyText
        }

        let voice = EdgeVoiceResolver.neuralVoiceIdentifier(for: settings)
        let rate = EdgeVoiceResolver.edgeRateString(speechRate: settings.speechRate)
        let pitch = EdgeVoiceResolver.edgePitchString(pitchMultiplier: settings.pitchMultiplier)

        // 在 detached 任务里跑实际合成，避免占用主 actor。
        // 超时 15 秒后通过 task 取消传到底层 URLSession。
        do {
            return try await withTaskTimeout(seconds: 15) {
                try await Self.runSynthesize(
                    service: self.service,
                    text: trimmed,
                    voice: voice,
                    rate: rate,
                    pitch: pitch,
                    outputURL: outputURL
                )
            }
        } catch is CancellationError {
            throw TTSEngineError.synthesisFailed("Edge TTS 请求超时（15秒）")
        } catch {
            throw TTSEngineError.synthesisFailed(error.localizedDescription)
        }
    }

    private static func runSynthesize(
        service: EdgeTTSService,
        text: String,
        voice: String,
        rate: String,
        pitch: String,
        outputURL: URL
    ) async throws -> URL {
        try await service.synthesize(
            text: text,
            voice: voice,
            outputURL: outputURL,
            rate: rate,
            volume: nil,
            pitch: pitch
        )
    }
}

/// 超时包装器：超过指定秒数则取消任务并抛出 CancellationError。
/// **关键**：内部用 `Task.detached` 跑 operation，确保它不在调用方 actor 上执行，
/// 否则主 actor 上的长时间 await 会阻塞 UI（包括朗读提示弹窗）。
func withTaskTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await Task.detached(priority: .userInitiated) {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CancellationError()
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }.value
}
