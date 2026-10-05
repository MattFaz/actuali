import Observation
import SwiftUI
import UIKit

/// The pure part of dragging a category in the Clean budget table: where a
/// dragged row would land among the groups, and the arrangement that results.
/// Kept free of views so the placement rules are unit-tested.
enum CategoryReorderPlanner {
    /// One group's categories, top to bottom.
    struct Entry: Equatable {
        let id: String
        var ids: [String]
    }

    /// A position: `index` among the group's *other* categories, so the
    /// dragged one never counts itself.
    struct Slot: Equatable {
        let groupId: String
        let index: Int
    }

    /// Where the category sits in `arrangement`, as a `Slot`.
    static func slot(of dragged: String, in arrangement: [Entry]) -> Slot? {
        for entry in arrangement {
            if let position = entry.ids.firstIndex(of: dragged) {
                return Slot(groupId: entry.id, index: position)
            }
        }
        return nil
    }

    /// The slot a dragged row's centre is over. The group is the one whose
    /// card the centre is in, or the nearest card when it's in a gap or over a
    /// header (so a row can be dropped at the very end of a group, and a gap
    /// never swallows it). Within the group, the index is the number of the
    /// other rows whose middle sits above the centre. `frames` are the rows'
    /// frames in one shared coordinate space, the dragged row's own slot
    /// included so a group it is alone in still has a card. An empty group's
    /// header supplies its bounds instead.
    static func destination(
        dragged: String,
        centerY: CGFloat,
        arrangement: [Entry],
        frames: [String: CGRect]
    ) -> Slot? {
        var best: (group: Int, distance: CGFloat)?
        for (position, entry) in arrangement.enumerated() {
            var rects = entry.ids.compactMap { frames[$0] }
            if entry.ids.isEmpty, let header = frames[headerKey(entry.id)] {
                rects = [header]
            }
            guard let top = rects.map(\.minY).min(), let bottom = rects.map(\.maxY).max() else { continue }
            let distance = if centerY < top {
                top - centerY
            } else if centerY > bottom {
                centerY - bottom
            } else {
                CGFloat(0)
            }
            if best == nil || distance < best!.distance {
                best = (position, distance)
            }
        }
        guard let group = best?.group else { return nil }
        let entry = arrangement[group]
        let index = entry.ids
            .filter { $0 != dragged }
            .count(where: { (frames[$0]?.midY ?? .infinity) < centerY })
        return Slot(groupId: entry.id, index: index)
    }

    /// `arrangement` with `dragged` taken out and put at `slot`.
    static func moved(_ arrangement: [Entry], dragged: String, to slot: Slot) -> [Entry] {
        var result = arrangement
        for position in result.indices {
            result[position].ids.removeAll { $0 == dragged }
        }
        guard let group = result.firstIndex(where: { $0.id == slot.groupId }) else { return arrangement }
        result[group].ids.insert(dragged, at: min(slot.index, result[group].ids.count))
        return result
    }

    /// The write that makes the database match `arrangement`: the dragged
    /// category goes into its group, before the category now below it (nil =
    /// last).
    static func target(of dragged: String, in arrangement: [Entry]) -> (groupId: String, before: String?)? {
        for entry in arrangement {
            if let position = entry.ids.firstIndex(of: dragged) {
                let next = entry.ids.indices.contains(position + 1) ? entry.ids[position + 1] : nil
                return (entry.id, next)
            }
        }
        return nil
    }

