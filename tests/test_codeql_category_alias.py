"""A category compatibility upload must preserve every rule and result verbatim."""

import copy
import unittest

from scripts.codeql_category_alias import LEGACY_ID, PLATFORM_ID, legacy_swift_alias


class CodeQLCategoryAliasTests(unittest.TestCase):
    def report(self):
        return {
            "version": "2.1.0",
            "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
            "runs": [{
                "automationDetails": {"id": PLATFORM_ID, "description": {"text": "Swift scan"}},
                "tool": {"driver": {"name": "CodeQL", "version": "2.27.2", "rules": [
                    {"id": "swift/example", "properties": {"security-severity": "9.8"}},
                ]}},
                "results": [{
                    "ruleId": "swift/example", "level": "error",
                    "message": {"text": "Preserve this finding, including ünicode."},
                    "locations": [{"physicalLocation": {"artifactLocation": {"uri": "Sources/App.swift"}}}],
                    "partialFingerprints": {"primaryLocationLineHash": "abc"},
                    "codeFlows": [{"threadFlows": []}],
                }],
                "invocations": [{"executionSuccessful": True}],
                "artifacts": [{"location": {"uri": "Sources/App.swift"}}],
                "properties": {"unknownFutureField": {"keep": True}},
            }],
        }

    def test_only_the_verified_legacy_identity_changes(self):
        source = self.report()
        original = copy.deepcopy(source)
        alias = legacy_swift_alias(source)
        self.assertEqual(source, original, "the normal platform scan must remain unchanged")
        self.assertEqual(alias["runs"][0]["automationDetails"]["id"], LEGACY_ID)
        alias["runs"][0]["automationDetails"]["id"] = PLATFORM_ID
        self.assertEqual(alias, original, "findings, rules and every other field must be identical")
        alias["runs"][0]["results"].clear()
        self.assertEqual(len(source["runs"][0]["results"]), 1, "the copy must not share nested findings")

    def test_an_authentic_empty_scan_stays_empty(self):
        source = self.report()
        source["runs"][0]["results"] = []
        self.assertEqual(legacy_swift_alias(source)["runs"][0]["results"], [])

    def test_raw_cli_output_without_an_identity_gets_only_the_legacy_identity(self):
        source = self.report()
        del source["runs"][0]["automationDetails"]
        original = copy.deepcopy(source)
        alias = legacy_swift_alias(source)
        self.assertEqual(source, original)
        self.assertEqual(alias["runs"][0].pop("automationDetails"), {"id": LEGACY_ID})
        self.assertEqual(alias, original, "raw CLI findings and rules must also stay intact")

    def test_unexpected_run_tool_or_identity_fails_closed(self):
        for edit in (
            lambda report: report.update(runs=[]),
            lambda report: report["runs"].append(copy.deepcopy(report["runs"][0])),
            lambda report: report["runs"][0]["tool"]["driver"].update(name="Other"),
            lambda report: report["runs"][0]["automationDetails"].update(id="another-configuration/"),
        ):
            source = self.report()
            edit(source)
            with self.assertRaises(ValueError):
                legacy_swift_alias(source)


if __name__ == "__main__":
    unittest.main()
