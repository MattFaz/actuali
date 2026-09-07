#!/usr/bin/env python3
"""Validate the localization catalog against production Swift sources."""

from __future__ import annotations

import json
import re
import sys
import textwrap
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CATALOG_PATH = ROOT / "Actuali/Actuali/Localizable.xcstrings"
APP_SHORTCUTS_CATALOG_PATH = ROOT / "Actuali/Actuali/AppShortcuts.xcstrings"
WIDGET_CATALOG_PATH = ROOT / "Actuali/ActualiWidgets/Localizable.xcstrings"
PROJECT_PATH = ROOT / "Actuali/Actuali.xcodeproj/project.pbxproj"
SOURCE_ROOTS = [ROOT / "Actuali/Actuali", ROOT / "Actuali/ActualiWidgets"]
SOURCE_LANGUAGE = "en"
REQUIRED_LOCALES = {"en", "fr", "es", "pt-BR", "de", "it", "nl"}
SUSPICIOUS_IDENTICAL_KEYS = {
    "Configured Credit Cards",
    "Statement Closing Day",
    "Payment Due After",
    "Credit Limit",
}

SWIFTUI_SINKS = {
    "Text", "Label", "Section", "navigationTitle", "Button", "Toggle", "Picker",
    "DatePicker", "TextField", "ContentUnavailableView", "LabeledContent", "Link",
    "Menu", "confirmationDialog", "Stepper", "alert", "accessibilityLabel",
    "accessibilityHint", "accessibilityValue", "searchable", "NavigationLink",
}
METADATA_CALLS = {
    "configurationDisplayName", "description", "IntentDescription",
    "Parameter", "TypeDisplayRepresentation", "DisplayRepresentation", "AppShortcut",
}
UI_COPY_NAMES = {"label", "title", "message", "statusText", "placeholder", "summary"}
DISPLAY_HELPERS = {"shortTitle", "monthLabel", "formattedAmount", "limitText", "dayOrdinal"}
ACCESSIBILITY_COPY_NAME = re.compile(r".*(?:accessibility|badge).*value|.*value.*(?:accessibility|badge)", re.IGNORECASE)
CHART_TECHNICAL_VALUES = {"p10", "p25", "p75", "p90"}
NON_PLURAL_COUNT_KEY = re.compile(
    r"(?:\b(?:HTTP|status)(?:\s+error|\s+code)?\b.*%lld\b|%lld(?:st|nd|rd|th)\b|"
    r"\b(?:day[ -]of[ -]month|month[ -]day|day\s+%lld\s+of\s+the\s+month)\b|%lldd\b|%lld\s*(?:%%|percent(?:age)?))",
    re.IGNORECASE,
)
COMPACT_COUNT_BADGE = re.compile(
    r"^\s*%lld\s+(?:pending|overspent|uncategorized|without a budget|not funded|nearing the limit|over budget)\s*$",
    re.IGNORECASE,
)
KNOWN_UI_FALLBACK = re.compile(r"^(?:Unknown (?:institution|payee|account|pool)|Schedule|Income)$")
PRINTF_CONVERSIONS = set("diouxXfFeEgGaAcCsSpn%@")
PRINTF_LENGTH_MODIFIERS = ("hh", "ll", "h", "l", "j", "z", "t", "L")
PRINTF_INTENT_STARTERS = set("0123456789$*")
# Used only to build interpolation matching patterns; actual parsing is done
# by _scan_printf below.
PLACEHOLDER_PATTERN = re.compile(
    r"%(?!%)(?:\d+\$)?[+\- #0]*(?:\*|\d+)?(?:\.(?:\*|\d+))?(?:hh|ll|h|l|j|z|t|L)?[diouxXfFeEgGaAcCsSpn@]"
)
# Swift string interpolation inside a localized key, e.g. "Found \(count) items"
INTERPOLATION_PATTERN = re.compile(r"\\\(")
APP_SHORTCUT_INTERPOLATION_PATTERN = re.compile(r"\\\([^()]*\)")
SUMMARY_PARAMETER_PATTERN = re.compile(r"\\\(\\\.\$([A-Za-z_][A-Za-z0-9_]*)\)")
SYMBOLIC_KEY_PATTERN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z0-9_.]+$")


def swift_string_value(value: str) -> str:
    """Normalize the Swift escapes used in source keys to catalog values."""
    value = re.sub(
        r"\\u\{([0-9A-Fa-f]+)\}",
        lambda match: chr(int(match.group(1), 16)),
        value,
    )
    return value.replace(r"\n", "\n").replace(r'\"', '"').replace(r"\\", "\\")


def _scan_printf(value: str) -> tuple[list[tuple[str, int, int]], list[str]]:
    found: list[tuple[str, int, int]] = []
    malformed: list[str] = []
    index = 0
    while index < len(value):
        if value.startswith("%%", index):
            index += 2
            continue
        if value[index] != "%":
            index += 1
            continue
        if index + 1 < len(value) and value[index + 1].isspace():
            index += 1
            continue

        start = index
        cursor = index + 1
        position_end = cursor
        while cursor < len(value) and value[cursor].isdigit():
            cursor += 1
        if cursor < len(value) and value[cursor] == "$":
            cursor += 1
            position_end = cursor
        else:
            cursor = index + 1

        while cursor < len(value) and value[cursor] in "+- #0":
            cursor += 1
        if cursor < len(value) and value[cursor] == "*":
            cursor += 1
        else:
            while cursor < len(value) and value[cursor].isdigit():
                cursor += 1
        if cursor < len(value) and value[cursor] == ".":
            cursor += 1
            if cursor < len(value) and value[cursor] == "*":
                cursor += 1
            else:
                while cursor < len(value) and value[cursor].isdigit():
                    cursor += 1
        for modifier in PRINTF_LENGTH_MODIFIERS:
            if value.startswith(modifier, cursor):
                cursor += len(modifier)
                break

        if cursor < len(value) and value[cursor] in PRINTF_CONVERSIONS - {"%"}:
            cursor += 1
            found.append((value[start:cursor], start, cursor))
            index = cursor
            continue

        # A percent followed by format syntax is a malformed format intent;
        # whitespace and ordinary punctuation remain natural prose percents.
        next_character = value[index + 1] if index + 1 < len(value) else ""
        if next_character in PRINTF_INTENT_STARTERS or next_character.isalpha():
            malformed.append(value[start:max(cursor, position_end, start + 2)])
            index = max(cursor, position_end, start + 2)
        else:
            index += 1
    return found, malformed