    /// Where one step up (-1) or down (+1) puts the category: the neighbouring
    /// position in its group, spilling over into the end of the previous group
    /// or the start of the next one at an edge. Nil at the very top or bottom.
    /// This is VoiceOver's alternative to dragging.
    static func step(_ direction: Int, of dragged: String, in arrangement: [Entry]) -> Slot? {
        guard let current = slot(of: dragged, in: arrangement),
              let group = arrangement.firstIndex(where: { $0.id == current.groupId }) else { return nil }
        let count = arrangement[group].ids.count
        if direction < 0 {
            if current.index > 0 {
                return Slot(groupId: current.groupId, index: current.index - 1)
            }
            guard group > 0 else { return nil }
            let previous = arrangement[group - 1]
            return Slot(groupId: previous.id, index: previous.ids.count)
        }
        if current.index < count - 1 {
            return Slot(groupId: current.groupId, index: current.index + 1)
        }
        guard group + 1 < arrangement.count else { return nil }
        return Slot(groupId: arrangement[group + 1].id, index: 0)
    }

    // MARK: - Groups

    /// The frame key a group's header is measured under.
    static func headerKey(_ groupId: String) -> String {
        "header-\(groupId)"
    }

    /// The index a dragged group's centre is over, among the *other* groups,
    /// counted by their header frames (the groups are folded to their headers
    /// while one is dragged).
    static func groupDestination(
        dragged: String,
        centerY: CGFloat,
        order: [String],
        frames: [String: CGRect]
    ) -> Int {
        order
            .filter { $0 != dragged }
            .count(where: { (frames[headerKey($0)]?.midY ?? .infinity) < centerY })
    }

    /// `order` with `dragged` taken out and put at `index` among the others.
    static func movedGroup(_ order: [String], dragged: String, to index: Int) -> [String] {
        var result = order.filter { $0 != dragged }
        result.insert(dragged, at: min(max(index, 0), result.count))
        return result
    }

    /// The group now below `dragged` (nil when it is last): what the save
    /// places it before.
    static func groupTarget(of dragged: String, in order: [String]) -> String? {
        guard let position = order.firstIndex(of: dragged),
              order.indices.contains(position + 1) else { return nil }
        return order[position + 1]
    }

    /// Where one step up (-1) or down (+1) puts a group among the others; nil
    /// at the top or bottom.
    static func groupStep(_ direction: Int, of dragged: String, in order: [String]) -> Int? {
        guard let position = order.firstIndex(of: dragged) else { return nil }
        let target = position + direction
        return order.indices.contains(target) ? target : nil
    }
}

/// A category move for the caller to persist.
struct CategoryMove: Equatable {
    let id: String
    let groupId: String
    let before: String?
}

/// A category group move for the caller to persist.
struct CategoryGroupMove: Equatable {
    let id: String
    let before: String?
}

/// What the table needs from its scroll view to auto-scroll while dragging.
struct ReorderScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var minOffset: CGFloat = 0
    var maxOffset: CGFloat = 0
    var viewportHeight: CGFloat = 0
}

/// Drives dragging a category by its handle in reorder mode. The lifted row is
/// a copy drawn above the list at the finger and its slot stays empty; the
/// other rows make way as it passes them. Nothing is saved until the finger
/// lifts, and the order stays on screen until the saved one replaces it.
@MainActor @Observable
final class CategoryReorderController {
    typealias Entry = CategoryReorderPlanner.Entry

    /// The scroll view's frame (touches, the lifted row) and its content (row
    /// frames, unaffected by scrolling).
    static let viewportSpace = "categoryReorderViewport"
    static let tableSpace = "categoryReorderTable"

    private(set) var liftedId: String?
    /// A dragged group: while one is lifted the groups are folded to their
    /// headers so they reorder as single rows.
    private(set) var liftedGroupId: String?
    private(set) var groupOrder: [String] = []
    private(set) var groupNames: [String: String] = [:]
    /// The arrangement being shown; empty until the first drag. It outlives
    /// the drop until `clearPreview()`, so rows don't snap back before the
    /// saved order arrives.
    private(set) var arrangement: [Entry] = []
    private(set) var lookup: [String: CategoryBudget] = [:]
    private(set) var liftedTop: CGFloat = 0
    private(set) var liftedLeading: CGFloat = 0
    private(set) var liftedSize: CGSize = .zero

