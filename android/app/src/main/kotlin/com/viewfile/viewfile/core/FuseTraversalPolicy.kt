package com.viewfile.viewfile.core

/** mtime 只决定当前层是否对账；无论结果如何，调用方都必须继续下钻现存子目录。 */
internal fun shouldDiffFuseDirectory(
    storedMtime: Long?,
    currentMtime: Long,
    forceRelist: Boolean
): Boolean = forceRelist || storedMtime == null || storedMtime != currentMtime
