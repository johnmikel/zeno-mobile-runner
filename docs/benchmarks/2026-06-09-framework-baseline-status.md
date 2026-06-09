# 2026-06-09 Framework Baseline Status

This note tracks the requested baseline coverage beyond the committed iOS demo
comparisons.

## Completed

| Baseline | Status | Evidence |
| --- | --- | --- |
| Maestro | Completed | [iOS ZMR vs Maestro comparison](2026-06-09-ios-maestro-comparison.md) |
| Appium | Completed | [iOS ZMR vs Appium comparison](2026-06-09-ios-appium-comparison.md) |
| XCTest floor | Completed | [iOS XCTest shim floor](2026-06-09-ios-xctest-floor.md) |

## Not Yet Fair To Publish

| Baseline | Why it needs a fixture first | Next evidence pack |
| --- | --- | --- |
| Detox | The CLI requires a project-local `detox` install and a React Native app with Detox configuration, native iOS/Android build targets, and a test file. Running it against the generated Swift demo would not be representative. | React Native fixture with the same launch, deep link, assertion, and warm-suite/cold-command modes. |
| Flutter | The local machine does not have the Flutter CLI installed, and ZMR should not claim Flutter widget-tree-driver coverage. | Flutter fixture using platform-level labels/deep links plus either Flutter `integration_test` or an external runner baseline. |
| Espresso | No Android emulator is currently attached in this workspace. Espresso should compare against an Android fixture with an instrumentation target rather than an iOS-only demo. | Android generated demo with ZMR, direct Espresso instrumentation, and Appium UIAutomator2 rows. |

## Speed Work Opened By This Pass

The XCTest floor showed that ZMR can be made faster. The first fix from this
pass skips the expensive iOS system-open alert probe for custom URL schemes and
keeps it for `http://` and `https://` links. On the generated iOS demo smoke
flow, the shim-backed ZMR mean dropped to `2007 ms` while the direct warmed
XCTest shim floor measured `1004 ms`.

The next speed target is a warm-suite mode where one ZMR process executes many
iterations in a single device session, avoiding repeated CLI startup and trace
setup for benchmark loops.
