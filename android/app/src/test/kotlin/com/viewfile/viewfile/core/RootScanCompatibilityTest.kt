package com.viewfile.viewfile.core

import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RootScanCompatibilityTest {
    @Test
    fun boundedCommandIsAbsoluteNulSafeAndPreservesBothPipelineStatuses() {
        val command = rootScanCommand(
            Area("/data/media/0/Android", "/storage/emulated/0/Android", depth = 2),
            RootScanStrategy.BOUNDED_PIPEFAIL,
        )
        assertTrue(command.startsWith("set -o pipefail || exit $?; "))
        assertTrue(command.contains("/system/bin/find '/data/media/0/Android' -maxdepth 2 -print0"))
        assertTrue(command.contains("/system/bin/xargs -0 -n 256 /system/bin/sh"))
        assertTrue(command.contains("printf") && command.contains("B%s\\n"))
        assertTrue(command.contains("%s\\0"))
        assertTrue(command.contains("/system/bin/stat -c") && command.contains("%F|%s|%Y"))
        assertFalse(command.contains("%n|"))
        assertFalse(command.contains("2>/dev/null"))
    }

    @Test
    fun binaryParserSurvivesChunksAndArbitraryUtf8PathCharacters() {
        val paths = listOf(
            "/data/data/a\npipe|quote's space",
            "/data/data/中文/文件",
        )
        val payload = buildList<Byte> {
            addAll("B2\n".encodeToByteArray().toList())
            paths.forEach { addAll(it.encodeToByteArray().toList()); add(0.toByte()) }
            addAll("regular file|12|34\ndirectory|0|35\n".encodeToByteArray().toList())
        }.toByteArray()
        val records = ArrayList<RootBinaryRecord>()
        val parser = RootBinaryRecordParser(records::add)
        var offset = 0
        val chunks = intArrayOf(1, 2, 7, 3, 11, 5)
        var chunk = 0
        while (offset < payload.size) {
            val n = minOf(chunks[chunk++ % chunks.size], payload.size - offset)
            parser.accept(payload.copyOfRange(offset, offset + n))
            offset += n
        }
        parser.finish()
        assertEquals(paths, records.map { it.rawPath })
        assertEquals(listOf(12L, 0L), records.map { it.size })
    }

    @Test
    fun containmentRejectsCrossAreaAndSamePrefixEvilPaths() {
        assertTrue(RootScanner.isWithinRawRoot("/data/data/x", "/data/data"))
        assertTrue(RootScanner.isWithinRawRoot("/data/data", "/data/data/"))
        assertFalse(RootScanner.isWithinRawRoot("/data/dataevil/x", "/data/data"))
        assertFalse(RootScanner.isWithinRawRoot("/data/media/0/Other", "/data/media/0/Android"))
    }

    @Test
    fun malformedBinaryProtocolFailsClosed() {
        val malformed = listOf(
            "B0\n".encodeToByteArray(),
            "B257\n".encodeToByteArray(),
            byteArrayOf('B'.code.toByte(), '1'.code.toByte(), '\n'.code.toByte(),
                0xC3.toByte(), 0x28.toByte(), 0.toByte()),
            "B1\n/data/data/x\u0000regular|not-a-size|1\n".encodeToByteArray(),
            "B1\n/data/data/x\u0000regular|1\n".encodeToByteArray(),
            "B1\n/data/data/x\u0000regular|1|9223372036854776\n".encodeToByteArray(),
        )
        for (payload in malformed) {
            val failed = runCatching {
                RootBinaryRecordParser {}.apply { accept(payload); finish() }
            }.isFailure
            assertTrue(failed)
        }
        assertTrue(runCatching {
            RootBinaryRecordParser {}.apply {
                accept("B1\n/data/data/x\u0000".encodeToByteArray())
                finish()
            }
        }.isFailure)
    }

    @Test
    fun exec126AndExplicitUnsupportedSelectCompatibilityFallbackOnly() {
        assertTrue(shouldUseBoundedRootFallback(126, ""))
        assertTrue(shouldUseBoundedRootFallback(1, "Argument list too long"))
        assertTrue(shouldUseBoundedRootFallback(1, "option not supported"))
        assertFalse(shouldUseBoundedRootFallback(2, "permission denied"))
        assertFalse(shouldUseBoundedRootFallback(1, "find traversal failed"))
    }

    @Test
    fun buildArtifactCleanupDeletesAllSidecarsAndIsIdempotent() {
        val dir = Files.createTempDirectory("vf-build-cleanup").toFile()
        val build = dir.resolve("index-new.db")
        val main = dir.resolve("index.db").apply { writeText("old-main") }
        buildArtifacts(build).forEach { it.writeText("temporary") }

        assertEquals(4, deleteBuildArtifacts(build).deleted)
        assertEquals(0, deleteBuildArtifacts(build).deleted)
        assertEquals("old-main", main.readText())
        assertTrue(buildArtifacts(build).none { it.exists() })
        dir.deleteRecursively()
    }
}
