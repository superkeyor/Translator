import Foundation

/// Represents an installed macOS dictionary.
struct InstalledDictionary: Identifiable, Hashable {
    let id: String       // internal identifier (short name or name)
    let name: String     // display name
    let shortName: String

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: InstalledDictionary, rhs: InstalledDictionary) -> Bool {
        lhs.id == rhs.id
    }
}

/// Uses private DictionaryServices API (via C bridge) to enumerate installed dictionaries.
final class DictionaryListService {
    static let shared = DictionaryListService()

    private(set) var dictionaries: [InstalledDictionary] = []

    private init() {
        refresh()
    }

    /// Refresh the list of installed dictionaries from the system.
    func refresh() {
        SNTRefreshDictionaries()
        var results: [InstalledDictionary] = []
        let bufLen: Int32 = 1024
        let nameBuf = UnsafeMutablePointer<CChar>.allocate(capacity: Int(bufLen))
        let shortBuf = UnsafeMutablePointer<CChar>.allocate(capacity: Int(bufLen))
        defer {
            nameBuf.deallocate()
            shortBuf.deallocate()
        }

        let count = SNTGetDictionaryCount()
        for i in 0..<count {
            guard SNTGetDictionaryName(Int32(i), nameBuf, bufLen) != 0 else { continue }
            let name = String(cString: nameBuf)

            let shortName: String
            if SNTGetDictionaryShortName(Int32(i), shortBuf, bufLen) != 0 {
                shortName = String(cString: shortBuf)
            } else {
                shortName = name
            }

            results.append(InstalledDictionary(
                id: shortName,
                name: name,
                shortName: shortName
            ))
        }

        dictionaries = results.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        #if DEBUG
        print("[DictionaryListService] Found \(dictionaries.count) dictionaries:")
        for d in dictionaries {
            print("  - \(d.name) (\(d.shortName))")
        }
        #endif
    }

    /// Look up a word using a specific dictionary by short name.
    /// Returns the raw definition text, or nil.
    func lookup(word: String, dictionaryShortName: String) -> String? {
        let count = SNTGetDictionaryCount()
        let bufLen: Int32 = 1024
        let shortBuf = UnsafeMutablePointer<CChar>.allocate(capacity: Int(bufLen))
        defer { shortBuf.deallocate() }

        for i in 0..<count {
            guard SNTGetDictionaryShortName(Int32(i), shortBuf, bufLen) != 0 else { continue }
            let sn = String(cString: shortBuf)
            if sn == dictionaryShortName {
                guard let cResult = SNTCopyDefinition(Int32(i), word) else { return nil }
                let result = String(cString: cResult)
                free(cResult)
                return result
            }
        }
        return nil
    }

    /// Look up a word using a specific dictionary and return HTML (with popover CSS).
    /// Returns the HTML string, or nil.
    func lookupHTML(word: String, dictionaryShortName: String) -> String? {
        let count = SNTGetDictionaryCount()
        let bufLen: Int32 = 1024
        let shortBuf = UnsafeMutablePointer<CChar>.allocate(capacity: Int(bufLen))
        defer { shortBuf.deallocate() }

        for i in 0..<count {
            guard SNTGetDictionaryShortName(Int32(i), shortBuf, bufLen) != 0 else { continue }
            let sn = String(cString: shortBuf)
            if sn == dictionaryShortName {
                // version 2 = HTML with popover CSS (nicely styled)
                guard let cResult = SNTCopyHTMLDefinition(Int32(i), word, 2) else { return nil }
                let result = String(cString: cResult)
                free(cResult)
                return result
            }
        }
        return nil
    }
}
