import importlib.util
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("validate-localization.py")
SPEC = importlib.util.spec_from_file_location("validate_localization", SCRIPT)
VALIDATOR = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(VALIDATOR)


class SourceExtractionTests(unittest.TestCase):
    def test_ignores_comments_and_sql_like_strings(self):
        source = '''
        // Text("comment")
        /* Text("outer") /* Text("nested") */ */
        let query = "Text(\\"not a key\\") SELECT * FROM String(localized: \\"fake\\")"
        Text("Real")
        '''
        self.assertEqual(VALIDATOR.extract_source_keys(source), {"Real"})

    def test_extracts_sinks_navigation_ternaries_and_fallbacks(self):
        source = '''
        Text("Direct")
        NavigationLink(isActive: $active) { Text("Destination") } label: {
            Text(flag ? "Yes" : other ? "Nested" : "No")
            Text(value ?? "Fallback")
        }
        Text(dynamicValue)
        Text(flag ? dynamicValue : "Static")
        Text(dynamicValue ?? otherValue)
        '''
        self.assertEqual(
            VALIDATOR.extract_source_keys(source),
            {"Direct", "Destination", "Yes", "Nested", "No", "Fallback", "Static"},
        )

    def test_string_localized_variants_and_trailing_arguments(self):
        source = '''
        String(localized: "One", table: "Localizable")
        String(localized: enabled ? "On" : "Off", comment: "state")
        String(localized: dynamicKey, bundle: .main)
        '''
        self.assertEqual(VALIDATOR.extract_source_keys(source), {"One", "On", "Off"})

    def test_widget_metadata_and_direct_text(self):
        source = '''
        Text("Widget text")
        .configurationDisplayName("Widget name")
        static let description = IntentDescription("Widget description")
        static let categoryName: LocalizedStringResource = "Widget category"
        '''
        self.assertEqual(
            VALIDATOR.extract_source_keys(source, widget=True),
            {"Widget text", "Widget name", "Widget description", "Widget category"},
        )

    def test_source_and_english_placeholders_are_checked_before_variations(self):
        entry = {
            "localizations": {
                "en": {"variations": {"plural": {"one": {"stringUnit": {"value": "%@ item"}}}}},
            }
        }
        english = VALIDATOR.localized_values(entry["localizations"]["en"])
        self.assertEqual(set(english), {("variations", "plural", "one")})
        self.assertFalse(VALIDATOR.source_matches_english_placeholders("%lld items", english))
        self.assertFalse(VALIDATOR.source_matches_english_placeholders("items", {(): "%@ items"}))

    def test_plural_and_positional_placeholders_remain_path_aware(self):
        english = {"one": "%1$@ has %2$@", "other": "%1$@ have %2$@"}
        french = {"one": "%2$@ a %1$@", "other": "%2$@ ont %1$@"}
        self.assertEqual(
            {path: tuple(VALIDATOR.placeholders(value)) for path, value in english.items()},
            {path: tuple(VALIDATOR.placeholders(value)) for path, value in french.items()},
        )

    def test_english_plural_leaves_all_match_source_signature(self):
        english = {
            ("variations", "plural", "one"): "%lld item",
            ("variations", "plural", "other"): "%@ items",
        }
        self.assertFalse(VALIDATOR.source_matches_english_placeholders("%lld items", english))
        self.assertTrue(
            VALIDATOR.source_matches_english_placeholders(
                "%lld items",
                {path: value.replace("%@", "%lld") for path, value in english.items()},
            )
        )

    def test_placeholder_signatures_allow_positional_reordering_but_not_types(self):
        self.assertTrue(
            VALIDATOR.source_matches_english_placeholders(
                "%1$@ has %2$lld",
                {(): "%2$lld has %1$@"},
            )
        )
        self.assertFalse(VALIDATOR.source_matches_english_placeholders("%lld", {(): "%@"}))
        self.assertTrue(VALIDATOR.source_matches_english_placeholders("Progress %%", {(): "Progress %%"}))
        self.assertTrue(
            VALIDATOR.source_matches_english_placeholders(
                "accounts.group.accessibility",
                {(): "Account %@"},
            )
        )

    def test_english_variation_paths_must_match_localized_paths(self):
        self.assertNotEqual(
            set(VALIDATOR.localized_values({"variations": {"plural": {"one": {"stringUnit": {"value": "one"}}}}})),
            set(VALIDATOR.localized_values({"variations": {"plural": {"other": {"stringUnit": {"value": "other"}}}}})),
        )

    def test_lexer_handles_raw_multiline_strings_and_escaped_delimiters(self):
        source = r'''
        let ordinary = "Text(\"not a key\")"
        let multiline = """
          Text("not a key")
        """
                let raw = #"Text("not a key") \#" still raw"#
        let rawMultiline = ##"""
          NavigationLink("not a key")
        """##
        Text(#"literal \#" quote"#)
        '''
        self.assertEqual(VALIDATOR.extract_source_keys(source), {r'literal \#" quote'})

    def test_metadata_is_label_aware_and_does_not_scan_category_assignments(self):
        source = '''
        let title: LocalizedStringResource = enabled ? "Enabled" : "Disabled"
        @Parameter(title: flag ? "Flag" : "Other", description: "Ignored")
        static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Type name")
        DisplayRepresentation(title: value ?? "Display fallback")
        IntentDescription("Intent prose", categoryName: "Category")
        let categoryName = "Not metadata"
        '''
        self.assertEqual(
            VALIDATOR.extract_source_keys(source, widget=True),
            {"Enabled", "Disabled", "Flag", "Other", "Type name", "Display fallback", "Intent prose", "Category"},
        )

    def test_literal_noise_and_nested_expressions_are_ignored(self):
        source = r'''
        Text(flag ? (first ?? "Fallback") : (other ? "Nested" : "-"), comment: foo())
        Text(value ? "\(count)" : "Before \(count) after")
        Text(value ? "%%" : "+")
        Text(value ? (dynamicValue ?? otherValue) : ("Deep \(a + (b * c))"))
        '''
        self.assertEqual(
            VALIDATOR.extract_source_keys(source),
            {"Fallback", "Nested", r"Before \(count) after", r"Deep \(a + (b * c))"},
        )

    def test_interpolated_budget_transfer_keys_match_normalized_english_values(self):
        catalog = {
            "budget.transfer.availableFooter": {
                "localizations": {"en": {"stringUnit": {"value": "%@ has %@ available in %@."}}}
            },
            "budget.transfer.overspentFooter": {
                "localizations": {"en": {"stringUnit": {"value": "%@ is overspent by %@ in %@."}}}
            },
        }
        self.assertTrue(
            VALIDATOR.interpolated_key_matches(
                r"\(context.category.categoryName) has \(budgetStore.displayBalance(context.category.available)) available in \(MonthPicker.title(for: context.category.month)).",
                catalog,
            )
        )
        self.assertTrue(
            VALIDATOR.interpolated_key_matches(
                r"\(context.category.categoryName) is overspent by \(budgetStore.displayBalance(abs(context.category.available))) in \(MonthPicker.title(for: context.category.month)).",
                catalog,
            )
        )

    def test_interpolation_matching_rejects_unbalanced_and_wrong_placeholder_counts(self):
        catalog = {
            "key": {"localizations": {"en": {"stringUnit": {"value": "%@ has %@."}}}},
        }
        self.assertFalse(VALIDATOR.interpolated_key_matches(r"\(name) has \(amount.", catalog))
        self.assertFalse(VALIDATOR.interpolated_key_matches(r"\(name) has \(amount) in \(month).", catalog))

    def test_nested_brackets_and_calls_are_removed_as_one_interpolation(self):
        catalog = {
            "key": {"localizations": {"en": {"stringUnit": {"value": "%@ -> %@."}}}},
        }
        self.assertTrue(
            VALIDATOR.interpolated_key_matches(
                r"\(items[index(for: values.filter { $0.isValid })]) -> \(format(value: map[key])).",
                catalog,
            )
        )

    def test_interpolation_only_strings_are_not_extracted(self):
        self.assertEqual(VALIDATOR.extract_source_keys(r'Text("\(value)")'), set())


if __name__ == "__main__":
    unittest.main()
