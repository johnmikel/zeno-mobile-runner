# ZMR Kotlin Client

Small JVM client for Kotlin agents and test harnesses that drive
`zmr serve --transport stdio`.

For now, build it from a local checkout and consume the generated jar:

```bash
git submodule add https://github.com/johnmikel/zig-mobile-runner.git vendor/zig-mobile-runner
gradle -p vendor/zig-mobile-runner/clients/kotlin build
```

Run the package test from the repository root:

```bash
gradle -p clients/kotlin test
```

Run the fake-session example from the repository root:

```bash
gradle -p clients/kotlin runFakeSession \
  -Pzmr="$PWD/zig-out/bin/zmr" \
  -Padb="$PWD/tests/fake-adb.sh" \
  -PtraceDir="$PWD/traces/demo-kotlin-client" \
  -PtraceOut="$PWD/traces/demo-kotlin-client-redacted.zmrtrace"
```

```kotlin
implementation(files("path/to/zig-mobile-runner/clients/kotlin/build/libs/zmr-client-0.1.0.jar"))
```

The Kotlin client is host-side. It is useful for Android teams that want test
or agent tooling in Kotlin, but it still controls the app through the local
`zmr` binary rather than running inside the app process.
