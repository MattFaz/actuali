import Foundation

/// One category's remaining balance as the widget shows it. The amount is
/// pre-formatted by the app because the currency settings live in the app's
/// standard UserDefaults, out of the widget process's reach.
struct WidgetCategoryBalance: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    /// In cents; carried alongside the formatted string so the widget can
    /// color overspent categories without parsing the display text.
    let available: Int
    let formattedAvailable: String

    var isOverspent: Bool {
        available < 0
    }
}

/// Everything the widget needs to render, written by the app after each data
/// refresh and read by the widget extension through the app group container.
/// App and widget ship as one bundle, so both always agree on this format;
/// a failed decode (nil) already covers any future format change.
struct WidgetSnapshot: Codable, Equatable {
    let generatedAt: Date
    /// Mirrors the app's hide-balances privacy setting. The formatted amounts
    /// arrive already masked; the widget additionally mutes overspent
    /// coloring so the sign doesn't leak through the mask.
    let balancesHidden: Bool
    let categories: [WidgetCategoryBalance]

    /// The user's chosen categories in their chosen order, capped at what the
    /// widget family can display. An empty selection falls back to the
    /// budget's first categories so a freshly added widget isn't blank.
    func categories(matching ids: [String], limit: Int) -> [WidgetCategoryBalance] {
        guard !ids.isEmpty else { return Array(categories.prefix(limit)) }
        let byId = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Array(ids.compactMap { byId[$0] }.prefix(limit))
    }
}
