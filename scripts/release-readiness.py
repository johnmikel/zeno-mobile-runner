#!/usr/bin/env python3
import argparse
import json
import os
import shlex
import stat
import sys
from pathlib import Path

from run_evidence_lib import bounded_io, constants, safe_io
from run_evidence_lib.contracts import (
    _comparability_tuple,
    _validate_index,
    recompute_comparability,
    validate_summary,
)


CLASSIFICATIONS = (
    "passed",
    "runner_failure",
    "app_failure",
    "infrastructure_failure",
    "configuration_failure",
    "cancelled",
)
MAX_RUN_DIAGNOSTICS = 256
MAX_RUN_DIAGNOSTIC_BYTES = 2048


def positive_integer(value):
    parsed = int(value)
    if parsed < 1:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return parsed


def parse_args():
    parser = argparse.ArgumentParser(description="Evaluate release-readiness evidence.")
    parser.add_argument(
        "--target",
        required=True,
        choices=("dev-preview", "production", "market-claim"),
    )
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--evidence", action="append", required=True)
    parser.add_argument("--run-summary", action="append", default=[])
    parser.add_argument("--attempt-index")
    parser.add_argument(
        "--certification-min-executions", type=positive_integer, default=300
    )
    parsed = parser.parse_args()
    if parsed.attempt_index and not parsed.run_summary:
        parser.error("--attempt-index requires --run-summary")
    return parsed


def _bounded_diagnostic(value):
    encoded = value.encode("utf-8")
    if len(encoded) <= MAX_RUN_DIAGNOSTIC_BYTES:
        return value
    suffix = b"... [truncated]"
    prefix = encoded[: MAX_RUN_DIAGNOSTIC_BYTES - len(suffix)]
    while True:
        try:
            return prefix.decode("utf-8") + suffix.decode("ascii")
        except UnicodeDecodeError:
            prefix = prefix[:-1]


def _read_json(root, path, label):
    with safe_io._rooted_io(root, mutation=False):
        if safe_io._evidence_is_symlink(path) or not safe_io._evidence_is_file(path):
            raise ValueError(f"{label} is missing or unsafe")
        metadata = safe_io._evidence_stat(path)
        value, byte_count = bounded_io._read_json_bounded(
            path,
            maximum=constants.MAX_STRUCTURED_JSON_BYTES,
            expected_metadata=metadata,
        )
    return value, byte_count


def _index_inventory(index_path, diagnostics, fatal_diagnostics):
    index_path = Path(index_path).absolute()
    publication_root = index_path.parent
    try:
        index, _byte_count = _read_json(
            publication_root, index_path, "attempt index"
        )
        _validate_index(index)
    except (OSError, RuntimeError, ValueError) as exc:
        message = f"attempt index is invalid: {exc}"
        diagnostics.append(message)
        fatal_diagnostics.append(message)
        return publication_root, None, {}

    entries = {}
    for execution in index["executions"]:
        for attempt in execution["attempts"]:
            entries[attempt["summary"]] = (execution, attempt)
    return publication_root, index, entries


def _discover_indexed_paths(publication_root, supplied, diagnostics, fatal_diagnostics):
    discovered = set()
    try:
        with safe_io._rooted_io(publication_root, mutation=False):
            for raw in supplied:
                path = Path(raw).absolute()
                try:
                    relative = path.relative_to(publication_root).as_posix()
                except ValueError:
                    message = "run-summary input is outside the attempt-index root"
                    diagnostics.append(message)
                    fatal_diagnostics.append(message)
                    continue
                if safe_io._evidence_is_symlink(path):
                    message = f"run-summary input is unsafe: {relative}"
                    diagnostics.append(message)
                    fatal_diagnostics.append(message)
                    continue
                if safe_io._evidence_is_file(path):
                    candidates = [path]
                elif safe_io._evidence_is_dir(path):
                    candidates = []
                    entry_count = 0
                    for candidate, metadata in bounded_io._iter_rooted_tree(
                        path,
                        maximum_directories=constants.MAX_BUNDLE_DIRECTORY_COUNT,
                    ):
                        if not stat.S_ISDIR(metadata.st_mode):
                            entry_count += 1
                            if entry_count > constants.MAX_BUNDLE_FILE_COUNT:
                                raise ValueError(
                                    "run-summary publication exceeds the maximum file count"
                                )
                        if candidate.name != "run-summary.json":
                            continue
                        if stat.S_ISLNK(metadata.st_mode):
                            candidate_relative = candidate.relative_to(
                                publication_root
                            ).as_posix()
                            message = f"run summary is unsafe: {candidate_relative}"
                            diagnostics.append(message)
                            fatal_diagnostics.append(message)
                        elif stat.S_ISREG(metadata.st_mode):
                            candidates.append(candidate)
                else:
                    message = f"run-summary input is missing: {relative}"
                    diagnostics.append(message)
                    fatal_diagnostics.append(message)
                    continue
                if len(discovered) + len(candidates) > constants.MAX_AGGREGATE_SUMMARY_COUNT:
                    raise ValueError("run-summary input count exceeds the aggregate maximum")
                for candidate in candidates:
                    candidate_relative = candidate.relative_to(publication_root).as_posix()
                    if safe_io._evidence_is_symlink(candidate):
                        message = f"run summary is unsafe: {candidate_relative}"
                        diagnostics.append(message)
                        fatal_diagnostics.append(message)
                    elif safe_io._evidence_is_file(candidate):
                        discovered.add(candidate_relative)
    except (OSError, RuntimeError, ValueError) as exc:
        message = f"run-summary discovery failed: {exc}"
        diagnostics.append(message)
        fatal_diagnostics.append(message)
    return discovered


