package dev.zmr

import java.io.BufferedReader
import java.io.BufferedWriter
import java.io.Closeable
import java.io.InputStreamReader
import java.io.OutputStreamWriter

class ZmrRpcException(
    val code: Int,
    message: String,
    val publicCode: String? = null
) : RuntimeException(message)

data class TraceDiscoverOptions(
    val includeActions: Boolean = false,
    val validate: Boolean = false,
    val force: Boolean = false,
    val name: String? = null,
    val appId: String? = null
)

class ZmrClient(
    private val command: List<String> = listOf("zmr", "serve", "--transport", "stdio")
) : Closeable {
    private var nextId = 1
    private val process = ProcessBuilder(command).redirectError(ProcessBuilder.Redirect.INHERIT).start()
    private val input = BufferedWriter(OutputStreamWriter(process.outputStream))
    private val output = BufferedReader(InputStreamReader(process.inputStream))

    fun createSession(): String = call("session.create")

    fun snapshot(): String = call("observe.snapshot")

    fun semanticSnapshot(): String = call("observe.semanticSnapshot")

    fun assertHealthy(timeoutMs: Long? = null): String {
        val params = timeoutMs?.let { "{\"timeoutMs\":$it}" } ?: "{}"
        return call("assert.healthy", params)
    }

    fun validateScenario(path: String): String =
        call("scenario.validate", """{"path":"${escapeJson(path)}"}""")

    fun discoverTrace(out: String, options: TraceDiscoverOptions = TraceDiscoverOptions()): String {
        val fields = mutableListOf(""""out":"${escapeJson(out)}"""")
        if (options.includeActions) fields.add(""""includeActions":true""")
        if (options.validate) fields.add(""""validate":true""")
        if (options.force) fields.add(""""force":true""")
        options.name?.let { fields.add(""""name":"${escapeJson(it)}"""") }
        options.appId?.let { fields.add(""""appId":"${escapeJson(it)}"""") }
        return call("trace.discover", "{${fields.joinToString(",")}}")
    }

    @Synchronized
    fun call(method: String, paramsJson: String? = null): String {
        val id = nextId++
        val params = paramsJson?.let { "," + "\"params\":" + it } ?: ""
        input.write("{\"jsonrpc\":\"2.0\",\"id\":$id,\"method\":\"$method\"$params}")
        input.newLine()
        input.flush()
        val response = output.readLine() ?: error("zmr closed stdout")
        if (response.contains(""""error"""")) {
            throw ZmrRpcException(
                code = extractNumber(response, "code") ?: -32000,
                message = extractString(response, "message").ifEmpty { "ZMR JSON-RPC error" },
                publicCode = extractString(response, "publicCode").ifEmpty { null }
            )
        }
        return response
    }

    override fun close() {
        runCatching { call("session.close") }
        runCatching { input.close() }
        process.destroy()
    }
}

private fun extractString(json: String, key: String): String {
    val pattern = """"$key"\s*:\s*"([^"]*)"""".toRegex()
    return pattern.find(json)?.groupValues?.get(1) ?: ""
}

private fun extractNumber(json: String, key: String): Int? {
    val pattern = """"$key"\s*:\s*(-?[0-9]+)""".toRegex()
    return pattern.find(json)?.groupValues?.get(1)?.toIntOrNull()
}

private fun escapeJson(value: String): String =
    value.replace("\\", "\\\\").replace("\"", "\\\"")
