#!/usr/bin/env python3
"""Canonicalise FastAPI's nullable idiom into OAS 3.1 type arrays.

PINNED DEBT (WP8 P0a, plan docs/plans/PLAN_2026-08-27_wp8-native-client.md §Phase 0a
"OpenAPI generation and provenance lane"). Ported verbatim (logic unchanged) from
memos-ng-ios's retired scripts/normalize-openapi.py (git show dfc2545~1 in that repo),
the estate's own prior fix for the SAME generator bug against the SAME FastAPI idiom.
This bridge is temporary: the schema fix belongs to P1-backend (the first phase permitted
to change img-manager's OpenAPI contract after v0.9.0 shipped). When img-manager emits
`type: ["string", "null"]` natively, this script's rewritten-count goes to 0 and it can be
retired the same way memos-ng-ios retired its copy at commit 433a3fe.

FastAPI writes an optional field as ``anyOf: [{"type": "string"}, {"type": "null"}]``.
swift-openapi-generator does not support a bare ``"null"`` schema and DROPS the whole
property, silently. **Confirmed for img-manager 2026-08-27**: all 29 inline-type
anyOf-nullable component-schema properties in v0.9.0's frontend/openapi.json (SHA
4b952701ac79a6ec7ac245e8f1bf3b9657ca64c6) vanish from the generated Types.swift with this
bug live, `ImagePage.next_cursor` included — see img-manager-ios/.phase-ledger.md for the
full failing-field list and the grep evidence.

``type: ["string", "null"]`` says exactly the same thing in JSON Schema 2020-12 and
generates a Swift optional. This rewrite is therefore lossless, and it is applied HERE, at
vendoring time, rather than hidden inside the generator config, so that OPENAPI_SOURCE can
record how many properties it touched.

Merging the retained member into its parent can only be lossless if the two do not disagree
about a shared keyword: a parent ``maxLength`` and a member ``maxLength`` with different
values cannot both survive, and silently keeping one would quietly relax or tighten the
contract. Any such collision FAILS the sync, naming the JSON path — a vendored contract
that differs from its source in a way nobody chose is worse than a sync that stops.

Only inline schemas are rewritten. ``anyOf: [{"$ref": ...}, {"type": "null"}]`` cannot
become a type array; those are left alone and reported, because a reference plus null is a
different fix (img-manager v0.9.0 has 12 of these — MaintenanceBusy.active_run and
similar — none read by P0a's empty scaffold).

Run ``tools/normalize-openapi.py --selftest`` to check the merge rules themselves.
"""

import json
import sys


class CollisionError(Exception):
    """The retained anyOf member and its parent disagree about a shared keyword."""


def is_null_schema(node):
    return isinstance(node, dict) and node.get("type") == "null" and len(node) == 1


def merge(keep, parent, path):
    """Fold the retained member into its parent, refusing to drop either side's meaning."""
    rest = {k: v for k, v in parent.items() if k != "anyOf"}
    for key in sorted(set(keep) & set(rest)):
        if keep[key] != rest[key]:
            raise CollisionError(
                f"{path}: '{key}' differs between the anyOf member ({keep[key]!r}) and its "
                f"parent ({rest[key]!r}); merging would silently drop one"
            )
    merged = dict(keep)
    merged.update(rest)
    merged["type"] = [keep["type"], "null"]
    return merged


def rewrite(node, counts, path="#"):
    if isinstance(node, dict):
        any_of = node.get("anyOf")
        if isinstance(any_of, list) and len(any_of) == 2 and any(is_null_schema(m) for m in any_of):
            keep = next(m for m in any_of if not is_null_schema(m))
            if "type" in keep and "$ref" not in keep:
                merged = merge(keep, node, path)
                node.clear()
                node.update(merged)
                counts["rewritten"] += 1
            else:
                counts["left"] += 1
        for key, value in list(node.items()):
            rewrite(value, counts, f"{path}/{key}")
    elif isinstance(node, list):
        for index, value in enumerate(node):
            rewrite(value, counts, f"{path}/{index}")


def selftest():
    document = {
        "properties": {
            "cursor": {
                "anyOf": [{"type": "string"}, {"type": "null"}],
                "title": "Cursor",
                "maxLength": 64,
            }
        }
    }
    counts = {"rewritten": 0, "left": 0}
    rewrite(document, counts)
    field = document["properties"]["cursor"]
    assert field["type"] == ["string", "null"], field
    assert field["title"] == "Cursor", field
    assert field["maxLength"] == 64, field
    assert "anyOf" not in field, field
    assert counts == {"rewritten": 1, "left": 0}, counts

    same = {"anyOf": [{"type": "string", "maxLength": 8}, {"type": "null"}], "maxLength": 8}
    counts = {"rewritten": 0, "left": 0}
    rewrite(same, counts)
    assert same["maxLength"] == 8, same
    assert counts["rewritten"] == 1, counts

    clash = {
        "properties": {
            "q": {"anyOf": [{"type": "string", "maxLength": 8}, {"type": "null"}], "maxLength": 99}
        }
    }
    try:
        rewrite(clash, {"rewritten": 0, "left": 0})
    except CollisionError as error:
        assert "maxLength" in str(error), error
        assert "#/properties/q" in str(error), error
    else:
        raise AssertionError("a colliding maxLength was merged instead of refused")

    referenced = {"anyOf": [{"$ref": "#/components/schemas/Visibility"}, {"type": "null"}]}
    counts = {"rewritten": 0, "left": 0}
    rewrite(referenced, counts)
    assert "anyOf" in referenced, referenced
    assert counts == {"rewritten": 0, "left": 1}, counts

    print("selftest OK: merge keeps parent keywords, accepts identical ones,")
    print("             refuses conflicting ones, and leaves $ref+null alone")
    return 0


def main(argv):
    if len(argv) == 2 and argv[1] == "--selftest":
        return selftest()
    if len(argv) != 3:
        print("usage: normalize-openapi.py <in.json> <out.json> | --selftest", file=sys.stderr)
        return 2
    with open(argv[1], encoding="utf-8") as handle:
        document = json.load(handle)
    counts = {"rewritten": 0, "left": 0}
    try:
        rewrite(document, counts)
    except CollisionError as error:
        print(f"normalize-openapi: {error}", file=sys.stderr)
        return 1
    with open(argv[2], "w", encoding="utf-8") as handle:
        json.dump(document, handle, indent=1, sort_keys=True)
        handle.write("\n")
    print(f"nullable_rewritten={counts['rewritten']}")
    print(f"nullable_left_as_anyof_ref={counts['left']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