def _load_indexed_summaries(supplied, index_path, diagnostics, fatal_diagnostics):
    publication_root, index, entries = _index_inventory(
        index_path, diagnostics, fatal_diagnostics
    )
    discovered = _discover_indexed_paths(
        publication_root, supplied, diagnostics, fatal_diagnostics
    )
    if index is not None:
        expected = set(entries)
        missing = sorted(expected - discovered)
        unindexed = sorted(discovered - expected)
        if missing:
            message = "attempt index references missing summaries: " + ", ".join(missing)
            diagnostics.append(message)
            fatal_diagnostics.append(message)
        if unindexed:
            message = "run-summary inputs contain unindexed summaries: " + ", ".join(unindexed)
            diagnostics.append(message)
            fatal_diagnostics.append(message)

    loaded = []
    inspected_bytes = 0
    for relative in sorted(discovered):
        path = publication_root.joinpath(*relative.split("/"))
        try:
            value, byte_count = _read_json(publication_root, path, relative)
        except (OSError, RuntimeError, ValueError) as exc:
            message = f"{relative}: {exc}"
            diagnostics.append(message)
            fatal_diagnostics.append(message)
            continue
        inspected_bytes += byte_count
        if inspected_bytes > constants.MAX_AGGREGATE_INSPECTED_BYTES:
            message = "run-summary inputs exceed the aggregate byte maximum"
            diagnostics.append(message)
            fatal_diagnostics.append(message)
            break
        loaded.append((relative, value, entries.get(relative)))
    return loaded


def _load_direct_summaries(supplied, diagnostics, fatal_diagnostics):
    if len(supplied) > constants.MAX_AGGREGATE_SUMMARY_COUNT:
        message = "run-summary input count exceeds the aggregate maximum"
        diagnostics.append(message)
        fatal_diagnostics.append(message)
        return []
    loaded = []
    inspected_bytes = 0
    for raw in supplied:
        path = Path(raw).absolute()
        root = path.parent
        if path.is_dir():
            message = "directory run-summary inputs require --attempt-index"
            diagnostics.append(message)
            fatal_diagnostics.append(message)
            continue
        try:
            value, byte_count = _read_json(root, path, path.name)
        except (OSError, RuntimeError, ValueError) as exc:
            message = f"run-summary input {path.name}: {exc}"
            diagnostics.append(message)
            fatal_diagnostics.append(message)
            continue
        inspected_bytes += byte_count
        if inspected_bytes > constants.MAX_AGGREGATE_INSPECTED_BYTES:
            message = "run-summary inputs exceed the aggregate byte maximum"
            diagnostics.append(message)
            fatal_diagnostics.append(message)
            break
        loaded.append((path.name, value, None))
    return loaded


def aggregate_run_evidence(supplied, index_path, certification_minimum):
    diagnostics = []
    fatal_diagnostics = []
    loaded = (
        _load_indexed_summaries(
            supplied, index_path, diagnostics, fatal_diagnostics
        )
        if index_path
        else _load_direct_summaries(supplied, diagnostics, fatal_diagnostics)
    )

    executions = {}
    seen_run_ids = set()
    for label, summary, registration in loaded:
        errors = validate_summary(summary)
        if errors:
            message = f"{label}: invalid run summary: " + "; ".join(errors)
            diagnostics.append(message)
            fatal_diagnostics.append(message)
            continue
        run_id = summary["runId"]
        if run_id in seen_run_ids:
            message = "run summaries contain a duplicate runId"
            diagnostics.append(message)
            fatal_diagnostics.append(message)
            continue
        seen_run_ids.add(run_id)
        raw_tuple = _comparability_tuple(summary)
        computed = recompute_comparability(summary)
        if registration is not None:
            registered_execution, registered_attempt = registration
            mismatches = []
            if registered_execution["executionId"] != summary["executionId"]:
                mismatches.append("executionId")
            if registered_attempt["runId"] != run_id:
                mismatches.append("runId")
            if registered_attempt["attempt"] != summary["attempt"]:
                mismatches.append("attempt")
            if registered_execution["comparabilityTuple"] != raw_tuple:
                mismatches.append("comparability tuple")
            if mismatches:
                message = f"{label}: attempt index disagrees on " + ", ".join(mismatches)
                diagnostics.append(message)
                fatal_diagnostics.append(message)

        execution = executions.setdefault(
            summary["executionId"],
            {
                "rawTuple": raw_tuple,
                "comparabilityKey": computed["comparabilityKey"],
                "certificationEligible": computed["certificationEligible"],
                "ineligibilityReasons": computed["ineligibilityReasons"],
                "attempts": [],
            },
        )
        if execution["rawTuple"] != raw_tuple:
            message = f"execution {summary['executionId']} changes retry comparability identity"
            diagnostics.append(message)
            fatal_diagnostics.append(message)
        execution["attempts"].append(summary)

    for execution_id, execution in executions.items():
        execution["attempts"].sort(key=lambda item: (item["attempt"], item["runId"]))
        numbers = [item["attempt"] for item in execution["attempts"]]
        if numbers != list(range(1, len(numbers) + 1)):
            message = f"execution {execution_id} attempts must start at 1 and be contiguous"
            diagnostics.append(message)
            fatal_diagnostics.append(message)
        if not execution["certificationEligible"]:
            diagnostics.append(
                f"execution {execution_id} is certification-ineligible: "
                + ", ".join(execution["ineligibilityReasons"])
            )

    classification_counts = {name: 0 for name in CLASSIFICATIONS}
    first_passes = 0
    eventual_passes = 0
    eligible_executions = 0
    cohort_map = {}
    for execution in executions.values():
        attempts = execution["attempts"]
        for attempt in attempts:
            classification_counts[attempt["classification"]] += 1
        if attempts and attempts[0]["status"] == "passed":
            first_passes += 1
        if attempts and attempts[-1]["status"] == "passed":
            eventual_passes += 1
        if execution["certificationEligible"]:
            eligible_executions += 1
        cohort_key = (
            execution["rawTuple"].get("candidateRevision"),
            execution["comparabilityKey"],
        )
        cohort = cohort_map.setdefault(
            cohort_key,
            {
                "candidateRevision": cohort_key[0],
                "comparabilityKey": cohort_key[1],
                "logicalExecutions": 0,
                "eligibleLogicalExecutions": 0,
            },
        )
        cohort["logicalExecutions"] += 1
        if execution["certificationEligible"]:
            cohort["eligibleLogicalExecutions"] += 1

    logical_executions = len(executions)
    percent = lambda count: (
        round(count * 100.0 / logical_executions, 10)
        if logical_executions
        else 0.0
    )
    cohorts = sorted(
        cohort_map.values(),
        key=lambda item: (item["candidateRevision"] or "", item["comparabilityKey"] or ""),
    )
    eligible_cohorts = [item for item in cohorts if item["eligibleLogicalExecutions"]]
    blocking_reasons = []
    if fatal_diagnostics:
        blocking_reasons.append("run evidence contains invalid or inconsistent inputs")
    if eligible_executions < certification_minimum:
        blocking_reasons.append(
            f"eligible logical executions {eligible_executions} is below certification minimum {certification_minimum}"
        )
    if len(eligible_cohorts) > 1:
        blocking_reasons.append(
            "certification evidence spans multiple candidate revisions or comparability keys"
        )
    if classification_counts["runner_failure"]:
        blocking_reasons.append("runner failure occurred in certification cohort")
    if logical_executions and eventual_passes != logical_executions:
        blocking_reasons.append("not every logical execution eventually passed")
    if not logical_executions:
        blocking_reasons.append("run evidence contains no logical executions")

    unique_diagnostics = sorted({_bounded_diagnostic(item) for item in diagnostics})
    if len(unique_diagnostics) > MAX_RUN_DIAGNOSTICS:
        omitted = len(unique_diagnostics) - MAX_RUN_DIAGNOSTICS
        unique_diagnostics = unique_diagnostics[:MAX_RUN_DIAGNOSTICS] + [
            f"{omitted} additional run-evidence diagnostics omitted"
        ]

    return {
        "attempts": sum(classification_counts.values()),
        "logicalExecutions": logical_executions,
        "eligibleLogicalExecutions": eligible_executions,
        "firstAttemptPassRate": percent(first_passes),
        "eventualPassRate": percent(eventual_passes),
        "classificationCounts": classification_counts,
        "certificationMinimum": certification_minimum,
        "certificationReady": not blocking_reasons,
        "cohorts": cohorts,
        "blockingReasons": blocking_reasons,
        "diagnostics": unique_diagnostics,
    }


