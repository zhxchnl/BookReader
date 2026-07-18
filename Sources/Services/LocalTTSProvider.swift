import AVFoundation
import Foundation

/// Phase 2：离线降级。使用系统 `AVSpeechSynthesizer.write` 生成 CAF（无需额外二进制），
/// 音质与原生朗读一致。**说明**：句间合成为同步回调，极端情况下后台续播不如 Edge 稳定；
/// 后续可在此处替换为 sherpa-onnx 生成的 PCM/WAV。
/// **线程模型**：移除 @MainActor 隔离。所有文件 I/O 与 buffer 合并放到独立后台队列，
/// 避免占用主 actor 阻塞 UI（包括朗读提示弹窗）。
final class LocalTTSProvider: NSObject, TTSProvider, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    var kind: TTSProviderKind { .systemOfflineFile }

    private let synthesizer: AVSpeechSynthesizer
    private let stateLock = NSLock()
    private var isSynthesizing: Bool = false
    /// 文件 I/O 与 buffer 合并的独立队列（避免 DispatchQueue.main）。
    private let ioQueue = DispatchQueue(label: "com.bookreader.tts.localio", qos: .userInitiated)

    override init() {
        self.synthesizer = AVSpeechSynthesizer()
        super.init()
        // AVSpeechSynthesizerDelegate 必须在主 actor 上设置。
        // 延迟到第一次访问时设置（async）以兼容非主 actor 构造路径。
        DispatchQueue.main.async { [synthesizer, weak self] in
            synthesizer.delegate = self
        }
    }

    func synthesizeToFile(text: String, settings: TTSSettings, outputURL: URL) async throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TTSEngineError.emptyText
        }
        if FileManager.default.fileExists(atPath: outputURL.path) {
            return outputURL
        }

        await waitForSynthesisTurn()

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.rate = settings.speechRate
        utterance.pitchMultiplier = settings.pitchMultiplier

        if let voiceId = systemVoiceIdentifier(from: settings) {
            utterance.voice = AVSpeechSynthesisVoice(identifier: voiceId)
        } else {
            let lang = TTSLanguage.language(for: settings.preferredLanguageIdentifier).rawValue
            utterance.voice = AVSpeechSynthesisVoice(language: lang)
        }

        // 把 AVSpeechSynthesizer.write 触发到主 actor 上（系统 API 要求），
        // 然后把它的 buffer 回调 hop 到我们的 ioQueue 上做合并与写盘。
        let synthesizerRef = synthesizer
        let ioQueueRef = ioQueue
        let stateLockRef = stateLock
        let providerRef = self

        return try await withCheckedThrowingContinuation { continuation in
            var buffers: [AVAudioPCMBuffer] = []
            var didComplete = false
            let lock = NSLock()

            let tryMarkCompleted: () -> Bool = {
                lock.lock()
                defer { lock.unlock() }
                if didComplete { return false }
                didComplete = true
                return true
            }
            let isCompleted: () -> Bool = {
                lock.lock()
                defer { lock.unlock() }
                return didComplete
            }

            let complete: (Result<URL, Error>) -> Void = { result in
                guard tryMarkCompleted() else { return }
                stateLockRef.lock()
                providerRef.isSynthesizing = false
                stateLockRef.unlock()
                switch result {
                case .success(let url):
                    continuation.resume(returning: url)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            // AVSpeechSynthesizer.write 必须在主线程上调用。
            // 用 DispatchQueue.main.async 而非 MainActor.assumeIsolated：
            // 后者在非主 actor 的 Task/detached 上下文里会触发 unsafeForcedSync，
            // 造成 "Potential Structural Swift Concurrency Issue" 警告并可能死锁。
            DispatchQueue.main.async {
                synthesizerRef.write(utterance) { buffer in
                    guard !isCompleted() else { return }

                    if let pcm = buffer as? AVAudioPCMBuffer, Self.bufferHasAudio(pcm) {
                        lock.lock()
                        buffers.append(pcm)
                        lock.unlock()
                        return
                    }

                    lock.lock()
                    let capturedBuffers = buffers
                    lock.unlock()

                    // 把合并与写文件挪到独立 ioQueue，绝不占用 DispatchQueue.main。
                    ioQueueRef.async {
                        do {
                            guard let merged = Self.mergeBuffers(capturedBuffers), Self.bufferHasAudio(merged) else {
                                complete(.failure(TTSEngineError.synthesisFailed("无音频数据")))
                                return
                            }
                            let directory = outputURL.deletingLastPathComponent()
                            try FileManager.default.createDirectory(
                                at: directory,
                                withIntermediateDirectories: true
                            )
                            if FileManager.default.fileExists(atPath: outputURL.path) {
                                try FileManager.default.removeItem(at: outputURL)
                            }
                            let file = try AVAudioFile(forWriting: outputURL, settings: merged.format.settings)
                            try file.write(from: merged)
                            complete(.success(outputURL))
                        } catch {
                            complete(.failure(TTSEngineError.synthesisFailed(error.localizedDescription)))
                        }
                    }
                }
            }
        }
    }

    private func waitForSynthesisTurn() async {
        while true {
            let busy: Bool = stateLock.withLock { isSynthesizing }
            if !busy { break }
            await Task.yield()
        }
        stateLock.withLock { isSynthesizing = true }
    }

    private func systemVoiceIdentifier(from settings: TTSSettings) -> String? {
        let id = settings.selectedVoiceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id != settings.preferredLanguageIdentifier else {
            return nil
        }
        if id.contains("Neural") {
            return nil
        }
        return AVSpeechSynthesisVoice(identifier: id) != nil ? id : nil
    }

    private static func bufferHasAudio(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard buffer.frameLength > 0 else { return false }
        return buffer.audioBufferList.pointee.mBuffers.mDataByteSize > 0
    }

    private static func mergeBuffers(_ buffers: [AVAudioPCMBuffer]) -> AVAudioPCMBuffer? {
        let nonEmpty = buffers.filter { bufferHasAudio($0) }
        guard let first = nonEmpty.first else { return nil }
        let format = first.format
        if nonEmpty.count == 1 { return first }

        let totalFrames = nonEmpty.reduce(AVAudioFrameCount(0)) { $0 + $1.frameLength }
        guard let merged = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else { return nil }

        var offset: AVAudioFrameCount = 0
        for buf in nonEmpty {
            let frames = buf.frameLength
            guard frames > 0 else { continue }

            if let src = buf.floatChannelData, let dst = merged.floatChannelData {
                let channels = Int(format.channelCount)
                for ch in 0..<channels {
                    memcpy(dst[ch].advanced(by: Int(offset)), src[ch], Int(frames) * MemoryLayout<Float>.size)
                }
            } else if let src = buf.int16ChannelData, let dst = merged.int16ChannelData {
                let channels = Int(format.channelCount)
                for ch in 0..<channels {
                    memcpy(dst[ch].advanced(by: Int(offset)), src[ch], Int(frames) * MemoryLayout<Int16>.size)
                }
            }
            offset += frames
        }
        merged.frameLength = totalFrames
        return merged
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
