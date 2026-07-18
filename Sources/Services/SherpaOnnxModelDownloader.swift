import Foundation

/// 负责从 Hugging Face 下载 sherpa-onnx TTS 模型到本地。
/// 下载完成后模型保存在 Application Support/SherpaModels/ 下。
@MainActor
final class SherpaOnnxModelDownloader: ObservableObject {
    static let shared = SherpaOnnxModelDownloader()

    @Published private(set) var downloadProgress: [String: Double] = [:]
    @Published private(set) var downloadingModelId: String?

    private var urlSession: URLSession?

    private init() {}

    func download(model: OfflineModelType, progressHandler: @escaping (Double) -> Void) async throws {
        let modelId = model.huggingfaceModelId
        guard downloadingModelId == nil else { return }
        downloadingModelId = modelId

        defer {
            Task { @MainActor in
                self.downloadingModelId = nil
                self.downloadProgress[modelId] = nil
            }
        }

        let destDir = SherpaOnnxTTSProvider.modelsDirectory().appendingPathComponent(model.rawValue)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let apiURL = URL(string: "https://huggingface.co/api/models/\(modelId)/tree/main")!
        var request = URLRequest(url: apiURL)
        request.setValue("Bearer \(huggingfaceToken)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let filesJson = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw SherpaDownloadError.invalidApiResponse
        }

        let modelFiles = filesJson.compactMap { entry -> (filename: String, path: String)? in
            guard let type = entry["type"] as? String, type == "file",
                  let path = entry["path"] as? String,
                  let filename = path.components(separatedBy: "/").last else {
                return nil
            }
            return (filename, path)
        }

        guard !modelFiles.isEmpty else {
            throw SherpaDownloadError.noFilesFound
        }

        for (index, file) in modelFiles.enumerated() {
            let fileProgress = Double(index) / Double(modelFiles.count)
            progressHandler(fileProgress)

            let fileURL = destDir.appendingPathComponent(file.filename)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                continue
            }

            let downloadURL = URL(string: "https://huggingface.co/\(modelId)/resolve/main/\(file.path)")!
            var fileRequest = URLRequest(url: downloadURL)
            fileRequest.setValue("Bearer \(huggingfaceToken)", forHTTPHeaderField: "Authorization")

            let (fileData, response) = try await URLSession.shared.data(for: fileRequest)

            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                try fileData.write(to: fileURL)
            }

            progressHandler(fileProgress + 1.0 / Double(modelFiles.count))
        }

        progressHandler(1.0)
    }

    private var huggingfaceToken: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            .flatMap { URL(fileURLWithPath: $0.path).appendingPathComponent("huggingface_token.txt") }
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            ?? ""
    }

    enum SherpaDownloadError: LocalizedError {
        case invalidApiResponse
        case noFilesFound
        case modelNotFound

        var errorDescription: String? {
            switch self {
            case .invalidApiResponse: return "无法获取模型文件列表"
            case .noFilesFound: return "模型目录下没有找到 ONNX 文件"
            case .modelNotFound: return "模型不存在"
            }
        }
    }
}

// MARK: - 模型自动降级策略管理器

/// 跟踪合成性能并在必要时触发模型降级/升级。
/// 当连续 N 句 RTF 超阈值时自动切换到更轻量/更重的模型。
@MainActor
final class TTSModelAdaptiveManager: ObservableObject {
    static let shared = TTSModelAdaptiveManager()

    /// 连续高压阈值（RTF 超过此值视为"慢"）
    private let degradeRTFThreshold: Double = 1.5
    /// 连续高性能阈值（RTF 低于此值且连续 N 次，可尝试升级）
    private let promoteRTFThreshold: Double = 0.7
    /// 触发降级的连续慢句数量
    private let degradeConsecutiveCount = 3
    /// 触发升级的连续快句数量
    private let promoteConsecutiveCount = 5

    /// 当前设备热状态（用于结合温度降级）
    private(set) var currentThermalState: ProcessInfo.ThermalState = .nominal

    /// 各模型的降级优先级（数字越大越轻量）
    private let modelPriority: [OfflineModelType: Int] = [
        .kokoroZH: 0,
        .matchaZH: 1,
    ]

    private var slowSentenceCount = 0
    private var fastSentenceCount = 0

    private init() {
        observeThermalState()
    }

    private func observeThermalState() {
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.currentThermalState = ProcessInfo.processInfo.thermalState
            }
        }
    }

    /// 记录一句的合成结果，返回是否需要切换模型
    func recordSynthesis(duration: TimeInterval, audioDuration: TimeInterval) -> ModelSwitchRecommendation? {
        guard audioDuration > 0 else { return nil }
        let rtf = duration / audioDuration

        if rtf > degradeRTFThreshold {
            slowSentenceCount += 1
            fastSentenceCount = 0
            if slowSentenceCount >= degradeConsecutiveCount {
                slowSentenceCount = 0
                return .degrade
            }
        } else if rtf < promoteRTFThreshold {
            fastSentenceCount += 1
            slowSentenceCount = 0
            if fastSentenceCount >= promoteConsecutiveCount {
                fastSentenceCount = 0
                return .promote
            }
        } else {
            slowSentenceCount = 0
            fastSentenceCount = 0
        }

        // 如果设备过热，强制降级
        if currentThermalState == .critical || currentThermalState == .serious {
            return .degrade
        }

        return nil
    }

    /// 根据当前模型和方向，推荐下一个模型
    func recommendedModel(current: OfflineModelType, direction: ModelSwitchDirection) -> OfflineModelType {
        let sorted = modelPriority.sorted { $0.value < $1.value }
        let currentIdx = sorted.firstIndex { $0.key == current } ?? 0

        switch direction {
        case .degrade:
            let nextIdx = min(currentIdx + 1, sorted.count - 1)
            return sorted[nextIdx].key
        case .promote:
            let nextIdx = max(currentIdx - 1, 0)
            return sorted[nextIdx].key
        }
    }

    enum ModelSwitchRecommendation {
        case degrade
        case promote
    }

    enum ModelSwitchDirection {
        case degrade
        case promote
    }
}