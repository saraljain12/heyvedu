import Foundation
import SQLite3

/// Copies the user's words and snippets out of Wispr Flow's local database.
///
/// Wispr keeps them in the `Dictionary` table of `Application Support/Wispr Flow/flow.sqlite`:
/// a plain word has no `replacement`, a replacement ("btw" → "by the way") has one, and a
/// snippet has one with `isSnippet` set. Words Wispr learned on its own (`source` =
/// `user_edits`) are skipped: they are mostly misheard fragments, often in the wrong case.
nonisolated enum WisprFlowImport {
    struct Row: Equatable {
        var phrase: String
        var replacement: String?
        var isSnippet: Bool
    }

    struct Result: Equatable {
        var words = 0
        var snippets = 0
    }

    struct ReadError: LocalizedError {
        var errorDescription: String?
    }

    static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wispr Flow/flow.sqlite")
    }

    static func read(from url: URL = defaultFileURL) throws -> [Row] {
        // Immutable: Wispr may have the database open, and a plain read-only open fails on
        // its WAL files. Nothing is ever written.
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "immutable", value: "1")]
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(components.string, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            throw ReadError(errorDescription: "Couldn't open Wispr Flow's data.")
        }
        let sql = """
            SELECT phrase, replacement, isSnippet FROM Dictionary
            WHERE isDeleted = 0 AND source IS NOT 'user_edits' ORDER BY createdAt
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ReadError(errorDescription: "Wispr Flow's dictionary wasn't found in its data.")
        }
        var rows: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let phrase = sqlite3_column_text(statement, 0) else { continue }
            let replacement = sqlite3_column_text(statement, 1).map { String(cString: $0) }
            rows.append(Row(phrase: String(cString: phrase), replacement: replacement,
                            isSnippet: sqlite3_column_int(statement, 2) != 0))
        }
        return rows
    }

    /// Adds what's new to `entries` and `snippets`; anything already there wins.
    static func merge(_ rows: [Row], entries: inout [PersonalDictionary.Entry],
                      snippets: inout [SnippetLibrary.Snippet]) -> Result {
        var result = Result()
        for row in rows {
            let phrase = row.phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = row.replacement?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !phrase.isEmpty else { continue }
            let key = DictionaryMatcher.normalized(phrase)

            if row.isSnippet {
                guard !replacement.isEmpty,
                      !snippets.contains(where: { DictionaryMatcher.normalized($0.trigger) == key })
                else { continue }
                // Wispr's snippet text is the stored replacement, not its HTML.
                snippets.append(.init(trigger: phrase, expansion: row.replacement!))
                result.snippets += 1
            } else {
                guard !entries.contains(where: { claims($0, key) }) else { continue }
                if replacement.isEmpty {
                    entries.append(.init(term: phrase))
                } else if let index = entries.firstIndex(where: { $0.term == replacement }) {
                    entries[index].alternatives.append(phrase)
                } else {
                    entries.append(.init(term: replacement, alternatives: [phrase]))
                }
                result.words += 1
            }
        }
        return result
    }

    /// Whether the entry already matches that phrase, as its term or an alternative.
    private static func claims(_ entry: PersonalDictionary.Entry, _ key: String) -> Bool {
        ([entry.term] + entry.alternatives).contains { DictionaryMatcher.normalized($0) == key }
    }
}
