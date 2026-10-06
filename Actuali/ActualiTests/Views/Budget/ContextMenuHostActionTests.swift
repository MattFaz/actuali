import Foundation
import Testing
@testable import Actuali

@MainActor
struct ContextMenuHostActionTests {
    @Test func groupActionsKeepCleanOrderIconsAndHandlers() {
        var calls: [String] = []
        let actions = ContextMenuHostAction.groupActions(
            isHidden: false,
            onApplyTemplate: { calls.append("apply") },
            onOverwriteTemplate: { calls.append("overwrite") },
            onRename: { calls.append("rename") },
            onSetHidden: { calls.append("hidden=\($0)") },
            locale: Locale(identifier: "en_US")
        )
        #expect(actions.map(\.title) == [
            "Apply Budget Template", "Overwrite with Budget Template", "Rename Group", "Hide Group",
        ])
        #expect(actions.map(\.systemImage) == [
            "wand.and.stars", "wand.and.stars.inverse", "pencil", "eye.slash",
        ])
        for action in actions {
            action.handler()
        }
        #expect(calls == ["apply", "overwrite", "rename", "hidden=true"])
    }

    @Test func hiddenGroupOffersShowAndMissingHandlersProduceNoActions() {
        var hidden = true
        let actions = ContextMenuHostAction.groupActions(
            isHidden: true,
            onRename: nil,
            onSetHidden: { hidden = $0 },
            locale: Locale(identifier: "en_US")
        )
        #expect(actions.map(\.title) == ["Show Group"])
        #expect(actions.map(\.systemImage) == ["eye"])
        actions.first?.handler()
        #expect(!hidden)
        #expect(ContextMenuHostAction.groupActions(
            isHidden: false,
            onRename: nil,
            onSetHidden: nil,
            locale: Locale(identifier: "en_US")
        ).isEmpty)
    }
}
