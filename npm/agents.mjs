import {
  devClientReportCommand,
  matrixCommand,
  pilotGateCommand,
  readinessCommand,
  reliabilityCommand,
  smokeReportCommand,
  smokeRunCommand,
  validateCommand,
} from "./commands.mjs";

export function nextStepCommands(config, { android = true, ios = true, packageScripts = false } = {}) {
  const command = (scriptName, directCommand) => ({
    label: scriptName,
    command: packageScripts ? `npm run ${scriptName}` : directCommand,
  });
  const steps = [];
  if (android) {
    steps.push(command("zmr:android", config.scripts.android));
    steps.push(command("zmr:android:report", config.scripts.androidReport));
    if (config.scripts.androidDevClient) steps.push(command("zmr:android:dev-client", config.scripts.androidDevClient));
    if (config.scripts.androidDevClientReport) steps.push(command("zmr:android:dev-client:report", config.scripts.androidDevClientReport));
    steps.push(command("zmr:android:reliability", config.scripts.androidReliability));
  }
  if (ios) {
    steps.push(command("zmr:ios", config.scripts.ios));
    steps.push(command("zmr:ios:report", config.scripts.iosReport));
    if (config.scripts.iosDevClient) steps.push(command("zmr:ios:dev-client", config.scripts.iosDevClient));
    if (config.scripts.iosDevClientReport) steps.push(command("zmr:ios:dev-client:report", config.scripts.iosDevClientReport));
    steps.push(command("zmr:ios:reliability", config.scripts.iosReliability));
  }
  if (android || ios) {
    steps.push(command("zmr:matrix", config.scripts.matrix));
    steps.push(command("zmr:pilot", config.scripts.pilotGate));
    if (android && ios) steps.push(command("zmr:readiness", config.scripts.readiness));
  }
  steps.push(command("zmr:serve", config.scripts.serve));
  steps.push(command("zmr:mcp", config.scripts.mcp));
  steps.push(command("zmr:explain", config.scripts.explain));
  steps.push(command("zmr:export", config.scripts.exportTrace));
  steps.push(command("zmr:schemas", config.scripts.schemas));
  steps.push(command("zmr:validate", config.scripts.validate));
  steps.push(command("zmr:doctor", config.scripts.doctor));
  return steps;
}

