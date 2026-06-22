# ZMR Kotlin Client

Small JVM client for Kotlin agents and test harnesses that drive
`zmr serve --transport stdio`.

For now, build it from a local checkout and consume the generated jar:

```bash
git submodule add https://github.com/johnmikel/zeno-mobile-runner.git vendor/zeno-mobile-runner
gradle -p vendor/zeno-mobile-runner/clients/kotlin build
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
implementation(files("path/to/zeno-mobile-runner/clients/kotlin/build/libs/zmr-client-0.2.12.jar"))
```

```kotlin
val client = ZmrClient(listOf("zmr", "serve", "--transport", "stdio", "--config", ".zmr/config.json"))
val out = ".zmr/discovered/kotlin-agent.json"
val discovered = client.discoverTrace(
    out,
    TraceDiscoverOptions(includeActions = true, validate = true, force = true)
)
val explored = client.exploreTrace(
    ".zmr/discovered/kotlin-goal.json",
    "find a stable login smoke",
    TraceDiscoverOptions(includeActions = true, validate = true, force = true)
)
val validation = client.validateScenario(out)
val explanation = client.explainTrace()
client.close()
```

The Kotlin client is host-side. It is useful for Android teams that want test
or agent tooling in Kotlin, but it still controls the app through the local
`zmr` binary rather than running inside the app process.
