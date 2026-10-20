"""Copy one authentic Swift scan for the still-active legacy CodeQL configuration.

Main analysis 1879685563 records the language-only environment and category below.
Its exported SARIF confirms the trailing slash in automationDetails.id. Only that
identity changes; the normal language+OS scan, findings and rules stay intact.
"""

import copy
import json
from pathlib import Path
import sys

PLATFORM_ID = ".github/workflows/codeql.yml:analyze/language:swift/os:macos-latest/"
LEGACY_ID = ".github/workflows/codeql.yml:analyze/language:swift/"


def legacy_swift_alias(report):
    runs = report.get("runs", [])
    if len(runs) != 1:
        raise ValueError("expected exactly one Swift CodeQL SARIF run")
    run = runs[0]
    if run.get("tool", {}).get("driver", {}).get("name") != "CodeQL":
        raise ValueError("expected a CodeQL scan")
    if run.get("automationDetails", {}).get("id") != PLATFORM_ID:
        raise ValueError("expected the existing language+OS Swift configuration")
    alias = copy.deepcopy(report)
    alias["runs"][0]["automationDetails"]["id"] = LEGACY_ID
    return alias


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: codeql_category_alias.py <swift.sarif> <legacy.sarif>")
    source, destination = map(Path, sys.argv[1:])
    alias = legacy_swift_alias(json.loads(source.read_text(encoding="utf-8")))
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(alias, ensure_ascii=False) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
