import AVFoundation
import Foundation

/// Pronunciation service with three-tier fallback:
/// 1. Custom Dictionary API (user-configurable URL) — human pronunciation audio
/// 2. Azure TTS (if key configured) — neural voice
/// 3. System AVSpeechSynthesizer — machine TTS
@MainActor
final class PronunciationService {
    private let synthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?

    /// Play pronunciation for a word with fallback chain.
    /// - Parameters:
    ///   - text: The word to pronounce
    ///   - language: Language code (e.g., "en", "zh-Hans")
    ///   - customAudioAPIURL: Custom API URL with {word} placeholder. Empty string to skip API.
    func pronounce(_ text: String, language: String?, customAudioAPIURL: String = "") {
        Task {
            #if DEBUG
            print("[PronunciationService] Pronouncing '\(text)', language: \(language ?? "nil"), customAudioAPIURL: \(customAudioAPIURL)")
            #endif

            // 1. Try custom Dictionary API for human pronunciation (with stemming fallback)
            let trimmedURL = customAudioAPIURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedURL.isEmpty {
                let candidates = WordStemmer.candidates(for: text)
                var foundAudio = false
                for candidate in candidates {
                    if let audioData = await fetchCustomAPIAudio(word: candidate, apiURL: trimmedURL) {
                        if await playAudioData(audioData) {
                            #if DEBUG
                            print("[PronunciationService] Playing Dictionary API audio for '\(candidate)'")
                            #endif
                            foundAudio = true
                            break
                        }
                    }
                }
                if foundAudio { return }
                #if DEBUG
                print("[PronunciationService] Dictionary API audio not available for '\(text)' (tried \(candidates.count) candidates)")
                #endif
            }

            // 2. Try Azure TTS (if key configured)
            if let key = ConfigManager.shared.azureTTSKey,
               let region = ConfigManager.shared.azureTTSRegion {
                if let audioData = await fetchAzureTTS(text: text, language: language, key: key, region: region) {
                    if await playAudioData(audioData) {
                        #if DEBUG
                        print("[PronunciationService] Playing Azure TTS audio")
                        #endif
                        return
                    }
                }
                #if DEBUG
                print("[PronunciationService] Azure TTS failed for '\(text)'")
                #endif
            }

            // 3. Fall back to system TTS
            #if DEBUG
            print("[PronunciationService] Falling back to system TTS for '\(text)'")
            #endif
            speakWithSystemTTS(text, language: language)
        }
    }

    // MARK: - Custom Dictionary API

