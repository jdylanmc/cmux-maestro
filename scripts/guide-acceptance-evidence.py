"""Closed native guide evidence gates. Parser fixtures are not native behavior proof."""

import hashlib
import json
import math
import re
from pathlib import Path
import struct

PRODUCERS = {
    "statuses": "CMUXMaestroGuideUITests/GuideAcceptanceTests/testSyntheticStatusesRetainNativeSizeScrollingAndAccessibleActions()",
    "recheck": "CMUXMaestroGuideUITests/GuideAcceptanceTests/testNativeRecheckDrivesCheckingChangedStatusAndRetry()",
}
SCENARIOS = ("missing", "unreadable", "different", "matching", "reference-unavailable")
APPEARANCES = ("light", "dark")
PHASES = {
    "statuses": ("initial-pre-readiness-diagnostic", "initial-ready", "scrolled-bottom", "copy-failure", "copy-success"),
    "recheck": ("initial-pre-readiness-diagnostic", "missing-ready", "unreadable-checking",
                "unreadable-completed", "matching-checking", "matching-completed"),
}
ORIGINALS = [
    "CMUXMaestroPreviewTests/CLIIntegrationGuideRenderingTests/" + name + "()"
    for name in (
        "syntheticStatusesRetainNativeSizeScrollingAndAccessibleActions",
        "nativeRecheckDrivesCheckingChangedStatusAndRetry",
        "builtReferenceMatchesCanonicalSourceWithoutBundlingGlobalGuide",
        "noOpRecheckFailsAtDeadlineAndCancelsItsReadStartWait",
        "accessibilityAcceptanceExcludesOmittedAndIgnoredRawControls",
    )
]


def require(value, message):
    if not value:
        raise ValueError(message)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "Duplicate JSON key: " + key)
        result[key] = value
    return result


def load(path):
    path = Path(path)
    require(path.is_file() and not path.is_symlink() and path.stat().st_size <= 16_777_216,
            "Missing/symlink/oversized evidence file.")
    return json.loads(path.read_text(), object_pairs_hook=unique_object,
                      parse_constant=lambda value: require(False, "Nonfinite JSON value: " + value))


def image_name(case, scenario, appearance, phase):
    if case == "statuses":
        suffix = {"initial-pre-readiness-diagnostic": "", "initial-ready": "", "scrolled-bottom": "-scrolled",
                  "copy-failure": "-copy-failure", "copy-success": "-copy-success"}[phase]
        return f"cli-guide-{scenario}-{appearance}{suffix}.png"
    if phase.endswith(("-checking", "-completed")):
        status, suffix = phase.split("-")
        return f"cli-guide-recheck-{status}-{appearance}-{suffix}.png"
    return None


def finite(value):
    return type(value) in (float, int) and math.isfinite(value)


