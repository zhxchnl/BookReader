import AVFoundation
import Foundation

/// sherpa-onnx 离线神经 TTS 提供者。
/// 支持 Kokoro、Melo 等 ONNX 模型，完全本地运行无需网络。
/// **线程模型**：不再标 @MainActor。ONNX wrapper 的创建与推理都是同步阻塞的 C 调用，
/// 如果放在主 actor 上会卡住整个 UI（包括朗读提示弹窗）。我们用一个内部串行队列 + 异步锁
/// 来替代 @MainActor 隔离，调用方可以从任意 actor 安全调用 synthesizeToFile。
final class SherpaOnnxTTSProvider: NSObject, TTSProvider, @unchecked Sendable {
    var kind: TTSProviderKind { .sherpaOnnxOffline }

#if SHERPA_ONNX_ENABLED
    private var wrapper: SherpaOnnxOfflineTtsWrapper?
#endif
    private var isInitialized = false
    private var initTask: Task<Void, Error>?
    /// 初始化失败后被冻结：避免后续 prefetch/warmup 反复触发 C 库 75MB+ ONNX 加载
    /// 造成"卡死"。失败原因已通过 lastInitError 暴露给上层。
    private var initAttemptFailed = false
    private var lastInitError: Error?
    private let stateLock = NSLock()

    private let modelDir: URL
    private let settings: TTSSettings

    init(modelDir: URL, settings: TTSSettings) {
        self.modelDir = modelDir
        self.settings = settings
        super.init()
    }

    func synthesizeToFile(text: String, settings: TTSSettings, outputURL: URL) async throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TTSEngineError.emptyText
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            return outputURL
        }

        try await ensureInitialized()

#if SHERPA_ONNX_ENABLED
        let currentWrapper: SherpaOnnxOfflineTtsWrapper? = stateLock.withLock { wrapper }
        guard let currentWrapper else {
            throw TTSEngineError.synthesisFailed("SherpaOnnx 初始化失败")
        }

        let prepared = TTSTextSanitizer.sanitizedForOfflineNeuralTTS(trimmed)
        guard !prepared.isEmpty else {
            throw TTSEngineError.emptyText
        }

        // 把耗时的 C API 推理与文件写入放到 detached 任务上，
        // 不阻塞调用方所在 actor（包括 @MainActor）。
        do {
            let audioURL = try await Self.runSynthesisPipeline(
                wrapper: currentWrapper,
                text: prepared,
                settings: settings,
                outputURL: outputURL
            )
            return audioURL
        } catch {
            throw TTSEngineError.synthesisFailed(error.localizedDescription)
        }
#else
        throw TTSEngineError.synthesisFailed("当前构建未启用 SherpaOnnx 依赖")
#endif
    }

    private func ensureInitialized() async throws {
        let alreadyInit: Bool = stateLock.withLock { isInitialized }
        if alreadyInit { return }

        // 已经失败过：直接抛最近一次的错误，不再触发 C 库加载，避免朗读时反复
        // 跑几秒的 ONNX 加载再失败，造成 UI 卡死。
        let (alreadyFailed, lastError): (Bool, Error?) = stateLock.withLock {
            (initAttemptFailed, lastInitError)
        }
        if alreadyFailed, let lastError {
            throw lastError
        }

        let existingTask: Task<Void, Error>? = stateLock.withLock { initTask }
        if let existingTask {
            try await existingTask.value
            return
        }

        let newTask = Task { [weak self] () throws -> Void in
            try await self?.initializeWrapper()
        }
        stateLock.withLock { self.initTask = newTask }

        do {
            try await newTask.value
        } catch {
            // 初始化失败：记录并冻结，之后调用方直接拿同一错误返回，不再触发 C 库加载。
            stateLock.withLock {
                self.initTask = nil
                self.initAttemptFailed = true
                self.lastInitError = error
            }
            throw error
        }
    }

    private func initializeWrapper() async throws {
#if SHERPA_ONNX_ENABLED
        try Self.validateModelDirectory(modelDir, modelType: settings.offlineModelType)

        let modelConfig = makeModelConfig(for: settings.offlineModelType, modelDir: modelDir)
        let ruleFsts = Self.ruleFsts(in: modelDir, modelType: settings.offlineModelType)

        // 必须在调用方所在 actor 上同步构造 C 配置并立刻传给 C 库。
        // C 结构体里 const char* 字段来自 toCPointer（NSString.utf8String），
        // 生命周期挂在调用方的 autorelease pool 上；若用 Task.detached 跳到别的
        // 线程/任务，pool 可能已被排空，C 端就会把 acoustic_model 读成空字符串
        // 进而报 "Please provide exactly one tts model."。所以这里保持同步调用。
        var config = sherpaOnnxOfflineTtsConfig(
            model: modelConfig,
            ruleFsts: ruleFsts
        )
        let created = withUnsafePointer(to: &config) { ptr in
            SherpaOnnxOfflineTtsWrapper(config: ptr)
        }

        guard created.tts != nil else {
            throw TTSEngineError.synthesisFailed("SherpaOnnx 引擎创建失败，请检查模型与 espeak-ng-data 是否完整")
        }
        stateLock.withLock {
            self.wrapper = created
            self.isInitialized = true
        }
#else
        throw TTSEngineError.synthesisFailed("当前构建未启用 SherpaOnnx 依赖")
#endif
    }

