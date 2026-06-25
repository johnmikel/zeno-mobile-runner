# Security Policy

ZMR is a local mobile automation runner. It can collect screenshots, UI trees,
logs, app identifiers, device metadata, scenario inputs, and trace events.
Treat raw traces as sensitive by default, especially when they come from a
private app or a signed device build.

## Supported Versions

The current supported line is the latest `0.2.x` developer preview. Security
fixes should target `main` and the latest published preview release until a
stable release exists.

## Reporting A Vulnerability

Open a private security advisory on GitHub when available. If private advisory
reporting is not enabled, contact the repository maintainer through the channel
listed in the project profile.

Include:

- ZMR version and platform.
- Reproduction steps.
- Whether the issue exposes screenshots, logs, trace data, credentials, or
  device access.
- A minimal scenario or redacted `.zmrtrace` bundle when possible.

Do not publish raw traces from private apps in public issues.

## Trace Handling

- Use `zmr export --redact` before sharing trace bundles.
- Add `--omit-screenshots` when visual artifacts may include personal,
  customer, or proprietary data.
- Do not share raw screenshot artifacts from private apps.
- Do not paste logs that include tokens, emails, API keys, or device identifiers.
- Keep `.zmr/` app configuration free of secrets; use the app's normal secure
  configuration path for credentials.
- Prefer fake-device reproductions for public bug reports.
