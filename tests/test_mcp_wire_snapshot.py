import json
import sys
import tempfile
import unittest
from pathlib import Path

# mcp_wire_snapshot.py is a sibling of this file inside tests/, not something
# reachable through the repo-root-based sys.path[0] that `python3 -m unittest
# tests/test_mcp_wire_snapshot.py` sets up (that matches how
# tests/test_mcp_stdio_harness.py reaches the repo-root test_mcp_stdio.py, but
# the direction is reversed here). Insert this file's own directory
# explicitly so the import works regardless of how the test is invoked.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import mcp_wire_snapshot as snap  # noqa: E402 (see sys.path shim above)


def _text_result(text):
    """A minimal JSON-RPC tools/call response wrapping one text content block,
    matching the shape MCPServer.sendTextResult / sendErrorResult produce."""
    return {"jsonrpc": "2.0", "id": 1, "result": {"content": [{"type": "text", "text": text}]}}


class CanonicalizationMaskingTests(unittest.TestCase):
    def test_masks_uuid_timestamp_and_payload_derived_app_identity(self):
        raw = {
            "call_get_active_app": _text_result(json.dumps({
                "frontmost": {"bundleId": "com.example.Foo", "name": "Foo App"},
                "fallback": {"bundleId": "com.example.Foo", "name": "Foo App"},
                "rawFrontmost": {"bundleId": None, "name": None},
            })),
            "call_circle_ok": _text_result(
                "Created circle annotation: 11111111-2222-3333-4444-555555555555 "
                "(linked to Foo App [com.example.Foo]: visible ONLY while that app is frontmost)"
            ),
            "call_list_annotations": _text_result(json.dumps({
                "annotations": [{
                    "id": "11111111-2222-3333-4444-555555555555",
                    "createdAt": 774238998.5,
                    "expiresAt": "2025-07-15T12:00:00.000Z",
                    "remainingSeconds": 42.25,
                    "appId": "com.example.Foo",
                    "appName": "Foo App",
                }],
                "count": 1,
            })),
        }

        canonical = snap.canonicalize_capture(raw)
        blob = json.dumps(canonical)

        self.assertNotIn("Foo App", blob)
        self.assertNotIn("com.example.Foo", blob)
        self.assertNotIn("11111111-2222-3333-4444-555555555555", blob)
        self.assertNotIn("774238998.5", blob)
        self.assertNotIn("2025-07-15T12:00:00.000Z", blob)
        self.assertNotIn("42.25", blob)
        self.assertIn("<APP>", blob)
        self.assertIn("<APPID>", blob)
        self.assertIn("<UUID>", blob)
        self.assertIn("<TIME>", blob)
        self.assertIn("<TTL>", blob)
        # count is a legitimate, non-volatile signal (how many annotations
        # actually exist) and must survive untouched.
        self.assertIn('"count": 1', blob)

    def test_generic_name_keys_outside_the_app_identity_schema_are_not_touched(self):
        # tools/list entries use a bare "name" key for the tool's own name,
        # and initialize's serverInfo does too. Neither is paired with
        # "bundleId" or "appId", so neither should be swept into the mask --
        # doing so would both corrupt unrelated text (short, common tool
        # names like "clear") and hide a real regression in exactly the
        # fields this tool exists to protect.
        raw = {
            "tools_list": {
                "jsonrpc": "2.0", "id": 1,
                "result": {"tools": [{"name": "clear", "description": "Clears annotations.", "inputSchema": {}}]},
            },
            "initialize": {
                "jsonrpc": "2.0", "id": 2,
                "result": {"serverInfo": {"name": "ai-chalkboard", "version": "1.2.0"}},
            },
        }
        canonical = snap.canonicalize_capture(raw)
        blob = json.dumps(canonical)
        self.assertIn("clear", blob)
        self.assertIn("ai-chalkboard", blob)
        self.assertNotIn("<APP>", blob)
        self.assertNotIn("<APPID>", blob)

    def test_longest_first_masking_does_not_corrupt_substring_app_names(self):
        # "Code" and "Visual Studio Code" both running at once: masking the
        # shorter name first would eat the "Code" inside the longer name too,
        # leaving a mangled "Visual Studio <APP>" residue instead of one
        # clean "<APP>" per app.
        raw = {
            "call_get_active_app": _text_result(json.dumps({
                "frontmost": {"bundleId": "com.example.code", "name": "Code"},
                "fallback": {"bundleId": "com.example.vscode", "name": "Visual Studio Code"},
            })),
        }
        canonical = snap.canonicalize_capture(raw)
        blob = json.dumps(canonical)

        self.assertNotIn("Visual Studio Code", blob)
        self.assertNotIn("Visual Studio <APP>", blob)  # the corrupted residue a wrong ordering would leave
        self.assertNotIn('"Code"', blob)
        self.assertEqual(blob.count("<APP>"), 2)

    def test_cleared_count_and_ambiguous_candidate_list_are_normalised(self):
        raw = {
            "call_clear_typo_scope": _text_result(
                "Cleared 3 annotation(s) visible over Foo App (its own annotations plus global ones)."
            ),
            "call_circle_ambiguous_app": _text_result(
                "App 'com.apple' is AMBIGUOUS -- it matches 7 running applications: "
                "'Finder' [com.apple.finder], 'Dock' [com.apple.dock] (and 5 more). "
                "Nothing was drawn, because picking one arbitrarily would link the annotation "
                "to an app you did not mean."
            ),
        }
        canonical = snap.canonicalize_capture(raw)
        blob = json.dumps(canonical)
        self.assertNotIn("Cleared 3 annotation(s)", blob)
        self.assertIn("Cleared <N> annotation(s)", blob)
        self.assertNotIn("com.apple.finder", blob)
        self.assertIn("matches <N> running applications: <CANDIDATES>", blob)
        # The wording surrounding the masked segment is exactly what a real
        # regression (e.g. a reworded error message) would show up in, so it
        # must survive unmasked.
        self.assertIn("Nothing was drawn, because picking one arbitrarily", blob)