export function agentInstructions(appId, { android = true, ios = true, packageScripts = false, scripts = {} } = {}) {
  const command = (name, fallback) => scripts[name] ?? fallback;
  const appCommand = (scriptName, directCommand) => packageScripts ? `npm run ${scriptName}` : directCommand;
  const inspectCommand = "zmr inspect --json --dir .";
  const doctorCommand = appCommand("zmr:doctor", command("doctor", "zmr doctor --strict --json --config .zmr/config.json"));
  const schemasCommand = appCommand("zmr:schemas", command("schemas", "zmr schemas --json"));
  const validateDirectCommand = command("validate", validateCommand({ android, ios }));
  const validateAppCommand = appCommand("zmr:validate", validateDirectCommand);
  const serveCommand = appCommand("zmr:serve", command("serve", "zmr serve --transport stdio --config .zmr/config.json --trace-dir traces/zmr-agent"));
  const mcpCommand = appCommand("zmr:mcp", command("mcp", "zmr mcp --config .zmr/config.json --trace-dir traces/zmr-agent"));
  const explainCommand = appCommand("zmr:explain", command("explain", "zmr explain traces/zmr-agent --json"));
  const exportCommand = appCommand("zmr:export", command("exportTrace", "zmr export traces/zmr-agent --out traces/zmr-agent-redacted.zmrtrace --redact"));
  const setupChecks = [
    inspectCommand,
    doctorCommand,
    schemasCommand,
    validateAppCommand,
  ];
  const directRuns = [];
  const nextStepScripts = {
    doctor: command("doctor", "zmr doctor --strict --json --config .zmr/config.json"),
    schemas: command("schemas", "zmr schemas --json"),
    matrix: command("matrix", matrixCommand()),
    pilotGate: command("pilotGate", pilotGateCommand({ android, ios, appId })),
    serve: command("serve", "zmr serve --transport stdio --config .zmr/config.json --trace-dir traces/zmr-agent"),
    mcp: command("mcp", "zmr mcp --config .zmr/config.json --trace-dir traces/zmr-agent"),
    explain: command("explain", "zmr explain traces/zmr-agent --json"),
    exportTrace: command("exportTrace", "zmr export traces/zmr-agent --out traces/zmr-agent-redacted.zmrtrace --redact"),
  };
  nextStepScripts.validate = validateDirectCommand;
  if (android) {
    directRuns.push(appCommand("zmr:android", command("android", smokeRunCommand({ platform: "android" }))));
    directRuns.push(appCommand("zmr:android:report", command("androidReport", smokeReportCommand({ platform: "android" }))));
    nextStepScripts.android = command("android", smokeRunCommand({ platform: "android" }));
    nextStepScripts.androidReport = command("androidReport", smokeReportCommand({ platform: "android" }));
    if (scripts.androidDevClient) {
      directRuns.push(appCommand("zmr:android:dev-client", scripts.androidDevClient));
      directRuns.push(appCommand("zmr:android:dev-client:report", command("androidDevClientReport", scripts.androidDevClientReport ?? devClientReportCommand({ platform: "android" }))));
      nextStepScripts.androidDevClient = command("androidDevClient", scripts.androidDevClient);
      nextStepScripts.androidDevClientReport = command("androidDevClientReport", scripts.androidDevClientReport ?? devClientReportCommand({ platform: "android" }));
    }
    nextStepScripts.androidReliability = command("androidReliability", reliabilityCommand({
      scenario: ".zmr/android-smoke.json",
      device: "emulator-5554",
      appId,
      traceRoot: "traces/zmr-android-reliability",
      maxP95Ms: 30000,
    }));
  }
  if (ios) {
    directRuns.push(appCommand("zmr:ios", command("ios", smokeRunCommand({ platform: "ios" }))));
    directRuns.push(appCommand("zmr:ios:report", command("iosReport", smokeReportCommand({ platform: "ios" }))));
    nextStepScripts.ios = command("ios", smokeRunCommand({ platform: "ios" }));
    nextStepScripts.iosReport = command("iosReport", smokeReportCommand({ platform: "ios" }));
    if (scripts.iosDevClient) {
      directRuns.push(appCommand("zmr:ios:dev-client", scripts.iosDevClient));
      directRuns.push(appCommand("zmr:ios:dev-client:report", command("iosDevClientReport", scripts.iosDevClientReport ?? devClientReportCommand({ platform: "ios" }))));
      nextStepScripts.iosDevClient = command("iosDevClient", scripts.iosDevClient);
      nextStepScripts.iosDevClientReport = command("iosDevClientReport", scripts.iosDevClientReport ?? devClientReportCommand({ platform: "ios" }));
    }
    nextStepScripts.iosReliability = command("iosReliability", reliabilityCommand({
      scenario: ".zmr/ios-smoke.json",
      platform: "ios",
      device: "booted",
      appId,
      xcrun: "xcrun",
      traceRoot: "traces/zmr-ios-reliability",
      maxP95Ms: 45000,
    }));
  }
  if (android && ios) {
    nextStepScripts.readiness = command("readiness", readinessCommand());
  }
  const readinessCommandText = appCommand("zmr:readiness", command("readiness", readinessCommand()));
  const appSectionTitle = packageScripts ? "App Scripts" : "App Commands";
  const appSectionCommands = nextStepCommands({ scripts: nextStepScripts }, { android, ios, packageScripts })
    .map((step) => step.command);
  appSectionCommands.unshift(inspectCommand);
  const releaseClaims = android && ios
    ? `\`\`\`bash
${readinessCommandText}
\`\`\`

Do not claim production readiness from smoke runs alone. Use \`satisfied\` for proven requirements; do not infer readiness from raw \`passed\` evidence. Use \`recommendedWording\` and keep \`claimLimitations\` intact when summarizing readiness. When readiness is blocked, follow \`nextSteps[].commands\` in order. Use \`nextSteps[].covers\` to map each command back to the blocked requirements it resolves.`
    : "Do not claim production readiness from a single-platform setup. Enable Android and iOS, then collect the full pilot evidence matrix before running the production readiness gate.";

  return `# ZMR Agent Instructions

App id: \`${appId}\`

Start from the app checkout. Keep generated scenarios and config under \`.zmr/\`, and write run output under \`traces/\`.

## Setup Checks

\`\`\`bash
${setupChecks.join("\n")}
\`\`\`

## Interactive Agent Session

\`\`\`bash
${serveCommand}
${mcpCommand}
\`\`\`

Use \`semantic_snapshot\` before choosing tap or type actions. Prefer selectors from accessibility identifiers, resource ids, labels, or exact text before coordinates. Export redacted traces before sharing artifacts.

## Discover From Trace

\`\`\`bash
zmr discover --from-trace traces/zmr-agent --out .zmr/discovered/replay-smoke.json --include-actions --validate --json
zmr draft --from-trace traces/zmr-agent --out .zmr/discovered/surface-smoke.json --json
zmr validate --json .zmr/discovered/surface-smoke.json
zmr draft --from-trace traces/zmr-agent --out .zmr/discovered/replay-smoke.json --include-actions --json
zmr validate --json .zmr/discovered/replay-smoke.json
\`\`\`

Treat discover output as a reviewable starting point. It writes from trace evidence and validates the generated file when \`--validate\` is present, but it does not crawl, invent missing actions, discover credentials, or commit tests. Treat draft output as a reviewable starting point when using the lower-level split workflow. The default draft contains only \`launch\`, \`snapshot\`, and conservative \`assertVisible\` checks. Use \`--include-actions\` only when the trace came from a reviewed agent session; unsupported events are skipped with warnings instead of guessed. Do not commit a discovered or drafted scenario until a human has reviewed and rerun it.

## Failure Triage

\`\`\`bash
${explainCommand}
\`\`\`

Use the JSON explanation before editing selectors. It includes the terminal status, partial visual-capture diagnostics, and the last useful failure context.

## Trace Sharing

\`\`\`bash
${exportCommand}
\`\`\`

Add \`--omit-screenshots\` when visual artifacts may contain sensitive data.

## Smoke Runs

\`\`\`bash
${directRuns.join("\n")}
\`\`\`

## Release Claims

${releaseClaims}

## ${appSectionTitle}

\`\`\`bash
${appSectionCommands.join("\n")}
\`\`\`
`;
}
