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

KEY_PATTERN = re.compile(r'String\(localized:\s*"((?:\\.|[^"\\])*)"')
WIDGET_KEY_PATTERN = re.compile(
    r'(?:Text|configurationDisplayName|description)\(\s*"((?:\\.|[^"\\])*)"'
)
PLACEHOLDER_PATTERN = re.compile(r"%(?!%)(?:\d+\$)?[+\-0-9.*lh]*[a-zA-Z@]")
# Swift string interpolation inside a localized key, e.g. "Found \(count) items"
INTERPOLATION_PATTERN = re.compile(r"\\\([^()]*(?:\([^()]*\)[^()]*)*\)")


def placeholders(value: str) -> list[str]:
    found = PLACEHOLDER_PATTERN.findall(value)
    # Positional specifiers (%1$@) carry the argument order explicitly, so a
    # translation may reorder them in the sentence; canonicalize back to
    # argument order so it compares equal to the source's specifier list.
    if any("$" in item for item in found):
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


def localized_values(value: object) -> list[str]:
    if isinstance(value, dict):
        if isinstance(value.get("stringUnit"), dict):
            string_value = value["stringUnit"].get("value")
            return [string_value] if isinstance(string_value, str) else []
        result: list[str] = []
        for child in value.values():
            result.extend(localized_values(child))
        return result
    return []


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
            source_text = source.read_text(encoding="utf-8")
            used.update(KEY_PATTERN.findall(source_text))
            if source_root.name == "ActualiWidgets":
                used.update(WIDGET_KEY_PATTERN.findall(source_text))

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

        source_values = localized_values(localizations.get("en", {})) or [key]
        source_placeholders = {tuple(placeholders(value)) for value in source_values}
        for locale in REQUIRED_LOCALES:
            values = localized_values(localizations.get(locale, {}))
            locale_placeholders = {tuple(placeholders(value)) for value in values}
            if locale_placeholders != source_placeholders:
                errors.append(
                    f"{key}: placeholder mismatch in {locale} "
                    f"({sorted(locale_placeholders)} != {sorted(source_placeholders)})"
                )

    if errors:
        print("localization validation failed:")
        print("\n".join(f"- {error}" for error in errors))
        return 1

    print(f"localization OK: {len(used)} source keys, {len(catalog)} catalog entries, {len(REQUIRED_LOCALES)} locales")
    return 0


if __name__ == "__main__":
    sys.exit(main())