    @ObservationIgnored var rowFrames: [String: CGRect] = [:]
    @ObservationIgnored var stackOriginY: CGFloat = 0
    @ObservationIgnored var scroll = ReorderScrollMetrics()
    @ObservationIgnored var onScrollBy: ((CGFloat) -> Void)?
    @ObservationIgnored var onDrop: ((CategoryMove) -> Void)?
    @ObservationIgnored var onDropGroup: ((CategoryGroupMove) -> Void)?

    @ObservationIgnored private var snapshot: [Entry] = []
    @ObservationIgnored private var groupSnapshot: [String] = []
    @ObservationIgnored private var fingerY: CGFloat = 0
    @ObservationIgnored private var grabOffset: CGFloat = 0
    @ObservationIgnored private var isSettling = false
    @ObservationIgnored private var isSaving = false
    @ObservationIgnored private var autoScroll: Task<Void, Never>?
    @ObservationIgnored private let impact = UIImpactFeedbackGenerator(style: .medium)
    @ObservationIgnored private let selection = UISelectionFeedbackGenerator()

    private static let reflowSpring = Animation.spring(response: 0.3, dampingFraction: 0.85)

    var isDragging: Bool {
        liftedId != nil || liftedGroupId != nil
    }

    var isDraggingGroup: Bool {
        liftedGroupId != nil
    }

    /// The groups in the order being shown: the dragged arrangement's while
    /// one is active, otherwise as given.
    func orderedGroups(_ groups: [BudgetView.CategoryGroupSection]) -> [BudgetView.CategoryGroupSection] {
        guard !groupOrder.isEmpty else { return groups }
        let byId = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = groupOrder.compactMap { byId[$0] }
        return ordered.count == groups.count ? ordered : groups
    }

    /// `group`'s categories for display: the arrangement's order while one is
    /// active, otherwise the group's own.
    func displayed(for group: String, fallback: [CategoryBudget]) -> [CategoryBudget] {
        guard !arrangement.isEmpty, let entry = arrangement.first(where: { $0.id == group }) else {
            return fallback
        }
        return entry.ids.compactMap { lookup[$0] }
    }

    // MARK: - Dragging

    /// A touch on a handle: the first sample lifts the row, later ones steer it.
    func touch(id: String, viewportY: CGFloat, groups: () -> [BudgetView.CategoryGroupSection]) {
        guard !isSaving else { return }
        if !isDragging {
            begin(id: id, viewportY: viewportY, groups: groups())
        } else if liftedId == id {
            move(toViewportY: viewportY)
        }
    }

    /// A touch on a group header's handle: the first sample lifts the group.
    func touchGroup(id: String, viewportY: CGFloat, groups: () -> [BudgetView.CategoryGroupSection]) {
        guard !isSaving else { return }
        if !isDragging {
            beginGroup(id: id, viewportY: viewportY, groups: groups())
        } else if liftedGroupId == id {
            move(toViewportY: viewportY)
        }
    }

    /// The finger lifted or the gesture was cancelled: settle the row into
    /// its slot and hand the move over if the order changed.
    func finish(ifLifted id: String) {
        guard liftedId == id, !isSettling else { return }
        autoScroll?.cancel()
        let move = CategoryReorderPlanner.target(of: id, in: arrangement).flatMap { target in
            arrangement == snapshot ? nil : CategoryMove(id: id, groupId: target.groupId, before: target.before)
        }
        guard let frame = rowFrames[id] else {
            land(move)
            return
        }
        isSettling = true
        withAnimation(Self.reflowSpring) {
            liftedTop = frame.minY + stackOriginY
            liftedLeading = frame.minX
        }
        Task {
            try? await Task.sleep(for: .milliseconds(240))
            land(move)
        }
    }

