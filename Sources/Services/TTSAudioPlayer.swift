import AVFoundation
import Foundation

/// 使用 `AVAudioPlayer` 播放合成后的音频文件（MP3 / CAF），以支持后台与锁屏控制。
final class TTSAudioPlayer: NSObject, AVAudioPlayerDelegate {
    var onPlaybackFinished: (() -> Void)?

    private var player: AVAudioPlayer?
    private var isEndedNotified = false
    private var sessionActivated = false

    /// 配置 AVAudioSession 为 `.playback` 长音频朗读模式。
    /// 仅在第一次播放时激活，避免句间被反复 deactivate 导致后台被系统挂起。
    func activatePlaybackSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
        } catch {
            print("[TTS] setCategory failed: \(error.localizedDescription)")
        }
        do {
            try session.setActive(true, options: [])
            sessionActivated = true
        } catch {
            print("[TTS] setActive failed: \(error.localizedDescription)")
        }
        #endif
    }

    /// 仅在彻底停止朗读（用户 stop 或队列结束）时调用。句间播放结束**不要**调用此方法，
    /// 否则在后台模式下会让系统判定 app 不再需要音频，从而挂起进程并停止后续合成。
    func deactivateSessionIfIdle() {
        #if os(iOS)
        guard player == nil else { return }
        guard sessionActivated else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            sessionActivated = false
        } catch {
            print("[TTS] setActive(false) failed: \(error.localizedDescription)")
        }
        #endif
    }

    /// 开始播放；结束时调用 `onPlaybackFinished`（仅一次）。
    func play(url: URL) throws {
        isEndedNotified = false
        activatePlaybackSession()
        player?.stop()
        let newPlayer = try AVAudioPlayer(contentsOf: url)
        newPlayer.delegate = self
        newPlayer.prepareToPlay()
        let started = newPlayer.play()
        if started == false {
            print("[TTS] AVAudioPlayer.play() returned false (session activated=\(sessionActivated))")
        }
        player = newPlayer
    }

    func pause() {
        player?.pause()
    }

    func resume() {
        player?.play()
    }

    /// 停止播放，且不触发完成回调。
    func stopSilently() {
        player?.delegate = nil
        player?.stop()
        player = nil
        isEndedNotified = false
    }

    var isPlaying: Bool {
        player?.isPlaying ?? false
    }

    var currentAudioDuration: TimeInterval {
        guard let player else { return 0 }
        return player.duration
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        self.player = nil
        guard !isEndedNotified else { return }
        isEndedNotified = true
        onPlaybackFinished?()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        self.player = nil
        guard !isEndedNotified else { return }
        isEndedNotified = true
        onPlaybackFinished?()
    }
}