args = parse_args()
target, json_mode = args.target, args.json
evidence_paths = args.evidence
run_evidence = (
    aggregate_run_evidence(
        args.run_summary,
        args.attempt_index,
        args.certification_min_executions,
    )
    if args.run_summary
    else None
)

rows = []
missing_evidence_files = []
invalid_evidence_lines = []
for evidence_path in evidence_paths:
    if not os.path.isfile(evidence_path):
        if json_mode:
            missing_evidence_files.append(evidence_path)
            continue
        print(f"error: evidence file not found: {evidence_path}", file=sys.stderr)
        sys.exit(2)
    with open(evidence_path, encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, 1):
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError as exc:
                if json_mode:
                    invalid_evidence_lines.append((evidence_path, line_number, str(exc)))
                    continue
                print(f"error: invalid evidence JSONL in {evidence_path} at line {line_number}: {exc}", file=sys.stderr)
                sys.exit(2)

def unique_names(names):
    seen = set()
    unique = []
    for name in names:
        if name in seen:
            continue
        seen.add(name)
        unique.append(name)
    return unique


failed = unique_names(row.get("name", "<unnamed>") for row in rows if row.get("status") == "failed")
planned = unique_names(row.get("name", "<unnamed>") for row in rows if row.get("status") == "planned")


def command_flags(row):
    command = row.get("command")
    if not isinstance(command, str):
        return {}
    try:
        parts = shlex.split(command)
    except ValueError:
        return {}
    flags = {}
    index = 0
    while index < len(parts):
        part = parts[index]
        if part.startswith("--"):
            if "=" in part:
                key, value = part.split("=", 1)
                flags[key] = value
            elif index + 1 < len(parts) and not parts[index + 1].startswith("--"):
                flags[part] = parts[index + 1]
                index += 1
            else:
                flags[part] = "true"
        index += 1
    return flags


def numeric_value(row, field, flag):
    value = row.get(field)
    if value is None:
        value = command_flags(row).get(flag)
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def structured_numeric_value(row, field):
    try:
        return float(row.get(field))
    except (TypeError, ValueError):
        return None


def concrete_value(value):
    return isinstance(value, str) and value.strip() and not value.strip().startswith("<")


def concrete_physical_device_value(value):
    if not concrete_value(value):
        return False
    return value.strip().lower() not in {"booted", "simulator", "iphonesimulator"}


def pilot_app_id_value(label, row):
    flags = command_flags(row)
    if label == "Android hardware pilot":
        candidates = [
            row.get("androidAppId"),
            row.get("appId"),
            flags.get("--android-app-id"),
            flags.get("--app-id"),
        ]
    else:
        candidates = [
            row.get("iosAppId"),
            row.get("appId"),
            flags.get("--ios-app-id"),
            flags.get("--app-id"),
        ]
    for candidate in candidates:
        if concrete_value(candidate):
            return candidate
    return None


