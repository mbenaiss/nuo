#!/usr/bin/env python3
"""Translation fragments for Localization/Localizable.xcstrings.

Code keys are the English text. Each translation batch writes its own fragment in Localization/fragments/,
so batches never edit the same file; `merge` folds every fragment into the catalog once they are done.

  scripts/strings.py check [--fragment F ...] [--scan DIR ...] [--derived-data DIR]
  scripts/strings.py merge

Fragment: a JSON object from the English key to its French text, or to an object for plurals, explicit keys
or comments:
  "Connected accounts": "Comptes connectés",
  "%lld accounts": {"en": {"one": "%lld account", "other": "%lld accounts"},
                    "fr": {"one": "%lld compte", "other": "%lld comptes"}},
  "demo.notes.weekly": {"en": "Long English text", "fr": "Long texte français", "comment": "Demo note"}
"""
import argparse
import json
import pathlib
import plistlib
import re
import sys

IOS = pathlib.Path(__file__).resolve().parent.parent
CATALOG = IOS / "Localization" / "Localizable.xcstrings"
FRAGMENTS = IOS / "Localization" / "fragments"
LANGUAGES = ("en", "fr")
PLURAL_FORMS = {"zero", "one", "two", "few", "many", "other"}
SPECIFIER = re.compile(r"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j|L)?[@dDiuUxXoOfFeEgGcCsSaAp]")
DASHES = ("\u2014", "\u2013")
FRENCH = re.compile(
    r"[éèêëàâçùûôîïœÉÈÊÀÇ«»]|\b(?:le|la|les|des|du|une|et|pour|avec|sur|pas|est|tes|ton|ta|ce|cette|au|aux|dans|par|aucun|aucune|ici|déjà|sans|tous|toutes)\b",
    re.IGNORECASE,
)
LITERAL = re.compile(r'"((?:[^"\\\n]|\\.)*)"')


def fail(message):
    print(message, file=sys.stderr)
    return 1


def specifiers(text):
    return sorted(re.sub(r"\d+\$", "", s) for s in SPECIFIER.findall(text.replace("%%", "")))


def forms(value):
    """Every text of a value: a string, or a plural dictionary."""
    if isinstance(value, str):
        return [value]
    return list(value.values())


def validate(path, data):
    errors = []
    if not isinstance(data, dict):
        return [f"{path}: the fragment must be a JSON object"]
    for key, value in data.items():
        where = f"{path}: {key!r}"
        if isinstance(value, str):
            entry = {"fr": value}
        elif isinstance(value, dict):
            entry = value
            unknown = set(entry) - {"en", "fr", "comment"}
            if unknown:
                errors.append(f"{where}: unknown fields {sorted(unknown)}")
                continue
            if "fr" not in entry:
                errors.append(f"{where}: no French text")
                continue
        else:
            errors.append(f"{where}: expected a string or an object")
            continue
        for language in LANGUAGES:
            value = entry.get(language)
            if value is None:
                continue
            if isinstance(value, dict):
                if not value or set(value) - PLURAL_FORMS or "other" not in value:
                    errors.append(f"{where}: plural forms must be among {sorted(PLURAL_FORMS)} and include other")
                    continue
                if not all(isinstance(v, str) for v in value.values()):
                    errors.append(f"{where}: plural forms must be strings")
                    continue
            elif not isinstance(value, str):
                errors.append(f"{where}: {language} must be a string or plural forms")
                continue
            if not "".join(forms(value)).strip():
                errors.append(f"{where}: empty {language} text")
        english = forms(entry["en"]) if "en" in entry else [key]
        for text in english:
            if any(d in text for d in DASHES):
                errors.append(f"{where}: no em or en dash in English text")
        expected = specifiers(english[-1])
        for text in forms(entry["fr"]) + english:
            # A plural form may drop the number ("one" as « un rappel »), never add or change one.
            found = specifiers(text)
            if found != expected and not (isinstance(entry["fr"], dict) and set(found) <= set(expected)):
                errors.append(f"{where}: format specifiers {found} do not match {expected}")
                break
    return errors


def load_fragments(paths):
    merged, origin, errors = {}, {}, []
    for path in paths:
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            errors.append(f"{path}: {error}")
            continue
        errors += validate(path, data)
        if not isinstance(data, dict):
            continue
        for key, value in data.items():
            if key in merged and merged[key] != value:
                errors.append(f"{path}: {key!r} is also in {origin[key]} with another translation")
            merged.setdefault(key, value)
            origin.setdefault(key, path.name)
    return merged, errors


def unit(value):
    if isinstance(value, str):
        return {"stringUnit": {"state": "translated", "value": value}}
    return {"variations": {"plural": {form: {"stringUnit": {"state": "translated", "value": text}}
                                      for form, text in value.items()}}}


