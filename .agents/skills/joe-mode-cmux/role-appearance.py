#!/usr/bin/env python3
"""Prepare local Joe appearance fields without launching or changing a session."""
import argparse
import json
from pathlib import Path


ROLE_MAP = Path(__file__).with_suffix(".json")


def unique_fields(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Role appearance mapping contains duplicate fields.")
        result[key] = value
    return result


def validate_appearance(value):
    if not isinstance(value, dict) or set(value) - {"icon", "color"}:
        raise ValueError("Appearance accepts only icon and color fields.")
    for field, maximum in (("icon", 128), ("color", 32)):
        if field in value and (
            not isinstance(value[field], str) or not 1 <= len(value[field]) <= maximum
            or any(ord(character) < 32 or ord(character) == 127 for character in value[field])
        ):
            raise ValueError(f"Appearance {field} must be a bounded nonempty string.")


def appearance_for(role, overrides=None):
    if not isinstance(role, str) or not role.strip() or len(role) > 100:
        raise ValueError("Choose an explicit operational role.")
    with ROLE_MAP.open("rb") as source:
        data = source.read(32_769)
    if len(data) > 32_768:
        raise ValueError("Role appearance mapping exceeds its bounded size.")
    mapping = json.loads(data, object_pairs_hook=unique_fields)
    if (
        not isinstance(mapping, dict) or set(mapping) != {"version", "roles"}
        or type(mapping["version"]) is not int or mapping["version"] != 1
        or not isinstance(mapping["roles"], dict) or not 1 <= len(mapping["roles"]) <= 64
    ):
        raise ValueError("Role appearance mapping is invalid.")
    for key, appearance in mapping["roles"].items():
        if not isinstance(key, str) or not key or key != "-".join(key.casefold().split()):
            raise ValueError("Role appearance keys must be canonical.")
        validate_appearance(appearance)
        if "icon" not in appearance:
            raise ValueError("Mapped roles require an explicit icon.")
    supplied = {} if overrides is None else overrides
    validate_appearance(supplied)
    defaults = mapping["roles"].get("-".join(role.casefold().split()), {})
    return {**defaults, **supplied}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--role", required=True)
    parser.add_argument("--icon", help="Explicit human icon choice, if supplied")
    parser.add_argument("--color", help="Explicit human color choice, if supplied")
    args = parser.parse_args()
    overrides = {key: value for key, value in {"icon": args.icon, "color": args.color}.items()
                 if value is not None}
    try:
        metadata = appearance_for(args.role, overrides)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    print(json.dumps(metadata, sort_keys=True))


if __name__ == "__main__":
    main()
