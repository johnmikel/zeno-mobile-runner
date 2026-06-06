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

    fun explainTrace(): String = call("trace.explain")

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
        if (hasTopLevelKey(response, "error")) {
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

private fun hasTopLevelKey(json: String, key: String): Boolean {
    var depth = 0
    var inString = false
    var escaped = false
    var stringStart = 0
    var i = 0
    while (i < json.length) {
        val ch = json[i]
        if (inString) {
            when {
                escaped -> escaped = false
                ch == '\\' -> escaped = true
                ch == '"' -> {
                    inString = false
                    if (depth == 1 && json.substring(stringStart, i) == key) {
                        var j = i + 1
                        while (j < json.length && json[j].isWhitespace()) j += 1
                        if (j < json.length && json[j] == ':') return true
                    }
                }
            }
        } else {
            when (ch) {
                '"' -> {
                    inString = true
                    stringStart = i + 1
                }
                '{', '[' -> depth += 1
                '}', ']' -> depth -= 1
            }
        }
        i += 1
    }
    return false
}

private fun escapeJson(value: String): String =
    value.replace("\\", "\\\\").replace("\"", "\\\"")