def placeholders(value: str) -> list[str]:
    found, _ = _scan_printf(value)
    placeholders = [placeholder for placeholder, _, _ in found]
    # Positional specifiers (%1$@) carry the argument order explicitly, so a
    # translation may reorder them in the sentence; canonicalize back to
    # argument order so it compares equal to the source's specifier list.
    if placeholders and all("$" in item for item in placeholders):
        placeholders = [
            "%" + item.split("$", 1)[1]
            for item in sorted(placeholders, key=lambda item: int(item[1 : item.index("$")]))
        ]
    return placeholders


def _integer_placeholders(value: str) -> list[str]:
    return [placeholder for placeholder in placeholders(value) if placeholder.endswith("lld")]


def _canonicalize_integer_placeholders(value: str) -> str:
    result: list[str] = []
    index = 0
    while index < len(value):
        if value.startswith("%%", index):
            result.append("%%")
            index += 2
            continue
        scanned, _ = _scan_printf(value[index:])
        if scanned and scanned[0][1] == 0:
            placeholder, _, end = scanned[0]
            result.append("%lld" if placeholder.endswith("lld") else placeholder)
            index += end
        else:
            result.append(value[index])
            index += 1
    return "".join(result)


def source_matches_english_placeholders(key: str, english_values: dict[tuple[str, ...], str]) -> bool:
    source = tuple(placeholders(key))
    english = [tuple(placeholders(value)) for value in english_values.values()]
    if not english:
        english = [source]
    if not source and SYMBOLIC_KEY_PATTERN.fullmatch(key):
        return True
    return all(value == source for value in english)


def _interpolation_ranges(value: str) -> list[tuple[int, int]]:
    ranges: list[tuple[int, int]] = []
    index = 0
    while index < len(value) - 1:
        if value[index:index + 2] != r"\(":
            index += 1
            continue
        depth = 1
        end = index + 2
        while end < len(value) and depth:
            if value[end] == "\\" and end + 1 < len(value):
                end += 2
                continue
            if value[end] == "(":
                depth += 1
            elif value[end] == ")":
                depth -= 1
            end += 1
        if depth == 0:
            ranges.append((index, end))
            index = end
        else:
            break
    return ranges


def _has_interpolation(value: str) -> bool:
    return bool(_interpolation_ranges(value))


def _without_interpolation(value: str) -> str:
    ranges = _interpolation_ranges(value)
    if not ranges:
        return value
    result: list[str] = []
    cursor = 0
    for start, end in ranges:
        result.append(value[cursor:start])
        cursor = end
    result.append(value[cursor:])
    return "".join(result)


def interpolated_key_matches(key: str, catalog: dict) -> bool:
    """True if a source key using \\(...) interpolation resolves to some
    catalog key — the compiler turns each interpolation into a format
    specifier (%lld, %@, ...) we can't know statically, so match any."""
    ranges = _interpolation_ranges(key)
    if not ranges or len(ranges) != len(INTERPOLATION_PATTERN.findall(key)):
        return False
    parts = []
    cursor = 0
    for start, end in ranges:
        parts.append(key[cursor:start])
        cursor = end
    parts.append(key[cursor:])
    pattern = re.compile(PLACEHOLDER_PATTERN.pattern.join(re.escape(part) for part in parts))
    candidates: list[str] = []
    for catalog_key, entry in catalog.items():
        candidates.append(catalog_key)
        if isinstance(entry, dict):
            english = localized_values(entry.get("localizations", {}).get(SOURCE_LANGUAGE, {}))
            candidates.extend(english.values())
    return any(isinstance(candidate, str) and pattern.fullmatch(candidate) for candidate in candidates)


def localized_values(value: object, path: tuple[str, ...] = ()) -> dict[tuple[str, ...], str]:
    if isinstance(value, dict):
        if isinstance(value.get("stringUnit"), dict):
            string_value = value["stringUnit"].get("value")
            return {path: string_value} if isinstance(string_value, str) else {}
        result: dict[tuple[str, ...], str] = {}
        for key, child in value.items():
            result.update(localized_values(child, path + (key,)))
        return result
    return {}