def pilot_app_root_value(label, row):
    flags = command_flags(row)
    if label == "Android hardware pilot":
        candidates = [
            row.get("androidAppRoot"),
            row.get("appRoot"),
            flags.get("--android-app-root"),
            flags.get("--app-root"),
        ]
    else:
        candidates = [
            row.get("iosAppRoot"),
            row.get("appRoot"),
            flags.get("--ios-app-root"),
            flags.get("--app-root"),
        ]
    for candidate in candidates:
        if concrete_value(candidate):
            return candidate
    return None


def pilot_app_artifact_value(label, row):
    if label == "Android hardware pilot":
        return pilot_app_root_value(label, row)
    flags = command_flags(row)
    candidates = [
        row.get("iosAppPath"),
        row.get("appPath"),
        flags.get("--ios-app-path"),
        flags.get("--app-path"),
    ]
    for candidate in candidates:
        if concrete_value(candidate):
            return candidate
    return None


def physical_ios_device_value(row):
    flags = command_flags(row)
    candidates = [
        row.get("iosDeviceId"),
        row.get("deviceId"),
        row.get("device"),
        flags.get("--ios-device"),
        flags.get("--device"),
    ]
    for candidate in candidates:
        if concrete_physical_device_value(candidate):
            return candidate
    return None


def ios_device_value(row):
    flags = command_flags(row)
    candidates = [
        row.get("iosDeviceId"),
        row.get("deviceId"),
        row.get("device"),
        flags.get("--ios-device"),
        flags.get("--device"),
    ]
    for candidate in candidates:
        if concrete_value(candidate):
            return candidate
    return None


def android_device_value(row):
    flags = command_flags(row)
    candidates = [
        row.get("androidDeviceId"),
        row.get("deviceId"),
        row.get("device"),
        flags.get("--android-device"),
        flags.get("--device"),
    ]
    for candidate in candidates:
        if concrete_value(candidate):
            return candidate
    return None


def pilot_thresholds_pass(label, row):
    runs = structured_numeric_value(row, "runs")
    min_pass_rate = structured_numeric_value(row, "minPassRate")
    max_failures = structured_numeric_value(row, "maxFailures")
    device_ok = True
    if label == "Android hardware pilot":
        device_ok = android_device_value(row) is not None
    if label == "iOS simulator hardware pilot":
        device_ok = ios_device_value(row) is not None
    if label == "iOS physical hardware pilot":
        device_ok = physical_ios_device_value(row) is not None
    return (
        runs is not None
        and runs >= 20
        and min_pass_rate is not None
        and min_pass_rate >= 100
        and max_failures is not None
        and max_failures <= 0
        and pilot_app_id_value(label, row) is not None
        and pilot_app_root_value(label, row) is not None
        and pilot_app_artifact_value(label, row) is not None
        and device_ok
    )


def pilot_threshold_reason(label, row):
    reasons = []
    runs = structured_numeric_value(row, "runs")
    min_pass_rate = structured_numeric_value(row, "minPassRate")
    max_failures = structured_numeric_value(row, "maxFailures")
    if runs is None:
        reasons.append("structured runs evidence present")
    elif runs < 20:
        reasons.append("runs >= 20")
    if min_pass_rate is None:
        reasons.append("structured minPassRate evidence present")
    elif min_pass_rate < 100:
        reasons.append("minPassRate >= 100")
    if max_failures is None:
        reasons.append("structured maxFailures evidence present")
    elif max_failures > 0:
        reasons.append("maxFailures <= 0")
    if pilot_app_id_value(label, row) is None:
        reasons.append("appId present")
    if pilot_app_root_value(label, row) is None:
        reasons.append("app root evidence present")
    if pilot_app_artifact_value(label, row) is None:
        reasons.append("app artifact evidence present")
    if label == "Android hardware pilot" and android_device_value(row) is None:
        reasons.append("Android device identifier present")
    if label == "iOS simulator hardware pilot" and ios_device_value(row) is None:
        reasons.append("iOS simulator device identifier present")
    if label == "iOS physical hardware pilot" and physical_ios_device_value(row) is None:
        reasons.append("physical device identifier present")
    return "requires " + ", ".join(reasons)


def benchmark_thresholds_pass(row):
    min_candidate_pass_rate = numeric_value(row, "minCandidatePassRate", "--min-candidate-pass-rate")
    max_candidate_failures = numeric_value(row, "maxCandidateFailures", "--max-candidate-failures")
    min_mean_speedup = numeric_value(row, "minMeanSpeedup", "--min-mean-speedup")
    min_p95_speedup = numeric_value(row, "minP95Speedup", "--min-p95-speedup")
    candidate_pass_rate = structured_numeric_value(row, "candidatePassRate")
    candidate_failures = structured_numeric_value(row, "candidateFailures")
    candidate_runs = structured_numeric_value(row, "candidateRuns")
    baseline_runs = structured_numeric_value(row, "baselineRuns")
    mean_speedup = structured_numeric_value(row, "meanSpeedup")
    p95_speedup = structured_numeric_value(row, "p95Speedup")
    return (
        min_candidate_pass_rate is not None
        and min_candidate_pass_rate >= 100
        and max_candidate_failures is not None
        and max_candidate_failures <= 0
        and min_mean_speedup is not None
        and min_mean_speedup >= 1.25
        and min_p95_speedup is not None
        and min_p95_speedup >= 1.25
        and benchmark_candidate_value(row) is not None
        and benchmark_baseline_value(row) is not None
        and benchmark_results_value(row) is not None
        and benchmark_same_context_pass(row)
        and candidate_runs is not None
        and candidate_runs >= 20
        and baseline_runs is not None
        and baseline_runs >= 20
        and candidate_pass_rate is not None
        and candidate_pass_rate >= min_candidate_pass_rate
        and candidate_failures is not None
        and candidate_failures <= max_candidate_failures
        and mean_speedup is not None
        and mean_speedup >= min_mean_speedup
        and p95_speedup is not None
        and p95_speedup >= min_p95_speedup
    )


