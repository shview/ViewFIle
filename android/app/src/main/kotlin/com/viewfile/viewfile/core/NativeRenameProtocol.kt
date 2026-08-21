package com.viewfile.viewfile.core

internal object NativeRenameProtocol {
    const val EEXIST = 17
    const val EXDEV = 18
    const val ENOSYS = 38

    private fun quote(value: String): String = "'" + value.replace("'", "'\\''") + "'"

    /** ProcessBuilder 参数数组；路径不经过 shell，空格和元字符保持原样。 */
    fun arguments(helper: String, oldPath: String, newPath: String): List<String> =
        listOf(helper, "--rename-noreplace", oldPath, newPath)

    fun command(helper: String, oldPath: String, newPath: String): String =
        "${quote(helper)} --rename-noreplace ${quote(oldPath)} ${quote(newPath)}"

    fun errorMessage(code: Int): String = when (code) {
        EEXIST -> "已存在同名项目"
        EXDEV -> "重命名失败（不支持跨文件系统）"
        ENOSYS -> "设备内核不支持安全的无覆盖重命名"
        else -> "重命名失败（存储权限或路径限制，rc=$code）"
    }

    enum class DirectDecision { SUCCESS, CONFLICT, RETRY_PRIVILEGED, UNCERTAIN }

    /**
     * 未拿到明确成功码时，只有源仍存在才能安全地换身份重试。源已消失可能是
     * helper 在 syscall 成功后、回传退出码前被终止，绝不能再次发起重命名。
     */
    fun decideDirectResult(code: Int, sourceExists: Boolean): DirectDecision = when {
        code == 0 -> DirectDecision.SUCCESS
        code == EEXIST -> DirectDecision.CONFLICT
        sourceExists -> DirectDecision.RETRY_PRIVILEGED
        else -> DirectDecision.UNCERTAIN
    }
}