def _tokens(source: str) -> list[tuple[str, str]]:
    """Tokenize enough Swift to distinguish code from comments and strings."""
    tokens: list[tuple[str, str]] = []
    index = 0
    block_depth = 0
    while index < len(source):
        if block_depth:
            if source.startswith("/*", index):
                block_depth += 1
                index += 2
            elif source.startswith("*/", index):
                block_depth -= 1
                index += 2
            else:
                index += 1
            continue
        if source.startswith("//", index):
            newline = source.find("\n", index)
            index = len(source) if newline < 0 else newline + 1
            continue
        if source.startswith("/*", index):
            block_depth = 1
            index += 2
            continue
        character = source[index]
        if character == "\n":
            tokens.append(("newline", "\n"))
            index += 1
            continue
        if character.isspace():
            index += 1
            continue
        hash_count = 0
        while index + hash_count < len(source) and source[index + hash_count] == "#":
            hash_count += 1
        quote_start = index + hash_count
        if quote_start < len(source) and source[quote_start] == '"':
            multiline = source.startswith('"""', quote_start)
            opening_length = hash_count + (3 if multiline else 1)
            delimiter = ('"""' if multiline else '"') + ("#" * hash_count)
            content_start = index + opening_length
            cursor = content_start
            content_end = len(source)
            end = len(source)
            while cursor < len(source):
                escaped_delimiter = "\\" + ("#" * hash_count) + ('"""' if multiline else '"')
                if source.startswith(escaped_delimiter, cursor):
                    cursor += len(escaped_delimiter)
                    continue
                if source.startswith(delimiter, cursor):
                    content_end = cursor
                    end = cursor + len(delimiter)
                    break
                if not hash_count and source[cursor] == "\\":
                    cursor += 2
                else:
                    cursor += 1
            kind = "raw_string" if hash_count else "string"
            tokens.append((kind, source[content_start:content_end]))
            index = end
            continue
        if source.startswith("??", index):
            tokens.append(("operator", "??"))
            index += 2
        elif character.isalpha() or character == "_":
            start = index
            index += 1
            while index < len(source) and (source[index].isalnum() or source[index] == "_"):
                index += 1
            tokens.append(("identifier", source[start:index]))
        else:
            tokens.append(("symbol", character))
            index += 1
    return tokens


def _matching_parenthesis(tokens: list[tuple[str, str]], opening: int) -> int | None:
    depth = 0
    for index in range(opening, len(tokens)):
        if tokens[index][1] == "(":
            depth += 1
        elif tokens[index][1] == ")":
            depth -= 1
            if depth == 0:
                return index
    return None


def _matching_delimiter(tokens: list[tuple[str, str]], opening: int, left: str, right: str) -> int | None:
    depth = 0
    for index in range(opening, len(tokens)):
        if tokens[index][1] == left:
            depth += 1
        elif tokens[index][1] == right:
            depth -= 1
            if depth == 0:
                return index
    return None


def _first_argument(tokens: list[tuple[str, str]], opening: int) -> list[tuple[str, str]] | None:
    closing = _matching_parenthesis(tokens, opening)
    if closing is None:
        return None
    depth = 0
    start = opening + 1
    for index in range(start, closing):
        value = tokens[index][1]
        if value in "([{":
            depth += 1
        elif value in ")]}":
            depth -= 1
        elif value == "," and depth == 0:
            return tokens[start:index]
    return tokens[start:closing]


def _arguments(tokens: list[tuple[str, str]], opening: int) -> list[list[tuple[str, str]]] | None:
    closing = _matching_parenthesis(tokens, opening)
    if closing is None:
        return None
    arguments: list[list[tuple[str, str]]] = []
    depth = 0
    start = opening + 1
    for index in range(start, closing):
        value = tokens[index][1]
        if value in "([{":
            depth += 1
        elif value in ")]}":
            depth -= 1
        elif value == "," and depth == 0:
            arguments.append(tokens[start:index])
            start = index + 1
    arguments.append(tokens[start:closing])
    return arguments


def _labeled_argument(argument: list[tuple[str, str]], label: str) -> list[tuple[str, str]] | None:
    argument = [token for token in argument if token[0] != "newline"]
    if len(argument) >= 2 and argument[0] == ("identifier", label) and argument[1][1] == ":":
        return argument[2:]
    return None


def _literal_leaves(expression: list[tuple[str, str]]) -> list[str]:
    """Return literals only for a static literal/ternary/coalescing expression."""
    expression = [token for token in expression if token[1] != "\n"]
    while expression and expression[0][1] == "(" and expression[-1][1] == ")":
        expression = expression[1:-1]
    if not expression:
        return []

    depth = 0
    question = None
    colon = None
    coalescing = None
    for index, (_, value) in enumerate(expression):
        if value in "([{":
            depth += 1
        elif value in ")]}":
            depth -= 1
        elif depth == 0 and value == "?":
            question = index
            break
        elif depth == 0 and value == "??":
            coalescing = index
            break
    if question is not None:
        depth = 0
        for index in range(question + 1, len(expression)):
            value = expression[index][1]
            if value in "([{":
                depth += 1
            elif value in ")]}":
                depth -= 1
            elif depth == 0 and value == ":":
                colon = index
                break
        if colon is None:
            return []
        return _literal_leaves(expression[question + 1:colon]) + _literal_leaves(expression[colon + 1:])
    if coalescing is not None:
        return _literal_leaves(expression[coalescing + 1:])
    if len(expression) == 1 and expression[0][0] in {"string", "raw_string"}:
        value = expression[0][1]
        if expression[0][0] == "string":
            value = swift_string_value(value)
        if "\n" in value:
            value = textwrap.dedent(value).strip("\n")
        return [value] if _without_interpolation(value).isalpha() or any(
            character.isalpha() for character in _without_interpolation(value)
        ) else []
    return []


def _line_end(tokens: list[tuple[str, str]], start: int, stop: int | None = None) -> int:
    limit = len(tokens) if stop is None else stop
    return next((index for index in range(start, limit) if tokens[index][1] in {"\n", "}"}), limit)


def _body_literal_leaves(tokens: list[tuple[str, str]], opening: int) -> set[str]:
    closing = _matching_delimiter(tokens, opening, "{", "}")
    if closing is None:
        return set()
    found: set[str] = set(_literal_leaves(tokens[opening + 1:closing]))
    for index in range(opening + 1, closing):
        if tokens[index][1] not in {"return", "=", ":"}:
            continue
        end = _line_end(tokens, index + 1, closing)
        found.update(_literal_leaves(tokens[index + 1:end]))
    return found


