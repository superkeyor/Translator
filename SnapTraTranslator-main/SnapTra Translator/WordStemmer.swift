import Foundation
import NaturalLanguage

/// Lightweight English word stemmer that produces candidate base forms for
/// inflected words (e.g. "translating" → ["translating", "translate"]).
///
/// Uses NLTagger lemmatisation first; falls back to suffix-stripping rules
/// when the system lemmatiser is unavailable or returns nothing useful.
enum WordStemmer {

    /// Return a list of candidate forms for `word`, starting with the word
    /// itself. Duplicates are removed and order is preserved.
    static func candidates(for word: String) -> [String] {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard !lower.isEmpty else { return [] }

        var result: [String] = [lower]

        // Also include original casing (useful for proper nouns / DCS lookup)
        if trimmed != lower && !result.contains(trimmed) {
            result.append(trimmed)
        }

        // 1. NLTagger lemma
        if let lemma = systemLemma(lower), lemma != lower {
            result.append(lemma)
        }

        // 2. Suffix-stripping heuristics
        let stripped = suffixStrippedForms(lower)
        for form in stripped where !result.contains(form) {
            result.append(form)
        }

        return result
    }

    // MARK: - NLTagger

    private static func systemLemma(_ word: String) -> String? {
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = word
        let range = word.startIndex..<word.endIndex
        let (tag, _) = tagger.tag(at: word.startIndex,
                                   unit: .word,
                                   scheme: .lemma)
        if let lemma = tag?.rawValue,
           !lemma.isEmpty,
           lemma != word {
            return lemma.lowercased()
        }
        // Also try enumerating
        var found: String?
        tagger.enumerateTags(in: range, unit: .word, scheme: .lemma) { tag, _ in
            if let rawTag = tag?.rawValue, !rawTag.isEmpty {
                found = rawTag.lowercased()
            }
            return false // stop after first
        }
        return found != word ? found : nil
    }

    // MARK: - Suffix stripping (English)

    private static func suffixStrippedForms(_ word: String) -> [String] {
        var forms: [String] = []

        // -ing
        if word.hasSuffix("ing") && word.count > 5 {
            let stem = String(word.dropLast(3))
            forms.append(stem)           // translating → translat  (may not be valid, but we try)
            forms.append(stem + "e")     // translating → translate
            // doubling: running → run
            if stem.count >= 3,
               stem.last == stem[stem.index(before: stem.endIndex)],
               !isVowel(stem.last!) {
                forms.append(String(stem.dropLast()))
            }
        }

        // -ed
        if word.hasSuffix("ed") && word.count > 4 {
            let stem = String(word.dropLast(2))
            forms.append(stem)           // fixed → fix (if -xed)
            forms.append(stem + "e")     // translated → translate
            // doubling: stopped → stop
            if stem.count >= 3,
               stem.last == stem[stem.index(before: stem.endIndex)],
               !isVowel(stem.last!) {
                forms.append(String(stem.dropLast()))
            }
            // -ied → -y
            if word.hasSuffix("ied") {
                forms.append(String(word.dropLast(3)) + "y")
            }
        }

        // -s / -es
        if word.hasSuffix("ies") && word.count > 4 {
            forms.append(String(word.dropLast(3)) + "y") // batteries → battery
        } else if word.hasSuffix("ses") || word.hasSuffix("xes") || word.hasSuffix("zes") ||
                    word.hasSuffix("ches") || word.hasSuffix("shes") {
            forms.append(String(word.dropLast(2)))
        } else if word.hasSuffix("s") && !word.hasSuffix("ss") && word.count > 3 {
            forms.append(String(word.dropLast()))
        }

        // -er / -est
        if word.hasSuffix("er") && word.count > 4 {
            let stem = String(word.dropLast(2))
            forms.append(stem)
            forms.append(stem + "e")
            if word.hasSuffix("ier") {
                forms.append(String(word.dropLast(3)) + "y")
            }
        }
        if word.hasSuffix("est") && word.count > 5 {
            let stem = String(word.dropLast(3))
            forms.append(stem)
            forms.append(stem + "e")
            if word.hasSuffix("iest") {
                forms.append(String(word.dropLast(4)) + "y")
            }
        }

        // -ly
        if word.hasSuffix("ly") && word.count > 4 {
            forms.append(String(word.dropLast(2)))
            if word.hasSuffix("ily") {
                forms.append(String(word.dropLast(3)) + "y")
            }
        }

        // -tion / -sion → verb form
        if word.hasSuffix("tion") && word.count > 5 {
            let stem = String(word.dropLast(4))
            forms.append(stem + "te")
            forms.append(stem + "t")
        }
        if word.hasSuffix("sion") && word.count > 5 {
            let stem = String(word.dropLast(4))
            forms.append(stem + "de")
            forms.append(stem + "d")
        }

        return forms.filter { !$0.isEmpty && $0.count >= 2 }
    }

    private static func isVowel(_ c: Character) -> Bool {
        "aeiou".contains(c)
    }
}
