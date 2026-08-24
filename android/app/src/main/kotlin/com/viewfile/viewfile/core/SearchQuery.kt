package com.viewfile.viewfile.core

import java.time.LocalDate
import java.time.ZoneId

/**
 * 搜索语法解析：名称关键词之外支持
 *   大小： >10mb  <500kb  >=1gb  1mb..50mb
 *   日期： >2024-01-01  <2024/06  today  yesterday  thisweek  thismonth  thisyear
 * 其余 token 原样作为名称关键词（空格分隔 AND 折叠匹配）。
 */
internal data class QueryFilter(
    val text: String,
    val sizeMin: Long?,
    val sizeMax: Long?,
    val timeMin: Long?, // epoch ms
    val timeMax: Long?  // epoch ms（开区间：mtime < timeMax）
) {
    val hasRange get() = sizeMin != null || sizeMax != null || timeMin != null || timeMax != null
}

internal object SearchQueryParser {

    private val sizeCmp =
        Regex("^(>=|<=|>|<)(\\d+(?:\\.\\d+)?)(b|kb|mb|gb)$", RegexOption.IGNORE_CASE)
    private val sizeRange =
        Regex("^(\\d+(?:\\.\\d+)?)(b|kb|mb|gb)\\.\\.(\\d+(?:\\.\\d+)?)(b|kb|mb|gb)$", RegexOption.IGNORE_CASE)
    private val dateCmp = Regex("^(>=|<=|>|<)(\\d{4})(?:-(\\d{2}))?(?:-(\\d{2}))?$")

    fun parse(raw: String): QueryFilter {
        var sizeMin: Long? = null
        var sizeMax: Long? = null
        var timeMin: Long? = null
        var timeMax: Long? = null
        val textParts = ArrayList<String>()

        for (tok0 in raw.trim().split(' ', '\t')) {
            if (tok0.isEmpty()) continue
            val tok = tok0.lowercase()

            val m = sizeRange.find(tok)
            if (m != null) {
                val a = bytes(m.groupValues[1], m.groupValues[2])
                val b = bytes(m.groupValues[3], m.groupValues[4])
                if (a != null && b != null && a <= b) {
                    sizeMin = a; sizeMax = b
                }
                continue
            }
            val c = sizeCmp.find(tok)
            if (c != null) {
                val v = bytes(c.groupValues[2], c.groupValues[3])
                if (v != null) {
                    when (c.groupValues[1]) {
                        ">" -> sizeMin = maxOf(sizeMin ?: Long.MIN_VALUE, v + 1)
                        ">=" -> sizeMin = maxOf(sizeMin ?: Long.MIN_VALUE, v)
                        "<" -> sizeMax = minOf(sizeMax ?: Long.MAX_VALUE, v - 1)
                        "<=" -> sizeMax = minOf(sizeMax ?: Long.MAX_VALUE, v)
                    }
                }
                continue
            }
            val dayRange = dayWordRange(tok)
            if (dayRange != null) {
                timeMin = maxOf(timeMin ?: Long.MIN_VALUE, dayRange.first)
                timeMax = minOf(timeMax ?: Long.MAX_VALUE, dayRange.second)
                continue
            }
            val d = dateCmp.find(tok)
            if (d != null) {
                val (nMin, nMax) = dateRange(d) ?: (null to null)
                if (nMin != null) {
                    timeMin = maxOf(timeMin ?: Long.MIN_VALUE, nMin)
                }
                if (nMax != null) {
                    timeMax = minOf(timeMax ?: Long.MAX_VALUE, nMax)
                }
                if (nMin != null || nMax != null) continue
            }

            textParts.add(tok0)
        }
        return QueryFilter(textParts.joinToString(" "), sizeMin, sizeMax, timeMin, timeMax)
    }

    /** >2024-01-01 → (该日次日0点, null)；<2024-06 → (null, 该月首日0点)…返回命中的边界 */
    private fun dateRange(m: MatchResult): Pair<Long?, Long?> {
        val y = m.groupValues[2].toIntOrNull() ?: return null to null
        val mo = m.groupValues[3].toIntOrNull()
        val day = m.groupValues[4].toIntOrNull()
        val base = runCatching {
            if (day != null && mo != null) LocalDate.of(y, mo, day)
            else if (mo != null) LocalDate.of(y, mo, 1)
            else LocalDate.of(y, 1, 1)
        }.getOrNull() ?: return null to null
        val startMs = atStart(base)
        val endMs = atStart(
            if (day != null && mo != null) base.plusDays(1)
            else if (mo != null) base.plusMonths(1)
            else base.plusYears(1)
        )
        return when (m.groupValues[1]) {
            ">" -> endMs to null
            ">=" -> startMs to null
            "<" -> null to startMs
            else -> null to endMs
        }
    }

    private fun dayWordRange(tok: String): Pair<Long, Long>? {
        val today = LocalDate.now()
        return when (tok) {
            "today" -> atStart(today) to atStart(today.plusDays(1))
            "yesterday" -> {
                val y = today.minusDays(1)
                atStart(y) to atStart(y.plusDays(1))
            }
            "thisweek" -> {
                val monday = today.minusDays((today.dayOfWeek.value - 1).toLong())
                atStart(monday) to atStart(today.plusDays(1))
            }
            "thismonth" -> atStart(today.withDayOfMonth(1)) to atStart(today.plusDays(1))
            "thisyear" -> atStart(today.withDayOfYear(1)) to atStart(today.plusDays(1))
            else -> null
        }
    }

    private fun bytes(num: String, unit: String): Long? {
        val v = num.toDoubleOrNull() ?: return null
        return when (unit.lowercase()) {
            "b" -> v.toLong()
            "kb" -> (v * 1024).toLong()
            "mb" -> (v * 1024 * 1024).toLong()
            "gb" -> (v * 1024 * 1024 * 1024).toLong()
            else -> null
        }
    }

    private fun atStart(d: LocalDate): Long =
        d.atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli()
}

/** 类型分类（用于搜索类型芯片过滤） */
internal object FileCategories {
    // 0 其他 1 图片 2 视频 3 音频 4 文档 5 APK 6 压缩包
    private val image = setOf("jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "dng", "avif")
    private val video = setOf("mp4", "mkv", "avi", "mov", "webm", "3gp", "m4v", "flv", "ts", "mpeg", "mpg")
    private val audio = setOf("mp3", "flac", "wav", "ogg", "m4a", "aac", "opus", "amr", "wma", "mid")
    private val doc = setOf("pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "md", "epub", "mobi", "csv", "json", "xml", "html", "htm")
    private val apk = setOf("apk", "xapk", "apks")
    private val archive = setOf("zip", "rar", "7z", "tar", "gz", "bz2", "xz")

    fun ofName(name: String): Byte {
        val dot = name.lastIndexOf('.')
        if (dot < 0 || dot == name.length - 1) return 0
        val e = name.substring(dot + 1).lowercase()
        return when {
            image.contains(e) -> 1
            video.contains(e) -> 2
            audio.contains(e) -> 3
            doc.contains(e) -> 4
            apk.contains(e) -> 5
            archive.contains(e) -> 6
            else -> 0
        }
    }

    fun idOf(category: String?): Byte = when (category) {
        "image" -> 1; "video" -> 2; "audio" -> 3; "doc" -> 4
        "apk" -> 5; "archive" -> 6; else -> 0
    }
}
