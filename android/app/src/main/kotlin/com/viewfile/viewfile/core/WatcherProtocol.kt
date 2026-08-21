package com.viewfile.viewfile.core

internal object WatcherProtocol {
    const val MAX_WATCH = 200000
    const val READY_TIMEOUT_MS = 5000L
    private const val READY_PREFIX = "R"
    private const val EVENT = "E"

    data class Ready(val requested: Int, val installed: Int)

    fun parseReady(line: String?): Ready? {
        if (line == null) return null
        val parts = line.split(' ')
        if (parts.size != 3 || parts[0] != READY_PREFIX) return null
        val requested = parts[1].toIntOrNull() ?: return null
        val installed = parts[2].toIntOrNull() ?: return null
        if (requested < 0 || installed < 0) return null
        return Ready(requested, installed)
    }

    fun coversExpected(expected: Int, ready: Ready): Boolean =
        expected <= MAX_WATCH && ready.requested == expected &&
                ready.installed == ready.requested

    fun isEvent(line: String): Boolean = line == EVENT
}
