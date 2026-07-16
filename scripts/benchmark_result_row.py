#!/usr/bin/env python3
import argparse
import json
from pathlib import Path


def parse_args():
    parser = argparse.ArgumentParser(description="Build one benchmark results JSON row.")
    parser.add_argument("--tool", required=True)
    parser.add_argument("--run", required=True, type=int)
    parser.add_argument("--command-status", required=True, type=int)
    parser.add_argument("--duration-ms", required=True, type=int)
    parser.add_argument("--trace-dir", required=True)
    parser.add_argument("--public-trace-dir")
    parser.add_argument("--platform")
    parser.add_argument("--device")
    parser.add_argument("--app-id")
    parser.add_argument("--scenario")
    parser.add_argument("--app-build")
    return parser.parse_args()


def read_zmr_trace(trace_dir):
    events_path = Path(trace_dir) / "events.jsonl"
    if not events_path.exists():
        return {}

    last_step_error = {}
    last_scenario_end = {}

    with events_path.open(encoding="utf-8") as events:
        for line in events:
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue

            payload = event.get("payload")
            if not isinstance(payload, dict):
                payload = {}

            if event.get("kind") == "step.error":
                last_step_error = payload
            elif event.get("kind") == "scenario.end":
                last_scenario_end = payload

    trace = {}
    if "status" in last_scenario_end:
        trace["traceStatus"] = last_scenario_end["status"]
    if "error" in last_scenario_end:
        trace["traceError"] = last_scenario_end["error"]
    elif "error" in last_step_error:
        trace["traceError"] = last_step_error["error"]
    if "failedStepIndex" in last_scenario_end:
        trace["failedStepIndex"] = last_scenario_end["failedStepIndex"]
    elif "index" in last_step_error:
        trace["failedStepIndex"] = last_step_error["index"]
    return trace


def main():
    args = parse_args()
    row = {
        "tool": args.tool,
        "run": args.run,
        "status": "ok" if args.command_status == 0 else "failed",
        "durationMs": args.duration_ms,
        "traceDir": args.public_trace_dir or args.trace_dir,
    }
    metadata = {
        "platform": args.platform,
        "device": args.device,
        "appId": args.app_id,
        "scenario": args.scenario,
        "appBuild": args.app_build,
    }
    row.update({key: value for key, value in metadata.items() if value})

    if args.tool == "zmr":
        row.update(read_zmr_trace(args.trace_dir))

    print(json.dumps(row, separators=(",", ":")))


if __name__ == "__main__":
    main()
