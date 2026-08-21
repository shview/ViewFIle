package com.viewfile.viewfile.core

internal data class RootRelistPlan(
    val selected: List<String>,
    val deferred: List<String>,
    val commitWithoutRelist: List<String>,
) {
    internal val selectedSet = selected.toHashSet()
    internal val deferredSet = deferred.toHashSet()
    internal val commitWithoutRelistSet = commitWithoutRelist.toHashSet()
}

internal enum class RootMtimeDisposition { SELECTED, DEFERRED, NO_RELIST }

internal fun RootRelistPlan.disposition(path: String): RootMtimeDisposition? = when (path) {
    in selectedSet -> RootMtimeDisposition.SELECTED
    in deferredSet -> RootMtimeDisposition.DEFERRED
    in commitWithoutRelistSet -> RootMtimeDisposition.NO_RELIST
    else -> null
}

/** depth-cap 项可直接提交；selected 只在重列整块成功后提交；deferred 永不在本轮提交。 */
internal fun shouldCommitRootMtime(
    disposition: RootMtimeDisposition,
    relistSucceeded: Boolean,
): Boolean = disposition == RootMtimeDisposition.NO_RELIST ||
        (disposition == RootMtimeDisposition.SELECTED && relistSucceeded)

internal data class RootContinuationState(val deferredDirs: Int, val processingOk: Boolean)

/** 仅 cap 延后可续排；任一 area 处理失败都禁止立即重试。 */
internal fun shouldAutoContinueRoot(states: List<RootContinuationState>): Boolean =
    states.sumOf { it.deferredDirs } > 0 && states.all { it.processingOk }

/** cap 续跑是内部收敛任务，不得二次完成 MethodChannel Result。 */
internal fun shouldDeliverSyncCallback(internalContinuation: Boolean): Boolean =
    !internalContinuation

internal fun shouldGuardRootMassDelete(deleteCount: Int, knownCount: Int): Boolean =
    deleteCount > 2000 || deleteCount > knownCount / 5

/**
 * 把变化目录分为本轮重列、超额延后和深度上限外三类。
 * 只有 [RootRelistPlan.selected] 在重列成功后才能提交 mtime；deferred
 * 必须保留旧 mtime，以便下一轮仍被识别为 changed。
 */
internal fun planRootRelists(
    changedDirs: List<String>,
    areaDisplay: String,
    depth: Int,
    limit: Int,
): RootRelistPlan {
    require(limit >= 0)
    val areaSlash = areaDisplay.count { it == '/' }
    val relistable = ArrayList<String>(changedDirs.size)
    val noRelist = ArrayList<String>()
    for (path in changedDirs) {
        val withinDepth = depth <= 0 ||
                (path.count { it == '/' } - areaSlash) < depth
        if (withinDepth) relistable.add(path) else noRelist.add(path)
    }
    return RootRelistPlan(
        selected = relistable.take(limit),
        deferred = relistable.drop(limit),
        commitWithoutRelist = noRelist,
    )
}
