"""Portable validation of versioned fixture observations, never native input."""
import json
import math
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


def integer(value):
    return type(value) is int and -(2**63) <= value < 2**63


def number(value):
    if type(value) not in (int, float):
        return False
    try:
        return math.isfinite(value)
    except OverflowError:
        return False


def point(value):
    require(isinstance(value, list) and len(value) == 2 and all(number(v) for v in value),
            "Invalid finite CGPoint")


def rect(value):
    require(isinstance(value, list) and len(value) == 2, "Invalid CGRect")
    for component in value:
        point(component)


def typed_fields(value, required, booleans=(), integers=(), numbers=(), strings=()):
    require(isinstance(value, dict) and set(required) <= set(value), "Missing typed evidence fields")
    for key in booleans:
        require(type(value[key]) is bool, f"Invalid Boolean {key}")
    for key in integers:
        require(integer(value[key]), f"Invalid integer {key}")
    for key in numbers:
        require(number(value[key]), f"Invalid finite number {key}")
    for key in strings:
        require(isinstance(value[key], str), f"Invalid string {key}")


def display_state(value):
    typed_fields(value, {"uptime", "screens", "ownerBackingScaleFactor", "foreignBackingScaleFactor"},
                 numbers=("uptime", "ownerBackingScaleFactor", "foreignBackingScaleFactor"))
    for key in ("ownerScreenNumber", "foreignScreenNumber"):
        require(value.get(key) is None or unsigned(value[key], 2**32 - 1), "Invalid screen number")
    require(isinstance(value["screens"], list), "Invalid screen array")
    for display in value["screens"]:
        typed_fields(display, {"frame", "visibleFrame", "backingScaleFactor"}, numbers=("backingScaleFactor",))
        rect(display["frame"])
        rect(display["visibleFrame"])
        require(display.get("number") is None or unsigned(display["number"], 2**32 - 1), "Invalid display number")
        require(display.get("colorProfileSHA256") is None or isinstance(display["colorProfileSHA256"], str),
                "Invalid profile string")


def lifetime(value):
    booleans = (
        "invalidated", "applicationActive", "ownerVisible", "foreignVisible",
        "ownerReceiverAttached", "foreignReceiverAttached", "evidenceAttached",
    )
    typed_fields(value, set(booleans) | {"failedRowIDs", "displaysAtSample"}, booleans=booleans)
    require(isinstance(value["failedRowIDs"], list) and all(isinstance(v, str) for v in value["failedRowIDs"]),
            "Invalid failed-row identities")
    display_state(value["displaysAtSample"])
    if value.get("displaysAtSetup") is not None:
        display_state(value["displaysAtSetup"])
    if value.get("firstInvalidation") is not None:
        invalidation = value["firstInvalidation"]
        typed_fields(invalidation, {"reason", "uptime", "setupComplete", "applicationActive", "ownerKey", "displays"},
                     booleans=("setupComplete", "applicationActive", "ownerKey"), numbers=("uptime",), strings=("reason",))
        require(invalidation["reason"] in {
            "overlappingMenu", "windowClosed", "applicationResigned", "screenParametersChanged",
        }, "Unknown invalidation reason")
        display_state(invalidation["displays"])


def responder(value):
    fields(value, {"kind", "control", "window"}, {"kind"})
    kind, control, window = value["kind"], value.get("control"), value.get("window")
    require(isinstance(kind, str) and kind in {"none", "control", "other"}, "Unknown responder kind")
    require(window is None or (isinstance(window, str) and window in WINDOWS), "Unknown fixture window")
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
    typed_fields(value, ROOT_KEYS, booleans=("live", "ownerKey", "tracking", "overflow"),
                 integers=("opens", "closes", "actions", "activations", "dismissals",
                           "ownerDown", "ownerUp", "foreignDown", "foreignUp"), strings=("caseID",))
    uuid.UUID(value["caseID"])
    rect(value["ownerFrame"])
    rect(value["foreignFrame"])
    lifetime(value["lifetime"])
    require(isinstance(value["rows"], list) and isinstance(value["inputs"], list)
            and len(value["inputs"]) <= 64, "Invalid input record bound")
    version = value["version"]
    for row in value["rows"]:
        fields(row, ROW_KEYS | ({"keyView"} if version == 4 else set()),
               ROW_KEYS | ({"keyView"} if version == 4 else set()))
        typed_fields(row, ROW_KEYS, booleans=("keyboard", "focused", "eligible", "titleIsResponder",
                                            "exteriorFocusRing", "bordered"),
                     integers=("windowNumber", "focusedControls"), strings=("id",))
        rect(row["frame"])
        rect(row["titleFrame"])
        if version == 4:
            key_view = row["keyView"]
            fields(key_view, {"canBecomeKeyView", "nextValidKeyView"}, {"canBecomeKeyView", "nextValidKeyView"})
            require(type(key_view["canBecomeKeyView"]) is bool, "Invalid key-view eligibility")
            responder(key_view["nextValidKeyView"])
    for item in value["inputs"]:
        fields(item, INPUT_KEYS | ({"keyboard", "dispatch"} if version == 4 else set()),
               {"window", "type", "timestamp"} | ({"dispatch"} if version == 4 else set()))
        typed_fields(item, {"window", "type", "timestamp"}, strings=("window",), numbers=("timestamp",))
        require(unsigned(item["type"], 2**64 - 1), "Invalid unsigned event type")
        if item.get("point") is not None:
            point(item["point"])
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