def benchmark_same_context_pass(row):
    if row.get("sameContext") is not True:
        return False
    context = row.get("context")
    if not isinstance(context, dict):
        return False
    required = ("platform", "device", "appId", "scenario", "appBuild")
    return all(concrete_value(context.get(field)) for field in required)


def benchmark_candidate_value(row):
    flags = command_flags(row)
    candidates = [
        row.get("candidate"),
        row.get("candidateName"),
        flags.get("--candidate"),
    ]
    for candidate in candidates:
        if concrete_value(candidate):
            return candidate
    return None


def benchmark_baseline_value(row):
    flags = command_flags(row)
    candidates = [
        row.get("baseline"),
        row.get("baselineName"),
        flags.get("--baseline"),
    ]
    for candidate in candidates:
        if concrete_value(candidate):
            return candidate
    return None


def benchmark_results_value(row):
    flags = command_flags(row)
    candidates = [
        row.get("results"),
        row.get("resultsPath"),
        flags.get("--results"),
    ]
    for candidate in candidates:
        if concrete_value(candidate):
            return candidate
    return None


def benchmark_threshold_reason(row):
    reasons = []
    min_candidate_pass_rate = numeric_value(row, "minCandidatePassRate", "--min-candidate-pass-rate")
    max_candidate_failures = numeric_value(row, "maxCandidateFailures", "--max-candidate-failures")
    min_mean_speedup = numeric_value(row, "minMeanSpeedup", "--min-mean-speedup")
    min_p95_speedup = numeric_value(row, "minP95Speedup", "--min-p95-speedup")
    candidate_pass_rate = structured_numeric_value(row, "candidatePassRate")
    candidate_failures = structured_numeric_value(row, "candidateFailures")
    candidate_runs = structured_numeric_value(row, "candidateRuns")
    baseline_runs = structured_numeric_value(row, "baselineRuns")
    mean_speedup = structured_numeric_value(row, "meanSpeedup")
    p95_speedup = structured_numeric_value(row, "p95Speedup")
    if min_candidate_pass_rate is None or min_candidate_pass_rate < 100:
        reasons.append("minCandidatePassRate >= 100")
    if max_candidate_failures is None or max_candidate_failures > 0:
        reasons.append("maxCandidateFailures <= 0")
    if min_mean_speedup is None or min_mean_speedup < 1.25:
        reasons.append("minMeanSpeedup >= 1.25")
    if min_p95_speedup is None or min_p95_speedup < 1.25:
        reasons.append("minP95Speedup >= 1.25")
    if benchmark_candidate_value(row) is None:
        reasons.append("candidate name present")
    if benchmark_baseline_value(row) is None:
        reasons.append("baseline name present")
    if benchmark_results_value(row) is None:
        reasons.append("results path present")
    if not benchmark_same_context_pass(row):
        reasons.append("same benchmark context evidence present")
    if candidate_runs is None or candidate_runs < 20:
        reasons.append("candidateRuns >= 20")
    if baseline_runs is None or baseline_runs < 20:
        reasons.append("baselineRuns >= 20")
    if (
        min_candidate_pass_rate is not None
        and candidate_pass_rate is None
        or (
            min_candidate_pass_rate is not None
            and candidate_pass_rate is not None
            and candidate_pass_rate < min_candidate_pass_rate
        )
    ):
        reasons.append("candidatePassRate >= minCandidatePassRate")
    if (
        max_candidate_failures is not None
        and candidate_failures is None
        or (
            max_candidate_failures is not None
            and candidate_failures is not None
            and candidate_failures > max_candidate_failures
        )
    ):
        reasons.append("candidateFailures <= maxCandidateFailures")
    if (
        min_mean_speedup is not None
        and mean_speedup is None
        or (
            min_mean_speedup is not None
            and mean_speedup is not None
            and mean_speedup < min_mean_speedup
        )
    ):
        reasons.append("meanSpeedup >= minMeanSpeedup")
    if (
        min_p95_speedup is not None
        and p95_speedup is None
        or (
            min_p95_speedup is not None
            and p95_speedup is not None
            and p95_speedup < min_p95_speedup
        )
    ):
        reasons.append("p95Speedup >= minP95Speedup")
    return "requires " + ", ".join(reasons)


agent_workflow_fields = (
    "agentWorkflow",
    "mcp",
    "jsonRpc",
    "semanticSnapshot",
    "typedActions",
    "traceEvents",
    "traceExplain",
    "traceExplore",
    "traceDiscover",
    "scenarioValidation",
    "redactedExport",
)


def agent_workflow_pass(row):
    command = row.get("command")
    if row.get("name") == "local release gate" and isinstance(command, str) and "release-gate.sh" in command:
        return True
    return all(row.get(field) is True for field in agent_workflow_fields)


def agent_workflow_reason(row):
    command = row.get("command")
    if row.get("name") == "local release gate" and (not isinstance(command, str) or "release-gate.sh" not in command):
        return "requires release-gate.sh or structured agentWorkflow evidence"
    missing = [field for field in agent_workflow_fields if row.get(field) is not True]
    if missing:
        return "requires release-gate.sh or structured agentWorkflow evidence: " + ", ".join(missing)
    return "requires release-gate.sh or structured agentWorkflow evidence"