def validate(document, case, invocation, head, tree, images):
    require(document["schemaVersion"] == 1 and document["invocation"] == invocation
            and document["producer"] == PRODUCERS[case]
            and document["sourceHead"] == head and document["sourceTree"] == tree,
            "Wrong acceptance envelope/producer/source.")
    scenarios = SCENARIOS if case == "statuses" else ("recheck",)
    keys = [(scenario, appearance, phase) for scenario in scenarios for appearance in APPEARANCES
            for phase in PHASES[case]]
    require(len(document["stages"]) == len(keys), "Incomplete/extra stage matrix.")
    previous_elapsed = -1
    manifest = []
    for record, (scenario, appearance, phase) in zip(document["stages"], keys):
        host, consumer = record["host"], record["consumer"]
        preceding_elapsed = previous_elapsed
        require((host["scenario"], host["appearance"], host["stage"]) == (scenario, appearance, phase),
                "Wrong/duplicate/out-of-order stage.")
        require(host["invocation"] == invocation and host["producer"] == PRODUCERS[case]
                and host["sourceHead"] == head and host["sourceTree"] == tree, "Stage identity/source differs.")
        require(finite(host["elapsed"]) and finite(consumer["elapsed"])
                and max(0, previous_elapsed) <= host["elapsed"] <= consumer["elapsed"] < 180,
                "Late/nonmonotonic stage.")
        previous_elapsed = consumer["elapsed"]
        require(consumer["complete"] is True and len(consumer["guideNodes"]) < 4096
                and len(consumer["minimalNodes"]) < 4096, "Incomplete public snapshot.")
        require(consumer["windowIdentifier"] == "guide-acceptance-window"
                and consumer["windowTitle"] == "Synthetic CLI guide host calibration"
                and consumer["guide"]["identifier"] == "guide-validation-real-guide-root"
                and consumer["guide"]["role"] == "AXScrollArea"
                and consumer["minimal"]["identifier"] == "guide-validation-minimal-root", "Wrong public roots.")
        presentation = host["presentation"]
        require(presentation["fittingWidth"] == 600 and presentation["fittingHeight"] == 350,
                "Actual fittingSize differs.")
        if case == "statuses" and phase == "initial-ready":
            require(presentation["document"]["width"] <= presentation["clip"]["width"] + 1
                    and presentation["document"]["height"] > presentation["clip"]["height"],
                    "Actual document/clip geometry differs.")
        for action in host["actions"]:
            require(action["returned"] is True and action["after"] == action["before"] + 1
                    and action["node"]["identifier"] == action["identifier"]
                    and action["node"]["role"] == "AXButton" and action["node"]["enabled"] is True,
                    "False/no-op/wrong AXPress.")
        if phase.startswith("copy-"):
            succeeds = phase == "copy-success"
            require(len(host["actions"]) == 1 and host["copies"] == (2 if succeeds else 1)
                    and host["actions"][0]["sinkResult"] is succeeds, "Copy sink/effect differs.")
        if phase.endswith("-checking"):
            require(host["checking"] is True and host["pendingRead"] is True
                    and len(host["actions"]) == 1 and host["actions"][0]["pendingRead"] is True
                    and not any(node["identifier"].startswith("cli-integration-status-")
                                for node in consumer["guideNodes"]), "Stale/no-op checking evidence.")
            recheck = [node for node in consumer["guideNodes"] if node["identifier"] == "cli-integration-recheck"]
            require(len(recheck) == 1 and recheck[0]["enabled"] is False, "Actual Re-check not disabled.")
        name = image_name(case, scenario, appearance, phase)
        image = host.get("image")
        if name is None:
            require(image is None, "Unexpected capture stage.")
            continue
        require(image is not None and image["name"] == name and image["points"]["width"] == 600
                and image["points"]["height"] == 350 and image["pixelsWide"] > 0 and image["pixelsHigh"] > 0
                and finite(image["backingScale"]) and image["backingScale"] > 0
                and finite(image["capturedAt"]) and max(0, preceding_elapsed) <= image["capturedAt"] <= host["elapsed"],
                "Wrong capture stage/geometry.")
        if phase == "initial-pre-readiness-diagnostic":
            continue
        path = images / name
        require(path.is_file() and not path.is_symlink(), "Missing/fresh image required.")
        data = path.read_bytes()
        require(len(data) == image["bytes"] and hashlib.sha256(data).hexdigest() == image["sha256"]
                and data[:8] == b"\x89PNG\r\n\x1a\n" and data[12:16] == b"IHDR"
                and struct.unpack(">II", data[16:24]) == (image["pixelsWide"], image["pixelsHigh"]),
                "Missing/mutated/non-PNG capture or substituted dimensions.")
        manifest.append({**image, "producer": PRODUCERS[case], "scenario": scenario,
                         "appearance": appearance, "stage": phase, "invocation": invocation})
    completion = document["completion"]
    require(finite(document["elapsed"]) and completion["elapsed"] <= document["elapsed"] < 180
            and completion["invocation"] == invocation and completion["producer"] == PRODUCERS[case]
            and finite(completion["elapsed"]) and previous_elapsed <= completion["elapsed"] < 180,
            "Missing/late final completion.")
    require(len(completion["cleanups"]) == len(scenarios) * 2, "Missing/extra cleanup.")
    for cleanup, key in zip(completion["cleanups"], [(s, a) for s in scenarios for a in APPEARANCES]):
        require((cleanup["scenario"], cleanup["appearance"]) == key
                and cleanup["originalPolicy"] == cleanup["restoredPolicy"]
                and cleanup.get("policyChangeReturned") is not False
                and cleanup.get("policyRestoreReturned") is not False
                and all(cleanup[k] is False for k in ("windowVisible", "guideHasParent", "minimalHasParent",
                                                      "readerPending", "readerWaiting"))
                and finite(cleanup["elapsed"]) and 0 <= cleanup["elapsed"] < 180, "Cleanup not preserved.")
    return manifest


