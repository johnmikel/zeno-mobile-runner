#!/usr/bin/env python3
import argparse
import json
import sys
from pathlib import Path


FIXTURE_STATUSES = {"planned", "fixture-available", "evidence-committed"}
ADAPTER_STATUSES = {"planned", "partial", "available", "evidence-committed"}
SLICE_STATUSES = {"next", "later", "done"}


def parse_args():
    parser = argparse.ArgumentParser(
        description="Validate and render a ZMR benchmark lab manifest.",
    )
    parser.add_argument(
        "--manifest",
        default="docs/benchmarks/benchmark-lab-v1.json",
        help="Benchmark lab manifest path.",
    )
    parser.add_argument(
        "--format",
        choices=("json", "markdown"),
        default="markdown",
        help="Output format.",
    )
    parser.add_argument("--out", help="Optional output file. Defaults to stdout.")
    return parser.parse_args()


def require_object(value, path):
    if not isinstance(value, dict):
        raise ValueError(f"{path} must be an object")


def require_array(value, path):
    if not isinstance(value, list):
        raise ValueError(f"{path} must be an array")


def require_string(value, path):
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{path} must be a non-empty string")
    return value.strip()


def validate_unique_ids(items, path):
    seen = set()
    for index, item in enumerate(items):
        require_object(item, f"{path}[{index}]")
        item_id = require_string(item.get("id"), f"{path}[{index}].id")
        if item_id in seen:
            raise ValueError(f"{path}[{index}].id is duplicated: {item_id}")
        seen.add(item_id)


def validate_status(value, allowed, path):
    actual = require_string(value, path)
    if actual not in allowed:
        raise ValueError(f"{path} must be one of: {', '.join(sorted(allowed))}")


def validate_manifest(data):
    require_object(data, "$")
    if data.get("schemaVersion") != 1:
        raise ValueError("$.schemaVersion must be 1")
    require_string(data.get("name"), "$.name")
    require_string(data.get("purpose"), "$.purpose")
    require_object(data.get("claimPolicy"), "$.claimPolicy")

    policy = data["claimPolicy"]
    if int(policy.get("minimumRuns", 0)) < 1:
        raise ValueError("$.claimPolicy.minimumRuns must be positive")
    if float(policy.get("candidatePassRate", -1)) < 0:
        raise ValueError("$.claimPolicy.candidatePassRate must be non-negative")
    if int(policy.get("candidateFailures", -1)) < 0:
        raise ValueError("$.claimPolicy.candidateFailures must be non-negative")
    if policy.get("requiresSameContext") is not True:
        raise ValueError("$.claimPolicy.requiresSameContext must be true")

    modes = data.get("modes")
    fixtures = data.get("fixtures")
    adapters = data.get("runnerAdapters")
    slices = data.get("nextSlices")
    require_array(modes, "$.modes")
    require_array(fixtures, "$.fixtures")
    require_array(adapters, "$.runnerAdapters")
    require_array(slices, "$.nextSlices")
    validate_unique_ids(modes, "$.modes")
    validate_unique_ids(fixtures, "$.fixtures")
    validate_unique_ids(adapters, "$.runnerAdapters")
    validate_unique_ids(slices, "$.nextSlices")

    mode_ids = {mode["id"] for mode in modes}
    for index, mode in enumerate(modes):
        require_string(mode.get("label"), f"$.modes[{index}].label")
        require_string(mode.get("description"), f"$.modes[{index}].description")

    for index, fixture in enumerate(fixtures):
        require_string(fixture.get("label"), f"$.fixtures[{index}].label")
        require_string(fixture.get("framework"), f"$.fixtures[{index}].framework")
        validate_status(fixture.get("status"), FIXTURE_STATUSES, f"$.fixtures[{index}].status")
        require_array(fixture.get("platforms"), f"$.fixtures[{index}].platforms")
        require_array(fixture.get("workflow"), f"$.fixtures[{index}].workflow")
        if fixture["status"] != "planned" and not fixture.get("scenario"):
            raise ValueError(f"$.fixtures[{index}].scenario is required unless status is planned")

    for index, adapter in enumerate(adapters):
        require_string(adapter.get("label"), f"$.runnerAdapters[{index}].label")
        validate_status(adapter.get("status"), ADAPTER_STATUSES, f"$.runnerAdapters[{index}].status")
        require_string(adapter.get("collector"), f"$.runnerAdapters[{index}].collector")
        require_array(adapter.get("modes"), f"$.runnerAdapters[{index}].modes")
        for mode in adapter["modes"]:
            if mode not in mode_ids:
                raise ValueError(f"$.runnerAdapters[{index}].modes references unknown mode: {mode}")

    for index, next_slice in enumerate(slices):
        validate_status(next_slice.get("status"), SLICE_STATUSES, f"$.nextSlices[{index}].status")
        require_string(next_slice.get("description"), f"$.nextSlices[{index}].description")


