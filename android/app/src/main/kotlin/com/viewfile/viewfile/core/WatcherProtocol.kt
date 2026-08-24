package com.viewfile.viewfile.core

internal object WatcherProtocol {
    const val MAX_WATCH = 200000
    const val READY_TIMEOUT_MS = 5000L
    private const val READY_PREFIX = "R"
    private const val DIRTY_PREFIX = "D"

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

    fun coversExpected(expected: Int, ready: Ready): Boolean {
        if (expected > MAX_WATCH || ready.requested != expected) return false
        val shortfall = ready.requested - ready.installed
        if (shortfall <= 0) return true
        // 少量 add_watch 失败多为瞬时竞态（安装期间目录被并发增删），
        // 差额 ≤0.5%（至少 256）仍接受；缺口由前台同步与下一轮对账兜底，
        // 比整体回退 media observer（只覆盖媒体文件）好得多
        return shortfall <= maxOf(256, ready.requested / 200)
    }

    /** 解析 native 的 0-based 目录序号；任何非精确格式或越界值都拒绝。 */
    fun parseDirtyOrdinal(line: String, directoryCount: Int): Int? {
        val parts = line.split(' ')
        if (parts.size != 2 || parts[0] != DIRTY_PREFIX) return null
        val ordinal = parts[1].toIntOrNull() ?: return null
        return ordinal.takeIf { it >= 0 && it < directoryCount }
    }
}

/** 只忽略 ViewFile 自身数据库目录；其他应用目录仍是索引功能的有效输入。 */
internal object WatcherEventFilter {
    private const val PACKAGE_NAME = "com.viewfile.viewfile"

    fun shouldTriggerSync(dirtyDirectory: String): Boolean =
        !isOwnDatabaseDirectory(dirtyDirectory)

    fun isOwnDatabaseDirectory(path: String): Boolean {
        val normalized = path.trimEnd('/')
        val legacy = "/data/data/$PACKAGE_NAME/databases"
        val userZero = "/data/user/0/$PACKAGE_NAME/databases"
        return normalized == legacy || normalized.startsWith("$legacy/") ||
                normalized == userZero || normalized.startsWith("$userZero/")
    }
}