def validate_all(output, invocation, head, tree):
    records = []
    for case in PRODUCERS:
        records += validate(load(output / (case + ".json")), case, invocation, head, tree, output / "images")
    expected = {image_name(case, s, a, phase) for case in PRODUCERS
                for s in (SCENARIOS if case == "statuses" else ("recheck",))
                for a in APPEARANCES for phase in PHASES[case]}
    expected.discard(None)
    require(len(records) == 48 and {item["name"] for item in records} == expected
            and {path.name for path in (output / "images").iterdir()} == expected,
            "Exact 48 fresh cacheDisplay image set required.")
    return records


def extract(export, case, output, *, identifier_path):
    manifest = load(export / "manifest.json")
    require(isinstance(manifest, list) and len(manifest) == 1, "Ambiguous attachment test attribution.")
    test = manifest[0]
    identity = PRODUCERS[case]
    require(test["testIdentifier"] in (identity, identity.split("/", 1)[1])
            and identifier_path(test["testIdentifierURL"]).removesuffix("()")
            == ("CMUXMaestroPreview/" + identity).removesuffix("()"), "Wrong attachment producer identity.")
    attachments = test["attachments"]
    def named(name):
        # Public xcresulttool adds its index/UUID/extension to the actual attachment name.
        pattern = re.escape(name) + r"_0_[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\.json"
        return [a for a in attachments if re.fullmatch(pattern, a["suggestedHumanReadableName"])]

    def read_attachment(attachment):
        require(attachment["isAssociatedWithFailure"] is False and "repetitionNumber" not in attachment
                and not attachment.get("arguments") and finite(attachment["timestamp"])
                and all(isinstance(attachment[key], str) and attachment[key]
                        for key in ("configurationName", "deviceName", "deviceId")),
                "Failed/repeated/parameterized/unattributed acceptance attachment.")
        name = attachment["exportedFileName"]
        require(isinstance(name, str) and Path(name).name == name and name not in ("", ".", ".."),
                "Attachment path escape.")
        return load(export / name)

    selected = named("guide-acceptance-" + case)
    require(len(selected) == 1, "Missing/duplicate completed acceptance attachment.")
    attachment = selected[0]
    value = read_attachment(attachment)
    expected_count = len(PHASES[case]) * len(APPEARANCES) * (len(SCENARIOS) if case == "statuses" else 1)
    require(len(value["stages"]) == expected_count, "Incomplete final stage attachment.")
    stage_attachments = [a for a in attachments if a["suggestedHumanReadableName"].startswith("guide-stage-")]
    require(len(stage_attachments) == expected_count, "Missing/extra native stage attachments.")
    previous_timestamp = None
    for ordinal, record in enumerate(value["stages"]):
        matches = named("guide-stage-" + str(ordinal))
        require(len(matches) == 1, "Missing/duplicate native stage attachment.")
        stage = matches[0]
        require(read_attachment(stage) == record, "Final record differs from actual native stage attachment.")
        require(all(stage[key] == attachment[key] for key in ("deviceId", "configurationName", "deviceName"))
                and 0 <= attachment["timestamp"] - stage["timestamp"] < 180,
                "Native attachment device/configuration/timing differs.")
        require(previous_timestamp is None or previous_timestamp <= stage["timestamp"],
                "Native stage attachment chronology decreases.")
        previous_timestamp = stage["timestamp"]
    destination = output / (case + ".json")
    require(not destination.exists(), "Refusing reused acceptance output.")
    destination.write_text(json.dumps(value, separators=(",", ":")) + "\n")


def case_url(document, identity, *, identifier_path):
    pending = list(document["testNodes"])
    matches = []
    while pending:
        node = pending.pop()
        if node.get("nodeType") == "Test Case":
            url = node.get("nodeIdentifierURL")
            if url and identifier_path(url).removesuffix("()") == ("CMUXMaestroPreview/" + identity).removesuffix("()"):
                matches.append(url)
        pending.extend(node.get("children", []))
    require(len(matches) == 1, "Missing/ambiguous native test URL for attachment extraction.")
    return matches[0]
