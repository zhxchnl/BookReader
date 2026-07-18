import Foundation

/// 预留：接入 sherpa-onnx 离线神经 TTS（需将预编译 `xcframework` 与中文模型打包进工程）。
/// 当前离线降级实现见 [`LocalTTSProvider`](LocalTTSProvider.swift)（系统 `AVSpeechSynthesizer.write`）。
/// 文档：<https://k2-fsa.github.io/sherpa/onnx/ios/index.html>
enum SherpaOnnxOfflineTTS {
#if SHERPA_ONNX_ENABLED
    static var isSupportedInBuild: Bool { true }
#else
    static var isSupportedInBuild: Bool { false }
#endif
}
