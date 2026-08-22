package com.viewfile.viewfile.core

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction

internal class RootBinaryRecordParser(
    private val onRecord: (RootBinaryRecord) -> Unit,
) {
    private enum class State { HEADER, PATHS, META }
    private var state = State.HEADER
    private val field = ByteArrayOutputStream()
    private val paths = ArrayList<String>(256)
    private var expected = 0
    private var metadataRead = 0

    fun accept(bytes: ByteArray, length: Int = bytes.size) {
        require(length in 0..bytes.size)
        for (i in 0 until length) {
            val b = bytes[i]
            val delimiter = when (state) {
                State.HEADER, State.META -> b == '\n'.code.toByte()
                State.PATHS -> b == 0.toByte()
            }
            if (delimiter) consumeField() else {
                if (field.size() >= MAX_FIELD_BYTES) error("root record field overflow")
                field.write(b.toInt())
            }
        }
    }

    fun finish() {
        if (state != State.HEADER || field.size() != 0 || paths.isNotEmpty()) {
            error("truncated root binary record")
        }
    }

    private fun consumeField() {
        val raw = field.toByteArray()
        field.reset()
        when (state) {
            State.HEADER -> {
                val header = decodeUtf8(raw)
                if (!header.startsWith("B") || header.length < 2 ||
                    header.drop(1).any { !it.isDigit() }
                ) error("malformed root batch header")
                expected = header.drop(1).toIntOrNull()
                    ?.takeIf { it in 1..MAX_BATCH } ?: error("root batch count overflow")
                paths.clear()
                metadataRead = 0
                state = State.PATHS
            }
            State.PATHS -> {
                val path = decodeUtf8(raw)
                if (path.isEmpty() || '\u0000' in path) error("malformed root path")
                paths.add(path)
                if (paths.size == expected) state = State.META
            }
            State.META -> {
                val parts = decodeUtf8(raw).split('|')
                if (parts.size != 3) error("malformed root metadata")
                val type = parts[0]
                if (type.isEmpty()) error("malformed root type")
                val size = parts[1].toLongOrNull() ?: error("malformed root size")
                val mtime = parts[2].toLongOrNull() ?: error("malformed root mtime")
                if (size < 0 || mtime < 0) error("negative root metadata")
                if (mtime > Long.MAX_VALUE / 1000) error("root mtime overflow")
                onRecord(RootBinaryRecord(paths[metadataRead], type, size, mtime * 1000))
                metadataRead++
                if (metadataRead == expected) {
                    paths.clear()
                    state = State.HEADER
                }
            }
        }
    }

    private fun decodeUtf8(bytes: ByteArray): String = Charsets.UTF_8.newDecoder()
        .onMalformedInput(CodingErrorAction.REPORT)
        .onUnmappableCharacter(CodingErrorAction.REPORT)
        .decode(ByteBuffer.wrap(bytes)).toString()

    companion object {
        const val MAX_BATCH = 256
        private const val MAX_FIELD_BYTES = 1024 * 1024
    }
}

internal data class RootBinaryRecord(
    val rawPath: String,
    val type: String,
    val size: Long,
    val mtimeMs: Long,
)