class StaticFixtureLiteralsSurviveMaskingTests(unittest.TestCase):
    def test_own_deterministic_bundle_id_fixture_is_not_masked(self):
        # A literal bundle id THIS fixture itself supplies (never running,
        # accepted verbatim) is not "live" data -- masking it the same way
        # as a genuinely volatile app identity would let a future regression
        # in the verbatim-acceptance path (storing/echoing the wrong id)
        # disappear behind the same mask token in both captures.
        self.assertTrue(snap._STATIC_APP_LITERALS, "fixture should supply at least one static bundle-id literal")
        literal = next(iter(snap._STATIC_APP_LITERALS))
        raw = {
            "call_x": _text_result(f"Created box annotation: <fake> (linked to {literal} [{literal}]: ...)"),
            "call_list_annotations": _text_result(json.dumps(
                {"annotations": [{"appId": literal, "appName": None}]}
            )),
        }
        canonical = snap.canonicalize_capture(raw)
        blob = json.dumps(canonical)
        self.assertIn(literal, blob)
        self.assertNotIn("<APPID>", blob)


class EmbeddedJsonKeyOrderTests(unittest.TestCase):
    def test_two_captures_differing_only_in_embedded_json_key_order_compare_equal(self):
        # Swift's JSONSerialization does not sort dictionary keys, so this is
        # exactly the nondeterminism get_screens/list_annotations/
        # get_active_app can legitimately produce between two runs of the
        # identical server.
        capture_a = {"call_get_screens": _text_result('{"b": 1, "a": {"y": 2, "x": 1}}')}
        capture_b = {"call_get_screens": _text_result('{"a": {"x": 1, "y": 2}, "b": 1}')}

        canonical_a = snap.canonicalize_capture(capture_a)
        canonical_b = snap.canonicalize_capture(capture_b)

        self.assertEqual(snap.diff_captures(canonical_a, canonical_b), [])

    def test_embedded_json_is_actually_parsed_not_left_as_an_opaque_string(self):
        capture = {"call_get_screens": _text_result('{"b": 1, "a": 2}')}
        canonical = snap.canonicalize_capture(capture)
        embedded = canonical["call_get_screens"]["result"]["content"][0]["text"]
        self.assertIsInstance(embedded, dict)
        self.assertEqual(embedded["__embedded_json__"], {"a": 2, "b": 1})


