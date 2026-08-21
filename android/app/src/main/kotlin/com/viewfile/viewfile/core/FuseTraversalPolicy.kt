package com.viewfile.viewfile.core

/** mtime 只决定当前层是否对账；无论结果如何，调用方都必须继续下钻现存子目录。 */
internal fun shouldDiffFuseDirectory(
    storedMtime: Long?,
    currentMtime: Long,
    forceRelist: Boolean
): Boolean = forceRelist || storedMtime == null || storedMtime != currentMtime

/** watcher 只在目录节点增删时需要重建 watch 集合。 */
internal fun directorySetChanged(dirAddedRemoved: Int): Boolean = dirAddedRemoved > 0

/** 子树任一层无法列目录，整个 FUSE 走查就不完整。 */
internal fun combineFuseTraversalResult(
    completeSoFar: Boolean,
    childComplete: Boolean,
): Boolean = completeSoFar && childComplete

internal fun fuseListingAvailable(children: Array<*>?): Boolean = children != null

internal enum class FuseMtimeStage { BEFORE_DIFF, DIFF_SUCCEEDED }

/** changed 目录的 mtime 是对账水位，只能在直接子项 diff 成功后提交。 */
internal fun shouldCommitFuseMtime(stage: FuseMtimeStage): Boolean =
    stage == FuseMtimeStage.DIFF_SUCCEEDED
