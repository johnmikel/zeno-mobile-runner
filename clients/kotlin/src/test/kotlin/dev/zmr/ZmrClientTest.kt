package dev.zmr

import java.io.File
import kotlin.test.Test
import kotlin.test.assertTrue
import kotlin.test.assertFailsWith

class ZmrClientTest {
    @Test
    fun drivesFakeJsonRpcSession() {
        val server = fakeServerPath()
        ZmrClient(listOf("node", server.absolutePath)).use { client ->
            val capabilities = client.call("runner.capabilities")
            assertTrue(capabilities.contains("\"protocolVersion\":\"2026-04-28\""))
            assertTrue(capabilities.contains("\"assert.healthy\""))

            val healthy = client.assertHealthy(timeoutMs = 1000)
            assertTrue(healthy.contains("\"result\":true"))

            val snapshot = client.snapshot()
            assertTrue(snapshot.contains("\"activePackage\":\"com.example.mobiletest\""))

            val discovered = client.discoverTrace(
                ".zmr/discovered/kotlin-client.json",
                TraceDiscoverOptions(
                    includeActions = true,
                    validate = true,
                    force = true,
                    name = "Kotlin discovery",
                    appId = "com.example.kotlin"
                )
            )
            assertTrue(discovered.contains("\"mode\":\"discover\""))
            assertTrue(discovered.contains("\"out\":\".zmr/discovered/kotlin-client.json\""))
            assertTrue(discovered.contains("\"appId\":\"com.example.kotlin\""))
            assertTrue(discovered.contains("\"validated\":true"))

            val validation = client.validateScenario(".zmr/discovered/kotlin-client.json")
            assertTrue(validation.contains("\"ok\":true"))
            assertTrue(validation.contains("\"path\":\".zmr/discovered/kotlin-client.json\""))
        }
    }

    @Test
    fun rejectsJsonRpcErrors() {
        val server = fakeServerPath()
        ZmrClient(listOf("node", server.absolutePath)).use { client ->
            val error = assertFailsWith<ZmrRpcException> {
                client.call("missing.method")
            }
            assertTrue(error.message.orEmpty().contains("method not found"))
            assertTrue(error.code == -32601)
        }
    }

    private fun fakeServerPath(): File {
        val candidates = listOf(
            File("tests/fake-json-rpc-server.mjs"),
            File("../../tests/fake-json-rpc-server.mjs")
        )
        return candidates.firstOrNull { it.isFile }?.absoluteFile
            ?: error("could not find tests/fake-json-rpc-server.mjs from ${File(".").absolutePath}")
    }
}
