import Foundation

/// Microsoft Azure Translator API client
/// Endpoint: https://api.cognitive.microsofttranslator.com/
final class AzureTranslatorService {
    private let baseURL = "https://api.cognitive.microsofttranslator.com"

    struct TranslationResult {
        let translatedText: String
        let detectedLanguage: String?
    }

    /// Translate text using Azure Translator API.
    /// Returns nil if no API key is configured.
    func translate(
        text: String,
        from sourceLanguage: String?,
        to targetLanguage: String
    ) async -> TranslationResult? {
        guard let apiKey = ConfigManager.shared.azureTranslatorKey else {
            print("[AzureTranslator] No API key configured — skipping")
            return nil
        }
        let region = ConfigManager.shared.azureTranslatorRegion ?? "global"

        // Map language identifiers to Azure format
        let azureTarget = mapToAzureLanguage(targetLanguage)
        let azureSource = sourceLanguage.map { mapToAzureLanguage($0) }

        var urlString = "\(baseURL)/translate?api-version=3.0&to=\(azureTarget)"
        if let azureSource {
            urlString += "&from=\(azureSource)"
        }

        guard let url = URL(string: urlString) else {
            print("[AzureTranslator] Invalid URL: \(urlString)")
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue(region, forHTTPHeaderField: "Ocp-Apim-Subscription-Region")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [[String: String]] = [["Text": text]]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = bodyData

        print("[AzureTranslator] POST \(urlString)  region=\(region)  text=\"\(text.prefix(40))\"")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return nil }

            if httpResponse.statusCode != 200 {
                let responseBody = String(data: data, encoding: .utf8) ?? "<binary>"
                print("[AzureTranslator] HTTP \(httpResponse.statusCode): \(responseBody)")
                return nil
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let first = json.first,
                  let translations = first["translations"] as? [[String: Any]],
                  let translatedText = translations.first?["text"] as? String else {
                let responseBody = String(data: data, encoding: .utf8) ?? "<binary>"
                print("[AzureTranslator] Unexpected response format: \(responseBody.prefix(200))")
                return nil
            }

            let detectedLang = (first["detectedLanguage"] as? [String: Any])?["language"] as? String

            print("[AzureTranslator] ✅ \"\(text.prefix(20))\" → \"\(translatedText.prefix(40))\"")
            return TranslationResult(translatedText: translatedText, detectedLanguage: detectedLang)
        } catch {
            print("[AzureTranslator] Request failed: \(error)")
            return nil
        }
    }

    /// Check if Azure Translator is configured with a valid key.
    var isConfigured: Bool {
        ConfigManager.shared.azureTranslatorKey != nil
    }

    // MARK: - Language mapping

    /// Map app language identifiers to Azure Translator language codes.
    private func mapToAzureLanguage(_ lang: String) -> String {
        switch lang {
        case "zh-Hans": return "zh-Hans"
        case "zh-Hant": return "zh-Hant"
        default:
            // Azure uses simple codes for most languages (en, ja, ko, fr, etc.)
            return lang.components(separatedBy: "-").first ?? lang
        }
    }
}