class RealDifferenceIsStillDetectedTests(unittest.TestCase):
    """The negative control: canonicalisation must never be so aggressive
    that it launders away an actual regression. This is the most important
    class in this file -- a snapshot tool that cannot fail is worse than no
    snapshot tool at all, because it looks like safety net while providing
    none."""

    def test_changed_tool_description_is_detected(self):
        before = {
            "tools_list": {
                "jsonrpc": "2.0", "id": 1,
                "result": {"tools": [{"name": "draw_circle", "description": "Draws a circle.", "inputSchema": {}}]},
            },
        }
        after = {
            "tools_list": {
                "jsonrpc": "2.0", "id": 1,
                "result": {
                    "tools": [{"name": "draw_circle", "description": "Draws a DIFFERENT circle.", "inputSchema": {}}]
                },
            },
        }
        diff = snap.diff_captures(snap.canonicalize_capture(before), snap.canonicalize_capture(after))
        self.assertNotEqual(diff, [])
        self.assertTrue(any("DIFFERENT circle" in line for line in diff))

    def test_changed_error_message_is_detected(self):
        before = {"call_circle_radius_nonpositive": _text_result("Error: radius must be > 0.")}
        after = {"call_circle_radius_nonpositive": _text_result("Error: radius must be >= 0.")}
        diff = snap.diff_captures(snap.canonicalize_capture(before), snap.canonicalize_capture(after))
        self.assertNotEqual(diff, [])

    def test_a_genuinely_different_live_app_name_is_still_a_real_difference_when_ids_disagree(self):
        # Masking collapses the SAME identity's every occurrence to one
        # token, but two captures reporting genuinely different bundle ids
        # (as opposed to the same one under environment noise) must still
        # disagree once masked, because they harvest and substitute
        # different id sets.
        before = {"call_get_active_app": _text_result(json.dumps(
            {"frontmost": {"bundleId": "com.example.A", "name": "A App"}}
        ))}
        after = {"call_get_active_app": _text_result(json.dumps(
            {"frontmost": {"bundleId": "com.example.A", "name": "A App"}, "extra_field": "new-in-this-build"}
        ))}
        diff = snap.diff_captures(snap.canonicalize_capture(before), snap.canonicalize_capture(after))
        self.assertNotEqual(diff, [])
        self.assertTrue(any("new-in-this-build" in line for line in diff))


class SelfCheckRejectsUnusableCapturesTests(unittest.TestCase):
    def test_empty_dict_is_rejected(self):
        with self.assertRaises(snap.CaptureValidationError):
            snap.validate_capture_shape({}, "empty.json")

    def test_non_dict_top_level_is_rejected(self):
        with self.assertRaises(snap.CaptureValidationError):
            snap.validate_capture_shape([], "list.json")
        with self.assertRaises(snap.CaptureValidationError):
            snap.validate_capture_shape(None, "null.json")

    def test_capture_missing_expected_keys_is_rejected(self):
        partial = {key: {"jsonrpc": "2.0", "id": 1, "result": {}} for key in list(snap.EXPECTED_KEYS)[:2]}
        with self.assertRaises(snap.CaptureValidationError):
            snap.validate_capture_shape(partial, "partial.json")

    def test_capture_with_an_empty_entry_is_rejected(self):
        full = {key: {"jsonrpc": "2.0", "id": 1, "result": {}} for key in snap.EXPECTED_KEYS}
        some_key = next(iter(snap.EXPECTED_KEYS))
        full[some_key] = {}
        with self.assertRaises(snap.CaptureValidationError):
            snap.validate_capture_shape(full, "truncated-entry.json")

    def test_a_complete_capture_passes_the_shape_check(self):
        full = {key: {"jsonrpc": "2.0", "id": 1, "result": {}} for key in snap.EXPECTED_KEYS}
        snap.validate_capture_shape(full, "complete.json")  # must not raise

    def test_compare_refuses_to_report_equivalent_on_two_empty_captures(self):
        # The exact failure this tool exists to prevent: a comparison that
        # silently "passes" because both sides are empty says nothing about
        # the server at all.
        with tempfile.TemporaryDirectory() as tmp:
            before = Path(tmp) / "before.json"
            after = Path(tmp) / "after.json"
            before.write_text("{}")
            after.write_text("{}")
            exit_code = snap.main(["compare", str(before), str(after)])
        self.assertNotEqual(exit_code, 0)

    def test_compare_refuses_to_report_equivalent_on_a_truncated_capture(self):
        with tempfile.TemporaryDirectory() as tmp:
            before = Path(tmp) / "before.json"
            after = Path(tmp) / "after.json"
            before.write_text("")
            after.write_text("{}")
            exit_code = snap.main(["compare", str(before), str(after)])
        self.assertNotEqual(exit_code, 0)

    def test_compare_succeeds_on_two_identical_complete_captures(self):
        full = {key: {"jsonrpc": "2.0", "id": 1, "result": {"content": [{"type": "text", "text": "ok"}]}}
                for key in snap.EXPECTED_KEYS}
        with tempfile.TemporaryDirectory() as tmp:
            before = Path(tmp) / "before.json"
            after = Path(tmp) / "after.json"
            before.write_text(json.dumps(full))
            after.write_text(json.dumps(full))
            exit_code = snap.main(["compare", str(before), str(after)])
        self.assertEqual(exit_code, 0)


if __name__ == "__main__":
    unittest.main()
