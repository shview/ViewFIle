package com.viewfile.viewfile.core

import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.zip.ZipFile

/**
 * 轻量 APK 清单解析：直接读 zip 内 AndroidManifest.xml 的二进制 AXML，
 * 提取 package / versionName / versionCode。
 * 不依赖 PackageManager（部分 ROM 对 FUSE 路径的 getPackageArchiveInfo
 * 行为异常返回 null），只要文件可读即可解析。
 */
object ApkManifest {

    data class Info(val pkg: String?, val versionName: String?, val versionCode: Long?)

    fun parse(path: String): Info? = try {
        ZipFile(path).use { zf ->
            val e = zf.getEntry("AndroidManifest.xml") ?: return null
            zf.getInputStream(e).use { parse(it) }
        }
    } catch (_: Throwable) {
        null
    }

    // ---- 二进制 XML（AXML）最小解析 ----
    // 结构：文件头(type=0x0003) + 字符串池(0x0001) + 若干元素块(0x0102 起/0x0103 止)
    private const val TYPE_STRING_POOL = 0x0001
    private const val TYPE_START_ELEM = 0x0102

    fun parse(ins: InputStream): Info? {
        val bytes = ins.readBytes()
        val buf = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)

        var strings: Array<String> = emptyArray()
        var info = Info(null, null, null)

        // 跳过文件头
        buf.position(8)
        while (buf.remaining() >= 8) {
            val type = buf.short.toInt() and 0xFFFF
            val headerSize = buf.short.toInt() and 0xFFFF
            val size = buf.int
            val chunkStart = buf.position() - 8
            when (type) {
                TYPE_STRING_POOL -> strings = parseStringPool(buf, chunkStart, size)
                TYPE_START_ELEM -> {
                    val r = parseStartElement(buf, strings)
                    if (r != null) {
                        info = r
                        break // 只需要 <manifest> 根元素
                    }
                }
            }
            buf.position(chunkStart + size)
        }
        return if (info.pkg != null) info else null
    }

    /** 解析字符串池（UTF-8 与 UTF-16 两种编码） */
    private fun parseStringPool(buf: ByteBuffer, chunkStart: Int, chunkSize: Int): Array<String> {
        val stringCount = buf.int
        buf.int // styleCount
        val flags = buf.int
        val stringsStart = buf.int
        buf.int // stylesStart
        val isUtf8 = (flags and 0x100) != 0
        val offsets = IntArray(stringCount)
        for (i in 0 until stringCount) offsets[i] = buf.int
        val out = ArrayList<String>(stringCount)
        for (i in 0 until stringCount) {
            val at = chunkStart + stringsStart + offsets[i]
            if (at < 0 || at >= buf.limit()) continue
            buf.position(at)
            val s = if (isUtf8) readUtf8(buf) else readUtf16(buf)
            out.add(s)
        }
        buf.position(chunkStart + chunkSize)
        return out.toTypedArray()
    }

    private fun readUtf8(buf: ByteBuffer): String {
        // 两个长度：字符数与字节数（都可能两字节扩展编码）
        skipLen8(buf)
        val byteLen = readLen8(buf)
        val arr = ByteArray(byteLen)
        buf.get(arr)
        return String(arr, Charsets.UTF_8)
    }

    private fun readUtf16(buf: ByteBuffer): String {
        val len = readLen16(buf)
        if (len <= 0) return ""
        val sb = StringBuilder(len)
        for (i in 0 until len) {
            val c = buf.short.toInt() and 0xFFFF
            sb.append(c.toChar())
        }
        return sb.toString()
    }

    private fun skipLen8(buf: ByteBuffer) { readLen8(buf) }
    private fun readLen8(buf: ByteBuffer): Int {
        val b = buf.get().toInt() and 0xFF
        return if (b and 0x80 != 0) ((b and 0x7F) shl 8) or (buf.get().toInt() and 0xFF) else b
    }

    private fun readLen16(buf: ByteBuffer): Int {
        val s = buf.short.toInt() and 0xFFFF
        return if (s and 0x8000 != 0) ((s and 0x7FFF) shl 16) or (buf.short.toInt() and 0xFFFF) else s
    }

    /** 解析 <manifest ...> 根元素的属性（chunk 头 8B 已由外层消费） */
    private fun parseStartElement(buf: ByteBuffer, strings: Array<String>): Info? {
        // 剩余块头：lineNumber(4) comment(4)，块体：ns(4) name(4)
        buf.int // lineNumber
        buf.int // comment
        buf.int // ns
        val nameIdx = buf.int
        val name = strings.getOrNull(nameIdx) ?: return null
        if (name != "manifest") return null
        // 属性表定位：attrStart(2) attrSize(2) attrCount(2) idIdx(2) classIdx(2) styleIdx(2)
        buf.short // attrStart（属性紧跟其后，无需偏移）
        buf.short // attrSize
        val attrCount = buf.short.toInt() and 0xFFFF
        buf.short // idIndex
        buf.short // classIndex
        buf.short // styleIndex
        var pkg: String? = null
        var versionName: String? = null
        var versionCode: Long? = null
        for (i in 0 until attrCount) {
            buf.int // attr ns
            val attrNameIdx = buf.int
            val rawValueIdx = buf.int
            buf.short // attr size
            buf.get() // res0
            val dataType = buf.get().toInt() and 0xFF
            val data = buf.int
            when (strings.getOrNull(attrNameIdx)) {
                "package" -> pkg = strings.getOrNull(data)
                "versionName" -> versionName =
                    strings.getOrNull(rawValueIdx) ?: strings.getOrNull(data)
                "versionCode" -> if (dataType == 0x10) {
                    versionCode = data.toLong() and 0xFFFFFFFFL
                }
            }
        }
        return Info(pkg, versionName, versionCode)
    }
}
