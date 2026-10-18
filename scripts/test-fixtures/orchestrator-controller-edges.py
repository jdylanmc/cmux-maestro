"""Fixture clock and executable edges for orchestration tests only.

Kept separate from the test suite so each fixture controller process loads
these few functions, not the whole suite and a second controller copy.
"""
import json
import os
from pathlib import Path


def fixture_edges(environment, driver):
    """Fixture clock and executable edges; the shipped controller reads none of these variables."""
    edges = {"CONTROLLER_ENTRYPOINT": Path(driver)}
    for name in ("STARTUP_SECONDS", "HEARTBEAT_SECONDS", "ARCHIVE_SECONDS", "BORN_ENROLL_WINDOW_SECONDS"):
        if f"FAKE_{name}" in environment:
            edges[name] = float(environment[f"FAKE_{name}"])
    if "FAKE_GIT" in environment:
        edges["GIT_EXECUTABLE"] = environment["FAKE_GIT"]
    return edges


def configure_fixture_controller(api, driver):
    controller = api["main"].__globals__
    controller.update(fixture_edges(os.environ, driver))
    controller["launch_reserved_session"] = legacy_fixture_launcher(controller["launch_reserved_session"], api)
    if "FAKE_FAIL_STATE_FSYNC_AT" in os.environ:
        controller["Store"]._atomic = staticmethod(failing_after_replace(controller["Store"]._atomic))
    if "FAKE_RESUME_RACE" in os.environ:
        controller["mutate_retiring_routes"] = racing_resume(controller["mutate_retiring_routes"], api)


def racing_resume(original, api):
    """Apply a state change after a resume's snapshot checks and before its commit lock."""
    def mutate_retiring_routes(root, operation, **options):
        if operation.__name__ == "resume":
            api["mutate"](root, lambda state: exec(os.environ["FAKE_RESUME_RACE"], {"state": state, "json": json, "os": os, "api": api}))
        return original(root, operation, **options)
    return mutate_retiring_routes


def legacy_fixture_launcher(original, api):
    def launch(root, cmux, identifier, *args):
        if os.environ.get("FAKE_SESSION_MODE") in {"bounded", "legacy-interactive"}:
            def persisted(state):
                node = state["nodes"][identifier]
                if os.environ["FAKE_SESSION_MODE"] == "bounded":
                    node.pop("executionMode", None)
                node.pop("launchMethod", None)
            api["mutate"](root, persisted)
        return original(root, cmux, identifier, *args)
    return launch


def failing_after_replace(original):
    """The Nth state.json write lands, then reports a failure (as a directory fsync error would)."""
    count = [0]

    def atomic(directory, name, data):
        original(directory, name, data)
        if name == "state.json":
            count[0] += 1
            if count[0] == int(os.environ["FAKE_FAIL_STATE_FSYNC_AT"]):
                raise OSError("synthetic directory fsync failure after replace")
    return atomic