def row_satisfies(label, row):
    if row.get("status") != "passed":
        return False
    if label in {
        "Android hardware pilot",
        "iOS simulator hardware pilot",
        "iOS physical hardware pilot",
    }:
        return pilot_thresholds_pass(label, row)
    if label == "physical iOS readiness":
        return physical_ios_device_value(row) is not None
    if label == "competitive benchmark comparison":
        return benchmark_thresholds_pass(row)
    if label == "agent workflow smoke":
        return agent_workflow_pass(row)
    return True


def has_passed_evidence(label, names):
    if isinstance(names, str):
        names = (names,)
    return any(row.get("name") in names and row_satisfies(label, row) for row in rows)


def requirement_status(label, names):
    if isinstance(names, str):
        names = (names,)
    matches = [row for row in rows if row.get("name") in names]
    for row in matches:
        if row_satisfies(label, row):
            return {
                "name": label,
                "status": "satisfied",
                "evidenceName": row.get("name", ""),
            }
    for row in matches:
        if row.get("status") == "failed":
            return {
                "name": label,
                "status": "failed",
                "evidenceName": row.get("name", ""),
                "reason": "evidence row failed",
            }
    for row in matches:
        if row.get("status") == "planned":
            return {
                "name": label,
                "status": "planned",
                "evidenceName": row.get("name", ""),
                "reason": "evidence row is planned but not executed",
            }
    for row in matches:
        if row.get("status") == "passed":
            reason = "passed evidence row does not satisfy this requirement"
            if label in {
                "Android hardware pilot",
                "iOS simulator hardware pilot",
                "iOS physical hardware pilot",
            }:
                reason = pilot_threshold_reason(label, row)
            elif label == "physical iOS readiness":
                reason = "requires concrete physical device identifier evidence"
            elif label == "competitive benchmark comparison":
                reason = benchmark_threshold_reason(row)
            elif label == "agent workflow smoke":
                reason = agent_workflow_reason(row)
            return {
                "name": label,
                "status": "insufficient",
                "evidenceName": row.get("name", ""),
                "reason": reason,
            }
    return {
        "name": label,
        "status": "missing",
        "reason": "no matching passed evidence row",
    }


passed_names = {row.get("name") for row in rows if row.get("status") == "passed"}

requirements = [
    ("local release gate", "local release gate"),
    ("public Android demo", ("public Android emulator demo", "public Android demo app build")),
    ("public iOS simulator demo", "public iOS simulator demo"),
]

if target in ("production", "market-claim"):
    requirements.extend([
        ("agent workflow smoke", ("agent workflow smoke", "local release gate")),
        ("physical iOS readiness", "physical iOS readiness"),
        ("Android hardware pilot", "Android hardware pilot"),
        ("iOS simulator hardware pilot", "iOS simulator hardware pilot"),
        ("iOS physical hardware pilot", "iOS physical hardware pilot"),
    ])

if target == "market-claim":
    requirements.append(("competitive benchmark comparison", ("competitive benchmark comparison", "benchmark comparison")))

missing_file_labels = [f"evidence file not found: {path}" for path in missing_evidence_files]
invalid_evidence_labels = [
    f"invalid evidence JSONL in {path} at line {line}: {error}"
    for path, line, error in invalid_evidence_lines
]
evidence_issue_labels = missing_file_labels + invalid_evidence_labels

requirement_results = [requirement_status(label, names) for label, names in requirements]
missing = evidence_issue_labels + [
    item["name"] for item in requirement_results if item.get("status") == "missing"
]
insufficient = [
    item["name"] for item in requirement_results if item.get("status") == "insufficient"
]
if run_evidence is not None and not run_evidence["certificationReady"]:
    insufficient.append("run certification evidence")
failed_evidence_labels = [f"failed evidence: {name}" for name in failed]
planned_evidence_labels = [f"planned evidence: {name}" for name in planned]
blocked = (
    evidence_issue_labels
    + failed_evidence_labels
    + planned_evidence_labels
    + [item["name"] for item in requirement_results if item.get("status") != "satisfied"]
)
if run_evidence is not None and not run_evidence["certificationReady"]:
    blocked.append("run certification evidence")
ok = not blocked
status = "ready" if ok else "blocked"

def grouped_simulator_pilot_command(evidence_out):
    return (
        "zmr-pilot-gate --android --ios "
        "--android-app-root /path/to/mobile-app "
        "--android-app-id <android-app-id> "
        "--android-device <android-serial> "
        "--ios-app-root /path/to/mobile-app "
        "--ios-app-path /path/to/mobile-app/build/Debug-iphonesimulator/Sample.app "
        "--ios-app-id <ios-app-id> "
        "--ios-device booted "
        "--ios-shim /path/to/mobile-app/.zmr/ios-shim "
        "--runs 20 "
        "--min-pass-rate 100 "
        "--max-failures 0 "
        f"--evidence-out {evidence_out}"
    )


def physical_ios_pilot_command(evidence_out):
    return (
        "zmr-pilot-gate --ios "
        "--ios-device-type physical "
        "--ios-device <physical-device-id> "
        "--ios-app-root /path/to/mobile-app "
        "--ios-app-path /path/to/mobile-app/build/Release-iphoneos/Sample.ipa "
        "--ios-app-id <ios-app-id> "
        "--ios-shim /path/to/mobile-app/.zmr/ios-shim "
        "--runs 20 "
        "--min-pass-rate 100 "
        "--max-failures 0 "
        f"--evidence-out {evidence_out}"
    )


default_pilot_evidence = "/path/to/mobile-app/traces/zmr-pilots/evidence.jsonl"

