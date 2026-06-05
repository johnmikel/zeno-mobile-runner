plugins {
    kotlin("jvm") version "2.0.21"
    `java-library`
}

group = "dev.zmr"
version = "0.1.4"

kotlin {
    jvmToolchain(17)
}

dependencies {
    testImplementation(kotlin("test"))
}

tasks.test {
    useJUnitPlatform()
}

tasks.register<JavaExec>("runFakeSession") {
    group = "application"
    description = "Run the fake ZMR JSON-RPC session example."
    dependsOn(tasks.named("classes"))
    classpath = sourceSets["main"].runtimeClasspath
    mainClass.set("dev.zmr.FakeSessionKt")
    args = listOf(
        "--zmr", providers.gradleProperty("zmr").orElse("zig-out/bin/zmr").get(),
        "--adb", providers.gradleProperty("adb").orElse("tests/fake-adb.sh").get(),
        "--device", providers.gradleProperty("device").orElse("fake-android-1").get(),
        "--app-id", providers.gradleProperty("appId").orElse("com.example.mobiletest").get(),
        "--trace-dir", providers.gradleProperty("traceDir").orElse("traces/demo-kotlin-client").get(),
        "--trace-out", providers.gradleProperty("traceOut").orElse("traces/demo-kotlin-client-redacted.zmrtrace").get()
    )
}