    /// The finger lifted off a group's handle.
    func finishGroup(ifLifted id: String) {
        guard liftedGroupId == id, !isSettling else { return }
        autoScroll?.cancel()
        let move: CategoryGroupMove? = groupOrder == groupSnapshot
            ? nil
            : CategoryGroupMove(id: id, before: CategoryReorderPlanner.groupTarget(of: id, in: groupOrder))
        guard let frame = rowFrames[CategoryReorderPlanner.headerKey(id)] else {
            landGroup(move)
            return
        }
        isSettling = true
        withAnimation(Self.reflowSpring) {
            liftedTop = frame.minY + stackOriginY
            liftedLeading = frame.minX
        }
        Task {
            try? await Task.sleep(for: .milliseconds(240))
            landGroup(move)
        }
    }

    /// Drop the arrangement once the saved order is on screen (or the write failed).
    func clearPreview() {
        isSaving = false
        arrangement = []
        snapshot = []
        groupOrder = []
        groupSnapshot = []
    }

    /// One step up or down for a group without dragging, for VoiceOver.
    func stepGroup(_ direction: Int, of id: String, groups: [BudgetView.CategoryGroupSection]) {
        guard !isDragging, !isSaving, let onDropGroup else { return }
        let order = groups.map(\.id)
        guard let index = CategoryReorderPlanner.groupStep(direction, of: id, in: order) else { return }
        let moved = CategoryReorderPlanner.movedGroup(order, dragged: id, to: index)
        isSaving = true
        onDropGroup(CategoryGroupMove(id: id, before: CategoryReorderPlanner.groupTarget(of: id, in: moved)))
    }

    /// One step up or down without dragging, for VoiceOver.
    func step(_ direction: Int, of id: String, groups: [BudgetView.CategoryGroupSection]) {
        guard !isDragging, !isSaving, let onDrop else { return }
        let entries = groups.map { Entry(id: $0.id, ids: $0.categories.map(\.categoryId)) }
        guard let slot = CategoryReorderPlanner.step(direction, of: id, in: entries) else { return }
        let moved = CategoryReorderPlanner.moved(entries, dragged: id, to: slot)
        guard let target = CategoryReorderPlanner.target(of: id, in: moved) else { return }
        isSaving = true
        onDrop(CategoryMove(id: id, groupId: target.groupId, before: target.before))
    }