next_step_commands = {
    "local release gate": ["./scripts/release-candidate.sh --mode local"],
    "public Android demo": ["zmr-demo-android --runs 5"],
    "public iOS simulator demo": ["zmr-demo-ios --runs 5"],
    "agent workflow smoke": ["./scripts/release-gate.sh"],
    "physical iOS readiness": [physical_ios_pilot_command(default_pilot_evidence)],
    "Android hardware pilot": [grouped_simulator_pilot_command(default_pilot_evidence)],
    "iOS simulator hardware pilot": [grouped_simulator_pilot_command(default_pilot_evidence)],
    "iOS physical hardware pilot": [physical_ios_pilot_command(default_pilot_evidence)],
    "competitive benchmark comparison": [
        "zmr-benchmark --zmr .zmr/android-smoke.json --platform <platform> --device <device-id> --app-id <app-id> --app-build <build-id-or-artifact> --runs 20 --trace-root traces/bench-comparison/zmr --results traces/bench-comparison/results.jsonl --replace --min-pass-rate 100 --max-failures 0",
        "zmr-benchmark-command --tool <baseline-name> --platform <platform> --device <device-id> --app-id <app-id> --scenario .zmr/android-smoke.json --app-build <build-id-or-artifact> --runs 20 --trace-root traces/bench-comparison/baseline --results traces/bench-comparison/results.jsonl -- <baseline command>",
        "zmr-compare-benchmarks --results traces/bench-comparison/results.jsonl --candidate zmr --baseline <baseline-name> --min-candidate-pass-rate 100 --max-candidate-failures 0 --min-mean-speedup 1.25 --min-p95-speedup 1.25 --out traces/bench-comparison/report.md --evidence-out traces/bench-comparison/evidence.jsonl",
    ],
    "run certification evidence": [
        "zmr-release-readiness --evidence <evidence.jsonl> --run-summary <publication-dir> --attempt-index <publication-dir>/attempt-index.json --target production --json"
    ],
}


def fallback_next_step_commands(item):
    if item.startswith("evidence file not found: "):
        evidence_path = item.removeprefix("evidence file not found: ")
        if target == "dev-preview":
            evidence_dir = os.path.dirname(evidence_path) or "."
            return [f"./scripts/release-candidate.sh --mode local --evidence-dir {shlex.quote(evidence_dir)}"]
        quoted_evidence_path = shlex.quote(evidence_path)
        commands = [
            grouped_simulator_pilot_command(quoted_evidence_path),
            physical_ios_pilot_command(quoted_evidence_path),
        ]
        if target == "market-claim":
            commands.extend([
                "zmr-benchmark --zmr .zmr/android-smoke.json --platform <platform> --device <device-id> --app-id <app-id> --app-build <build-id-or-artifact> --runs 20 --trace-root traces/bench-comparison/zmr --results traces/bench-comparison/results.jsonl --replace --min-pass-rate 100 --max-failures 0",
                "zmr-benchmark-command --tool <baseline-name> --platform <platform> --device <device-id> --app-id <app-id> --scenario .zmr/android-smoke.json --app-build <build-id-or-artifact> --runs 20 --trace-root traces/bench-comparison/baseline --results traces/bench-comparison/results.jsonl -- <baseline command>",
                "zmr-compare-benchmarks --results traces/bench-comparison/results.jsonl --candidate zmr --baseline <baseline-name> --min-candidate-pass-rate 100 --max-candidate-failures 0 --min-mean-speedup 1.25 --min-p95-speedup 1.25 --out traces/bench-comparison/report.md "
                f"--evidence-out {quoted_evidence_path}",
            ])
        return commands
    if item.startswith("invalid evidence JSONL in "):
        evidence_path = item.removeprefix("invalid evidence JSONL in ").split(" at line ", 1)[0]
        quoted_evidence_path = shlex.quote(evidence_path)
        return [f"zmr-release-readiness --evidence {quoted_evidence_path} --target {target} --json"]
    if item.startswith("failed evidence: "):
        evidence_name = item.removeprefix("failed evidence: ")
        command = evidence_command("failed", evidence_name)
        if command is not None:
            return [command]
        return [f"zmr-release-readiness --target {target} --json"]
    if item.startswith("planned evidence: "):
        evidence_name = item.removeprefix("planned evidence: ")
        command = evidence_command("planned", evidence_name)
        if command is not None:
            return [command]
        return [f"zmr-release-readiness --target {target} --json"]
    return [f"zmr-pilot-gate --android --ios --evidence-out {shlex.quote(item)}"]


def evidence_command(status, name):
    for row in rows:
        if row.get("status") != status or row.get("name") != name:
            continue
        command = row.get("command")
        if concrete_value(command):
            return command
    return None


def make_next_step(requirement, commands, covers=None):
    if covers is None:
        covers = [requirement]
    return {
        "requirement": requirement,
        "command": " && ".join(commands),
        "commands": commands,
        "covers": covers,
    }


def append_next_step(next_steps, requirement, commands, covers=None):
    next_steps.append(make_next_step(requirement, commands, covers))


