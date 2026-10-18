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
    if "FAKE_FAIL_STATE_FSYNC_AT" in os.environ or "FAKE_FAIL_PROJECTION_AT" in os.environ:
        controller["Store"]._atomic = staticmethod(failing_after_replace(controller["Store"]._atomic))
    if "FAKE_PAUSE_AFTER_BIND" in os.environ:
        controller["bind_messaging"] = pausing_after(controller["bind_messaging"], os.environ["FAKE_PAUSE_AFTER_BIND"])
    if "FAKE_AFTER_RESUME_SET" in os.environ:
        cmux_type = controller["Cmux"]
        original_set = cmux_type.set_resume_binding

        def set_then_race(self, *args, **kwargs):
            result = original_set(self, *args, **kwargs)
            api["mutate"](controller["default_root"](),
                          lambda state: exec(os.environ["FAKE_AFTER_RESUME_SET"], {"state": state}))
            return result
        cmux_type.set_resume_binding = set_then_race
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
    """The Nth state.json (or current.json projection) write lands, then reports a failure."""
    counts = {"state.json": 0, "current.json": 0}
    limits = {"state.json": os.environ.get("FAKE_FAIL_STATE_FSYNC_AT"),
              "current.json": os.environ.get("FAKE_FAIL_PROJECTION_AT")}

    def atomic(directory, name, data):
        original(directory, name, data)
        if name in counts:
            counts[name] += 1
            if limits[name] is not None and counts[name] == int(limits[name]):
                raise OSError("synthetic directory fsync failure after replace")
    return atomic


def pausing_after(original, marker):
    """Hold the caller right after the wrapped step until the test releases it."""
    import time

    def wrapped(*args, **kwargs):
        result = original(*args, **kwargs)
        Path(marker + ".ready").write_text("ready")
        deadline = time.monotonic() + 10
        while not Path(marker + ".release").exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        return result
    return wrapped