#if SHERPA_ONNX_ENABLED
    /// 在 detached 任务上跑推理 + 写文件，避免阻塞调用 actor。
    private static func runSynthesisPipeline(
        wrapper: SherpaOnnxOfflineTtsWrapper,
        text: String,
        settings: TTSSettings,
        outputURL: URL
    ) async throws -> URL {
        try await Task.detached(priority: .userInitiated) { () throws -> URL in
            let audio = generateAudioSync(wrapper: wrapper, text: text, settings: settings)
            // C 库遇到全 OOV 文本（如 ※※※）时会返回 null 指针；
            // 在访问 audio.n 之前必须先检查底层指针，否则会触发隐式解包 nil 崩溃。
            guard audio.audio != nil else {
                throw TTSEngineError.synthesisFailed("文本含模型不支持的符号，无法合成音频")
            }
            guard audio.n > 0, !audio.samples.isEmpty else {
                throw TTSEngineError.synthesisFailed("无音频数据")
            }
            try writeAudioToFileSync(audio: audio, outputURL: outputURL, settings: settings)
            return outputURL
        }.value
    }

    private func makeModelConfig(for modelType: OfflineModelType, modelDir: URL) -> SherpaOnnxOfflineTtsModelConfig {
        switch modelType {
        case .kokoroZH:
            let modelPath = modelDir.appendingPathComponent("model.onnx").path
            let tokensPath = modelDir.appendingPathComponent("tokens.txt").path
            let voicesPath = resolveVoicesPath(in: modelDir)
            let dataDir = modelDir.appendingPathComponent("espeak-ng-data").path
            let dictDir = modelDir.appendingPathComponent("dict").path
            let lexiconPath = resolveKokoroLexicon(in: modelDir)
            let kokoroConfig = sherpaOnnxOfflineTtsKokoroModelConfig(
                model: modelPath,
                voices: voicesPath,
                tokens: tokensPath,
                dataDir: dataDir,
                dictDir: dictDir,
                lexicon: lexiconPath,
                lang: "cmn"
            )
            return sherpaOnnxOfflineTtsModelConfig(kokoro: kokoroConfig, numThreads: 4, debug: 0)
        case .matchaZH:
            let acousticModelPath = resolveMatchaAcousticModelPath(in: modelDir).path
            let vocoderPath = modelDir.appendingPathComponent("vocos-22khz-univ.onnx").path
            let tokensPath = modelDir.appendingPathComponent("tokens.txt").path
            let lexiconPath = modelDir.appendingPathComponent("lexicon.txt").path
            let dictDir = modelDir.appendingPathComponent("dict").path
            // C 库会校验 espeak-ng-data/phontab 是否存在；若本目录缺失，尝试借用
            // 同 app 内已打包的 kokoro-zh 的 espeak-ng-data（同一 espeak-ng 版本，
            // 可以共用）。这样可在不重新下载的前提下让 Matcha 跑起来。
            let dataDir = resolveMatchaDataDir(primaryModelDir: modelDir)
            let matchaConfig = sherpaOnnxOfflineTtsMatchaModelConfig(
                acousticModel: acousticModelPath,
                vocoder: vocoderPath,
                lexicon: lexiconPath,
                tokens: tokensPath,
                dataDir: dataDir,
                noiseScale: settings.matchaNoiseScale,
                lengthScale: settings.matchaLengthScale,
                dictDir: dictDir
            )
            return sherpaOnnxOfflineTtsModelConfig(matcha: matchaConfig, numThreads: 4, debug: 0)
        }
    }

    private func resolveKokoroLexicon(in modelDir: URL) -> String {
        let zh = modelDir.appendingPathComponent("lexicon-zh.txt")
        let en = modelDir.appendingPathComponent("lexicon-us-en.txt")
        if FileManager.default.fileExists(atPath: zh.path),
           FileManager.default.fileExists(atPath: en.path) {
            return "\(en.path),\(zh.path)"
        }
        return zh.path
    }

    private func resolveVoicesPath(in modelDir: URL) -> String {
        let candidates = ["voices.bin", "voices.onnx"]
        for name in candidates {
            let url = modelDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                return url.path
            }
        }
        return modelDir.appendingPathComponent("voices.bin").path
    }

    /// Matcha 声学模型在 icefall 发布包中通常命名为 `model-steps-3.onnx`。
    /// 这里优先尝试该命名，回退到 `model.onnx`。
    private func resolveMatchaAcousticModelPath(in modelDir: URL) -> URL {
        let fm = FileManager.default
        let preferredNames = ["model-steps-3.onnx", "model.onnx"]
        for name in preferredNames {
            let url = modelDir.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) {
                return url
            }
        }
        return modelDir.appendingPathComponent("model-steps-3.onnx")
    }

    /// 为 Matcha 选择 espeak-ng-data 目录。
    /// 优先用本目录下的 `espeak-ng-data/`，否则借用 kokoro-zh 的同名目录——它们的
    /// phontab 来自同一 espeak-ng 版本，可以共享使用。最后回退到本目录路径，调用方
    /// 会在 C 库校验时拿到明确报错。
    private func resolveMatchaDataDir(primaryModelDir: URL) -> String {
        let fm = FileManager.default
        let phontab = "espeak-ng-data/phontab"
        let primary = primaryModelDir.appendingPathComponent("espeak-ng-data").path
        if fm.fileExists(atPath: primaryModelDir.appendingPathComponent(phontab).path) {
            return primary
        }
        if let dir = Self.bundledModelDir(for: "kokoro-zh") ?? resolveRuntimeModelDirIfValid("kokoro-zh") {
            let candidate = dir.appendingPathComponent("espeak-ng-data").path
            if fm.fileExists(atPath: dir.appendingPathComponent(phontab).path) {
                return candidate
            }
        }
        return primary
    }

    private func resolveRuntimeModelDirIfValid(_ modelId: String) -> URL? {
        let modelType = OfflineModelType(rawValue: modelId) ?? .kokoroZH
        let dir = Self.modelsDirectory().appendingPathComponent(modelId)
        return Self.isValidModelDirectory(dir, modelType: modelType) ? dir : nil
    }

    private static func generateAudioSync(
        wrapper: SherpaOnnxOfflineTtsWrapper,
        text: String,
        settings: TTSSettings
    ) -> SherpaOnnxGeneratedAudioWrapper {
        let baseSpeed = settings.speechRate * 2
        switch settings.offlineModelType {
        case .kokoroZH:
            let config = SherpaOnnxGenerationConfigSwift(
                speed: baseSpeed,
                sid: settings.kokoroSpeakerId
            )
            return wrapper.generateWithConfig(text: text, config: config, callback: nil, arg: nil)
        case .matchaZH:
            // Matcha 自身没有 lengthScale 在 wrapper 层的二次缩放；
            // 全局语速仍然走 speed 通道（与 VITS 行为一致）。
            let config = SherpaOnnxGenerationConfigSwift(
                speed: baseSpeed,
                sid: 0
            )
            return wrapper.generateWithConfig(text: text, config: config, callback: nil, arg: nil)
        }
    }

    private static func writeAudioToFileSync(
        audio: SherpaOnnxGeneratedAudioWrapper,
        outputURL: URL,
        settings: TTSSettings
    ) throws {
        let directory = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let sampleRate = Double(audio.sampleRate)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!

        let samples = paddedSamples(
            audio.samples,
            sampleRate: Int(audio.sampleRate),
            leadingMs: 0
        )
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)

        if let channelData = buffer.floatChannelData {
            for (index, sample) in samples.enumerated() {
                channelData[0][index] = sample
            }
        }

        let file = try AVAudioFile(forWriting: outputURL, settings: format.settings)
        try file.write(from: buffer)
    }

    private static func paddedSamples(_ samples: [Float], sampleRate: Int, leadingMs: Int) -> [Float] {
        guard leadingMs > 0, sampleRate > 0 else { return samples }
        let padCount = sampleRate * leadingMs / 1000
        guard padCount > 0 else { return samples }
        return [Float](repeating: 0, count: padCount) + samples
    }
