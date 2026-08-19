import AppIntents
import WidgetKit

struct SelectCategoriesIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Select Categories"
    static let description = IntentDescription("Choose which category balances the widget shows.")

    /// nil / empty means "not configured yet" — the widget falls back to the
    /// budget's first categories instead of rendering blank.
    @Parameter(title: "Categories")
    var categories: [WidgetCategoryEntity]?
}
