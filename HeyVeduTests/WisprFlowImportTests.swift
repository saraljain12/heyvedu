import Foundation
import Testing
@testable import HeyVedu

struct WisprFlowImportTests {
    private func row(_ phrase: String, _ replacement: String? = nil, snippet: Bool = false) -> WisprFlowImport.Row {
        .init(phrase: phrase, replacement: replacement, isSnippet: snippet)
    }

    @Test func importsWordsReplacementsAndSnippets() {
        var entries: [PersonalDictionary.Entry] = []
        var snippets: [SnippetLibrary.Snippet] = []
        let result = WisprFlowImport.merge(
            [row("Saral Jain"), row("btw", "by the way"), row("my email", "a@b.co", snippet: true)],
            entries: &entries, snippets: &snippets)
        #expect(result == .init(words: 2, snippets: 1))
        #expect(entries.map(\.term) == ["Saral Jain", "by the way"])
        #expect(entries[1].alternatives == ["btw"])
        #expect(snippets.map(\.trigger) == ["my email"])
        #expect(snippets[0].expansion == "a@b.co")
    }

    @Test func keepsWhatIsAlreadyThere() {
        var entries: [PersonalDictionary.Entry] = [.init(term: "VictoriaMetrics", alternatives: ["victoria metrics"])]
        var snippets: [SnippetLibrary.Snippet] = [.init(trigger: "My Email", expansion: "mine")]
        let result = WisprFlowImport.merge(
            [row("victoriametrics"), row("Victoria, Metrics"), row("my email", "theirs", snippet: true), row("  ")],
            entries: &entries, snippets: &snippets)
        #expect(result == .init())
        #expect(entries.count == 1 && snippets == [.init(id: snippets[0].id, trigger: "My Email", expansion: "mine")])
    }

    @Test func addsAReplacementToAnExistingTerm() {
        var entries: [PersonalDictionary.Entry] = [.init(term: "by the way")]
        var snippets: [SnippetLibrary.Snippet] = []
        #expect(WisprFlowImport.merge([row("btw", "by the way")], entries: &entries, snippets: &snippets).words == 1)
        #expect(entries.count == 1 && entries[0].alternatives == ["btw"])
    }

    @Test func importingTwiceAddsNothing() {
        let rows = [row("Saral"), row("btw", "by the way"), row("sig", "Best", snippet: true)]
        var entries: [PersonalDictionary.Entry] = []
        var snippets: [SnippetLibrary.Snippet] = []
        _ = WisprFlowImport.merge(rows, entries: &entries, snippets: &snippets)
        #expect(WisprFlowImport.merge(rows, entries: &entries, snippets: &snippets) == .init())
    }

    @Test func readsWisprsDatabaseSkippingDeletedAndLearnedWords() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let sql = """
            CREATE TABLE Dictionary (phrase TEXT, replacement TEXT, isSnippet INT, isDeleted INT, source TEXT, createdAt TEXT);
            INSERT INTO Dictionary VALUES ('Saral', NULL, 0, 0, 'manual', '1'), ('gone', NULL, 0, 1, 'manual', '2'),
              ('Abor', NULL, 0, 0, 'user_edits', '3'), ('sig', 'Best', 1, 0, 'default', '4'), ('JP', NULL, 0, 0, NULL, '5');
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [url.path, sql]
        try process.run()
        process.waitUntilExit()
        #expect(try WisprFlowImport.read(from: url)
            == [row("Saral"), row("sig", "Best", snippet: true), row("JP")])
    }

    @Test func readingAMissingDatabaseThrows() {
        #expect(throws: WisprFlowImport.ReadError.self) {
            try WisprFlowImport.read(from: URL(fileURLWithPath: "/nonexistent/flow.sqlite"))
        }
    }
}