def entry(key, value):
    if isinstance(value, str):
        value = {"fr": value}
    # Without an English entry the compiled bundle has no en.lproj, and iOS then shows French to English users.
    value = {"en": key, **value}
    result = {"localizations": {language: unit(value[language]) for language in LANGUAGES if language in value}}
    if value.get("comment"):
        result["comment"] = value["comment"]
    return result


def read_catalog():
    if CATALOG.exists():
        return json.loads(CATALOG.read_text(encoding="utf-8"))
    return {"sourceLanguage": "en", "strings": {}, "version": "1.0"}


def write_catalog(catalog):
    text = json.dumps(catalog, ensure_ascii=False, indent=2, separators=(",", " : "), sort_keys=True)
    CATALOG.write_text(text + "\n", encoding="utf-8")


def translated_keys(catalog):
    return {key for key, value in catalog["strings"].items() if "fr" in value.get("localizations", {})}


def compiled_keys(derived_data, directories):
    """Keys the compiler extracted (SWIFT_EMIT_LOC_STRINGS) from the Swift files under `directories`."""
    roots = [str((IOS / d).resolve()) + "/" for d in directories]
    keys = {}
    for path in pathlib.Path(derived_data).rglob("*.stringsdata"):
        try:
            data = json.loads(path.read_bytes())
        except ValueError:
            try:
                data = plistlib.loads(path.read_bytes())
            except Exception:
                continue
        source = data.get("source", "")
        if roots and not any(source.startswith(root) for root in roots):
            continue
        for table, items in data.get("tables", {}).items():
            if table != "Localizable":
                continue
            for item in items:
                # `Text("")` or `Text("\(count)")` have nothing to translate; use Text(verbatim:) for those.
                if re.search(r"[A-Za-z\u00C0-\u017F]", re.sub(r"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?[a-zA-Z@]+", "", item["key"])):
                    keys.setdefault(item["key"], source)
    return keys


def scan(directories):
    """Swift lines that still hold French-looking literals, comments left out."""
    hits = []
    for directory in directories:
        root = IOS / directory
        for path in [root] if root.is_file() else sorted(root.rglob("*.swift")):
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                code = line.strip()
                if code.startswith("//") or code.startswith("*"):
                    continue
                code = re.split(r"\s//\s", line)[0]
                if any(FRENCH.search(m.group(1)) for m in LITERAL.finditer(code)):
                    hits.append(f"{path.relative_to(IOS)}:{number}: {line.strip()[:160]}")
    return hits


def check(args):
    paths = [pathlib.Path(p) for p in args.fragment] or sorted(FRAGMENTS.glob("*.json"))
    fragments, errors = load_fragments(paths)
    catalog = read_catalog()
    status = 0
    for error in errors:
        status = fail(error)
    if args.derived_data:
        known = translated_keys(catalog) | set(fragments)
        missing = {k: s for k, s in compiled_keys(args.derived_data, args.scan).items() if k not in known}
        for key, source in sorted(missing.items(), key=lambda item: (item[1], item[0])):
            status = fail(f"no French text: {key!r} ({pathlib.Path(source).relative_to(IOS) if source.startswith(str(IOS)) else source})")
    if args.scan:
        hits = scan(args.scan)
        for hit in hits:
            print(f"French literal left: {hit}")
        print(f"{len(hits)} French-looking literals left in {', '.join(args.scan)}: each must be parser vocabulary, data sent to a bot, or a test fixture.")
    print(f"{len(fragments)} keys in {len(paths)} fragments, {'errors above' if status else 'no errors'}.")
    return status


def merge(_args):
    paths = sorted(FRAGMENTS.glob("*.json"))
    fragments, errors = load_fragments(paths)
    if errors:
        for error in errors:
            fail(error)
        return 1
    catalog = read_catalog()
    catalog["sourceLanguage"] = "en"
    for key, value in fragments.items():
        catalog["strings"][key] = entry(key, value)
    write_catalog(catalog)
    print(f"Merged {len(fragments)} keys from {len(paths)} fragments into {CATALOG.relative_to(IOS)}.")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    checking = commands.add_parser("check", help="validate fragments, list keys and literals left to translate")
    checking.add_argument("--fragment", action="append", default=[], help="fragment to check (default: all)")
    checking.add_argument("--scan", action="append", default=[], help="folder under ios/ to scan, repeatable")
    checking.add_argument("--derived-data", help="DerivedData of a build, to compare the compiled keys")
    checking.set_defaults(run=check)
    merging = commands.add_parser("merge", help="fold every fragment into Localizable.xcstrings")
    merging.set_defaults(run=merge)
    args = parser.parse_args()
    return args.run(args)


if __name__ == "__main__":
    sys.exit(main())