def _extract_declared_copy(tokens: list[tuple[str, str]]) -> set[str]:
    found: set[str] = set()
    names = UI_COPY_NAMES | DISPLAY_HELPERS
    for index, (kind, name) in enumerate(tokens):
        if kind != "identifier" or name not in names:
            continue
        preceding = {tokens[position][1] for position in range(max(0, index - 3), index)}
        if not preceding.intersection({"var", "let", "func"}):
            continue
        is_function = "func" in preceding
        opening = None
        depth = 0
        for position in range(index + 1, len(tokens)):
            value = tokens[position][1]
            if value in "([":
                depth += 1
            elif value in ")]":
                depth -= 1
            elif value == "{" and depth == 0:
                opening = position
                break
            elif value == "\n" and depth == 0 and not is_function:
                break
        if opening is not None:
            found.update(_body_literal_leaves(tokens, opening))
        equals = next(
            (position for position in range(index + 1, _line_end(tokens, index + 1)) if tokens[position][1] == "="),
            None,
        )
        if equals is not None:
            found.update(_literal_leaves(tokens[equals + 1:_line_end(tokens, equals + 1)]))
    return found


def _extract_accessibility_copy(tokens: list[tuple[str, str]]) -> set[str]:
    found: set[str] = set()
    for index, token in enumerate(tokens):
        if token[0] != "identifier" or not ACCESSIBILITY_COPY_NAME.fullmatch(token[1]):
            continue
        declaration_start = max(
            (position for position in range(max(0, index - 4), index) if tokens[position][1] == "\n"),
            default=-1,
        )
        if not any(tokens[position][1] in {"let", "var"} for position in range(declaration_start + 1, index)):
            continue
        end = _line_end(tokens, index + 1)
        equals = next((position for position in range(index + 1, end) if tokens[position][1] == "="), None)
        if equals is not None:
            found.update(_literal_leaves(tokens[equals + 1:end]))
            continue
        opening = next((position for position in range(index + 1, len(tokens)) if tokens[position][1] == "{"), None)
        if opening is not None:
            closing = _matching_delimiter(tokens, opening, "{", "}")
            if closing is not None:
                for kind, value in tokens[opening + 1:closing]:
                    if kind == "string":
                        value = swift_string_value(value)
                        if value:
                            found.add(value)
                    elif kind == "raw_string":
                        if value:
                            found.add(value)
    return found


def _extract_labeled_literals(tokens: list[tuple[str, str]], label: str) -> set[str]:
    found: set[str] = set()
    for index in range(len(tokens) - 2):
        if tokens[index][0] != "identifier" or tokens[index][1] != label or tokens[index + 1][1] != ":":
            continue
        end = index + 2
        while end < len(tokens) and tokens[end][1] not in {",", "]", "}"}:
            end += 1
        found.update(_literal_leaves(tokens[index + 2:end]))
    return found


def _extract_known_ui_fallbacks(tokens: list[tuple[str, str]]) -> set[str]:
    found: set[str] = set()
    for index, token in enumerate(tokens):
        if token[1] not in {"??", "?"}:
            continue
        end = _line_end(tokens, index + 1)
        for position in range(index + 1, end):
            if tokens[position][0] in {"string", "raw_string"}:
                value = tokens[position][1]
                if tokens[position][0] == "string":
                    value = swift_string_value(value)
                if KNOWN_UI_FALLBACK.fullmatch(value):
                    found.add(value)
    return found


def _extract_error_assignments(tokens: list[tuple[str, str]]) -> set[str]:
    found: set[str] = set()
    budget_store_ranges: list[tuple[int, int]] = []
    for index in range(len(tokens) - 1):
        if tokens[index][1] != "BudgetStore" or tokens[index - 1][1] not in {"class", "struct"}:
            continue
        opening = next((position for position in range(index + 1, len(tokens)) if tokens[position][1] == "{"), None)
        if opening is not None:
            closing = _matching_delimiter(tokens, opening, "{", "}")
            if closing is not None:
                budget_store_ranges.append((opening, closing))
    for index in range(len(tokens) - 2):
        if tokens[index][0] != "identifier":
            continue
        is_error = tokens[index][1] == "errorMessage"
        is_budget_error = (
            index + 3 < len(tokens)
            and tokens[index][1] == "budgetStore"
            and tokens[index + 1][1] == "."
            and tokens[index + 2][1] == "error"
        )
        is_self_error = (
            index + 3 < len(tokens)
            and tokens[index][1] == "self"
            and tokens[index + 1][1] == "."
            and tokens[index + 2][1] == "error"
            and any(start < index < end for start, end in budget_store_ranges)
        )
        is_goal_template_error = (
            index + 3 < len(tokens)
            and tokens[index][1] == "errorTemplate"
            and tokens[index + 1][1] == "."
            and tokens[index + 2][1] == "error"
        )
        if not (is_error or is_budget_error or is_self_error or is_goal_template_error):
            continue
        name_end = index + (3 if (is_budget_error or is_self_error or is_goal_template_error) else 1)
        if tokens[name_end][1] != "=":
            continue
        end = _line_end(tokens, name_end + 1)
        found.update(_literal_leaves(tokens[name_end + 1:end]))
    return found


def _is_plural_count_key(key: str) -> bool:
    interpolation_ranges = _interpolation_ranges(key)
    normalized = key
    for start, end in reversed(interpolation_ranges):
        normalized = normalized[:start] + "%lld" + normalized[end:]
    integer_placeholders = _integer_placeholders(normalized)
    normalized = _canonicalize_integer_placeholders(normalized)
    if not integer_placeholders:
        return False
    if NON_PLURAL_COUNT_KEY.search(normalized) or COMPACT_COUNT_BADGE.fullmatch(normalized):
        return False
    return True


