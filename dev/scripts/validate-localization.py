#!/usr/bin/env python3
"""Validate the localization catalog against production Swift sources."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CATALOG_PATH = ROOT / "Actuali/Actuali/Localizable.xcstrings"
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

KEY_PATTERN = re.compile(r'String\(localized:\s*"((?:\\.|[^"\\])*)"')
WIDGET_KEY_PATTERN = re.compile(
    r'(?:String\(localized:|configurationDisplayName|description)\(\s*"((?:\\.|[^"\\])*)"'
)
SWIFTUI_LITERAL_PATTERN = re.compile(
    r'(?:(?:Text|Label|Section|navigationTitle|Button|Toggle|Picker|DatePicker|TextField|ContentUnavailableView|LabeledContent|Link|Menu|confirmationDialog|Stepper|alert|accessibilityLabel|accessibilityHint|accessibilityValue|searchable)\s*\(\s*"((?:\\.|[^"\\])*)"'
    r')'
)
PLACEHOLDER_PATTERN = re.compile(r"%(?!%)(?:\d+\$)?[+\-0-9.*lh]*[a-zA-Z@]")
# Swift string interpolation inside a localized key, e.g. "Found \(count) items"
INTERPOLATION_PATTERN = re.compile(r"\\\([^()]*(?:\([^()]*\)[^()]*)*\)")


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


def interpolated_key_matches(key: str, catalog: dict) -> bool:
    """True if a source key using \\(...) interpolation resolves to some
    catalog key — the compiler turns each interpolation into a format
    specifier (%lld, %@, ...) we can't know statically, so match any."""
    parts = INTERPOLATION_PATTERN.split(key)
    pattern = re.compile(PLACEHOLDER_PATTERN.pattern.join(re.escape(part) for part in parts))
    return any(pattern.fullmatch(candidate) for candidate in catalog)


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


def main() -> int:
    try:
        catalog_data = json.loads(CATALOG_PATH.read_text(encoding="utf-8"))
        catalog = catalog_data["strings"]
    except (OSError, json.JSONDecodeError, KeyError) as error:
        print(f"catalog: {error}", file=sys.stderr)
        return 1

    try:
        project = PROJECT_PATH.read_text(encoding="utf-8")
    except OSError as error:
        print(f"project: {error}", file=sys.stderr)
        return 1

    used: set[str] = set()
    for source_root in SOURCE_ROOTS:
        for source in source_root.rglob("*.swift"):
            source_text = "\n".join(
                line for line in source.read_text(encoding="utf-8").splitlines()
                if not line.lstrip().startswith(("//", "/*", "*", "*/"))
            )
            used.update(swift_string_value(key) for key in KEY_PATTERN.findall(source_text))
            if source_root.name == "ActualiWidgets":
                used.update(
                    swift_string_value(key)
                    for key in WIDGET_KEY_PATTERN.findall(source_text)
                )
            else:
                for match in SWIFTUI_LITERAL_PATTERN.finditer(source_text):
                    key = match.group(1)
                    static_text = INTERPOLATION_PATTERN.sub("", key)
                    interpolation_only = key.lstrip().startswith(r"\(")
                    if key not in {"", "%"} and not interpolation_only and (r"\(" not in key or static_text.strip()):
                        used.add(swift_string_value(key))

    errors: list[str] = []
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

        source_values = localized_values(localizations.get("en", {})) or {(): key}
        source_placeholders = {
            path: tuple(placeholders(value)) for path, value in source_values.items()
        }
        for locale in REQUIRED_LOCALES:
            values = localized_values(localizations.get(locale, {}))
            locale_placeholders = {
                path: tuple(placeholders(value)) for path, value in values.items()
            }
            if locale_placeholders != source_placeholders:
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

    print(f"localization OK: {len(used)} source keys, {len(catalog)} catalog entries, {len(REQUIRED_LOCALES)} locales")
    return 0


if __name__ == "__main__":
    sys.exit(main())
