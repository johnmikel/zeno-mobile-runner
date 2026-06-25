# Android Shim Protocol

The Android shim protocol is internal. It may change before `v1.0.0` without a
public protocol version bump.

The implementation should mirror the public ZMR action model:

- `snapshot`
- `tap`
- `type`
- `eraseText`
- `hideKeyboard`
- `swipe`
- `pressBack`
- `settle`
- `appState`

The Zig adapter must keep ADB/UI Automator fallback behavior so the runner can
still operate when the shim is not installed.
