import AVFoundation
import Combine

@MainActor
final class VoiceGuidance: NSObject, ObservableObject {
    private static let muteKey = "navigationVoiceMuted"

    @Published var isMuted: Bool {
        didSet {
            UserDefaults.standard.set(isMuted, forKey: Self.muteKey)
            if isMuted {
                synthesizer.stopSpeaking(at: .immediate)
                deactivateSession()
            }
        }
    }

    private let synthesizer = AVSpeechSynthesizer()
    private var sessionActive = false

    override init() {
        isMuted = UserDefaults.standard.bool(forKey: Self.muteKey)
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        guard !isMuted else { return }
        guard !text.isEmpty else { return }

        synthesizer.stopSpeaking(at: .immediate)
        activateSession()

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        utterance.prefersAssistiveTechnologySettings = false
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        deactivateSession()
    }

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playback,
                mode: .voicePrompt,
                options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers]
            )
            try session.setActive(true, options: [])
            sessionActive = true
        } catch {
            NSLog("[BikeNoCo] VoiceGuidance session activate failed: %@", error.localizedDescription)
        }
    }

    private func deactivateSession() {
        guard sessionActive else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            NSLog("[BikeNoCo] VoiceGuidance session deactivate failed: %@", error.localizedDescription)
        }
        sessionActive = false
    }
}

extension VoiceGuidance: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            self.deactivateSession()
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            self.deactivateSession()
        }
    }
}
