import Foundation
import AVFoundation

/// FaceTime-style call tones, ported from Jungle's `useVoiceCallSounds.ts` /
/// `utils/sounds.ts` (same three mp3 assets, same transition rules):
///
///   1. callingSound     — LOOPS while the call is being placed (.connecting).
///   2. callAnsweredSound — one-shot the instant the coach joins.
///   3. callHangUpSound   — one-shot ONLY when a call that actually connected
///                          ends. Cancel-during-connect / connect-failure just
///                          stops the ringtone — nothing answered, so nothing
///                          can "hang up".
///
/// Driven by `handleTransition(from:to:)` on every phase change.
@MainActor
final class VoiceCallSounds {
    static let shared = VoiceCallSounds()

    private var callingPlayer: AVAudioPlayer?
    private var answeredPlayer: AVAudioPlayer?
    private var hangUpPlayer: AVAudioPlayer?

    private init() {
        callingPlayer = Self.makePlayer("callingSound")
        callingPlayer?.numberOfLoops = -1   // ring until explicitly stopped
        answeredPlayer = Self.makePlayer("callAnsweredSound")
        hangUpPlayer = Self.makePlayer("callHangUpSound")
    }

    private static func makePlayer(_ name: String) -> AVAudioPlayer? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "mp3") else {
            vclog("sound asset missing: \(name).mp3")
            return nil
        }
        let player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
        return player
    }

    // Jungle's state buckets, mapped to our phases. `.authenticating` is
    // Jungle's `requesting-mic` — sign-in/permission prompts are open, the
    // call hasn't been "placed" yet, so no ringtone there.
    private static func isPreCall(_ p: VoiceCoachManager.Phase) -> Bool {
        p == .connecting
    }
    private static func isConnected(_ p: VoiceCoachManager.Phase) -> Bool {
        p == .listening || p == .speaking
    }
    private static func isEnded(_ p: VoiceCoachManager.Phase) -> Bool {
        if case .error = p { return true }
        return p == .ended || p == .idle
    }

    func handleTransition(from old: VoiceCoachManager.Phase, to new: VoiceCoachManager.Phase) {
        // Pre-call begins → start the looping ringtone (don't restart if
        // already looping — that creates a brief tick).
        if !Self.isPreCall(old), Self.isPreCall(new) {
            if callingPlayer?.isPlaying != true {
                callingPlayer?.currentTime = 0
                callingPlayer?.play()
            }
            return
        }
        // Ringing → connected: stop ringtone, play the answered tone.
        if Self.isPreCall(old), Self.isConnected(new) {
            callingPlayer?.stop()
            answeredPlayer?.currentTime = 0
            answeredPlayer?.play()
            return
        }
        // Connected → ended: the call was real — hang-up tone.
        if Self.isConnected(old), Self.isEnded(new) {
            callingPlayer?.stop()   // belt-and-suspenders
            hangUpPlayer?.currentTime = 0
            hangUpPlayer?.play()
            return
        }
        // Ringing → ended without connecting: just silence the ringtone.
        if Self.isPreCall(old), Self.isEnded(new) {
            callingPlayer?.stop()
            return
        }
    }
}