def validate_plural_count_variations(used: set[str], catalog: dict, target: str = "catalog") -> list[str]:
    errors: list[str] = []
    checked: set[str] = set()
    for source_key in sorted(used):
        matching = [
            (catalog_key, entry)
            for catalog_key, entry in catalog.items()
            if source_key == catalog_key or interpolated_key_matches(source_key, {catalog_key: entry})
        ]
        for catalog_key, entry in matching:
            if catalog_key in checked or not _is_plural_count_key(catalog_key):
                continue
            checked.add(catalog_key)
            for locale in REQUIRED_LOCALES:
                localization = entry.get("localizations", {}).get(locale, {})
                if not isinstance(localization.get("variations", {}).get("plural"), dict):
                    errors.append(f"{target} {catalog_key}: count-bearing interpolation requires plural variation in {locale}")
    return errors


def _extract_chart_values(tokens: list[tuple[str, str]]) -> set[str]:
    found: set[str] = set()
    for index in range(len(tokens) - 3):
        if tokens[index:index + 3] != [("symbol", "."), ("identifier", "value"), ("symbol", "(")]:
            continue
        arguments = _arguments(tokens, index + 2)
        if not arguments:
            continue
        label = _literal_leaves(arguments[0])
        found.update(value for value in label if value.lower() not in CHART_TECHNICAL_VALUES)
        context = {tokens[position][1] for position in range(max(0, index - 6), index)}
        if len(arguments) > 1 and context.intersection({"series", "foregroundStyle", "position"}):
            found.update(_literal_leaves(arguments[1]))
    return found


def _extract_shortcut_metadata(tokens: list[tuple[str, str]]) -> set[str]:
    found: set[str] = set()
    for index, (kind, name) in enumerate(tokens[:-1]):
        if kind != "identifier" or name != "AppShortcut" or tokens[index + 1][1] != "(":
            continue
        for argument in _arguments(tokens, index + 1) or []:
            labeled = _labeled_argument(argument, "shortTitle")
            if labeled is not None:
                found.update(_literal_leaves(labeled))
    return found


def extract_app_shortcut_phrases(source: str) -> set[str]:
    """Extract only string literals in AppShortcut `phrases` arrays."""
    tokens = _tokens(source)
    found: set[str] = set()
    for index, (kind, name) in enumerate(tokens[:-1]):
        if kind != "identifier" or name != "AppShortcut" or tokens[index + 1][1] != "(":
            continue
        for argument in _arguments(tokens, index + 1) or []:
            phrases = _labeled_argument(argument, "phrases")
            if not phrases or phrases[0][1] != "[":
                continue
            closing = _matching_delimiter(phrases, 0, "[", "]")
            if closing is None:
                continue
            for phrase_kind, phrase in phrases[1:closing]:
                if phrase_kind == "string":
                    found.add(swift_string_value(phrase))
                elif phrase_kind == "raw_string":
                    found.add(phrase)
    return found


def app_shortcut_interpolation_tokens(value: str) -> tuple[str, ...]:
    return tuple(sorted(Counter(APP_SHORTCUT_INTERPOLATION_PATTERN.findall(value)).elements()))


def parameter_summary_tokens(value: str) -> tuple[str, ...]:
    """Return the multiset of AppIntents parameter references in a Summary literal."""
    return tuple(sorted(Counter(SUMMARY_PARAMETER_PATTERN.findall(value)).elements()))


def extract_parameter_summaries(source: str) -> dict[str, tuple[str, ...]]:
    """Extract literal Summary strings without scanning ordinary Swift strings."""
    tokens = _tokens(source)
    found: dict[str, tuple[str, ...]] = {}
    for index, (kind, name) in enumerate(tokens[:-1]):
        if kind != "identifier" or name != "Summary" or tokens[index + 1][1] != "(":
            continue
        expression = _first_argument(tokens, index + 1)
        if expression is None or len(expression) != 1 or expression[0][0] not in {"string", "raw_string"}:
            continue
        value = expression[0][1]
        if expression[0][0] == "string":
            value = swift_string_value(value)
        if "\n" in value:
            value = textwrap.dedent(value).strip("\n")
        if parameter_summary_tokens(value):
            found[value] = parameter_summary_tokens(value)
    return found


def validate_parameter_summaries(summaries: dict[str, tuple[str, ...]], catalog: dict) -> list[str]:
    errors: list[str] = []
    for key, source_tokens in sorted(summaries.items()):
        entry = catalog.get(key)
        if entry is None:
            errors.append(f"app Summary: missing catalog key: {key}")
            continue
        localizations = entry.get("localizations", {})
        missing_locales = REQUIRED_LOCALES - set(localizations)
        if missing_locales:
            errors.append(f"app Summary {key}: missing locales {', '.join(sorted(missing_locales))}")
        for locale in sorted(REQUIRED_LOCALES):
            values = localized_values(localizations.get(locale, {}))
            if not values or any(parameter_summary_tokens(value) != source_tokens for value in values.values()):
                errors.append(f"app Summary {key}: parameter token mismatch in {locale}")
    return errors