    private func begin(id: String, viewportY: CGFloat, groups: [BudgetView.CategoryGroupSection]) {
        guard let frame = rowFrames[id] else { return }
        let entries = groups.map { Entry(id: $0.id, ids: $0.categories.map(\.categoryId)) }
        guard CategoryReorderPlanner.slot(of: id, in: entries) != nil else { return }
        lookup = Dictionary(
            groups.flatMap(\.categories).map { ($0.categoryId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        snapshot = entries
        arrangement = entries
        fingerY = viewportY
        liftedTop = frame.minY + stackOriginY
        liftedLeading = frame.minX
        liftedSize = frame.size
        grabOffset = viewportY - liftedTop
        impact.impactOccurred()
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            liftedId = id
        }
        startAutoScroll()
    }

    private func beginGroup(id: String, viewportY: CGFloat, groups: [BudgetView.CategoryGroupSection]) {
        guard let frame = rowFrames[CategoryReorderPlanner.headerKey(id)] else { return }
        let order = groups.map(\.id)
        guard order.contains(id) else { return }
        groupNames = Dictionary(groups.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        groupSnapshot = order
        groupOrder = order
        fingerY = viewportY
        liftedTop = frame.minY + stackOriginY
        liftedLeading = frame.minX
        liftedSize = frame.size
        grabOffset = viewportY - liftedTop
        impact.impactOccurred()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            liftedGroupId = id
        }
        // Folding the groups shrinks the content. From far down the list that
        // clamps the scroll offset mid-drag and the headers jump under the
        // finger, so start from the top where the folded headers all fit.
        if scroll.offset > scroll.minOffset {
            onScrollBy?(scroll.minOffset - scroll.offset)
        }
        startAutoScroll()
    }

    private func landGroup(_ move: CategoryGroupMove?) {
        withAnimation(.easeOut(duration: 0.15)) {
            liftedGroupId = nil
        }
        isSettling = false
        if let move, let onDropGroup {
            isSaving = true
            onDropGroup(move)
        } else {
            clearPreview()
        }
    }

    private func move(toViewportY y: CGFloat) {
        guard !isSettling else { return }
        fingerY = y
        liftedTop = y - grabOffset
        reflow()
    }

    private func land(_ move: CategoryMove?) {
        withAnimation(.easeOut(duration: 0.12)) {
            liftedId = nil
        }
        isSettling = false
        if let move, let onDrop {
            isSaving = true
            onDrop(move)
        } else {
            clearPreview()
        }
    }

    private func reflow() {
        if let group = liftedGroupId {
            let centerY = liftedTop + liftedSize.height / 2 - stackOriginY
            let index = CategoryReorderPlanner.groupDestination(
                dragged: group, centerY: centerY, order: groupOrder, frames: rowFrames
            )
            let moved = CategoryReorderPlanner.movedGroup(groupOrder, dragged: group, to: index)
            guard moved != groupOrder else { return }
            selection.selectionChanged()
            withAnimation(Self.reflowSpring) {
                groupOrder = moved
            }
            return
        }
        guard let id = liftedId else { return }
        let centerY = liftedTop + liftedSize.height / 2 - stackOriginY
        guard let destination = CategoryReorderPlanner.destination(
            dragged: id, centerY: centerY, arrangement: arrangement, frames: rowFrames
        ), destination != CategoryReorderPlanner.slot(of: id, in: arrangement) else { return }
        selection.selectionChanged()
        withAnimation(Self.reflowSpring) {
            arrangement = CategoryReorderPlanner.moved(arrangement, dragged: id, to: destination)
        }
    }

    // MARK: - Auto-scroll

    private func startAutoScroll() {
        autoScroll?.cancel()
        autoScroll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                self?.autoScrollTick()
            }
        }
    }

    /// Scrolls toward an edge the finger is pressed against, faster the closer
    /// it gets, then re-checks the slot since rows have moved under it.
    private func autoScrollTick() {
        guard isDragging, !isSettling, scroll.viewportHeight > 0 else { return }
        let zone: CGFloat = 90
        let bottomZone: CGFloat = 120 // clears the floating tab bar
        let maxStep: CGFloat = 12
        var step: CGFloat = 0
        if fingerY < zone {
            step = -maxStep * min(1, (zone - fingerY) / zone)
        } else if fingerY > scroll.viewportHeight - bottomZone {
            step = maxStep * min(1, (fingerY - (scroll.viewportHeight - bottomZone)) / bottomZone)
        }
        guard step != 0 else { return }
        let target = min(max(scroll.offset + step, scroll.minOffset), scroll.maxOffset)
        guard target != scroll.offset else { return }
        onScrollBy?(target - scroll.offset)
        reflow()
    }
}

/// Row frames in the table's content space, keyed by category id.
struct CategoryRowFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Where the table's content starts, in the scroll view's own space: how a
/// touch converts to a content position whatever the scroll offset.
struct CategoryStackOriginKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Reorder mode's table: every group and its categories as slim rows with a
/// drag handle. One flat list, so a row keeps its identity when it crosses
/// into another group and the move animates instead of being rebuilt.
struct CategoryReorderTable: View {
    @State private var controller = CategoryReorderController()
    @State private var scrollPosition = ScrollPosition()

    let groups: [BudgetView.CategoryGroupSection]
    /// Persist a drop or a VoiceOver step.
    let onMove: (CategoryMove) async -> Void
    let onMoveGroup: (CategoryGroupMove) async -> Void

    private enum Item: Identifiable {
        case header(id: String, name: String)
        case row(CategoryBudget, isFirst: Bool, isLast: Bool)

        var id: String {
            switch self {
            case .header(let id, _): "header-\(id)"
            case .row(let category, _, _): category.categoryId
            }
        }
    }

