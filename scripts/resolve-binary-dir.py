#!/usr/bin/env python3
"""Print a configure preset's binaryDir relative to the source root.

Follows the `inherits` chain, so presets that inherit binaryDir from a base
preset resolve correctly. Usage: resolve-binary-dir.py CMakePresets.json PRESET
"""
import json
import sys


def main() -> int:
    presets_path, name = sys.argv[1], sys.argv[2]
    with open(presets_path, encoding="utf-8") as f:
        doc = json.load(f)
    by_name = {p["name"]: p for p in doc.get("configurePresets", [])}

    def resolve(preset: str, key: str):
        p = by_name.get(preset)
        if p is None:
            return None
        if key in p:
            return p[key]
        parents = p.get("inherits", [])
        if isinstance(parents, str):
            parents = [parents]
        for parent in parents:
            value = resolve(parent, key)
            if value is not None:
                return value
        return None

    binary_dir = resolve(name, "binaryDir")
    if binary_dir is None:
        print(f"no binaryDir for preset {name}", file=sys.stderr)
        return 1
    binary_dir = binary_dir.replace("${sourceDir}", ".").replace("${presetName}", name)
    print(binary_dir)
    return 0


if __name__ == "__main__":
    sys.exit(main())
