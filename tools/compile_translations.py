"""Compile NanumPlayer's UTF-8 translation catalogs into allocation-free lookups."""
import argparse
import json
import re
from pathlib import Path

LANGUAGES = ("ko", "en", "ja", "zh-CN", "zh-TW", "es")
FORMAT = re.compile(r"%%|%[-+ #0]*(?:\*|\d*)(?:\.(?:\*|\d+))?(?:hh|ll|I64|[hljztL])?[diuoxXfFeEgGaAcspq]")


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate translation key: {key!r}")
        result[key] = value
    return result


def load_catalog(path):
    catalog = json.loads(Path(path).read_text(encoding="utf-8-sig"), object_pairs_hook=unique_object)
    if not isinstance(catalog, dict) or not catalog:
        raise ValueError(f"{path}: expected a nonempty translation object")
    for key, translations in catalog.items():
        if not isinstance(key, str) or not key or "\0" in key or not isinstance(translations, dict):
            raise ValueError(f"{path}: invalid translation entry {key!r}")
        unknown = translations.keys() - set(LANGUAGES)
        if unknown:
            raise ValueError(f"{path}: unknown languages for {key!r}: {sorted(unknown)}")
        formats = FORMAT.findall(key)
        for language in LANGUAGES:
            text = translations.get(language, key if language == "ko" else None)
            if not isinstance(text, str) or not text or "\0" in text:
                raise ValueError(f"{path}: missing {language} translation for {key!r}")
            if formats and FORMAT.findall(text) != formats:
                raise ValueError(f"{path}: {language} format mismatch for {key!r}: {FORMAT.findall(text)} != {formats}")
    return catalog


def compile_catalog(catalog, prefix, wide=False):
    if not re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]*", prefix):
        raise ValueError("Prefix must be a C identifier")
    character = "wchar_t" if wide else "char"
    comparison = "wcscmp" if wide else "strcmp"
    include = "wchar.h" if wide else "string.h"
    def literal(text):
        # UTF-8 sources; both native build systems explicitly select UTF-8.
        return ("L" if wide else "") + json.dumps(text, ensure_ascii=False)
    def sort_key(text):
        # Windows wchar_t uses UTF-16 code units; strcmp compares UTF-8 bytes.
        return text.encode("utf-16-be" if wide else "utf-8")
    lines = ["/* Generated from the translation catalog. Do not edit. */", "#pragma once",
             f"#include <{include}>", "#include <stddef.h>",
             f"static const struct {{ const {character} *key; const {character} *text[6]; }} {prefix}_messages[] = {{"]
    for key in sorted(catalog, key=sort_key):
        texts = ", ".join(literal(catalog[key].get(lang, key)) for lang in LANGUAGES)
        lines.append(f"    {{ {literal(key)}, {{ {texts} }} }},")
    lines += ["};", f"static inline const {character} *{prefix}_tr(const {character} *key, unsigned language)",
              "{", "    if (!key) return key;", "    if (language >= 6) language = 0;",
              f"    size_t lo = 0, hi = sizeof({prefix}_messages) / sizeof({prefix}_messages[0]);",
              "    while (lo < hi) {", "        size_t mid = lo + (hi - lo) / 2;",
              f"        int order = {comparison}(key, {prefix}_messages[mid].key);",
              f"        if (!order) return {prefix}_messages[mid].text[language];",
              "        if (order < 0) hi = mid; else lo = mid + 1;", "    }", "    return key;", "}", ""]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--prefix", required=True)
    parser.add_argument("--wide", action="store_true")
    args = parser.parse_args()
    text = compile_catalog(load_catalog(args.input), args.prefix, args.wide)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main()