    /// The groups' headers and rows, flat. While a group is dragged only the
    /// headers show, so the groups reorder as single rows.
    private var items: [Item] {
        controller.orderedGroups(groups).flatMap { group -> [Item] in
            let header = Item.header(id: group.id, name: group.name)
            guard !controller.isDraggingGroup else { return [header] }
            let categories = controller.displayed(for: group.id, fallback: group.categories)
            return [header]
                + categories.enumerated().map { index, category in
                    Item.row(category, isFirst: index == 0, isLast: index == categories.count - 1)
                }
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    switch item {
                    case .header(let groupId, let name):
                        ReorderHeader(
                            groupId: groupId, name: name, controller: controller,
                            groups: groups
                        )
                    case .row(let category, let isFirst, let isLast):
                        ReorderRow(category: category, isFirst: isFirst, isLast: isLast, controller: controller, groups: groups)
                    }
                }
            }
            .padding(.horizontal, TopBoxLayout.horizontalContentMargin)
            .padding(.bottom, 24)
            .coordinateSpace(name: CategoryReorderController.tableSpace)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: CategoryStackOriginKey.self,
                        value: proxy.frame(in: .named(CategoryReorderController.viewportSpace)).minY
                    )
                }
            )
            .onPreferenceChange(CategoryRowFramesKey.self) { controller.rowFrames = $0 }
            .onPreferenceChange(CategoryStackOriginKey.self) { controller.stackOriginY = $0 }
            // The preference above only refreshes when the layout changes, not
            // while scrolling, so a row reached by scrolling would be lifted
            // at the wrong place. Geometry changes track the scroll itself.
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .named(CategoryReorderController.viewportSpace)).minY
            } action: { origin in
                controller.stackOriginY = origin
            }
        }
        .scrollPosition($scrollPosition)
        .scrollDisabled(controller.isDragging)
        .onScrollGeometryChange(for: ReorderScrollMetrics.self) { geometry in
            ReorderScrollMetrics(
                offset: geometry.contentOffset.y,
                minOffset: -geometry.contentInsets.top,
                maxOffset: max(
                    geometry.contentSize.height - geometry.containerSize.height + geometry.contentInsets.bottom,
                    -geometry.contentInsets.top
                ),
                viewportHeight: geometry.containerSize.height
            )
        } action: { _, metrics in
            controller.scroll = metrics
        }
        .overlay {
            LiftedReorderRow(controller: controller)
        }
        .coordinateSpace(name: CategoryReorderController.viewportSpace)
        .onAppear {
            controller.onScrollBy = { delta in
                scrollPosition.scrollTo(y: controller.scroll.offset + delta)
            }
            controller.onDrop = { move in
                Task {
                    await onMove(move)
                    controller.clearPreview()
                }
            }
            controller.onDropGroup = { move in
                Task {
                    await onMoveGroup(move)
                    controller.clearPreview()
                }
            }
        }
    }
}

/// The row's name and its drag handle: shared by the list row and the lifted copy.
private struct ReorderRowContent: View {
    let category: CategoryBudget
    var handle: AnyView?

    var body: some View {
        HStack(spacing: 8) {
            Text(category.categoryName)
                .font(.body)
                .lineLimit(1)
                .opacity(category.isEffectivelyHidden ? 0.5 : 1)
            Spacer(minLength: 8)
            if let handle {
                handle
            } else {
                Image(systemName: "line.3.horizontal")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 52, height: 54)
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 4)
        .frame(height: 54)
    }
}

