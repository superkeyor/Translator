import CoreServices
import Foundation

final class DictionaryService {

    func lookup(_ word: String, preferEnglish: Bool = false, preferredDictionary: String? = nil) -> DictionaryEntry? {
        
        guard let normalized = normalizeWord(word) else {
            return nil
        }

        // Build candidate list: original word + stemmed variants
        let candidates = WordStemmer.candidates(for: normalized)

        var html: String?
        var dcsHTML: String?     // Rich HTML from DCSCopyRecordsForSearchString
        var matchedWord = normalized
        var matchedDictId: String?

        // Try preferred dictionary first via the C bridge
        if let dictId = preferredDictionary, !dictId.isEmpty {
            for candidate in candidates {
                if let result = DictionaryListService.shared.lookup(word: candidate, dictionaryShortName: dictId) {
                    html = result
                    matchedWord = candidate
                    matchedDictId = dictId
                    #if DEBUG
                    print("[DictionaryService] Preferred dict '\(dictId)' result for '\(candidate)' (\(result.count) chars)")
                    #endif
                    break
                }
            }
            #if DEBUG
            if html == nil {
                print("[DictionaryService] Preferred dict '\(preferredDictionary ?? "")' returned nil for all candidates of '\(normalized)', falling back to system default")
            }
            #endif
        }

        // Fallback to system default (all active dictionaries), also with stemming
        if html == nil {
            for candidate in candidates {
                let range = CFRange(location: 0, length: candidate.utf16.count)
                if let definition = DCSCopyTextDefinition(nil, candidate as CFString, range) {
                    html = definition.takeRetainedValue() as String
                    matchedWord = candidate
                    #if DEBUG
                    print("[DictionaryService] Default dictionary result for '\(candidate)' (\(html!.count) chars):\n\(html!.prefix(2000))")
                    #endif
                    break
                }
            }
        }

        guard let rawHTML = html else { return nil }

        // Also fetch rich HTML from the DCS record API for WebView rendering
        if let dictId = matchedDictId {
            dcsHTML = DictionaryListService.shared.lookupHTML(word: matchedWord, dictionaryShortName: dictId)
        }

        if preferEnglish {
            var entry = parseEnglishHTML(rawHTML, word: matchedWord)
            if let dcsHTML {
                entry = DictionaryEntry(word: entry.word, phonetic: entry.phonetic, definitions: entry.definitions, phonetics: entry.phonetics, rawHTML: dcsHTML)
            }
            return entry
        }

        var entry = parseHTML(rawHTML, word: matchedWord)
        if let dcsHTML {
            entry = DictionaryEntry(word: entry.word, phonetic: entry.phonetic, definitions: entry.definitions, phonetics: entry.phonetics, rawHTML: dcsHTML)
        }
        return entry
    }

    // MARK: - Private

    private func normalizeWord(_ word: String) -> String? {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        let firstToken = trimmed.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? trimmed
        let allowed = CharacterSet.letters.union(CharacterSet(charactersIn: "-''"))
        let cleaned = firstToken.trimmingCharacters(in: allowed.inverted)
        return cleaned.isEmpty ? nil : cleaned.lowercased()
    }

    private func parseHTML(_ html: String, word: String) -> DictionaryEntry {
        let phonetic = extractPhonetic(from: html)
        let phonetics = extractAllPhonetics(from: html)
        let definitions = extractDefinitions(from: html)

        return DictionaryEntry(
            word: word,
            phonetic: phonetic,
            definitions: definitions,
            phonetics: phonetics
        )
    }
    
    private func parseEnglishHTML(_ html: String, word: String) -> DictionaryEntry {
        let phonetic = extractPhonetic(from: html)
        let phonetics = extractAllPhonetics(from: html)
        let definitions = extractEnglishDefinitions(from: html)

        return DictionaryEntry(
            word: word,
            phonetic: phonetic,
            definitions: definitions,
            phonetics: phonetics
        )
    }
    