def validate_app_shortcut_catalog(source_phrases: set[str], catalog: dict) -> list[str]:
    errors: list[str] = []
    for phrase in sorted(source_phrases):
        if phrase not in catalog:
            errors.append(f"app shortcuts: missing catalog key: {phrase}")
    for phrase, entry in sorted(catalog.items()):
        localizations = entry.get("localizations", {})
        missing_locales = REQUIRED_LOCALES - set(localizations)
        if missing_locales:
            errors.append(f"app shortcuts {phrase}: missing locales {', '.join(sorted(missing_locales))}")
        source_tokens = app_shortcut_interpolation_tokens(phrase)
        for locale in REQUIRED_LOCALES:
            values = localized_values(localizations.get(locale, {}))
            locale_tokens = tuple(
                app_shortcut_interpolation_tokens(value)
                for value in values.values()
            )
            if not values or any(tokens != source_tokens for tokens in locale_tokens):
                errors.append(f"app shortcuts {phrase}: interpolation token mismatch in {locale}")
    return errors


def validate_catalog_entries(catalog: dict, target: str = "catalog") -> list[str]:
    """Validate locale and format-shape parity for every catalog entry."""
    errors: list[str] = []
    for key, entry in sorted(catalog.items()):
        localizations = entry.get("localizations", {})
        missing_locales = REQUIRED_LOCALES - set(localizations)
        if missing_locales:
            errors.append(f"{target} {key}: missing locales {', '.join(sorted(missing_locales))}")

        english_values = localized_values(localizations.get(SOURCE_LANGUAGE, {})) or {(): key}
        malformed_values: set[tuple[str, str]] = set()

        def collect_malformed(value: str, label: str) -> None:
            for malformed in _scan_printf(value)[1]:
                malformed_values.add((label, malformed))

        collect_malformed(key, "source")
        for path, value in english_values.items():
            collect_malformed(value, f"English {path or 'value'}")
        source_placeholders_by_path = {
            path: tuple(placeholders(value)) for path, value in english_values.items()
        }
        if not source_matches_english_placeholders(key, english_values):
            errors.append(f"{target} {key}: source/English placeholder mismatch")
        for locale in REQUIRED_LOCALES:
            locale_values = localized_values(localizations.get(locale, {}))
            for path, value in locale_values.items():
                collect_malformed(value, f"locale {locale} {path or 'value'}")
            locale_placeholders = {
                path: tuple(placeholders(value))
                for path, value in locale_values.items()
            }
            if locale_placeholders != source_placeholders_by_path:
                errors.append(f"{target} {key}: placeholder mismatch in {locale}")
        for label, malformed in sorted(malformed_values):
            errors.append(f"{target} {key}: malformed format {malformed!r} in {label}")
    return errors


def _extract_parse_error_messages(tokens: list[tuple[str, str]]) -> set[str]:
    found: set[str] = set()
    for index, (kind, name) in enumerate(tokens[:-1]):
        if kind != "identifier" or name != "ParseError" or tokens[index + 1][1] != "(":
            continue
        for argument in _arguments(tokens, index + 1) or []:
            labeled = _labeled_argument(argument, "message")
            if labeled is not None:
                found.update(_literal_leaves(labeled))
                for nested_index, (nested_kind, nested_name) in enumerate(labeled[:-1]):
                    if (
                        nested_kind == "identifier"
                        and nested_name == "localizedError"
                        and labeled[nested_index + 1][1] == "("
                    ):
                        nested_arguments = _arguments(labeled, nested_index + 1)
                        if nested_arguments:
                            found.update(_literal_leaves(nested_arguments[0]))
    return found


def _extract_report_strings(tokens: list[tuple[str, str]]) -> set[str]:
    found: set[str] = set()
    for index, (kind, name) in enumerate(tokens[:-3]):
        if (
            kind != "identifier"
            or name != "ReportStrings"
            or tokens[index + 1][1] != "."
            or tokens[index + 2][1] not in {"text", "format"}
            or tokens[index + 3][1] != "("
        ):
            continue
        expression = _first_argument(tokens, index + 3)
        if expression is not None:
            found.update(_literal_leaves(expression))
    return found


def _static_assignment_literals(
    tokens: list[tuple[str, str]], before: int, name: str
) -> set[str]:
    for index in range(before - 1, -1, -1):
        if tokens[index] != ("identifier", name) or index + 1 >= len(tokens):
            continue
        if tokens[index + 1][1] != "=":
            continue
        if index > 0 and tokens[index - 1][1] not in {"let", "var"}:
            continue
        end = len(tokens)
        for position in range(index + 2, len(tokens)):
            if tokens[position][1] == "\n":
                next_value = next(
                    (tokens[next_position][1] for next_position in range(position + 1, len(tokens)) if tokens[next_position][1] != "\n"),
                    None,
                )
                if next_value not in {"?", ":", "??"}:
                    end = position
                    break
            elif tokens[position][1] == "}" and position > index + 2:
                end = position
                break
        assignment = tokens[index + 2:end]
        if not any(token[1] in {"?", "??"} for token in assignment):
            return set()
        return set(_literal_leaves(assignment))
    return set()


def _extract_localization_value_assignments(tokens: list[tuple[str, str]]) -> dict[str, set[str]]:
    """Resolve literals assigned to typed String.LocalizationValue constants."""
    assignments: dict[str, set[str]] = {}
    for index, token in enumerate(tokens):
        if token != ("identifier", "let") and token != ("identifier", "var"):
            continue
        if index + 1 >= len(tokens) or tokens[index + 1][0] != "identifier":
            continue
        name = tokens[index + 1][1]
        colon = next(
            (position for position in range(index + 2, _line_end(tokens, index + 2)) if tokens[position][1] == ":"),
            None,
        )
        equals = next(
            (position for position in range((colon or index + 2) + 1, _line_end(tokens, index + 2)) if tokens[position][1] == "="),
            None,
        )
        if colon is None or equals is None:
            continue
        type_tokens = [token[1] for token in tokens[colon + 1:equals] if token[1] != "\n"]
        if type_tokens != ["String", ".", "LocalizationValue"]:
            continue
        assignments[name] = set(_literal_leaves(tokens[equals + 1:_line_end(tokens, equals + 1)]))
    return assignments