private struct ReorderRow: View {
    @GestureState private var touching = false
    let category: CategoryBudget
    let isFirst: Bool
    let isLast: Bool
    let controller: CategoryReorderController
    let groups: [BudgetView.CategoryGroupSection]

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: isFirst ? 22 : 0,
            bottomLeadingRadius: isLast ? 22 : 0,
            bottomTrailingRadius: isLast ? 22 : 0,
            topTrailingRadius: isFirst ? 22 : 0,
            style: .continuous
        )
    }

    private var handle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.title3)
            .foregroundStyle(.secondary)
            .frame(width: 52, height: 54)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(CategoryReorderController.viewportSpace))
                    .updating($touching) { _, state, _ in
                        state = true
                    }
                    .onChanged { value in
                        controller.touch(id: category.categoryId, viewportY: value.location.y) { groups }
                    }
            )
            .onChange(of: touching) { _, active in
                if !active {
                    controller.finish(ifLifted: category.categoryId)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(Text("Reorder \(category.categoryName)"))
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("reorder.handle.\(category.categoryId)")
            .accessibilityAction(named: "Move Up") {
                controller.step(-1, of: category.categoryId, groups: groups)
            }
            .accessibilityAction(named: "Move Down") {
                controller.step(1, of: category.categoryId, groups: groups)
            }
    }

    var body: some View {
        ReorderRowContent(category: category, handle: AnyView(handle))
            .background(Color(.secondarySystemGroupedBackground), in: shape)
            .overlay(alignment: .bottom) {
                if !isLast {
                    Divider().padding(.leading, 20)
                }
            }
            // While lifted, the row's slot stays as an empty gap.
            .opacity(controller.liftedId == category.categoryId ? 0 : 1)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: CategoryRowFramesKey.self,
                        value: [category.categoryId: proxy.frame(in: .named(CategoryReorderController.tableSpace))]
                    )
                }
            )
    }
}

/// A group's header in reorder mode, with the handle that drags the group.
private struct ReorderHeader: View {
    @GestureState private var touching = false
    let groupId: String
    let name: String
    let controller: CategoryReorderController
    let groups: [BudgetView.CategoryGroupSection]

    private var handle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.title3)
            .foregroundStyle(.secondary)
            .frame(width: 52, height: 44)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(CategoryReorderController.viewportSpace))
                    .updating($touching) { _, state, _ in
                        state = true
                    }
                    .onChanged { value in
                        controller.touchGroup(id: groupId, viewportY: value.location.y) { groups }
                    }
            )
            .onChange(of: touching) { _, active in
                if !active {
                    controller.finishGroup(ifLifted: groupId)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(Text("Reorder \(name)"))
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("reorder.groupHandle.\(groupId)")
            .accessibilityAction(named: "Move Up") {
                controller.stepGroup(-1, of: groupId, groups: groups)
            }
            .accessibilityAction(named: "Move Down") {
                controller.stepGroup(1, of: groupId, groups: groups)
            }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            handle
        }
        .padding(.leading, 20)
        .padding(.trailing, 4)
        .frame(height: 44)
        .padding(.top, 10)
        .opacity(controller.liftedGroupId == groupId ? 0 : 1)
        .accessibilityAddTraits(.isHeader)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: CategoryRowFramesKey.self,
                    value: [CategoryReorderPlanner.headerKey(groupId): proxy.frame(in: .named(CategoryReorderController.tableSpace))]
                )
            }
        )
    }
}

/// The lifted row, drawn above the table at the finger so a card never clips
/// it and it can cross groups. A view of its own so moving the finger redraws
/// only this.
private struct LiftedReorderRow: View {
    let controller: CategoryReorderController

    var body: some View {
        if let id = controller.liftedId, let category = controller.lookup[id] {
            lifted {
                ReorderRowContent(category: category)
            }
        } else if let id = controller.liftedGroupId, let name = controller.groupNames[id] {
            lifted {
                HStack(spacing: 8) {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Image(systemName: "line.3.horizontal")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 52, height: 44)
                }
                .padding(.leading, 20)
                .padding(.trailing, 4)
                .frame(height: 44)
            }
        }
    }

    private func lifted(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .frame(width: controller.liftedSize.width)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 14, y: 6)
            .scaleEffect(1.03)
            .offset(x: controller.liftedLeading, y: controller.liftedTop)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
