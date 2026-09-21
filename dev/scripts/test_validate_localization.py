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

    def test_extracts_live_fallback_literals_and_localized_error_routes(self):
        source = '''
        let institution = org.name ?? "Unknown institution"
        let kind = isIncome ? "Income" : "Schedule"
        return accountName ?? "Unknown account"
        var errorTemplate = GoalTemplate(type: .error, directive: .error)
        errorTemplate.error = parseError.message ?? String(localized: "Invalid template syntax")
        '''
        self.assertEqual(
            VALIDATOR.extract_source_keys(source),
            {"Unknown institution", "Income", "Schedule", "Unknown account", "Invalid template syntax"},
        )

    def test_extracts_localized_error_wrapper_literals_only_in_parse_errors(self):
        source = '''
        throw ParseError(message: localizedError("Wrapped parser error"))
        let unrelated = localizedError("Not a parser key")
        '''
        self.assertEqual(
            VALIDATOR.extract_source_keys(source),
            {"Wrapped parser error"},
        )

    def test_validates_localized_error_wrapper_literals(self):
        source = 'throw ParseError(message: localizedError("Missing wrapped error"))'
        self.assertEqual(
            VALIDATOR.validate_source_keys(
                VALIDATOR.extract_source_keys(source), {"Present": {}}
            ),
            ["catalog: missing catalog key: Missing wrapped error"],
        )

    def test_extracts_ns_localized_description_and_accessibility_copy(self):
        source = r'''
        // [NSLocalizedDescriptionKey: "Comment"]
        let raw = #"[NSLocalizedDescriptionKey: "Raw"]"#
        let multiline = """
            [NSLocalizedDescriptionKey: "Multiline"]
        """
        let error = NSError(userInfo: [NSLocalizedDescriptionKey: "Sign-in failed"])
        var overspentBadgeValue: String {
            count == 1 ? "1 overspent category" : "\(count) overspent categories"
        }
        '''
        self.assertEqual(
            VALIDATOR.extract_source_keys(source),
            {"Sign-in failed", "1 overspent category", r"\(count) overspent categories"},
        )

    def test_string_localized_variants_and_trailing_arguments(self):
        source = '''
        String(localized: "One", table: "Localizable")
        String(localized: enabled ? "On" : "Off", comment: "state")
        String(localized: dynamicKey, bundle: .main)
        '''
        self.assertEqual(VALIDATOR.extract_source_keys(source), {"One", "On", "Off"})

    def test_report_strings_extracts_literal_keys_and_ignores_dynamic_arguments(self):
        source = '''
        ReportStrings.text("Direct report key", locale: locale)
        ReportStrings.text(enabled ? "Report enabled" : "Report disabled", bundle: bundle)
        ReportStrings.format("Progress: %lld%%", progress, locale: locale)
        ReportStrings.format(
            enabled ? "One %@" : "Many %@",
            arguments: [value],
            locale: locale
        )
        ReportStrings.text(rawValue, locale: locale)
        ReportStrings.format(data.key, arguments: data.arguments, locale: locale)
        '''
        self.assertEqual(
            VALIDATOR.extract_source_keys(source),
            {
                "Direct report key",
                "Report enabled",
                "Report disabled",
                "Progress: %lld%%",
                "One %@",
                "Many %@",
            },
        )

    def test_report_strings_missing_literal_keys_are_validated(self):
        source = '''
        ReportStrings.text("Present report key")
        ReportStrings.format(flag ? "Missing report branch" : "Missing report format %@", value)
        ReportStrings.text(rawValue)
        '''
        catalog = {"Present report key": {}}
        self.assertEqual(
            VALIDATOR.validate_source_keys(
                VALIDATOR.extract_source_keys(source), catalog
            ),
            [
                "catalog: missing catalog key: Missing report branch",
                "catalog: missing catalog key: Missing report format %@",
            ],
        )

    def test_extracts_localized_string_resource_literals_and_static_branches(self):
        source = '''
        let direct = LocalizedStringResource("Direct")
        let key = enabled ? "Enabled" : "Disabled"
        let resource = LocalizedStringResource(String.LocalizationValue(key), locale: locale)
        LocalizedStringResource(dynamicKey, locale: locale)
        LocalizedStringResource(String.LocalizationValue(runtimeValue), locale: locale)
        '''
        self.assertEqual(
            VALIDATOR.extract_source_keys(source),
            {"Direct", "Enabled", "Disabled"},
        )

    def test_extracts_typed_localization_values_used_by_string_localized(self):
        source = '''
        private enum RuleValueEditorLocalization {
            static let value: String.LocalizationValue = "Value"
            static let values: String.LocalizationValue = "Values"
        }
        let first = String(localized: RuleValueEditorLocalization.value)
        let second = String(localized: RuleValueEditorLocalization.values, locale: locale)
        '''
        self.assertEqual(VALIDATOR.extract_source_keys(source), {"Value", "Values"})

    def test_typed_localization_values_ignore_comments_raw_and_multiline_noise(self):
        source = r'''
        // static let fake: String.LocalizationValue = "Comment"
        let raw = #"static let fake: String.LocalizationValue = "Raw""#
        let multiline = """
            static let fake: String.LocalizationValue = "Multiline"
        """
        static let real: String.LocalizationValue = "Real"
        String(localized: Namespace.real)
        '''
        self.assertEqual(VALIDATOR.extract_source_keys(source), {"Real"})

    def test_extracts_live_rule_and_schedule_ternary_forms(self):
        source = '''
        String(localized: type == .date ? "rule.op.isAfter" : "rule.op.isGreaterThan")
        String(localized: type == .date ? "rule.op.isAfterOrEquals" : "rule.op.isGreaterThanOrEquals")
        String(localized: type == .date ? "rule.op.isBefore" : "rule.op.isLessThan")
        String(localized: type == .date ? "rule.op.isBeforeOrEquals" : "rule.op.isLessThanOrEquals")
        Text(String(localized: "\\(completedCount) completed schedules hidden."))
        '''
        self.assertEqual(
            VALIDATOR.extract_source_keys(source),
            {
                "rule.op.isAfter",
                "rule.op.isGreaterThan",
                "rule.op.isAfterOrEquals",
                "rule.op.isGreaterThanOrEquals",
                "rule.op.isBefore",
                "rule.op.isLessThan",
                "rule.op.isBeforeOrEquals",
                "rule.op.isLessThanOrEquals",
                r"\(completedCount) completed schedules hidden.",
            },
        )

    def test_validates_both_branches_of_computed_localized_ternaries(self):
        source = '''
        String(localized: condition ? "date-op" : "generic-op")
        '''
        extracted = VALIDATOR.extract_source_keys(source)
        catalog = {
            "date-op": {
                "localizations": {
                    locale: {"stringUnit": {"value": "date-op"}}
                    for locale in VALIDATOR.REQUIRED_LOCALES
                }
            }
        }

        self.assertEqual(extracted, {"date-op", "generic-op"})
        self.assertEqual(
            VALIDATOR.validate_source_keys(extracted, catalog),
            ["catalog: missing catalog key: generic-op"],
        )

    def test_localized_string_resource_ignores_noise_and_multiline_dynamic_values(self):
        source = r'''
        // LocalizedStringResource("comment")
        let raw = #"LocalizedStringResource("not a key")"#
        let multiline = """
            LocalizedStringResource("not a key")
        """
        let stableIdentifier = "stable.identifier"
        let stableKey = "stable.key"
        let runtimeValue = value
        let key = flag
            ? "First"
            : other
                ? "Second"
                : "Third"
        let resource = LocalizedStringResource(
            String.LocalizationValue(key),
            locale: locale
        )
        LocalizedStringResource(stableIdentifier)
        LocalizedStringResource(String.LocalizationValue(stableKey))
        LocalizedStringResource(runtimeValue)
        '''
        self.assertEqual(
            VALIDATOR.extract_source_keys(source),
            {"First", "Second", "Third"},
        )

    def test_static_resource_branches_report_only_missing_catalog_keys(self):
        source = '''
        let key = flag ? "Present" : "Missing"
        LocalizedStringResource(String.LocalizationValue(key))
        '''
        extracted = VALIDATOR.extract_source_keys(source)
        catalog = {"Present": {}}
        self.assertIn("Present", extracted)
        self.assertEqual(extracted - set(catalog), {"Missing"})

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

    def test_widget_navigation_link_and_trailing_label_literals(self):
        source = '''
        NavigationLink("Literal") { Text("Trailing label") }
        NavigationLink(destination: destination) {
            Text("Trailing label content")
        }
        '''
        self.assertEqual(
            VALIDATOR.extract_source_keys(source, widget=True),
            {"Literal", "Trailing label", "Trailing label content"},
        )

    def test_widget_nested_localized_branches_are_extracted(self):
        source = '''
        Text(flag ? String(localized: "Widget yes") : String(localized: "Widget no"))
        Text(value ?? String(localized: "Widget fallback"))
        '''
        self.assertEqual(
            VALIDATOR.extract_source_keys(source, widget=True),
            {"Widget yes", "Widget no", "Widget fallback"},
        )

    def test_widget_validation_reports_missing_raw_and_nested_localized_keys(self):
        source = '''
        Text("Missing widget text")
        Text(flag ? String(localized: "Missing widget branch") : String(localized: "Present widget branch"))
        '''
        catalog = {
            "Present widget branch": {
                "localizations": {
                    locale: {"stringUnit": {"value": "Present widget branch"}}
                    for locale in VALIDATOR.REQUIRED_LOCALES
                }
            }
        }
        errors = VALIDATOR.validate_source_keys(
            VALIDATOR.extract_source_keys(source, widget=True),
            catalog,
            "widget",
        )
        self.assertIn("widget: missing catalog key: Missing widget text", errors)
        self.assertIn("widget: missing catalog key: Missing widget branch", errors)

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

    def test_placeholders_consume_escaped_percent_pairs(self):
        self.assertEqual(VALIDATOR.placeholders("%%%lld items"), ["%lld"])
        self.assertTrue(VALIDATOR._is_plural_count_key("%%%lld items"))
        self.assertEqual(VALIDATOR.placeholders("%%%%@"), [])
        self.assertFalse(VALIDATOR._is_plural_count_key("%%%%@"))
        self.assertEqual(VALIDATOR.placeholders("%1$lld %2$@"), ["%lld", "%@"])
        self.assertEqual(VALIDATOR.placeholders("%lld%%"), ["%lld"])
        self.assertEqual(VALIDATOR.placeholders("%%lld"), [])

    def test_printf_scanner_accepts_foundation_forms_and_consumes_percent_pairs(self):
        cases = {
            "%@": ["%@"],
            "%lld": ["%lld"],
            "%1$@ %2$lld": ["%@", "%lld"],
            "%lld%%": ["%lld"],
            "%%%lld": ["%lld"],
            "%%lld": [],
            "%lldd": ["%lld"],
            "%ld %f %d %s %p": ["%ld", "%f", "%d", "%s", "%p"],
        }
        for value, expected in cases.items():
            with self.subTest(value=value):
                self.assertEqual(VALIDATOR.placeholders(value), expected)

    def test_printf_scanner_reports_malformed_format_intent_but_not_prose(self):
        for value in ("%q", "%1$q", "%1$", "%ll", "%*"):
            with self.subTest(value=value):
                self.assertTrue(VALIDATOR._scan_printf(value)[1])
        for value in ("100%", "100%.", "0% and 100%", "% ", "%,", "% of income"):
            with self.subTest(value=value):
                self.assertEqual(VALIDATOR._scan_printf(value)[1], [])

    def test_catalog_rejects_matching_malformed_format_in_every_value(self):
        value = "Broken %q"
        catalog = {
            value: {
                "localizations": {
                    locale: {"stringUnit": {"value": value}}
                    for locale in VALIDATOR.REQUIRED_LOCALES
                }
            }
        }
        errors = VALIDATOR.validate_catalog_entries(catalog)
        self.assertTrue(any("source" in error and "%q" in error for error in errors))
        self.assertTrue(any("English value" in error and "%q" in error for error in errors))
        self.assertTrue(any("locale fr value" in error and "%q" in error for error in errors))

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
            {"Enabled", "Disabled", "Flag", "Other", "Ignored", "Type name", "Display fallback", "Intent prose", "Category"},
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

    def test_extracts_copy_properties_and_display_helpers(self):
        source = '''
        var title: String { flag ? "Ready" : "Waiting" }
        var placeholder: String { value ?? "Enter a value" }
        func shortTitle(
            for month: String
        ) -> String { return month.isEmpty ? "This month" : month }
        func dynamicSummary() -> String { return model.summary }
        let title = model.title
        func unrelated() -> String { return "Not UI copy" }
        '''
        self.assertEqual(
            VALIDATOR.extract_source_keys(source),
            {"Ready", "Waiting", "Enter a value", "This month"},
        )

    def test_extracts_visible_error_assignments_but_not_dynamic_errors(self):
        source = '''
        budgetStore.error = "Could not save"
        errorMessage = failed ? "Try again" : "Dismiss"
        errorMessage = error.localizedDescription
        struct BudgetStore { var error: String?; func fail() { self.error = "Sync failed" } }
        struct Other { func fail() { self.error = "Do not extract" } }
        '''
        self.assertEqual(
            VALIDATOR.extract_source_keys(source),
            {"Could not save", "Try again", "Dismiss", "Sync failed"},
        )

    def test_extracts_chart_labels_and_static_series_values(self):
        source = '''
        x: .value("Month", point.month)
        y: .value("Balance", point.balance)
        series: .value("Segment", "Forecast")
        .foregroundStyle(by: .value("Group", point.group))
        .position(by: .value("Kind", "Income"))
        .value("p90", band.p90)
        .value("Date", user.date)
        .value("Axis", "Static axis value")
        '''
        self.assertEqual(
            VALIDATOR.extract_source_keys(source),
            {"Month", "Balance", "Segment", "Forecast", "Group", "Kind", "Income", "Date", "Axis"},
        )

    def test_extracts_app_short_title_metadata(self):
        source = '''
        AppShortcut(intent: AddIntent(), phrases: ["Add"], shortTitle: "Add transaction", systemImageName: "plus")
        AppShortcut(intent: OtherIntent(), shortTitle: dynamicTitle)
        '''
        self.assertEqual(VALIDATOR.extract_source_keys(source), {"Add transaction"})

    def test_extracts_only_app_shortcut_phrase_array_literals(self):
        source = r'''
        // AppShortcut(intent: Fake(), phrases: ["Comment phrase"])
        let raw = #"AppShortcut(intent: Fake(), phrases: ["Raw phrase"])"#
        AppShortcut(
            intent: AddIntent(),
            phrases: [
                "First \(.applicationName)",
                "Second \(.applicationName)",
            ],
            shortTitle: "Not a phrase",
            systemImageName: "plus"
        )
        AppShortcut(intent: OtherIntent(), shortTitle: "Also not a phrase")
        '''
        self.assertEqual(
            VALIDATOR.extract_app_shortcut_phrases(source),
            {r"First \(.applicationName)", r"Second \(.applicationName)"},
        )

    def test_app_shortcut_interpolation_tokens_are_order_independent(self):
        source = r"\(.applicationName) \(\.$account) \(.applicationName)"
        translated = r"\(.applicationName) \(.applicationName) \(\.$account)"
        altered = r"\(.applicationName) \(\.$category) \(.applicationName)"
        self.assertEqual(
            VALIDATOR.app_shortcut_interpolation_tokens(source),
            VALIDATOR.app_shortcut_interpolation_tokens(translated),
        )
        self.assertNotEqual(
            VALIDATOR.app_shortcut_interpolation_tokens(source),
            VALIDATOR.app_shortcut_interpolation_tokens(altered),
        )

    def test_app_shortcut_interpolation_tokens_detect_missing_and_duplicate_tokens(self):
        source = r"Check \(\.$account) in \(.applicationName)"
        self.assertNotEqual(
            VALIDATOR.app_shortcut_interpolation_tokens(source),
            VALIDATOR.app_shortcut_interpolation_tokens(r"Check in \(.applicationName)"),
        )
        self.assertNotEqual(
            VALIDATOR.app_shortcut_interpolation_tokens(source),
            VALIDATOR.app_shortcut_interpolation_tokens(
                r"Check \(\.$account) in \(.applicationName) \(.applicationName)"
            ),
        )

    def test_app_shortcut_catalog_reports_missing_key_and_locale(self):
        source = {"Phrase \(.applicationName)", "Missing \(.applicationName)"}
        catalog = {
            "Phrase \\(.applicationName)": {
                "localizations": {
                    locale: {"stringUnit": {"value": "Phrase \\(.applicationName)"}}
                    for locale in VALIDATOR.REQUIRED_LOCALES - {"nl"}
                }
            }
        }
        errors = VALIDATOR.validate_app_shortcut_catalog(source, catalog)
        self.assertTrue(any("missing catalog key: Missing" in error for error in errors))
        self.assertTrue(any("missing locales nl" in error for error in errors))

    def test_main_catalog_reports_missing_locale_per_entry(self):
        catalog = {
            "Main key": {
                "localizations": {
                    locale: {"stringUnit": {"value": "Main key"}}
                    for locale in VALIDATOR.REQUIRED_LOCALES - {"fr"}
                }
            }
        }
        errors = VALIDATOR.validate_catalog_entries(catalog)
        self.assertIn("catalog Main key: missing locales fr", errors)

    def test_count_bearing_interpolation_requires_plural_variations(self):
        source = r'''
        Text("Found \(locked) items")
        Text("Total: \(totalItems) items")
        Text("Active in \(scopes) scopes")
        Text("String interpolation \(name)")
        Text("HTTP error %lld")
        Text("Status code %lld")
        Text("Ordinal %lldth")
        Text("Day of month %lld")
        Text("Compact %lldd")
        Text("Progress %lld%%")
        Text("%lld pending")
        Text("%lld overspent")
        Text("%lld uncategorized")
        Text("%lld without a budget")
        Text("%lld not funded")
        Text("%lld nearing the limit")
        '''
        flat = {
            "Found %lld items": {"localizations": {locale: {"stringUnit": {"value": "Found %lld items"}} for locale in VALIDATOR.REQUIRED_LOCALES}},
            "Active in %lld scopes": {"localizations": {locale: {"stringUnit": {"value": "Active in %lld scopes"}} for locale in VALIDATOR.REQUIRED_LOCALES}},
            "String interpolation %@": {"localizations": {locale: {"stringUnit": {"value": "String interpolation %@"}} for locale in VALIDATOR.REQUIRED_LOCALES}},
        }
        errors = VALIDATOR.validate_plural_count_variations(
            VALIDATOR.extract_source_keys(source), flat
        )
        self.assertTrue(any("requires plural variation in fr" in error for error in errors))
        self.assertTrue(any("Active in %lld scopes" in error for error in errors))
        self.assertFalse(any("String interpolation %@" in error for error in errors))

        plural = {
            key: {"localizations": {locale: {"variations": {"plural": {"one": {}, "other": {}}}} for locale in VALIDATOR.REQUIRED_LOCALES}}
            for key in ("Found %lld items", "Active in %lld scopes")
        }
        self.assertEqual(
            VALIDATOR.validate_plural_count_variations(
                VALIDATOR.extract_source_keys(source), plural | {"String interpolation %@": flat["String interpolation %@"]}
            ),
            [],
        )

    def test_plural_count_classification_uses_integer_placeholders_and_exceptions(self):
        true_keys = ["%lld items", "%lld times", "Every %lld days", "%lld months", "%lld years"]
        false_keys = [
            "HTTP %lld", "Status code %lld", "%lldth item", "Day-of-month %lld", "%lldd", "%lld%%",
            "%lld pending", "%lld overspent", "%lld uncategorized", "%lld without a budget",
            "%lld not funded", "%lld nearing the limit", "%lld over budget", "String %@",
            "%%lld",
        ]
        for key in true_keys:
            self.assertTrue(VALIDATOR._is_plural_count_key(key), key)
        for key in false_keys:
            self.assertFalse(VALIDATOR._is_plural_count_key(key), key)
        self.assertTrue(VALIDATOR._is_plural_count_key("%1$lld items"))

    def test_main_catalog_reports_placeholder_mismatch_in_variation_locale(self):
        catalog = {
            "%lld items": {
                "localizations": {
                    "en": {"variations": {"plural": {
                        "one": {"stringUnit": {"value": "%lld item"}},
                        "other": {"stringUnit": {"value": "%lld items"}},
                    }}},
                    **{
                        locale: {"variations": {"plural": {
                            "one": {"stringUnit": {"value": "%lld article"}},
                            "other": {"stringUnit": {"value": "%@ articles"}},
                        }}}
                        for locale in VALIDATOR.REQUIRED_LOCALES - {"en"}
                    },
                }
            }
        }
        errors = VALIDATOR.validate_catalog_entries(catalog)
        self.assertIn("catalog %lld items: placeholder mismatch in fr", errors)

    def test_catalog_validation_keeps_target_routing_explicit(self):
        catalog = {"Widget key": {"localizations": {locale: {"stringUnit": {"value": "Widget key"}} for locale in VALIDATOR.REQUIRED_LOCALES}}}
        self.assertEqual(
            VALIDATOR.validate_catalog_entries(catalog, "widget"),
            [],
        )

    def test_extracts_app_intent_metadata_and_parse_errors(self):
        source = r'''
        // IntentDescription("comment") @Parameter(title: "comment")
        /* DisplayRepresentation(title: "comment") */
        static let description = IntentDescription(
            "Describe the intent",
            categoryName: "Intent category"
        )
        @Parameter(
            title: enabled ? "Enabled title" : "Disabled title",
            description: #"Parameter description"#
        )
        static let typeDisplayRepresentation: TypeDisplayRepresentation = "Entity name"
        DisplayRepresentation(title: "Display name")
        ParseError(message: "Visible parser error")
        ParseError(message: dynamicMessage)
        ParseError(message: """
            Multiline parser error
        """)
        let stableIdentifier = "not user-facing copy"
        AppShortcut(intent: AddIntent(), shortTitle: "Shortcut title", systemImageName: "plus")
        AppShortcut(intent: AddIntent(), shortTitle: dynamicTitle, systemImageName: "plus")
        '''
        self.assertEqual(
            VALIDATOR.extract_source_keys(source),
            {
                "Describe the intent",
                "Intent category",
                "Enabled title",
                "Disabled title",
                "Parameter description",
                "Entity name",
                "Display name",
                "Visible parser error",
                "Multiline parser error",
                "Shortcut title",
            },
        )

    def test_extracts_multiline_parameter_summaries_and_ignores_noise(self):
        source = r'''
        // Summary("Comment \(\.$fake)")
        let raw = #"Summary("Raw \(\.$fake)")"#
        let runtime = "Runtime \(value)"
        static var parameterSummary: some ParameterSummary {
            Summary("""
                Add \(\.$amount) at \(\.$payee) in \(\.$account)
            """)
        }
        Summary("Check \(\.$account) and \(\.$account)")
        '''
        self.assertEqual(
            VALIDATOR.extract_parameter_summaries(source),
            {
                r"Add \(\.$amount) at \(\.$payee) in \(\.$account)": ("account", "amount", "payee"),
                r"Check \(\.$account) and \(\.$account)": ("account", "account"),
            },
        )

    def test_parameter_summary_catalog_reports_missing_key_locale_and_tokens(self):
        summaries = {r"Log \(\.$amount) at \(\.$payee)": ("amount", "payee")}
        catalog = {
            r"Log \(\.$amount) at \(\.$payee)": {
                "localizations": {
                    locale: {"stringUnit": {"value": r"Log \(\.$amount)"}}
                    for locale in VALIDATOR.REQUIRED_LOCALES - {"nl"}
                }
            }
        }
        errors = VALIDATOR.validate_parameter_summaries(summaries, catalog)
        self.assertTrue(any("missing locales nl" in error for error in errors))
        self.assertTrue(any("parameter token mismatch in en" in error for error in errors))
        errors = VALIDATOR.validate_parameter_summaries(
            {r"Missing \(\.$text)": ("text",)}, catalog
        )
        self.assertEqual(errors, [r"app Summary: missing catalog key: Missing \(\.$text)"])

    def test_parameter_summary_tokens_allow_reordering(self):
        source = {r"Add \(\.$amount) and \(\.$payee)": ("amount", "payee")}
        catalog = {
            r"Add \(\.$amount) and \(\.$payee)": {
                "localizations": {
                    locale: {"stringUnit": {"value": r"Ajouter \(\.$payee) et \(\.$amount)"}}
                    for locale in VALIDATOR.REQUIRED_LOCALES
                }
            }
        }
        self.assertEqual(VALIDATOR.validate_parameter_summaries(source, catalog), [])

    def test_app_metadata_is_scanned_for_both_targets_without_identifier_noise(self):
        source = '''
        static let typeDisplayRepresentation: TypeDisplayRepresentation = "App entity"
        static let persistenceKey = "stable.identifier"
        Text("Visible text")
        IntentDescription("App description")
        '''
        expected = {"App entity", "Visible text", "App description"}
        self.assertEqual(VALIDATOR.extract_source_keys(source), expected)
        self.assertEqual(VALIDATOR.extract_source_keys(source, widget=True), expected)


if __name__ == "__main__":
    unittest.main()