def _extract_localized_string_resources(tokens: list[tuple[str, str]]) -> set[str]:
    found: set[str] = set()
    for index, (kind, name) in enumerate(tokens[:-1]):
        if kind != "identifier" or name != "LocalizedStringResource":
            continue
        opening = index + 1
        if tokens[opening][1] != "(":
            continue
        expression = _first_argument(tokens, opening)
        if expression is None:
            continue
        literals = _literal_leaves(expression)
        if literals:
            found.update(literals)
            continue
        expression = [token for token in expression if token[1] != "\n"]
        wrapped = False
        if (
            len(expression) >= 5
            and expression[:4]
            == [
                ("identifier", "String"),
                ("symbol", "."),
                ("identifier", "LocalizationValue"),
                ("symbol", "("),
            ]
            and expression[-1][1] == ")"
        ):
            expression = expression[4:-1]
            wrapped = True
        if wrapped and len(expression) == 1 and expression[0][0] == "identifier":
            found.update(_static_assignment_literals(tokens, index, expression[0][1]))
    return found


def extract_source_keys(source: str, *, widget: bool = False) -> set[str]:
    tokens = _tokens(source)
    found: set[str] = set()
    localization_value_assignments = _extract_localization_value_assignments(tokens)
    found.update(_extract_declared_copy(tokens))
    found.update(_extract_accessibility_copy(tokens))
    found.update(_extract_labeled_literals(tokens, "NSLocalizedDescriptionKey"))
    found.update(_extract_known_ui_fallbacks(tokens))
    found.update(_extract_error_assignments(tokens))
    found.update(_extract_chart_values(tokens))
    found.update(_extract_shortcut_metadata(tokens))
    found.update(_extract_parse_error_messages(tokens))
    found.update(_extract_report_strings(tokens))
    found.update(_extract_localized_string_resources(tokens))
    for index, (kind, name) in enumerate(tokens[:-1]):
        if kind != "identifier" or tokens[index + 1][1] != "(":
            continue
        expression = _first_argument(tokens, index + 1)
        if expression is None:
            continue
        if name == "String" and expression[:2] == [("identifier", "localized"), ("symbol", ":")]:
            localized_expression = expression[2:]
            found.update(_literal_leaves(localized_expression))
            assignment_name = None
            if len(localized_expression) == 1 and localized_expression[0][0] == "identifier":
                assignment_name = localized_expression[0][1]
            elif (
                len(localized_expression) == 3
                and localized_expression[0][0] == "identifier"
                and localized_expression[1][1] == "."
                and localized_expression[2][0] == "identifier"
            ):
                assignment_name = localized_expression[2][1]
            if assignment_name is not None:
                found.update(localization_value_assignments.get(assignment_name, set()))
        elif name in SWIFTUI_SINKS or name in METADATA_CALLS:
            if name in {"Parameter", "DisplayRepresentation", "TypeDisplayRepresentation"}:
                arguments = _arguments(tokens, index + 1) or []
                candidates = []
                for argument in arguments:
                    labeled = (
                        _labeled_argument(argument, "title")
                        or _labeled_argument(argument, "name")
                        or _labeled_argument(argument, "description")
                    )
                    if labeled is not None:
                        candidates.extend(_literal_leaves(labeled))
                found.update(candidates)
            elif name == "IntentDescription":
                arguments = _arguments(tokens, index + 1) or []
                if arguments:
                    found.update(_literal_leaves(arguments[0]))
                    for argument in arguments[1:]:
                        labeled = _labeled_argument(argument, "categoryName")
                        if labeled is not None:
                            found.update(_literal_leaves(labeled))
            else:
                found.update(_literal_leaves(expression))

    for index, (kind, name) in enumerate(tokens[:-3]):
        if kind == "identifier" and name in {"LocalizedStringResource", "TypeDisplayRepresentation"}:
            line_end = next(
                (position for position in range(index + 1, len(tokens)) if tokens[position][1] == "\n"),
                len(tokens),
            )
            assignment = next(
                (position for position in range(index + 1, line_end) if tokens[position][1] == "="),
                None,
            )
            if assignment is not None:
                found.update(_literal_leaves(tokens[assignment + 1:line_end]))
    return found


def validate_source_keys(source_keys: set[str], catalog: dict, target: str = "catalog") -> list[str]:
    errors: list[str] = []
    for key in sorted(source_keys):
        if INTERPOLATION_PATTERN.search(key):
            if not interpolated_key_matches(key, catalog):
                errors.append(f"{target}: missing catalog key for interpolated: {key}")
        elif key not in catalog:
            errors.append(f"{target}: missing catalog key: {key}")
    return errors


