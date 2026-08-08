# Support Matrix

Use this page to decide what ZMR can claim today, what needs app-local proof,
and what is still outside the preview. ZMR is intended as an AI-agent-first
replacement path for mobile automation: agents observe UI state, choose typed
actions, validate generated scenarios, and export trace evidence that can replay
in CI without an LLM.

Support is claimed only when ZMR has lifecycle, observation, selector/action,
trace, and repeat-run evidence for the target class.

| Target | Status | Evidence standard | Notes |
| --- | --- | --- | --- |
| Android emulator | Supported | Public demo smoke plus 20-run pilot gate | ADB/UI Automator, optional Android shim, emulator lifecycle helpers |
| Android physical device | Supported, app-team evidence required | 20-run pilot gate on a connected device | Same ADB path; publish only redacted app-safe evidence |
| iPhone simulator | Supported | Public iOS simulator demo smoke plus shim traces | `simctl` lifecycle with app-local XCTest/XCUIAutomation shim for selector-grade actions |
| iPad simulator | Supported, evidence-needed | iPad simulator smoke plus 20-run pilot gate before production claims | Uses the same iOS simulator path; teams should verify tablet layouts and size-class branches |
| iPhone physical device | Lifecycle only -- selector actions NOT supported | 20-run pilot gate on a trusted device, lifecycle steps only | `devicectl` handles install, launch, stop, deep links and screenshots. Selector-grade actions (tap, type, waits, assertions) need the XCTest shim, and the shim talks over a directory on the host Mac that a phone cannot reach, so `--device-type physical` is refused at install. Needs a real host-device transport |
| iPad physical device | Lifecycle only -- selector actions NOT supported | 20-run pilot gate on a trusted iPad, lifecycle steps only | Same physical iOS/iPadOS limitation as iPhone above; kept as its own row because tablet UI can diverge once the transport exists |
| tvOS simulator/device | Not supported in this preview | Separate proof of concept, shim, destination, and trace evidence required | Reasonable Apple-platform research after iPad evidence, but not a 1.0 dependency |
| watchOS simulator/device | Not supported in this preview | Separate companion/pairing/lifecycle design and evidence required | Treat as customer-driven roadmap work, not a 1.0 dependency |
| Cloud device farms | Not included | Adapter and provider-specific evidence required | Current focus is local and self-managed devices |

## Evidence Policy

- Production-stable support requires a 20-run pilot gate with zero failures and
  redacted trace/report artifacts.
- iPad evidence must stay separate from iPhone evidence. The runner path is
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
