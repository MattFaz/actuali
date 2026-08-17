import Foundation
import GRDB
import Testing

@testable import Actuali

struct BackupRetentionTests {
    /// Local-calendar date, matching how prune buckets by day.
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private var today: Date { day(2017, 1, 1) }

    // Upstream vector 1: keeps 3 backups on the current day.
    @Test func keepsThreeOnCurrentDay() {
        let backups = (1...4).map { (id: "backup\($0)", date: day(2017, 1, 1)) }
        #expect(BackupService.backupsToRemove(backups, today: today) == ["backup4"])
    }

    // Upstream vector 2: nothing to delete — ≤3 today, 1 per prior day.
    @Test func keepsOnePerPriorDay() {
        let backups = [
            (id: "backup1", date: day(2017, 1, 1)),
            (id: "backup2", date: day(2017, 1, 1)),
            (id: "backup3", date: day(2016, 12, 30)),
            (id: "backup4", date: day(2016, 12, 29)),
        ]
        #expect(BackupService.backupsToRemove(backups, today: today).isEmpty)
    }

    // Upstream vector 3: extra copies on a prior day are deleted.
    @Test func deletesExtrasOnPriorDays() {
        let backups = [
            (id: "backup1", date: day(2017, 1, 1)),
            (id: "backup2", date: day(2017, 1, 1)),
            (id: "backup3", date: day(2016, 12, 29)),
            (id: "backup4", date: day(2016, 12, 29)),
            (id: "backup5", date: day(2016, 12, 29)),
        ]
        let removed = BackupService.backupsToRemove(backups, today: today)
        #expect(Set(removed) == ["backup4", "backup5"])
    }

    // Upstream vector 4: cap at 10 total (12 in → backup11/12 out).
    @Test func capsAtTenTotal() {
        var backups = [
            (id: "backup1", date: day(2017, 1, 1)),
            (id: "backup2", date: day(2017, 1, 1)),
        ]
        for (index, dayOfMonth) in (20...29).reversed().enumerated() {
            backups.append((id: "backup\(index + 3)", date: day(2016, 12, dayOfMonth)))
        }
        let removed = BackupService.backupsToRemove(backups, today: today)
        #expect(Set(removed) == ["backup11", "backup12"])
    }

    // Ours: a backup from 23:59 yesterday is "yesterday", not "today".
    @Test func dayBucketsUseLocalMidnightBoundary() {
        let yesterdayLate = Calendar.current.date(
            byAdding: DateComponents(minute: -1), to: today
        )!
        let backups = [
            (id: "today1", date: today),
            (id: "late1", date: yesterdayLate),
            (id: "late2", date: yesterdayLate),
        ]
        #expect(BackupService.backupsToRemove(backups, today: today) == ["late2"])
    }

    // Retention runs as part of makeBackup (end-to-end over real files).
    @Test func makeBackupPrunes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = BudgetFileManager(rootDirectoryForTesting: root)

        let dir = manager.budgetDirectory(for: "b")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbQueue = try GRDB.DatabaseQueue(path: manager.databasePath(for: "b").path)
        try await dbQueue.write { try $0.execute(sql: "CREATE TABLE t (id TEXT)") }
        try JSONEncoder().encode(BudgetMetadata(
            id: "b", budgetName: nil, cloudFileId: nil, groupId: nil,
            resetClock: nil, lastUploaded: nil, encryptKeyId: nil
        )).write(to: manager.metadataPath(for: "b"))

        // 4 same-day backups (distinct seconds so names differ) → 3 survive.
        let service = BackupService(fileManager: manager)
        let base = Date()
        for offset in 0..<4 {
            try await service.makeBackup(
                budgetId: "b", database: nil, now: base.addingTimeInterval(Double(offset))
            )
        }
        let kept = await service.availableBackups(budgetId: "b")
        #expect(kept.count == 3)
        #expect(kept.allSatisfy { !$0.isLatest })
    }
}