def read_manifest(path):
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise ValueError(f"{path}:{exc.lineno}:{exc.colno}: invalid json: {exc.msg}") from exc
    validate_manifest(data)
    return data


def summary(data):
    fixtures = data["fixtures"]
    adapters = data["runnerAdapters"]
    next_slices = data["nextSlices"]
    return {
        "ok": True,
        "name": data["name"],
        "schemaVersion": data["schemaVersion"],
        "fixtureCount": len(fixtures),
        "adapterCount": len(adapters),
        "modeCount": len(data["modes"]),
        "evidenceFixtures": [fixture["id"] for fixture in fixtures if fixture["status"] == "evidence-committed"],
        "availableFixtures": [fixture["id"] for fixture in fixtures if fixture["status"] in ("fixture-available", "evidence-committed")],
        "plannedFixtures": [fixture["id"] for fixture in fixtures if fixture["status"] == "planned"],
        "nextSlices": [item["id"] for item in next_slices if item["status"] == "next"],
        "minimumRuns": data["claimPolicy"]["minimumRuns"],
        "candidatePassRate": data["claimPolicy"]["candidatePassRate"],
        "candidateFailures": data["claimPolicy"]["candidateFailures"],
    }


def markdown_table(headers, rows):
    lines = [
        "| " + " | ".join(headers) + " |",
        "| " + " | ".join("---" for _ in headers) + " |",
    ]
    for row in rows:
        lines.append("| " + " | ".join(row) + " |")
    return "\n".join(lines)


def render_markdown(data):
    fixtures = [
        [
            fixture["id"],
            fixture["framework"],
            ", ".join(fixture["platforms"]),
            fixture["status"],
            fixture.get("scenario", "pending"),
        ]
        for fixture in data["fixtures"]
    ]
    adapters = [
        [
            adapter["id"],
            adapter["status"],
            adapter["collector"],
            ", ".join(adapter["modes"]),
        ]
        for adapter in data["runnerAdapters"]
    ]
    modes = [
        [mode["id"], mode["label"], mode["description"]]
        for mode in data["modes"]
    ]
    next_slices = [
        [item["id"], item["status"], item["description"]]
        for item in data["nextSlices"]
    ]
    policy = data["claimPolicy"]
    return "\n".join(
        [
            f"# {data['name']}",
            "",
            data["purpose"],
            "",
            "## Claim Policy",
            "",
            f"- Minimum runs: {policy['minimumRuns']}",
            f"- Candidate pass rate: {policy['candidatePassRate']}%",
            f"- Candidate failures: {policy['candidateFailures']}",
            f"- Requires same context: {'yes' if policy['requiresSameContext'] else 'no'}",
            f"- Requires committed rows: {'yes' if policy['requiresCommittedRows'] else 'no'}",
            f"- Forbidden claim: {policy['forbiddenClaim']}",
            "",
            "## Fixtures",
            "",
            markdown_table(["Fixture", "Framework", "Platforms", "Status", "Scenario"], fixtures),
            "",
            "## Runner Adapters",
            "",
            markdown_table(["Adapter", "Status", "Collector", "Modes"], adapters),
            "",
            "## Modes",
            "",
            markdown_table(["Mode", "Label", "Description"], modes),
            "",
            "## Next Slices",
            "",
            markdown_table(["Slice", "Status", "Description"], next_slices),
            "",
        ]
    )


def write_output(content, path):
    if path:
        out = Path(path)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(content, encoding="utf-8")
    else:
        sys.stdout.write(content)


def main():
    args = parse_args()
    try:
        data = read_manifest(args.manifest)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    if args.format == "json":
        content = json.dumps(summary(data), sort_keys=True, separators=(",", ":")) + "\n"
    else:
        content = render_markdown(data)
    write_output(content, args.out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
