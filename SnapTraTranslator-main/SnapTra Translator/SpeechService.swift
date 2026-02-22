import AVFoundation
import Foundation

/// Thin wrapper that delegates to PronunciationService for the full fallback chain:
/// Dictionary API audio → Azure TTS → system AVSpeechSynthesizer.
@MainActor
final class SpeechService {
    private let pronunciationService = PronunciationService()

    func speak(_ text: String, language: String?, customAudioAPIURL: String = "") {
        pronunciationService.pronounce(text, language: language, customAudioAPIURL: customAudioAPIURL)
    }
}