#endif
}

// MARK: - 模型目录管理

extension SherpaOnnxTTSProvider {
    /// 模型文件根目录（运行时位置）：Application Support/SherpaModels/
    static func modelsDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("SherpaModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 查找 App Bundle 内已打包的模型目录。
    static func bundledModelDir(for modelId: String) -> URL? {
        let candidates: [URL] = [
            Bundle.main.resourceURL?.appendingPathComponent(modelId),
            Bundle.main.resourceURL?.appendingPathComponent("Models").appendingPathComponent(modelId),
        ].compactMap { $0 }

        for dir in candidates {
            if Self.resolveOnnxModelPath(in: dir) != nil {
                return dir
            }
        }
        return nil
    }

    /// 查找模型目录中的主 ONNX 文件。Piper 等发布包使用 `zh_CN-huayan-medium.onnx` 等命名，而非 `model.onnx`。
    static func resolveOnnxModelPath(in modelDir: URL) -> URL? {
        let fm = FileManager.default
        let standard = modelDir.appendingPathComponent("model.onnx")
        if fm.fileExists(atPath: standard.path) {
            return standard
        }
        guard let contents = try? fm.contentsOfDirectory(
            at: modelDir,
            includingPropertiesForKeys: nil
        ) else {
            return nil
        }
        return contents
            .filter { $0.pathExtension == "onnx" }
            .filter { $0.lastPathComponent != "voices.onnx" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
    }

    /// 检查指定模型是否已下载/内置到本地（须包含 espeak-ng-data 等必需文件）
    static func isModelDownloaded(modelId: String) -> Bool {
        let modelType = OfflineModelType(rawValue: modelId) ?? .kokoroZH
        let runtimeDir = modelsDirectory().appendingPathComponent(modelId)
        if isValidModelDirectory(runtimeDir, modelType: modelType) {
            return true
        }
        if let bundled = bundledModelDir(for: modelId),
           isValidModelDirectory(bundled, modelType: modelType) {
            return true
        }
        return false
    }

    /// 获取模型目录，优先完整运行时下载，否则用 Bundle 内置
    static func resolveModelDir(for modelId: String) -> URL {
        let modelType = OfflineModelType(rawValue: modelId) ?? .kokoroZH
        let runtimeDir = modelsDirectory().appendingPathComponent(modelId)
        if isValidModelDirectory(runtimeDir, modelType: modelType) {
            return runtimeDir
        }
        if let bundled = bundledModelDir(for: modelId),
           isValidModelDirectory(bundled, modelType: modelType) {
            return bundled
        }
        return runtimeDir
    }

    private static func isValidModelDirectory(_ dir: URL, modelType: OfflineModelType) -> Bool {
        let fm = FileManager.default
        guard resolveOnnxModelPath(in: dir) != nil,
              fm.fileExists(atPath: dir.appendingPathComponent("tokens.txt").path) else {
            return false
        }
        switch modelType {
        case .kokoroZH:
            guard fm.fileExists(atPath: dir.appendingPathComponent("espeak-ng-data/phontab").path),
                  fm.fileExists(atPath: dir.appendingPathComponent("dict/jieba.dict.utf8").path),
                  fm.fileExists(atPath: dir.appendingPathComponent("lexicon-zh.txt").path) else {
                return false
            }
            let hasVoice = ["voices.bin", "voices.onnx"].contains {
                fm.fileExists(atPath: dir.appendingPathComponent($0).path)
            }
            return hasVoice
        case .matchaZH:
            // 声学模型（model-steps-3.onnx 或 model.onnx 已被 resolveOnnxModelPath 通过）
            // 声码器必须独立存在
            let hasAcoustic = fm.fileExists(atPath: dir.appendingPathComponent("model-steps-3.onnx").path)
                || fm.fileExists(atPath: dir.appendingPathComponent("model.onnx").path)
            let hasVocoder = fm.fileExists(atPath: dir.appendingPathComponent("vocos-22khz-univ.onnx").path)
                || fm.fileExists(atPath: dir.appendingPathComponent("hifigan_v2.onnx").path)
                || fm.fileExists(atPath: dir.appendingPathComponent("hifigan_v3.onnx").path)
            guard hasAcoustic, hasVocoder,
                  fm.fileExists(atPath: dir.appendingPathComponent("lexicon.txt").path) else {
                return false
            }
            // C 库 MatchaModelConfig::Validate 要求 espeak-ng-data/phontab 必须存在。
            // 缺时尝试借用 kokoro-zh 的同名目录——它们是同一 espeak-ng 版本，
            // 若可用即视为本模型就绪，避免误判导致朗读走错路径。
            if fm.fileExists(atPath: dir.appendingPathComponent("espeak-ng-data/phontab").path) {
                return true
            }
            if let shared = bundledModelDir(for: "kokoro-zh")
                ?? Self.runtimeModelDirIfValid("kokoro-zh"),
               fm.fileExists(atPath: shared.appendingPathComponent("espeak-ng-data/phontab").path) {
                return true
            }
            return false
        }
    }

    private static func runtimeModelDirIfValid(_ modelId: String) -> URL? {
        let modelType = OfflineModelType(rawValue: modelId) ?? .kokoroZH
        let dir = modelsDirectory().appendingPathComponent(modelId)
        return isValidModelDirectory(dir, modelType: modelType) ? dir : nil
    }

    private static func validateModelDirectory(_ dir: URL, modelType: OfflineModelType) throws {
        guard isValidModelDirectory(dir, modelType: modelType) else {
            let hint: String
            switch modelType {
            case .kokoroZH:
                hint = "缺少 espeak-ng-data、dict 或 lexicon。若曾不完整下载，请删除 Application Support/SherpaModels/\(dir.lastPathComponent) 后重装 App 或重新下载。"
            case .matchaZH:
                hint = "缺少声学 model-steps-3.onnx、声码器 vocos-22khz-univ.onnx、lexicon.txt 或 espeak-ng-data/phontab。Matcha 需包含声学 onnx + 声码器 onnx + lexicon.txt + tokens.txt + dict/ + phone/date/number.fst + espeak-ng-data/（可借用 kokoro-zh 的同名目录）。"
            }
            throw TTSEngineError.synthesisFailed("模型目录不完整（\(dir.path)）：\(hint)")
        }
    }

    private static func ruleFsts(in modelDir: URL, modelType: OfflineModelType) -> String {
        let names: [String]
        switch modelType {
        case .kokoroZH:
            names = ["phone-zh.fst", "date-zh.fst", "number-zh.fst"]
        case .matchaZH:
            names = ["phone.fst", "date.fst", "number.fst"]
        }
        let paths = names
            .map { modelDir.appendingPathComponent($0).path }
            .filter { FileManager.default.fileExists(atPath: $0) }
        return paths.joined(separator: ",")
    }

    /// 返回当前设置的离线模型 ID（如 "kokoro-zh", "matcha-zh"）
    static func activeModelId(for settings: TTSSettings) -> String {
        settings.offlineModelType.rawValue
    }

#if SHERPA_ONNX_ENABLED
    static var isRuntimeSupported: Bool { true }
#else
    static var isRuntimeSupported: Bool { false }
#endif
}

// MARK: - 线程同步辅助

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
