/// Row placement for the ordered lists Actual keeps in `sort_order` columns.
/// Ported from upstream `packages/loot-core/src/server/db/sort.ts` so a
/// category created here lands where the web UI would put it.
enum SortOrder {
    /// The gap upstream leaves between neighbouring rows, so an insert
    /// between two of them usually only has to pick a midpoint.
    static let increment: Double = 16384

    /// One row of an ordered list: its id and where it sits.
    struct Position: Equatable {
        let id: String
        let sortOrder: Double
    }

    /// A position for a new row, plus the existing rows that have to shift
    /// for it to fit.
    struct Placement: Equatable {
        let sortOrder: Double
        let moved: [Position]
    }

    /// Where a new row goes when it should sit immediately before `targetId`
    /// in `items` (already ordered by sort_order, then id).
    ///
    /// Normally that's the midpoint between the target and whatever precedes
    /// it. When those two have closed to within 2 there's no usable midpoint
    /// left, so the target and the rows after it are pushed up by a full
    /// increment first. A nil or unknown `targetId` appends instead.
    ///
    /// Mirrors upstream `shoveSortOrders`, including its quirk of measuring
    /// the midpoint against the *pre-shove* values: the shoved rows all move
    /// well above it, so the new row still lands ahead of them.
    static func shove(
        _ items: [Position],
        before targetId: String?
    ) -> Placement {
        guard let targetId,
              let to = items.firstIndex(where: { $0.id == targetId }) else {
            return Placement(sortOrder: (items.last?.sortOrder ?? 0) + increment, moved: [])
        }

        var moved: [Position] = []
        let preceding = to > 0 ? items[to - 1].sortOrder : 0
        if items[to].sortOrder - preceding <= 2 {
            var next = to
            var order = items[to].sortOrder.rounded(.down) + increment
            while next < items.count {
                // A row already past the new order has a big enough gap of
                // its own, and so does everything below it.
                if order <= items[next].sortOrder { break }
                moved.append(Position(id: items[next].id, sortOrder: order))
                next += 1
                order += increment
            }
        }

        let above = items[to].sortOrder
        let sortOrder = to > 0 ? (items[to - 1].sortOrder + above) / 2 : above / 2
        return Placement(sortOrder: sortOrder, moved: moved)
    }
}
