#!/usr/bin/env python3
"""Validate the localization catalog against production Swift sources."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CATALOG_PATH = ROOT / "Actuali/Actuali/Localizable.xcstrings"
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
    "Parameter", "TypeDisplayRepresentation", "DisplayRepresentation",
}
PLACEHOLDER_PATTERN = re.compile(r"%(?!%)(?:\d+\$)?[+\-0-9.*lh]*[a-zA-Z@]")
# Swift string interpolation inside a localized key, e.g. "Found \(count) items"
INTERPOLATION_PATTERN = re.compile(r"\\\(")
SYMBOLIC_KEY_PATTERN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z0-9_.]+$")


def swift_string_value(value: str) -> str:
    """Normalize the Swift escapes used in source keys to catalog values."""
    value = re.sub(
        r"\\u\{([0-9A-Fa-f]+)\}",
        lambda match: chr(int(match.group(1), 16)),
        value,
    )
    return value.replace(r"\n", "\n").replace(r'\"', '"').replace(r"\\", "\\")


def placeholders(value: str) -> list[str]:
    found = PLACEHOLDER_PATTERN.findall(value)
    # Positional specifiers (%1$@) carry the argument order explicitly, so a
    # translation may reorder them in the sentence; canonicalize back to
    # argument order so it compares equal to the source's specifier list.
    if found and all("$" in item for item in found):
        found = [
            "%" + item.split("$", 1)[1]
            for item in sorted(found, key=lambda item: int(item[1 : item.index("$")]))
        ]
    return found


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
        return [value] if _without_interpolation(value).isalpha() or any(
            character.isalpha() for character in _without_interpolation(value)
        ) else []
    return []


def extract_source_keys(source: str, *, widget: bool = False) -> set[str]:
    tokens = _tokens(source)
    found: set[str] = set()
    for index, (kind, name) in enumerate(tokens[:-1]):
        if kind != "identifier" or tokens[index + 1][1] != "(":
            continue
        expression = _first_argument(tokens, index + 1)
        if expression is None:
            continue
        if name == "String" and expression[:2] == [("identifier", "localized"), ("symbol", ":")]:
            found.update(_literal_leaves(expression[2:]))
        elif name in SWIFTUI_SINKS or (widget and name in METADATA_CALLS):
            if widget and name in {"Parameter", "DisplayRepresentation", "TypeDisplayRepresentation"}:
                arguments = _arguments(tokens, index + 1) or []
                candidates = []
                for argument in arguments:
                    labeled = _labeled_argument(argument, "title") or _labeled_argument(argument, "name")
                    if labeled is not None:
                        candidates.extend(_literal_leaves(labeled))
                found.update(candidates)
            elif widget and name == "IntentDescription":
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
        if kind == "identifier" and name == "LocalizedStringResource":
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


def main() -> int:
    try:
        catalog_data = json.loads(CATALOG_PATH.read_text(encoding="utf-8"))
        catalog = catalog_data["strings"]
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
    widget_used: set[str] = set()
    for source_root in SOURCE_ROOTS:
        for source in source_root.rglob("*.swift"):
            extracted = extract_source_keys(
                source.read_text(encoding="utf-8"),
                widget=source_root.name == "ActualiWidgets",
            )
            (widget_used if source_root.name == "ActualiWidgets" else used).update(extracted)

    errors: list[str] = []
    for target, target_catalog_data, target_catalog, target_used in [
        ("widget", widget_catalog_data, widget_catalog, widget_used),
    ]:
        if target_catalog_data.get("sourceLanguage") != SOURCE_LANGUAGE:
            errors.append(f"{target} catalog sourceLanguage is not {SOURCE_LANGUAGE!r}")
        for key in sorted(target_used):
            if INTERPOLATION_PATTERN.search(key):
                if not interpolated_key_matches(key, target_catalog):
                    errors.append(f"{target}: missing catalog key for interpolated: {key}")
            elif key not in target_catalog:
                errors.append(f"{target}: missing catalog key: {key}")
        for key, entry in sorted(target_catalog.items()):
            localizations = entry.get("localizations", {})
            missing_locales = REQUIRED_LOCALES - set(localizations)
            if missing_locales:
                errors.append(f"{target} {key}: missing locales {', '.join(sorted(missing_locales))}")
            english_values = localized_values(localizations.get("en", {})) or {(): key}
            source_placeholders = tuple(placeholders(key))
            if not source_matches_english_placeholders(key, english_values):
                errors.append(f"{target} {key}: source/English placeholder mismatch")
            source_placeholders_by_path = {
                path: tuple(placeholders(value)) for path, value in english_values.items()
            }
            for locale in REQUIRED_LOCALES:
                locale_placeholders = {
                    path: tuple(placeholders(value))
                    for path, value in localized_values(localizations.get(locale, {})).items()
                }
                if locale_placeholders != source_placeholders_by_path:
                    errors.append(f"{target} {key}: placeholder mismatch in {locale}")

    if catalog_data.get("sourceLanguage") != SOURCE_LANGUAGE:
        errors.append(
            f"catalog sourceLanguage is {catalog_data.get('sourceLanguage')!r}, "
            f"expected {SOURCE_LANGUAGE!r}"
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

    for key in sorted(used):
        if INTERPOLATION_PATTERN.search(key):
            if not interpolated_key_matches(key, catalog):
                errors.append(f"missing catalog key for interpolated: {key}")
        elif key not in catalog:
            errors.append(f"missing catalog key: {key}")

    for key, entry in sorted(catalog.items()):
        localizations = entry.get("localizations", {})
        missing_locales = REQUIRED_LOCALES - set(localizations)
        if missing_locales:
            errors.append(f"{key}: missing locales {', '.join(sorted(missing_locales))}")

        english_values = localized_values(localizations.get("en", {})) or {(): key}
        source_placeholders = tuple(placeholders(key))
        if not source_matches_english_placeholders(key, english_values):
            errors.append(f"{key}: source/English placeholder mismatch")
        source_placeholders_by_path = {
            path: tuple(placeholders(value)) for path, value in english_values.items()
        }
        for locale in REQUIRED_LOCALES:
            values = localized_values(localizations.get(locale, {}))
            locale_placeholders = {
                path: tuple(placeholders(value)) for path, value in values.items()
            }
            if locale_placeholders != source_placeholders_by_path:
                errors.append(
                    f"{key}: placeholder mismatch in {locale} "
                    f"({locale_placeholders} != {source_placeholders})"
                )

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

    print(f"localization OK: {len(used) + len(widget_used)} source keys, {len(catalog) + len(widget_catalog)} catalog entries, {len(REQUIRED_LOCALES)} locales")
    return 0


if __name__ == "__main__":
    sys.exit(main())