def append_grouped_next_steps(blocked_items):
    next_steps = []
    handled = set()

    def missing_file_covers(item):
        covers = [item]
        if target in ("production", "market-claim"):
            covers.extend([
                "physical iOS readiness",
                "Android hardware pilot",
                "iOS simulator hardware pilot",
                "iOS physical hardware pilot",
            ])
        if target == "market-claim":
            covers.append("competitive benchmark comparison")
        return [cover for cover in covers if cover in blocked_items]

    for item in blocked_items:
        if not item.startswith("evidence file not found: "):
            continue
        commands = fallback_next_step_commands(item)
        covers = missing_file_covers(item)
        append_next_step(next_steps, item, commands, covers)
        handled.update(covers)

    def maybe_group(requirements, label, commands):
        present = [item for item in requirements if item in blocked_items]
        if any(item in handled for item in present):
            return
        if len(present) == len(requirements):
            append_next_step(next_steps, label, commands, present)
            handled.update(present)

    maybe_group(
        ["local release gate", "agent workflow smoke"],
        "local release gate + agent workflow smoke",
        ["./scripts/release-candidate.sh --mode local"],
    )
    maybe_group(
        ["Android hardware pilot", "iOS simulator hardware pilot"],
        "Android hardware pilot + iOS simulator hardware pilot",
        [grouped_simulator_pilot_command(default_pilot_evidence)],
    )
    maybe_group(
        ["physical iOS readiness", "iOS physical hardware pilot"],
        "physical iOS readiness + iOS physical hardware pilot",
        [physical_ios_pilot_command(default_pilot_evidence)],
    )

    for item in blocked_items:
        if item in handled:
            continue
        commands = next_step_commands.get(item) or fallback_next_step_commands(item)
        append_next_step(next_steps, item, commands)
    return next_steps


next_steps = append_grouped_next_steps(blocked)

def claim_label(target):
    if target == "market-claim":
        return "market claim"
    if target == "dev-preview":
        return "developer-preview claim"
    return f"{target} claim"


def claim_guidance(target, ok, missing, insufficient, invalid_evidence, failed, planned):
    limitations = []
    if not ok:
        missing_for_guidance = [item for item in missing if item not in invalid_evidence]
        if missing_for_guidance:
            limitations.append("missing evidence")
        if insufficient:
            limitations.append("insufficient evidence")
        if invalid_evidence:
            limitations.append("invalid evidence")
        if failed:
            limitations.append("failed evidence")
        if planned:
            limitations.append("planned evidence is not proof")
        blockers = []
        if missing_for_guidance:
            blockers.append(f"Missing evidence: {', '.join(missing_for_guidance)}.")
        if insufficient:
            blockers.append(f"Insufficient evidence: {', '.join(insufficient)}.")
        if invalid_evidence:
            blockers.append(f"Invalid evidence: {', '.join(invalid_evidence)}.")
        if failed:
            blockers.append(f"Failed evidence: {', '.join(failed)}.")
        if planned:
            blockers.append(f"Planned evidence is not proof: {', '.join(planned)}.")
        return (
            f"Do not publish the {claim_label(target)} yet. {' '.join(blockers)}"
        ), limitations
    if target == "dev-preview":
        return (
            "ZMR is ready to publish as a public developer preview. Do not describe it as production-stable or competitively better without production and market-claim evidence."
        ), ["production-stable", "competitive leadership"]
    if target == "production":
        return (
            "ZMR has evidence for production readiness for the checked app/device matrix. Do not make competitive claims without market-claim evidence."
        ), ["competitive leadership"]
    return (
        "ZMR has evidence for the checked competitive claim. Publish the benchmark report, device state, app path, thresholds, and trace evidence with the claim."
    ), []

recommended_wording, claim_limitations = claim_guidance(target, ok, missing, insufficient, invalid_evidence_labels, failed, planned)
satisfied = [item["name"] for item in requirement_results if item.get("status") == "satisfied"]

result = {
    "ok": ok,
    "target": target,
    "status": status,
    "evidence": evidence_paths[0],
    "evidenceFiles": evidence_paths,
    "passed": sorted(name for name in passed_names if name),
    "satisfied": satisfied,
    "failed": failed,
    "planned": planned,
    "missing": missing,
    "insufficient": insufficient,
    "blocked": blocked,
    "requirements": requirement_results,
    "nextSteps": next_steps,
    "recommendedWording": recommended_wording,
    "claimLimitations": claim_limitations,
}
if run_evidence is not None:
    result["runEvidence"] = run_evidence

if json_mode:
    print(json.dumps(result, separators=(",", ":")))
else:
    print(f"ZMR release readiness: {status}")
    print(f"target: {target}")
    if len(evidence_paths) == 1:
        print(f"evidence: {evidence_paths[0]}")
    else:
        print("evidence:")
        for evidence_path in evidence_paths:
            print(f"- {evidence_path}")
    if satisfied:
        print("")
        print("Satisfied requirements:")
        for item in satisfied:
            print(f"- {item}")
    if blocked:
        print("")
        print("Blocked requirements:")
        for item in requirement_results:
            if item.get("status") == "satisfied":
                continue
            reason = item.get("reason")
            if reason:
                print(f"- {item['name']}: {item['status']} - {reason}")
            else:
                print(f"- {item['name']}: {item['status']}")
    if missing:
        print("")
        print("Missing evidence:")
        for item in missing:
            print(f"- {item}")
    if failed:
        print("")
        print("Failed evidence:")
        for item in failed:
            print(f"- {item}")
    if planned:
        print("")
        print("Planned but not executed:")
        for item in planned:
            print(f"- {item}")
    print("")
    print(f"Recommended wording: {recommended_wording}")
    if claim_limitations:
        print("Claim limitations:")
        for item in claim_limitations:
            print(f"- {item}")
    if next_steps:
        print("")
        print("Next steps:")
        for item in next_steps:
            print(f"- {item['requirement']}: {item['command']}")
    if run_evidence is not None:
        print("")
        print("Run evidence:")
        print(f"- attempts: {run_evidence['attempts']}")
        print(f"- logical executions: {run_evidence['logicalExecutions']}")
        print(f"- eligible logical executions: {run_evidence['eligibleLogicalExecutions']}")
        print(f"- certification ready: {str(run_evidence['certificationReady']).lower()}")
        for reason in run_evidence["blockingReasons"]:
            print(f"- blocker: {reason}")

sys.exit(0 if ok else 1)
