# Support Matrix

Use this page to decide what ZMR can claim today, what needs app-local proof,
and what is still outside the preview. ZMR is intended as an AI-agent-first
replacement path for mobile automation: agents observe UI state, choose typed
actions, validate generated scenarios, and export trace evidence that can replay
in CI without an LLM.

Support is claimed only when ZMR has lifecycle, observation, selector/action,
trace, and repeat-run evidence for the target class.

For app-team claims, start by generating an evidence workspace:

```bash
zmr-support-evidence --out .zmr/support-evidence --app-id com.example.mobiletest
```

The generated matrix and pilot commands keep Android, iPhone, and iPad targets
separate while using the existing `zmr-device-matrix` and `zmr-pilot-gate`
execution paths.

| Target | Status | Evidence standard | Notes |
| --- | --- | --- | --- |
| Android emulator | Supported | Public demo smoke plus 20-run pilot gate | ADB/UI Automator, optional Android shim, emulator lifecycle helpers |
| Android physical device | Supported, app-team evidence required | 20-run pilot gate on a connected device | Same ADB path; publish only redacted app-safe evidence |
| iPhone simulator | Supported | Public iOS simulator demo smoke plus shim traces | `simctl` lifecycle with app-local XCTest/XCUIAutomation shim for selector-grade actions |
| iPad simulator | Supported, evidence-needed | iPad simulator smoke plus 20-run pilot gate before production claims | Uses the same iOS simulator path; teams should verify tablet layouts and size-class branches |
| iPhone physical device | Supported, validate locally | 20-run pilot gate on a trusted device | `devicectl` lifecycle plus XCTest shim, subject to signing, Developer Mode, and Xcode availability |
| iPad physical device | Supported, evidence-needed | 20-run pilot gate on a trusted iPad before production claims | Uses the same physical iOS/iPadOS path; keep it a separate row because tablet UI can diverge |
| tvOS simulator/device | Not supported in this preview | Separate proof of concept, shim, destination, and trace evidence required | Reasonable Apple-platform research after iPad evidence, but not a 1.0 dependency |
| watchOS simulator/device | Not supported in this preview | Separate companion/pairing/lifecycle design and evidence required | Treat as customer-driven roadmap work, not a 1.0 dependency |
| Cloud device farms | Not included | Adapter and provider-specific evidence required | Current focus is local and self-managed devices |

## Evidence Policy

- Production-stable support requires a 20-run pilot gate with zero failures and
  redacted trace/report artifacts.
- iPad evidence stays separate from iPhone evidence. The runner path is
  shared, but layouts, split views, and size-class behavior can produce
  different UI trees and selector outcomes.
- App-owned selectors should come first: `resourceId`/`id`, accessibility
  identifiers, content descriptions, accessibility labels, then stable visible
  text.
- Use `stableId` only as a fallback copied from a current semantic snapshot. It
  is useful for immediate agent actions; committed CI scenarios should prefer
  app-owned identifiers.
- tvOS and watchOS should stay out of public support claims until their platform
  lifecycles, shim protocols, and trace evidence exist.
