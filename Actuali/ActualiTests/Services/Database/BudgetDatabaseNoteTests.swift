import Foundation
import GRDB
import Testing
@testable import Actuali

/// Reading notes out of Actual's `notes` table — categories (GH #131) and
/// accounts (GH #198). The table is keyed by the annotated row's own id, so a
/// note lives at `notes.id = <that row's id>` whatever kind of row it is.
struct BudgetDatabaseNoteTests {
    /// A budget file with (or deliberately without) the `notes` table.
    private func makeDatabase(
        includeNotesTable: Bool = true,
        seedSQL: String = ""
    ) async throws -> (BudgetDatabase, URL) {
        try await makeTestDatabase(includeNotesTable ? TestSchema.notes : "", seedSQL)
    }

    @Test func readsStoredNote() async throws {
        let (database, path) = try await makeDatabase(seedSQL: """
        INSERT INTO notes (id, note) VALUES ('cat-groceries', 'Cap at $400/mo');
        """)
        defer { cleanup(path) }

        let note = try await database.fetchNote(id: "cat-groceries")

        #expect(note.supported)
        #expect(note.text == "Cap at $400/mo")
        #expect(!note.isEmpty)
    }

    /// Multi-line notes are the norm for budgeting guidance, so newlines must
    /// survive the round trip untouched.
    @Test func preservesMultilineNoteText() async throws {
        let (database, path) = try await makeDatabase(seedSQL: """
        INSERT INTO notes (id, note) VALUES ('cat-groceries', 'Line one
        Line two');
        """)
        defer { cleanup(path) }

        let note = try await database.fetchNote(id: "cat-groceries")

        #expect(note.text.contains("\n"))
    }

    /// A category nobody has annotated has no row at all — that's an empty
    /// note on a file that supports them, not a missing feature.
    @Test func categoryWithoutARowIsSupportedAndEmpty() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }

        let note = try await database.fetchNote(id: "cat-groceries")

        #expect(note.supported)
        #expect(note.text.isEmpty)
        #expect(note.isEmpty)
    }

    /// A row whose note is NULL reads as empty rather than crashing on the
    /// non-optional `text`.
    @Test func nullNoteReadsAsEmpty() async throws {
        let (database, path) = try await makeDatabase(seedSQL: """
        INSERT INTO notes (id) VALUES ('cat-groceries');
        """)
        defer { cleanup(path) }

        let note = try await database.fetchNote(id: "cat-groceries")

        #expect(note.supported)
        #expect(note.text.isEmpty)
    }

    /// Notes must not read across entities: another row's note is not this
    /// category's.
    @Test func doesNotReadAnotherEntitysNote() async throws {
        let (database, path) = try await makeDatabase(seedSQL: """
        INSERT INTO notes (id, note) VALUES ('cat-fuel', 'Fuel note');
        """)
        defer { cleanup(path) }

        let note = try await database.fetchNote(id: "cat-groceries")

        #expect(note.text.isEmpty)
    }

    /// A file with no `notes` table at all (older snapshot, partially migrated
    /// file) reports unsupported so the UI can hide the section rather than
    /// offer an edit that could never save.
    @Test func fileWithoutNotesTableIsUnsupported() async throws {
        let (database, path) = try await makeDatabase(includeNotesTable: false)
        defer { cleanup(path) }

        let note = try await database.fetchNote(id: "cat-groceries")

        #expect(!note.supported)
        #expect(note.text.isEmpty)
    }

    // MARK: - Write-path guard

    @Test func notesTableExistsReportsPresence() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }

        #expect(try database.notesTableExists())
    }

    @Test func notesTableExistsReportsAbsence() async throws {
        let (database, path) = try await makeDatabase(includeNotesTable: false)
        defer { cleanup(path) }

        #expect(try database.notesTableExists() == false)
    }
}