    /// Fetch audio from custom API URL.
    /// Supports two response types:
    /// - JSON with phonetics[].audio (dictionaryapi.dev format)
    /// - Binary audio data (mp3/wav)
    private func fetchCustomAPIAudio(word: String, apiURL: String) async -> Data? {
        // Normalize: lowercase, trim, take first word token only
        let normalized = word.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .first
            .map(String.init) ?? word.lowercased()
        
        // Replace {word} placeholder with the actual word
        let encodedWord = normalized.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? normalized
        let urlString = apiURL.replacingOccurrences(of: "{word}", with: encodedWord)
        
        guard let url = URL(string: urlString) else {
            #if DEBUG
            print("[PronunciationService] Invalid URL: '\(urlString)'")
            #endif
            return nil
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url))
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }

            // Check content type to determine response format
            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            
            // If it's audio data, return directly
            if contentType.contains("audio/") || contentType.contains("application/octet-stream") {
                #if DEBUG
                print("[PronunciationService] Received binary audio data (\(data.count) bytes)")
                #endif
                return data
            }
            
            // Try to parse as JSON (dictionaryapi.dev format)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let first = json.first,
               let phonetics = first["phonetics"] as? [[String: Any]] {
                // Find first phonetic entry with an audio URL
                for phonetic in phonetics {
                    if let audioString = phonetic["audio"] as? String,
                       !audioString.isEmpty,
                       let audioURL = URL(string: audioString) {
                        // Fetch the actual audio from the URL
                        return await fetchAudioFromURL(audioURL)
                    }
                }
            }
            
            // Check if data starts with audio file signatures (mp3, wav, etc.)
            if data.count > 4 {
                let header = [UInt8](data.prefix(4))
                // MP3 frame sync or ID3 tag
                if (header[0] == 0xFF && (header[1] & 0xE0) == 0xE0) ||
                   (header[0] == 0x49 && header[1] == 0x44 && header[2] == 0x33) {
                    #if DEBUG
                    print("[PronunciationService] Detected MP3 audio data (\(data.count) bytes)")
                    #endif
                    return data
                }
                // WAV header
                if header[0] == 0x52 && header[1] == 0x49 && header[2] == 0x46 && header[3] == 0x46 {
                    #if DEBUG
                    print("[PronunciationService] Detected WAV audio data (\(data.count) bytes)")
                    #endif
                    return data
                }
            }

            return nil
        } catch {
            #if DEBUG
            print("[PronunciationService] Dictionary API failed: \(error)")
            #endif
            return nil
        }
    }
    
    private func fetchAudioFromURL(_ url: URL) async -> Data? {
        do {
            let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url))
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }

    // MARK: - Azure TTS

    /// Fetch speech audio from Azure Cognitive Services TTS.
    private func fetchAzureTTS(text: String, language: String?, key: String, region: String) async -> Data? {
        let urlString = "https://\(region).tts.speech.microsoft.com/cognitiveservices/v1"
        guard let url = URL(string: urlString) else {
            print("[PronunciationService] Azure TTS: invalid URL for region=\(region)")
            return nil
        }

        let voiceName = azureVoiceName(for: language)
        let langCode = azureLanguageCode(for: language)

        let ssml = """
        <speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='\(langCode)'>
            <voice name='\(voiceName)'>\(escapeXML(text))</voice>
        </speak>
        """

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue("application/ssml+xml", forHTTPHeaderField: "Content-Type")
        request.setValue("audio-16khz-32kbitrate-mono-mp3", forHTTPHeaderField: "X-Microsoft-OutputFormat")
        request.httpBody = ssml.data(using: .utf8)

        print("[PronunciationService] Azure TTS POST \(urlString)  voice=\(voiceName)  text=\"\(text.prefix(30))\"")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return nil }

            if httpResponse.statusCode != 200 {
                let body = String(data: data, encoding: .utf8) ?? "<binary>"
                print("[PronunciationService] Azure TTS HTTP \(httpResponse.statusCode): \(body.prefix(200))")
                return nil
            }
            print("[PronunciationService] Azure TTS ✅ received \(data.count) bytes")
            return data
        } catch {
            print("[PronunciationService] Azure TTS failed: \(error)")
            return nil
        }
    }

    // MARK: - System TTS

    private func speakWithSystemTTS(_ text: String, language: String?) {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        if let language {
            utterance.voice = AVSpeechSynthesisVoice(language: language)
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    // MARK: - Audio playback helpers

    private func playAudioData(_ data: Data) async -> Bool {
        do {
            let player = try AVAudioPlayer(data: data)
            audioPlayer = player
            player.play()
            return true
        } catch {
            print("[PronunciationService] Audio playback failed: \(error)")
            return false
        }
    }

    // MARK: - Azure voice mapping

    private func azureVoiceName(for language: String?) -> String {
        guard let lang = language else { return "en-US-JennyNeural" }
        let code = lang.components(separatedBy: "-").first ?? lang
        switch code {
        case "en": return "en-US-JennyNeural"
        case "zh": return lang.contains("Hant") ? "zh-TW-HsiaoChenNeural" : "zh-CN-XiaoxiaoNeural"
        case "ja": return "ja-JP-NanamiNeural"
        case "ko": return "ko-KR-SunHiNeural"
        case "fr": return "fr-FR-DeniseNeural"
        case "de": return "de-DE-KatjaNeural"
        case "es": return "es-ES-ElviraNeural"
        case "it": return "it-IT-ElsaNeural"
        case "pt": return "pt-BR-FranciscaNeural"
        case "ru": return "ru-RU-SvetlanaNeural"
        case "ar": return "ar-SA-ZariyahNeural"
        case "th": return "th-TH-PremwadeeNeural"
        case "vi": return "vi-VN-HoaiMyNeural"
        default: return "en-US-JennyNeural"
        }
    }

    private func azureLanguageCode(for language: String?) -> String {
        guard let lang = language else { return "en-US" }
        let code = lang.components(separatedBy: "-").first ?? lang
        switch code {
        case "en": return "en-US"
        case "zh": return lang.contains("Hant") ? "zh-TW" : "zh-CN"
        case "ja": return "ja-JP"
        case "ko": return "ko-KR"
        case "fr": return "fr-FR"
        case "de": return "de-DE"
        case "es": return "es-ES"
        case "it": return "it-IT"
        case "pt": return "pt-BR"
        case "ru": return "ru-RU"
        case "ar": return "ar-SA"
        case "th": return "th-TH"
        case "vi": return "vi-VN"
        default: return "en-US"
        }
    }

    private func escapeXML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