    private func extractEnglishDefinitions(from html: String) -> [DictionaryEntry.Definition] {
        var definitions: [DictionaryEntry.Definition] = []
        let text = stripHTML(html)
        
        let posPattern = "(plural noun|noun|verb|adjective|adverb|preposition|conjunction|pronoun|interjection)"
        guard let posRegex = try? NSRegularExpression(pattern: posPattern, options: .caseInsensitive) else {
            return definitions
        }
        
        let posMatches = posRegex.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text))
        
        for (index, match) in posMatches.enumerated() {
            guard let posRange = Range(match.range, in: text) else { continue }
            let pos = normalizePOS(String(text[posRange]))
            
            let contentStart = posRange.upperBound
            let contentEnd: String.Index
            if index + 1 < posMatches.count, let nextRange = Range(posMatches[index + 1].range, in: text) {
                contentEnd = nextRange.lowerBound
            } else {
                let phrasesRange = text.range(of: "PHRASES", options: .caseInsensitive, range: contentStart..<text.endIndex)
                let originRange = text.range(of: "ORIGIN", options: .caseInsensitive, range: contentStart..<text.endIndex)
                if let phrases = phrasesRange, let origin = originRange {
                    contentEnd = min(phrases.lowerBound, origin.lowerBound)
                } else {
                    contentEnd = phrasesRange?.lowerBound ?? originRange?.lowerBound ?? text.endIndex
                }
            }
            
            let content = String(text[contentStart..<contentEnd])
            
            let numberedPattern = "(?:^|\\s)(\\d+)\\s+(.+?)(?=(?:\\s+\\d+\\s+)|$)"
            guard let numRegex = try? NSRegularExpression(pattern: numberedPattern, options: [.dotMatchesLineSeparators]) else { continue }
            
            let numMatches = numRegex.matches(in: content, options: [], range: NSRange(content.startIndex..., in: content))
            
            for numMatch in numMatches {
                guard numMatch.numberOfRanges >= 3,
                      let meaningRange = Range(numMatch.range(at: 2), in: content) else { continue }
                
                var meaning = String(content[meaningRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                meaning = cleanEnglishDefinition(meaning)
                
                if meaning.count > 5, meaning.range(of: "[a-zA-Z]{3,}", options: .regularExpression) != nil {
                    definitions.append(DictionaryEntry.Definition(
                        partOfSpeech: pos,
                        meaning: meaning,
                        translation: meaning,
                        examples: []
                    ))
                }
            }
            
            if numMatches.isEmpty {
                var meaning = content.trimmingCharacters(in: .whitespacesAndNewlines)
                meaning = cleanEnglishDefinition(meaning)
                
                if meaning.count > 5, meaning.range(of: "[a-zA-Z]{3,}", options: .regularExpression) != nil {
                    definitions.append(DictionaryEntry.Definition(
                        partOfSpeech: pos,
                        meaning: meaning,
                        translation: meaning,
                        examples: []
                    ))
                }
            }
        }
        
        if definitions.isEmpty {
            let fallbackDefs = extractFallbackEnglishDefinitions(from: text)
            definitions.append(contentsOf: fallbackDefs)
        }
        
        return definitions
    }
    
    private func cleanEnglishDefinition(_ text: String) -> String {
        var result = text
        
        if let colonIndex = result.firstIndex(of: ":") {
            result = String(result[..<colonIndex])
        }
        
        result = result.replacingOccurrences(of: "\\s*\\|.*", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\([^)]*\\)", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func detectPartOfSpeech(_ text: String) -> String? {
        let posPatterns = [
            "^(noun|verb|adjective|adverb|preposition|conjunction|pronoun|interjection)\\s*$",
            "^(n\\.|v\\.|adj\\.|adv\\.|prep\\.|conj\\.|pron\\.|interj\\.)\\s*$"
        ]
        
        let lowercased = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for pattern in posPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               regex.firstMatch(in: lowercased, options: [], range: NSRange(lowercased.startIndex..., in: lowercased)) != nil {
                return normalizePOS(lowercased)
            }
        }
        return nil
    }
    
    private func extractNumberedMeaning(_ text: String) -> (Int, String)? {
        let pattern = "^(\\d+)\\s+(.+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges == 3,
              let numRange = Range(match.range(at: 1), in: text),
              let meaningRange = Range(match.range(at: 2), in: text),
              let number = Int(String(text[numRange])) else {
            return nil
        }
        return (number, String(text[meaningRange]))
    }
    
    private func cleanEnglishMeaning(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: ":\\s*$", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\s*\\|.*$", with: "", options: .regularExpression)
        
        if let colonIndex = result.firstIndex(of: ":") {
            result = String(result[..<colonIndex])
        }
        
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func extractFallbackEnglishDefinitions(from text: String) -> [DictionaryEntry.Definition] {
        var definitions: [DictionaryEntry.Definition] = []
        
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".;"))
        var currentPOS = ""
        
        for sentence in sentences {
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count > 10, trimmed.count < 200 else { continue }
            
            let containsChinese = trimmed.range(of: "\\p{Han}", options: .regularExpression) != nil
            guard !containsChinese else { continue }
            
            if let pos = detectPartOfSpeech(trimmed) {
                currentPOS = pos
                continue
            }
            
            let hasEnglishContent = trimmed.range(of: "[a-zA-Z]{4,}", options: .regularExpression) != nil
            if hasEnglishContent {
                definitions.append(DictionaryEntry.Definition(
                    partOfSpeech: currentPOS,
                    meaning: trimmed,
                    translation: trimmed,
                    examples: []
                ))
                if definitions.count >= 3 {
                    break
                }
            }
        }
        
        return definitions
    }

    // MARK: - Phonetic Extraction

    private func extractPhonetic(from html: String) -> String? {
        let patterns = [
            "<span[^>]*class=\"[^\"]*pr[^\"]*\"[^>]*>([^<]+)</span>",
            "<span[^>]*class=\"[^\"]*ipa[^\"]*\"[^>]*>([^<]+)</span>",
            "<span[^>]*class=\"[^\"]*pron[^\"]*\"[^>]*>([^<]+)</span>",
            "<span[^>]*class=\"[^\"]*phon[^\"]*\"[^>]*>([^<]+)</span>",
            "\\|([^|]+)\\|",  // |phonetic| 格式
            "/([^/]+)/"       // /phonetic/ 格式
        ]

        for pattern in patterns {
            if let match = matchFirst(pattern: pattern, in: html) {
                let cleaned = match.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    return cleaned
                }
            }
        }
        return nil
    }

    /// Extract all phonetic notations from raw dictionary text.
    /// Handles formats: |rɪˈfreʃ|, /rɪˈfreʃ/, BrE /.../ NAmE /.../, [phonetic]
    /// Returns array like ["/rɪˈfreʃ/"] or ["BrE /rɪˈfreʃ/", "NAmE /rɪˈfreʃ/"]
    /// Only searches the first ~300 characters to avoid picking up compound words (e.g., screenland/screenplay for "screen")
    private func extractAllPhonetics(from html: String) -> [String] {
        var results: [String] = []

        // Work on both raw text and stripped text
        let fullText = stripHTML(html)
        
        // Limit search to the first 300 characters to only get the main word's phonetic,
        // not phonetics for compound words that appear later in the dictionary entry
        let text = String(fullText.prefix(300))

        #if DEBUG
        // Log first 300 chars of raw text for phonetic debugging
        let preview = text.prefix(300)
        print("[DictionaryService] extractAllPhonetics text preview: \(preview)")
        #endif

        // Pattern 1: Labelled phonetics — "BrE /.../" or "NAmE /.../" or "AmE /.../"
        if let regex = try? NSRegularExpression(pattern: "((?:BrE|NAmE|AmE)\\s*/[^/]+/)", options: []) {
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, options: [], range: range)
            for match in matches {
                if let r = Range(match.range(at: 1), in: text) {
                    let cleaned = String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty && !results.contains(cleaned) {
                        results.append(cleaned)
                    }
                }
            }
        }
        if !results.isEmpty { return results }

        // Pattern 2: Pipe notation — |phonetic| (common in macOS dictionary plain text)
        // Match IPA characters inside pipes: |rɪˈfreʃ|
        if let regex = try? NSRegularExpression(pattern: "\\|([^|]{2,40})\\|", options: []) {
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, options: [], range: range)
            for match in matches {
                if let r = Range(match.range(at: 1), in: text) {
                    let inner = String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                    // Verify it looks like IPA (contains IPA-ish characters, not just plain English)
                    let hasIPAChars = inner.range(of: "[ɪɛæɑɒʊʌəɜɔðθʃʒŋˈˌː]", options: .regularExpression) != nil
                    let hasSlashOrPipe = inner.contains("/")
                    if !inner.isEmpty && (hasIPAChars || hasSlashOrPipe || inner.count < 25) {
                        let formatted = "/\(inner)/"
                        if !results.contains(formatted) {
                            results.append(formatted)
                        }
                    }
                }
            }
        }
        if !results.isEmpty { return results }

        // Pattern 3: Standalone /phonetic/ in plain text
        if let regex = try? NSRegularExpression(pattern: "(/[^/\\s][^/]{1,30}[^/\\s]/)", options: []) {
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, options: [], range: range)
            for match in matches {
                if let r = Range(match.range(at: 1), in: text) {
                    let cleaned = String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty && !results.contains(cleaned) {
                        results.append(cleaned)
                        if results.count >= 3 { break }
                    }
                }
            }
        }
        if !results.isEmpty { return results }

        // Pattern 4: Square bracket phonetics [phonetic]
        if let regex = try? NSRegularExpression(pattern: "\\[([^\\]]{2,30})\\]", options: []) {
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, options: [], range: range)
            for match in matches {
                if let r = Range(match.range(at: 1), in: text) {
                    let inner = String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let hasIPAChars = inner.range(of: "[ɪɛæɑɒʊʌəɜɔðθʃʒŋˈˌː]", options: .regularExpression) != nil
                    if hasIPAChars {
                        let formatted = "/\(inner)/"
                        if !results.contains(formatted) {
                            results.append(formatted)
                        }
                    }
                }
            }
        }

        // Pattern 5: HTML class-based phonetics (fallback for HTML dictionaries)
        if results.isEmpty {
            let htmlPatterns = [
                "<span[^>]*class=\"[^\"]*pr[^\"]*\"[^>]*>([^<]+)</span>",
                "<span[^>]*class=\"[^\"]*ipa[^\"]*\"[^>]*>([^<]+)</span>",
                "<span[^>]*class=\"[^\"]*pron[^\"]*\"[^>]*>([^<]+)</span>",
                "<span[^>]*class=\"[^\"]*phon[^\"]*\"[^>]*>([^<]+)</span>",
            ]
            for pattern in htmlPatterns {
                let matches = matchAll(pattern: pattern, in: html)
                for m in matches {
                    let cleaned = m.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty && !results.contains(cleaned) {
                        results.append(cleaned)
                    }
                }
                if !results.isEmpty { break }
            }
        }

        return results
    }

    // MARK: - Definition Extraction

    private func extractDefinitions(from html: String) -> [DictionaryEntry.Definition] {
        var definitions: [DictionaryEntry.Definition] = []

        // 尝试提取词性分组
        var posGroups = extractPartOfSpeechGroups(from: html)
        if posGroups.isEmpty {
            posGroups = extractPlainTextPartOfSpeechGroups(from: html)
        }

        if !posGroups.isEmpty {
            for (pos, content) in posGroups {
                let examples = extractExamples(from: content)

                if !content.contains("<") {
                    let plainMeanings = extractPlainTextMeanings(from: content)
                    if !plainMeanings.isEmpty {
                        for meaning in plainMeanings {
                            definitions.append(DictionaryEntry.Definition(
                                partOfSpeech: pos,
                                meaning: meaning.meaning,
                                translation: meaning.translation,
                                examples: []
                            ))
                        }
                        continue
                    }
                }

                let meanings = extractMeanings(from: content)
                if !meanings.isEmpty {
                    for meaning in meanings {
                        definitions.append(DictionaryEntry.Definition(
                            partOfSpeech: pos,
                            meaning: meaning,
                            translation: nil,
                            examples: examples
                        ))
                    }
                } else {
                    // 如果没有提取到具体释义，使用整个内容作为释义
                    let plainContent = stripHTML(content)
                    if !plainContent.isEmpty {
                        definitions.append(DictionaryEntry.Definition(
                            partOfSpeech: pos,
                            meaning: plainContent,
                            translation: nil,
                            examples: examples
                        ))
                    }
                }
            }
        }

        // 如果没有提取到词性分组，尝试直接提取释义
        if definitions.isEmpty {
            let fallbackPOS = extractPlainTextPartOfSpeech(from: html) ?? ""
            let plainMeanings = extractPlainTextMeanings(from: html)
            if !plainMeanings.isEmpty {
                for meaning in plainMeanings.prefix(3) {
                    definitions.append(DictionaryEntry.Definition(
                        partOfSpeech: fallbackPOS,
                        meaning: meaning.meaning,
                        translation: meaning.translation,
                        examples: []
                    ))
                }
            } else {
                let allMeanings = extractAllMeanings(from: html)
                let allExamples = extractExamples(from: html)

                for meaning in allMeanings.prefix(3) {
                    definitions.append(DictionaryEntry.Definition(
                        partOfSpeech: fallbackPOS,
                        meaning: meaning,
                        translation: nil,
                        examples: allExamples
                    ))
                }
            }
        }

        return definitions
    }

    private func extractPartOfSpeechGroups(from html: String) -> [(String, String)] {
        var groups: [(String, String)] = []

        // 匹配词性标签及其后续内容
        let posPatterns = [
            // 匹配 <span class="posg">noun</span> 或类似格式
            "<span[^>]*class=\"[^\"]*(?:posg|pos|fg)[^\"]*\"[^>]*>([^<]+)</span>",
            // 匹配 <b>noun</b> 格式
            "<b>\\s*(transitive verb|intransitive verb|vt\\.?|vi\\.?|noun|verb|adjective|adverb|preposition|conjunction|pronoun|interjection|n\\.|v\\.|adj\\.|adv\\.)\\s*</b>"
        ]

        for pattern in posPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
                continue
            }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            let matches = regex.matches(in: html, options: [], range: range)

            for (index, match) in matches.enumerated() {
                guard match.numberOfRanges > 1,
                      let posRange = Range(match.range(at: 1), in: html) else {
                    continue
                }

                let pos = String(html[posRange]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

                // 验证是否为有效词性
                let isValidPOS = isValidPartOfSpeech(pos)
                guard isValidPOS else { continue }

                // 获取该词性后面的内容（直到下一个词性或结束）
                let startIndex = match.range.upperBound
                let endIndex: Int
                if index + 1 < matches.count {
                    endIndex = matches[index + 1].range.lowerBound
                } else {
                    endIndex = html.utf16.count
                }

                if startIndex < endIndex,
                   let contentStartIndex = html.index(html.startIndex, offsetBy: startIndex, limitedBy: html.endIndex),
                   let contentEndIndex = html.index(html.startIndex, offsetBy: min(endIndex, html.utf16.count), limitedBy: html.endIndex) {
                    let content = String(html[contentStartIndex..<contentEndIndex])
                    groups.append((normalizePOS(pos), content))
                }
            }

            if !groups.isEmpty {
                break
            }
        }

        return groups
    }

    private func normalizePOS(_ pos: String) -> String {
        let lowercased = pos.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch lowercased {
        case "n", "n.", "noun", "名词": return "n."
        case "vt", "vt.", "transitive verb", "及物动词": return "vt."
        case "vi", "vi.", "intransitive verb", "不及物动词": return "vi."
        case "v", "v.", "verb", "动词": return "v."
        case "adj", "adj.", "adjective", "形容词": return "adj."
        case "adv", "adv.", "adverb", "副词": return "adv."
        case "prep", "prep.", "preposition": return "prep."
        case "conj", "conj.", "conjunction": return "conj."
        case "pron", "pron.", "pronoun": return "pron."
        case "int", "int.": return "int."
        case "interj", "interj.", "interjection": return "interj."
        default: return lowercased
        }
    }

    private struct PlainTextMeaning {
        let meaning: String
        let translation: String?
    }

    private func extractPlainTextPartOfSpeech(from html: String) -> String? {
        let text = stripHTML(html)
        guard !text.isEmpty else { return nil }
        let header = splitPlainTextSenses(text).first ?? text
        if let headerPOS = findFirstPartOfSpeech(in: header) {
            return headerPOS
        }
        return findFirstPartOfSpeech(in: text)
    }

    private func findFirstPartOfSpeech(in text: String) -> String? {
        guard let range = findFirstPartOfSpeechRange(in: text) else { return nil }
        let label = String(text[range])
        return normalizePOS(label)
    }

    private func findFirstPartOfSpeechRange(in text: String) -> Range<String.Index>? {
        // Word-boundary guards prevent matching POS labels inside words
        // e.g. "vi" should NOT match inside "visit"
        let pattern = "(?:^|(?<=[^A-Za-z]))(transitive verb|intransitive verb|adjective|adverb|preposition|conjunction|interjection|pronoun|noun|verb|adj\\.?|adv\\.?|vt\\.?|vi\\.?|n\\.|v\\.|名词|动词|形容词|副词|及物动词|不及物动词)(?=[^A-Za-z]|$)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let matchRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return matchRange
    }

    private func isHeaderLine(_ text: String) -> Bool {
        text.contains("BrE") || text.contains("AmE")
    }

    private func extractPlainTextPartOfSpeechGroups(from html: String) -> [(String, String)] {
        let text = stripHTML(html)
        guard !text.isEmpty else { return [] }

        // Pre-strip CJK special sections from the text to prevent compound entries
        // from being parsed as definitions in any strategy.
        var cleanedText = text
        for cutoff in ["特殊用法", "习惯用语", "继承用法", "参考词汇"] {
            if let range = cleanedText.range(of: cutoff) {
                cleanedText = String(cleanedText[..<range.lowerBound])
            }
        }

        // --- Strategy 1: CJK dictionary format — POS after phonetic bracket ']' ---
        // Check this FIRST because CJK dictionaries may contain false uppercase
        // letter patterns that confuse the Roman numeral strategy.
        let cjkGroups = extractCJKBracketPOSGroups(from: cleanedText)
        if !cjkGroups.isEmpty { return cjkGroups }

        // --- Strategy 2: Roman numeral sections (e.g. "I. noun", "II. adj.") ---
        if let regex = try? NSRegularExpression(pattern: "(?:^|[^A-Za-z])([A-Z])\\.", options: []) {
            let range = NSRange(cleanedText.startIndex..<cleanedText.endIndex, in: cleanedText)
            let matches = regex.matches(in: cleanedText, options: [], range: range)
            var groups: [(String, String)] = []
            if !matches.isEmpty {
                for (index, match) in matches.enumerated() {
                    let startIndex = match.range.upperBound
                    guard let contentStart = cleanedText.index(cleanedText.startIndex, offsetBy: startIndex, limitedBy: cleanedText.endIndex) else {
                        continue
                    }
                    let (posLabel, posEndIndex) = parsePOSLabel(in: cleanedText, from: contentStart)
                    let normalizedPOS = normalizePOS(posLabel)
                    guard isValidPartOfSpeech(posLabel), !normalizedPOS.isEmpty else { continue }

                    let contentStartIndex = skipWhitespace(in: cleanedText, from: posEndIndex)
                    let endIndex: Int
                    if index + 1 < matches.count {
                        endIndex = matches[index + 1].range.lowerBound
                    } else {
                        endIndex = cleanedText.utf16.count
                    }

                    if let contentEndIndex = cleanedText.index(cleanedText.startIndex, offsetBy: min(endIndex, cleanedText.utf16.count), limitedBy: cleanedText.endIndex),
                       contentStartIndex < contentEndIndex {
                        let content = String(cleanedText[contentStartIndex..<contentEndIndex])
                        groups.append((normalizedPOS, content))
                    }
                }
            }
            if !groups.isEmpty {
                return groups
            }
        }

        // --- Strategy 3: Collins format — numbered entries with N-COUNT, ADJ-GRADED etc. ---
        let collinsGroups = extractCollinsPOSGroups(from: cleanedText)
        if !collinsGroups.isEmpty { return collinsGroups }

        // --- Strategy 3.5: Numbered entries without POS labels (e.g. "1) def 2) def") ---
        let numberedGroups = extractNumberedParenGroups(from: cleanedText)
        if !numberedGroups.isEmpty { return numberedGroups }

        // --- Strategy 4: Single POS fallback ---
        if let posRange = findFirstPartOfSpeechRange(in: cleanedText) {
            let posLabel = String(cleanedText[posRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedPOS = normalizePOS(posLabel)
            let contentStartIndex = skipWhitespace(in: cleanedText, from: posRange.upperBound)
            let content = String(cleanedText[contentStartIndex...])
            if !content.isEmpty, isValidPartOfSpeech(posLabel) {
                return [(normalizedPOS, content)]
            }
        }

        return []
    }

    /// Extract POS groups from CJK dictionaries where POS labels follow ']' bracket.
    /// Handles: ]adj.1.■..., ]n.1.■..., ]vi., vt.1.■..., standalone int.1.■
    private func extractCJKBracketPOSGroups(from text: String) -> [(String, String)] {
        // Find POS labels after ']' — the standard CJK dict pattern
        // Also find standalone POS followed by numbered ■ definitions (e.g. "int.1.■")
        let posAlternation = "adj|n|vt|vi|v|int|interj|adv|prep|conj|pron"
        let singlePOS = "(?:\(posAlternation))\\."
        // Composite POS: vi., vt. or similar
        let compositePOS = "\(singlePOS)(?:\\s*,\\s*\(singlePOS))*"
        // After ']' or preceded by non-letter + followed by digit.■
        let pattern = "(?:\\]|(?<=[^A-Za-z]))(\(compositePOS))\\s*(?:\\([^)]*\\)\\s*)?(?=\\d+\\.\\s*■)"

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: nsRange)

        guard !matches.isEmpty else { return [] }

        var groups: [(String, String)] = []
        for (index, match) in matches.enumerated() {
            guard match.numberOfRanges > 1,
                  let posRange = Range(match.range(at: 1), in: text) else { continue }

            let rawPOS = String(text[posRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            // Take the first POS label from composite "vi., vt." → "vi."
            let primaryPOS = rawPOS.components(separatedBy: ",").first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? rawPOS
            let normalizedPOS = normalizePOS(primaryPOS)

            // Content starts after the POS match and optional grammar note
            guard let fullMatchRange = Range(match.range, in: text) else { continue }
            let contentStart = fullMatchRange.upperBound
            let contentEnd: String.Index
            if index + 1 < matches.count,
               let nextRange = Range(matches[index + 1].range, in: text) {
                contentEnd = nextRange.lowerBound
            } else {
                contentEnd = text.endIndex
            }

            if contentStart < contentEnd {
                let content = String(text[contentStart..<contentEnd])
                groups.append((normalizedPOS, content))
            }
        }

        return groups
    }

    /// Extract POS groups from Collins Cobuild format.
    /// Collins uses: 1) N-COUNT definition... 2) ADJ-GRADED definition... 3) VERB definition...
    private func extractCollinsPOSGroups(from text: String) -> [(String, String)] {
        // Collins POS labels
        let collinsLabels = "N-COUNT|N-SING|N-UNCOUNT|N-PLURAL|N-TITLE|N-VOC|N-PROPER(?:-COLL)?|N-VAR|NOUN|ADJ-GRADED|ADJ|VERB|V-ERG|V-RECIP|V-LINK|V-PASSIVE|ADV|MODAL|CONVENTION|EXCLAM|PHRASE|PHRASAL VERB|QUANT|DET|PREP|CONJ|PRON"
        let pattern = "(\\d+)\\)\\s+(\(collinsLabels))(?:[;:\\s])"

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: nsRange)

        // Need at least 2 numbered entries to confirm Collins format
        guard matches.count >= 2 else { return [] }

        var groups: [(String, String)] = []
        for (index, match) in matches.enumerated() {
            guard match.numberOfRanges > 2,
                  let posRange = Range(match.range(at: 2), in: text),
                  let fullRange = Range(match.range, in: text) else { continue }

            let collinsLabel = String(text[posRange])
            let normalizedPOS = normalizeCollinsPOS(collinsLabel)

            // Content: from end of this match to start of next match
            let contentStart = fullRange.upperBound
            let contentEnd: String.Index
            if index + 1 < matches.count,
               let nextRange = Range(matches[index + 1].range, in: text) {
                contentEnd = nextRange.lowerBound
            } else {
                contentEnd = text.endIndex
            }

            if contentStart < contentEnd {
                var content = String(text[contentStart..<contentEnd])
                // Strip phonetic notations that may leak into definition text
                content = stripPhoneticNotation(from: content)
                // Extract first sentence as the definition (Collins defs are verbose)
                let firstSentence = extractFirstSentence(from: content)
                if !firstSentence.isEmpty {
                    groups.append((normalizedPOS, firstSentence))
                }
            }
        }

        return groups
    }

    /// Extract numbered definition groups like "1) text 2) text" without POS labels.
    /// Common in Collins Simplified and bilingual dictionaries.
    private func extractNumberedParenGroups(from text: String) -> [(String, String)] {
        // Pattern: "N)" at start or after whitespace, where N is a digit
        let pattern = "(?:^|\\s)(\\d+)\\)\\s+"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: nsRange)

        // Need at least 1 numbered entry
        guard !matches.isEmpty else { return [] }

        // Try to find a POS label before the first numbered entry
        var headerPOS = ""
        if let firstMatch = matches.first,
           let firstRange = Range(firstMatch.range, in: text) {
            let headerText = String(text[..<firstRange.lowerBound])
            if let pos = findFirstPartOfSpeech(in: headerText) {
                headerPOS = pos
            }
        }

        var groups: [(String, String)] = []
        for (index, match) in matches.enumerated() {
            guard let fullRange = Range(match.range, in: text) else { continue }
            let contentStart = fullRange.upperBound
            let contentEnd: String.Index
            if index + 1 < matches.count,
               let nextRange = Range(matches[index + 1].range, in: text) {
                contentEnd = nextRange.lowerBound
            } else {
                contentEnd = text.endIndex
            }
            if contentStart < contentEnd {
                var content = String(text[contentStart..<contentEnd])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // Strip phonetic notations that may leak into definition text
                content = stripPhoneticNotation(from: content)
                let firstSentence = extractFirstSentence(from: content)
                if !firstSentence.isEmpty {
                    groups.append((headerPOS, firstSentence))
                }
            }
        }

        return groups
    }

    /// Strip phonetic notation patterns (|...|, /.../) from text to prevent
    /// IPA symbols from leaking into definitions and translations.
    private func stripPhoneticNotation(from text: String) -> String {
        var result = text
        // Strip |phonetic| patterns (pipe notation)
        result = result.replacingOccurrences(
            of: "\\|[^|]{2,40}\\|",
            with: "",
            options: .regularExpression
        )
        // Strip /phonetic/ patterns at the beginning or after whitespace
        // Only strip if it looks like IPA (short, contains IPA-ish chars)
        if let regex = try? NSRegularExpression(
            pattern: "(?:^|\\s)/[^/]{2,30}/",
            options: []
        ) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            let matches = regex.matches(in: result, options: [], range: range)
            for match in matches.reversed() {
                if let r = Range(match.range, in: result) {
                    let inner = String(result[r])
                    // Only strip if it contains IPA characters
                    let hasIPA = inner.range(of: "[ɪɛæɑɒʊʌəɜɔðθʃʒŋˈˌː]", options: .regularExpression) != nil
                    if hasIPA {
                        result.replaceSubrange(r, with: "")
                    }
                }
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Map Collins Cobuild POS labels to standard abbreviations.
    private func normalizeCollinsPOS(_ label: String) -> String {
        let up = label.uppercased()
        if up.hasPrefix("N-") || up == "NOUN" { return "n." }
        if up.hasPrefix("ADJ") { return "adj." }
        if up.hasPrefix("V") || up == "VERB" || up == "MODAL" { return "v." }
        if up == "ADV" { return "adv." }
        if up == "CONVENTION" || up == "EXCLAM" { return "interj." }
        if up == "PHRASE" || up == "PHRASAL VERB" { return "phr." }
        if up == "PREP" { return "prep." }
        if up == "CONJ" { return "conj." }
        if up == "PRON" { return "pron." }
        if up == "DET" || up == "QUANT" { return "det." }
        return ""
    }

    /// Extract the first meaningful sentence from Collins-style verbose text.
    private func extractFirstSentence(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Collins definitions end with a period followed by example or another section.
        // Take text up to the first period that's followed by a space and a capital letter
        // (indicating the start of an example sentence).
        if let regex = try? NSRegularExpression(pattern: "\\.\\s+[A-Z]", options: []),
           let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)),
           let range = Range(match.range, in: trimmed) {
            let sentence = String(trimmed[..<range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if sentence.count > 5 { return sentence }
        }

        // Fallback: take first 120 characters
        if trimmed.count > 120 {
            let prefix = String(trimmed.prefix(120))
            // Try to break at a natural boundary
            if let lastSpace = prefix.lastIndex(of: " ") {
                return String(prefix[..<lastSpace])
            }
            return prefix
        }
        return trimmed
    }

    private func extractPlainTextMeanings(from html: String) -> [PlainTextMeaning] {
        let text = stripHTML(html)
        var senses = splitPlainTextSenses(text)
        guard !senses.isEmpty else { return [] }

        if let first = senses.first, isHeaderLine(first) {
            senses.removeFirst()
        }

        var meanings: [PlainTextMeaning] = []
        for sense in senses {
            var trimmed = sense.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // Skip compound entries: lines that start with multi-word English
            // phrases (e.g. "electric screen ...", "sound recording ...").
            // Main definitions either start with CJK, punctuation, or 【.
            let beforeCJK = trimmed.prefix(while: { !$0.isChineseCharacter && $0 != "【" })
            let englishWords = beforeCJK.split(whereSeparator: { $0.isWhitespace })
                .filter { $0.range(of: "[A-Za-z]", options: .regularExpression) != nil }
            if englishWords.count >= 2 {
                // Looks like a compound entry, skip it
                continue
            }

            // Truncate example sentences that follow CJK definitions.
            // Pattern: Chinese definition text followed by English phrases.
            // e.g. "属于共同本质的the general opinion一般舆论..." → "属于共同本质的"
            trimmed = truncateExampleSentences(trimmed)

            let content = trimmed.components(separatedBy: "▸").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? trimmed
            let parsed = splitMeaningAndTranslation(from: content)
            if parsed.meaning.count > 1 {
                meanings.append(parsed)
            }
        }
        return meanings
    }

    /// Truncate example sentences that follow CJK definitions.
    /// CJK dictionaries (英汉汉英 etc.) embed examples after the last ■-split definition:
    ///   "唱片, 录了音的磁带write a record of one's journey写下旅行记录..."
    /// This function detects the CJK→English transition and truncates there.
    private func truncateExampleSentences(_ sense: String) -> String {
        // Only truncate long senses that start with CJK-ish content
        guard sense.count > 30 else { return sense }
        guard let firstChar = sense.first,
              firstChar.isChineseCharacter || firstChar == "(" || firstChar == "（"
                || firstChar == "[" || firstChar == "【" || firstChar == "〈" else {
            return sense
        }

        // Find position where CJK text transitions to English phrases.
        // Pattern: a CJK character (or CJK punctuation) followed immediately by
        // an English letter that starts what looks like an example phrase.
        // e.g. "属于共同本质的the" or "录了音的磁带write" or "警戒幕a folding"
        if let regex = try? NSRegularExpression(
            pattern: "([\\p{Han}，；])([a-zA-Z])",
            options: []
        ) {
            let nsRange = NSRange(sense.startIndex..<sense.endIndex, in: sense)
            if let match = regex.firstMatch(in: sense, options: [], range: nsRange),
               let cjkRange = Range(match.range(at: 1), in: sense) {
                let result = String(sense[..<cjkRange.upperBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "，,；;"))
                if result.count > 1 {
                    return result
                }
            }
        }

        return sense
    }

    private func splitPlainTextSenses(_ text: String) -> [String] {
        // Section headers that mark the end of main definitions.
        // Everything after these is compound entries / special usages.
        let sectionCutoffs = ["词性变化", "特殊用法", "习惯用语", "继承用法", "参考词汇", "同义词", "反义词"]

        // Truncate text before compound / special-usage sections
        var truncated = text
        for cutoff in sectionCutoffs {
            if let range = truncated.range(of: cutoff) {
                truncated = String(truncated[..<range.lowerBound])
            }
        }

        let markers: [Character] = ["①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨", "⑩", "■"]
        var senses: [String] = []
        var current = ""

        for character in truncated {
            if markers.contains(character) {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    senses.append(trimmed)
                }
                current = ""
            } else {
                current.append(character)
            }
        }

        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            senses.append(trimmed)
        }

        // Strip embedded numbering leaked from the raw dictionary text.
        // The 英汉汉英 format uses patterns like "1.■普通的2.■普遍的" so after
        // splitting on ■, each sense may have a leading "N." prefix and/or a
        // trailing "N." suffix from the next entry's number.
        return senses.map { cleanSenseNumbering($0) }
    }

    /// Remove leading/trailing dictionary numbering patterns (e.g. "1.", "2)")
    /// that bleed across ■ delimiters in the raw text.
    private func cleanSenseNumbering(_ sense: String) -> String {
        var result = sense
        // Strip leading number prefix: "1.", "2. ", "12)", "(3)" etc.
        result = result.replacingOccurrences(
            of: #"^\s*\(?\d+[.)]\)?\s*"#,
            with: "",
            options: .regularExpression
        )
        // Strip trailing number suffix: a dangling "2.", "3." at the end
        result = result.replacingOccurrences(
            of: #"\s*\d+[.)]\s*$"#,
            with: "",
            options: .regularExpression
        )
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func splitMeaningAndTranslation(from text: String) -> PlainTextMeaning {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: "\\p{Han}", options: .regularExpression) else {
            return PlainTextMeaning(meaning: trimmed, translation: nil)
        }
        let englishPart = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // If the "English part" is only punctuation/brackets (e.g. "(") before
        // CJK characters, treat the entire text as translation to avoid eating
        // the opening parenthesis: "(以食物, 睡眠等)使精力…" should stay intact.
        let hasRealEnglish = englishPart.range(of: "[A-Za-z]{2,}", options: .regularExpression) != nil
        guard hasRealEnglish else {
            // Entire text is effectively CJK translation
            let fullTranslation = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
            return PlainTextMeaning(meaning: fullTranslation, translation: fullTranslation)
        }

        let chinesePart = String(trimmed[range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedTranslation = sanitizePlainTextTranslation(chinesePart)
        return PlainTextMeaning(meaning: englishPart, translation: cleanedTranslation.isEmpty ? nil : cleanedTranslation)
    }

    private func sanitizePlainTextTranslation(_ text: String) -> String {
        var result = text
        let latinPattern = "[A-Za-z\\u00C0-\\u024F\\u1E00-\\u1EFF]+"
        result = result.replacingOccurrences(of: "«[^»]*»", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "‹[^›]*›", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\([^\\)]*[A-Za-z\\u00C0-\\u024F\\u1E00-\\u1EFF][^\\)]*\\)", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: latinPattern, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parsePOSLabel(in text: String, from startIndex: String.Index) -> (String, String.Index) {
        var index = skipWhitespace(in: text, from: startIndex)
        let labelStart = index

        while index < text.endIndex {
            let character = text[index]
            if isPOSLabelCharacter(character) {
                index = text.index(after: index)
            } else {
                break
            }
        }

        let rawLabel = String(text[labelStart..<index]).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        let normalizedLabel = normalizePOSLabel(rawLabel)
        let labelEndIndex = text.index(labelStart, offsetBy: normalizedLabel.count, limitedBy: index) ?? index
        return (normalizedLabel, labelEndIndex)
    }

    private func normalizePOSLabel(_ label: String) -> String {
        let lowercased = label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["transitive verb", "intransitive verb", "vt", "vi", "noun", "verb", "adjective", "adverb",
                        "preposition", "conjunction", "pronoun", "interjection", "n.", "v.", "adj.", "adv.",
                        "n", "v", "adj", "adv", "名词", "动词", "形容词", "副词", "及物动词", "不及物动词"]
        for prefix in prefixes {
            if lowercased.hasPrefix(prefix) {
                return prefix
            }
        }
        if let range = findFirstPartOfSpeechRange(in: label) {
            return String(label[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return label.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func skipWhitespace(in text: String, from index: String.Index) -> String.Index {
        var currentIndex = index
        while currentIndex < text.endIndex, text[currentIndex].isWhitespace {
            currentIndex = text.index(after: currentIndex)
        }
        return currentIndex
    }

    private func isPOSLabelCharacter(_ character: Character) -> Bool {
        if character == "." || character == "-" {
            return true
        }
        if character.isWhitespace {
            return true
        }
        return character.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) }
    }

    private func isValidPartOfSpeech(_ pos: String) -> Bool {
        let lowercased = pos.lowercased()
        let knownPOS = ["noun", "verb", "adjective", "adverb", "preposition", "conjunction",
                        "pronoun", "interjection", "transitive verb", "intransitive verb", "vt", "vi",
                        "n.", "v.", "adj.", "adv.", "n", "v", "adj", "adv", "名词", "动词", "形容词", "副词", "及物动词", "不及物动词"]
        return knownPOS.contains { lowercased.contains($0) }
    }

    private func extractMeanings(from html: String) -> [String] {
        var meanings: [String] = []

        // 匹配释义标签
        let patterns = [
            "<span[^>]*class=\"[^\"]*(?:df|def|definition|meaning)[^\"]*\"[^>]*>([^<]+(?:<[^>]+>[^<]*</[^>]+>)?[^<]*)</span>",
            "<div[^>]*class=\"[^\"]*(?:df|def|definition|meaning)[^\"]*\"[^>]*>([^<]+)</div>"
        ]

        for pattern in patterns {
            let matches = matchAll(pattern: pattern, in: html)
            for match in matches {
                let cleaned = stripHTML(match).trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty && cleaned.count > 2 {
                    meanings.append(cleaned)
                }
            }
            if !meanings.isEmpty {
                break
            }
        }

        return meanings
    }

    private func extractAllMeanings(from html: String) -> [String] {
        var meanings: [String] = []

        // 尝试多种方式提取释义
        let patterns = [
            "<span[^>]*class=\"[^\"]*(?:df|def)[^\"]*\"[^>]*>([^<]+)</span>",
            "<d:def[^>]*>([^<]+)</d:def>"
        ]

        for pattern in patterns {
            let matches = matchAll(pattern: pattern, in: html)
            for match in matches {
                let cleaned = stripHTML(match).trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty && cleaned.count > 3 {
                    meanings.append(cleaned)
                }
            }
        }

        // 如果还是没有，尝试从纯文本中提取
        if meanings.isEmpty {
            let plainText = stripHTML(html)
            let sentences = plainText.components(separatedBy: CharacterSet(charactersIn: ".;"))
            for sentence in sentences.prefix(3) {
                let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count > 10 && trimmed.count < 200 {
                    meanings.append(trimmed + ".")
                    break
                }
            }
        }

        return meanings
    }

    private func extractExamples(from html: String) -> [String] {
        var examples: [String] = []

        // 匹配例句标签
        let patterns = [
            "<span[^>]*class=\"[^\"]*(?:eg|ex|example)[^\"]*\"[^>]*>([^<]+)</span>",
            "<i>([^<]+)</i>",  // 斜体通常是例句
            "[\u{201C}\u{201D}]([^\u{201C}\u{201D}]+)[\u{201C}\u{201D}]"  // 引号内的内容
        ]

        for pattern in patterns {
            let matches = matchAll(pattern: pattern, in: html)
            for match in matches {
                let cleaned = match.trimmingCharacters(in: .whitespacesAndNewlines)
                // 例句通常较长，且包含空格
                if cleaned.count > 10 && cleaned.contains(" ") {
                    examples.append(cleaned)
                    if examples.count >= 2 {
                        break
                    }
                }
            }
            if !examples.isEmpty {
                break
            }
        }

        return examples
    }

    // MARK: - Helpers

    private func matchFirst(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range), match.numberOfRanges > 1 else {
            return nil
        }
        guard let matchRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[matchRange])
    }

    private func matchAll(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)

        return matches.compactMap { match -> String? in
            guard match.numberOfRanges > 1,
                  let matchRange = Range(match.range(at: 1), in: text) else {
                return nil
            }
            return String(text[matchRange])
        }
    }

    private func stripHTML(_ html: String) -> String {
        // 移除 HTML 标签
        var result = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        // 解码 HTML 实体
        result = result.replacingOccurrences(of: "&nbsp;", with: " ")
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        result = result.replacingOccurrences(of: "&#39;", with: "'")
        // 压缩空白
        result = result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Character Extension

private extension Character {
    /// Returns true for CJK Unified Ideographs (Chinese/Japanese/Korean characters).
    var isChineseCharacter: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        let value = scalar.value
        // CJK Unified Ideographs: U+4E00–U+9FFF
        // CJK Extension A: U+3400–U+4DBF
        // CJK Extension B+: U+20000–U+2A6DF
        // CJK Compatibility: U+F900–U+FAFF
        return (0x4E00...0x9FFF).contains(value)
            || (0x3400...0x4DBF).contains(value)
            || (0x20000...0x2A6DF).contains(value)
            || (0xF900...0xFAFF).contains(value)
    }
}
