#!/usr/bin/env python3
"""Check Sideboard's translations.

    python3 tools/check_localizations.py

- Every language has exactly the keys in en.lproj (English is the reference).
- Placeholders (%@, %lld, ...) match the English key in each translation.
- Every localizable string literal in Sources/ has a key in en.lproj.

Exits with status 1 if anything is wrong.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LOCALIZATION = ROOT / "Resources" / "Localization"
SOURCES = ROOT / "Sources"

ENTRY = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";\s*$')
PLACEHOLDER = re.compile(r"%(?:\d+\$)?(?:@|l{0,2}[duxXf])")

# Literals SwiftUI localizes: Text("…"), Button("…"), Label("…", …), LocalizedStringKey("…"),
# InfoRow("…", …), the remote's key(.x, "symbol", "…") and both sides of `cond ? "…" : "…"`.
LITERAL = r'"((?:[^"\\]|\\.)*)"'
SWIFT_PATTERNS = [
    re.compile(r"\bText\(" + LITERAL),
    re.compile(r"\bButton\(" + LITERAL),
    re.compile(r"\bLabel\(" + LITERAL),
    re.compile(r"\bLocalizedStringKey\(" + LITERAL),
    re.compile(r"\b(?:title|detail|note): " + LITERAL),
    re.compile(r"\(" + LITERAL + r", \.\w+\)"),  # ("Good", .green)
    re.compile(r"\brow\(" + LITERAL),
    re.compile(r"\bsection\(" + LITERAL),
    re.compile(r"\breading\(" + LITERAL),
    re.compile(r"(?<![.\w])row\(" + LITERAL),
    re.compile(r"\bPicker\(" + LITERAL),
    re.compile(r"\bToggle\(" + LITERAL),
    re.compile(r"\bbadge: .*?" + LITERAL),
    re.compile(r"String\(localized: " + LITERAL),
    re.compile(r"\bInfoRow\(" + LITERAL),
    re.compile(r"\bkey\(\.\w+, \"[^\"]*\", " + LITERAL),
    re.compile(r"\? " + LITERAL + r" :"),
    re.compile(r" : " + LITERAL + r"[,)]"),
]
# `case .developer: "Developer tools"`, `case .normal: "Normal"`.
CATEGORY_PATTERN = re.compile(r"case \.\w+: " + LITERAL)
# Strings that are deliberately not translated.
NOT_LOCALIZED = {"Sideboard", "2.4 GHz", "5 GHz", "6 GHz", "/"}
# Not UI: adb's own messages, the --status report and the made-up screenshot data.
SKIPPED_FILES = {"Adb.swift", "SideboardApp.swift", "Snapshots.swift"}


def read_strings(path):
    entries = {}
    # Blank out /* … */ comments but keep their line breaks, so line numbers stay right.
    text = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group(0).count("\n"), path.read_text(encoding="utf-8"), flags=re.S)
    for number, line in enumerate(text.splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("//"):
            continue
        match = ENTRY.match(line)
        if not match:
            sys.exit(f"{path}:{number}: can't parse: {line}")
        entries[match.group(1)] = match.group(2)
    return entries


def swift_keys():
    keys = set()
    for path in SOURCES.rglob("*.swift"):
        if path.name in SKIPPED_FILES:
            continue
        text = path.read_text(encoding="utf-8")
        # `case .x: "…"` returns localized text everywhere except the language names.
        patterns = SWIFT_PATTERNS + ([] if path.name == "AppLanguage.swift" else [CATEGORY_PATTERN])
        for pattern in patterns:
            for literal in pattern.findall(text):
                # String interpolation becomes a placeholder (allows one level of nested parentheses).
                keys.add((re.sub(r"\\\((?:[^()]|\([^()]*\))*\)", "%", literal), path.name))
    return keys


def main():
    problems = []
    english = read_strings(LOCALIZATION / "en.lproj" / "Localizable.strings")
    languages = sorted(p.name.removesuffix(".lproj") for p in LOCALIZATION.glob("*.lproj"))

    for language in languages:
        if language == "en":
            continue
        entries = read_strings(LOCALIZATION / f"{language}.lproj" / "Localizable.strings")
        for key in english.keys() - entries.keys():
            problems.append(f"{language}: missing {key!r}")
        for key in entries.keys() - english.keys():
            problems.append(f"{language}: not in English {key!r}")
        for key, value in entries.items():
            if key in english and sorted(PLACEHOLDER.findall(key)) != sorted(PLACEHOLDER.findall(value)):
                problems.append(f"{language}: placeholders differ in {key!r} -> {value!r}")

    english_shapes = {PLACEHOLDER.sub("%", key) for key in english}
    for literal, file in sorted(swift_keys()):
        # SF Symbol names such as "checkmark.square.fill" aren't text.
        if re.fullmatch(r"[a-z0-9.]+", literal):
            continue
        if literal and literal not in NOT_LOCALIZED and literal not in english_shapes:
            problems.append(f"{file}: no translation key for {literal!r}")

    for problem in problems:
        print(problem)
    print(f"{len(languages)} languages, {len(english)} keys, {len(problems)} problems")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