def main() -> int:
    try:
        catalog_data = json.loads(CATALOG_PATH.read_text(encoding="utf-8"))
        catalog = catalog_data["strings"]
        app_shortcuts_catalog_data = json.loads(APP_SHORTCUTS_CATALOG_PATH.read_text(encoding="utf-8"))
        app_shortcuts_catalog = app_shortcuts_catalog_data["strings"]
        widget_catalog_data = json.loads(WIDGET_CATALOG_PATH.read_text(encoding="utf-8"))
        widget_catalog = widget_catalog_data["strings"]
    except (OSError, json.JSONDecodeError, KeyError) as error:
        print(f"catalog: {error}", file=sys.stderr)
        return 1

    try:
        project = PROJECT_PATH.read_text(encoding="utf-8")
    except OSError as error:
        print(f"project: {error}", file=sys.stderr)
        return 1

    used: set[str] = set()
    app_shortcuts_used: set[str] = set()
    parameter_summaries: dict[str, tuple[str, ...]] = {}
    widget_used: set[str] = set()
    for source_root in SOURCE_ROOTS:
        for source in source_root.rglob("*.swift"):
            source_text = source.read_text(encoding="utf-8")
            extracted = extract_source_keys(
                source_text,
                widget=source_root.name == "ActualiWidgets",
            )
            (widget_used if source_root.name == "ActualiWidgets" else used).update(extracted)
            if source_root.name == "Actuali":
                app_shortcuts_used.update(extract_app_shortcut_phrases(source_text))
                parameter_summaries.update(extract_parameter_summaries(source_text))

    errors: list[str] = []
    errors.extend(validate_parameter_summaries(parameter_summaries, catalog))
    for target, target_catalog_data, target_catalog, target_used in [
        ("app shortcuts", app_shortcuts_catalog_data, app_shortcuts_catalog, app_shortcuts_used),
        ("widget", widget_catalog_data, widget_catalog, widget_used),
    ]:
        if target_catalog_data.get("sourceLanguage") != SOURCE_LANGUAGE:
            errors.append(f"{target} catalog sourceLanguage is not {SOURCE_LANGUAGE!r}")
        if target == "app shortcuts":
            errors.extend(validate_app_shortcut_catalog(target_used, target_catalog))
        if target != "app shortcuts":
            errors.extend(validate_source_keys(target_used, target_catalog, target))
        for key, entry in sorted(target_catalog.items()):
            localizations = entry.get("localizations", {})
            missing_locales = REQUIRED_LOCALES - set(localizations)
            if missing_locales:
                errors.append(f"{target} {key}: missing locales {', '.join(sorted(missing_locales))}")
            english_values = localized_values(localizations.get("en", {})) or {(): key}
            if target != "app shortcuts":
                errors.extend(validate_catalog_entries({key: entry}, target))

    if catalog_data.get("sourceLanguage") != SOURCE_LANGUAGE:
        errors.append(
            f"catalog sourceLanguage is {catalog_data.get('sourceLanguage')!r}, "
            f"expected {SOURCE_LANGUAGE!r}"
        )

    if app_shortcuts_catalog_data.get("sourceLanguage") != SOURCE_LANGUAGE:
        errors.append(
            f"app shortcuts catalog sourceLanguage is {app_shortcuts_catalog_data.get('sourceLanguage')!r}, "
            f"expected {SOURCE_LANGUAGE!r}"
        )

    phrases_in_main_catalog = app_shortcuts_used.intersection(catalog)
    if phrases_in_main_catalog:
        errors.append(
            "app shortcut phrases must not be in the main catalog: "
            + ", ".join(sorted(phrases_in_main_catalog))
        )

    catalog_locales = {
        locale
        for entry in catalog.values()
        for locale in entry.get("localizations", {})
    }
    missing_catalog_locales = REQUIRED_LOCALES - catalog_locales
    extra_catalog_locales = catalog_locales - REQUIRED_LOCALES
    if missing_catalog_locales:
        errors.append(
            "catalog is missing locales " + ", ".join(sorted(missing_catalog_locales))
        )
    if extra_catalog_locales:
        errors.append(
            "catalog has unsupported locales " + ", ".join(sorted(extra_catalog_locales))
        )

    development_region = re.search(r"\bdevelopmentRegion = ([^;]+);", project)
    if development_region is None:
        errors.append("project is missing developmentRegion")
    elif development_region.group(1).strip().strip('"') != SOURCE_LANGUAGE:
        errors.append(
            f"project developmentRegion is {development_region.group(1).strip()!r}, "
            f"expected {SOURCE_LANGUAGE!r}"
        )

    known_regions = re.search(r"\bknownRegions = \((.*?)\);", project, re.DOTALL)
    if known_regions is None:
        errors.append("project is missing knownRegions")
    else:
        project_locales = {
            line.split("/*", 1)[0].strip().rstrip(",").strip('"')
            for line in known_regions.group(1).splitlines()
            if line.split("/*", 1)[0].strip()
        } - {"Base"}
        missing_project_locales = REQUIRED_LOCALES - project_locales
        extra_project_locales = project_locales - REQUIRED_LOCALES
        if missing_project_locales:
            errors.append(
                "project knownRegions is missing "
                + ", ".join(sorted(missing_project_locales))
            )
        if extra_project_locales:
            errors.append(
                "project knownRegions has unsupported locales "
                + ", ".join(sorted(extra_project_locales))
            )

    errors.extend(validate_source_keys(used, catalog))

    errors.extend(validate_catalog_entries(catalog))
    errors.extend(validate_plural_count_variations(used, catalog))

    for key, entry in sorted(catalog.items()):
        localizations = entry.get("localizations", {})

        english = localizations.get("en", {}).get("stringUnit", {}).get("value")
        if key in SUSPICIOUS_IDENTICAL_KEYS and isinstance(english, str):
            identical_locales = [
                locale for locale in REQUIRED_LOCALES - {SOURCE_LANGUAGE}
                if localizations.get(locale, {}).get("stringUnit", {}).get("value") == english
            ]
            if identical_locales:
                errors.append(
                    f"{key}: untranslated source-equal values in "
                    + ", ".join(sorted(identical_locales))
                )

    if errors:
        print("localization validation failed:")
        print("\n".join(f"- {error}" for error in errors))
        return 1

    print(
        f"localization OK: {len(used) + len(widget_used)} source keys, "
        f"{len(app_shortcuts_used)} app shortcut phrases, "
        f"{len(catalog) + len(app_shortcuts_catalog) + len(widget_catalog)} catalog entries, "
        f"{len(REQUIRED_LOCALES)} locales"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
