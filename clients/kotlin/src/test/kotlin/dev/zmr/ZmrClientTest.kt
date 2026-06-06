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
            assertTrue(capabilities.contains("\"trace.explain\""))

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

            val explored = client.exploreTrace(
                ".zmr/discovered/kotlin-client-explore.json",
                "find kotlin client smoke",
                TraceDiscoverOptions(
                    includeActions = true,
                    validate = true,
                    force = true,
                    name = "Kotlin exploration",
                    appId = "com.example.kotlin"
                )
            )
            assertTrue(explored.contains("\"mode\":\"explore\""))
            assertTrue(explored.contains("\"goal\":\"find kotlin client smoke\""))
            assertTrue(explored.contains("\"out\":\".zmr/discovered/kotlin-client-explore.json\""))
            assertTrue(explored.contains("\"reviewRequired\":true"))
            assertTrue(explored.contains("\"autonomous\":false"))
            assertTrue(explored.contains("requires human review before commit"))

            val explanation = client.explainTrace()
            assertTrue(explanation.contains("\"traceDir\":\"traces/client\""))
            assertTrue(explanation.contains("\"scenario\":\"client session\""))
            assertTrue(explanation.contains("\"status\":\"failed\""))
            assertTrue(explanation.contains("\"error\":\"WaitTimeout\""))
            assertTrue(explanation.contains("\"kind\":\"wait.visible\""))
            assertTrue(explanation.contains("\"visibleTexts\":[\"Home\",\"Retry\"]"))
            assertTrue(explanation.contains("zmr explain traces/client --json"))

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
