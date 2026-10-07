"""Portable validation of versioned fixture observations, never native input."""
import json
import uuid

ROOT_KEYS = {
    "version", "caseID", "live", "lifetime", "rows", "ownerFrame", "foreignFrame", "ownerKey",
    "opens", "closes", "tracking", "actions", "activations", "dismissals", "ownerDown", "ownerUp",
    "foreignDown", "foreignUp", "inputs", "overflow",
}
ROW_KEYS = {
    "id", "windowNumber", "keyboard", "focused", "eligible", "focusedControls",
    "titleIsResponder", "exteriorFocusRing", "bordered", "frame", "titleFrame",
}
INPUT_KEYS = {"window", "type", "timestamp", "point"}
WINDOWS = {"row-input-owner", "row-input-foreign"}
CONTROLS = {
    "owner-title": "row-input-owner", "sibling-title": "row-input-owner",
    "foreign-title": "row-input-foreign", "owner-click": "row-input-owner",
    "foreign-click": "row-input-foreign", "owner-content": "row-input-owner",
    "foreign-content": "row-input-foreign",
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def fields(value, allowed, required):
    require(isinstance(value, dict), "Expected diagnostic object")
    require(set(value) <= allowed and required <= set(value), "Unknown or missing diagnostic fields")


def unsigned(value, maximum):
    return type(value) is int and 0 <= value <= maximum


def responder(value):
    fields(value, {"kind", "control", "window"}, {"kind"})
    kind, control, window = value["kind"], value.get("control"), value.get("window")
    require(kind in {"none", "control", "other"}, "Unknown responder kind")
    require(window is None or window in WINDOWS, "Unknown fixture window")
    if kind == "none":
        require(control is None and window is None, "Absent responder cannot claim identity")
    elif kind == "control":
        require(isinstance(control, str) and control in CONTROLS and window == CONTROLS[control],
                "Control belongs to a different or unknown fixture window")
    else:
        require(control is None, "Unknown responder cannot claim a control")


def decode(payload):
    require(isinstance(payload, bytes) and len(payload) <= 32_768, "Invalid bounded row-input bytes")
    value = json.loads(payload)
    fields(value, ROOT_KEYS, ROOT_KEYS)
    require(type(value["version"]) is int and value["version"] in {3, 4}, "Unsupported evidence version")
    uuid.UUID(value["caseID"])
    require(isinstance(value["rows"], list) and isinstance(value["inputs"], list)
            and len(value["inputs"]) <= 64, "Invalid input record bound")
    version = value["version"]
    for row in value["rows"]:
        fields(row, ROW_KEYS | ({"keyView"} if version == 4 else set()),
               ROW_KEYS | ({"keyView"} if version == 4 else set()))
        if version == 4:
            key_view = row["keyView"]
            fields(key_view, {"canBecomeKeyView", "nextValidKeyView"}, {"canBecomeKeyView", "nextValidKeyView"})
            require(type(key_view["canBecomeKeyView"]) is bool, "Invalid key-view eligibility")
            responder(key_view["nextValidKeyView"])
    for item in value["inputs"]:
        fields(item, INPUT_KEYS | ({"keyboard", "dispatch"} if version == 4 else set()),
               {"window", "type", "timestamp"} | ({"dispatch"} if version == 4 else set()))
        if version == 3:
            continue
        require(item["window"] in WINDOWS and type(item["type"]) is int
                and item["type"] in {1, 2, 10, 11}, "Unknown fixture dispatch")
        dispatch = item["dispatch"]
        fields(dispatch, {"before", "after"}, {"before", "after"})
        responder(dispatch["before"])
        responder(dispatch["after"])
        if item["type"] in {10, 11}:
            require("point" not in item and "keyboard" in item, "Key events require keys, not mouse coordinates")
            keyboard = item["keyboard"]
            fields(keyboard, {"keyCode", "modifierFlags"}, {"keyCode", "modifierFlags"})
            require(unsigned(keyboard["keyCode"], 65_535)
                    and unsigned(keyboard["modifierFlags"], 2**64 - 1), "Invalid typed keyboard values")
        else:
            require("keyboard" not in item and item.get("point") is not None,
                    "Mouse events cannot carry keyboard diagnostics")
    return value
