package com.viewfile.viewfile.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RootRelistPolicyTest {
    @Test
    fun deferredParentRemainsChangedAndIsSelectedOnSecondRound() {
        val paths = (0..2000).map { "/data/data/app$it" }
        val actual = paths.associateWith { 2000L }
        val stored = paths.associateWith { 1000L }.toMutableMap()

        val firstChanged = paths.filter { stored[it] != actual[it] }
        val first = planRootRelists(firstChanged, "/data/data", depth = 0, limit = 2000)
        assertEquals(2000, first.selected.size)
        assertEquals(listOf("/data/data/app2000"), first.deferred)

        // 模拟仅提交成功处理的 selected，deferred 保留旧 mtime。
        first.selected.forEach { stored[it] = actual.getValue(it) }
        val secondChanged = paths.filter { stored[it] != actual[it] }
        val second = planRootRelists(secondChanged, "/data/data", depth = 0, limit = 2000)
        assertEquals(listOf("/data/data/app2000"), second.selected)
        assertTrue(second.deferred.isEmpty())
    }

    @Test
    fun depthCappedDirectoriesCommitWithoutRelist() {
        val plan = planRootRelists(
            listOf("/data/data", "/data/data/app", "/data/data/app/files"),
            "/data/data", depth = 2, limit = 2000)
        assertEquals(listOf("/data/data", "/data/data/app"), plan.selected)
        assertEquals(listOf("/data/data/app/files"), plan.commitWithoutRelist)
    }

    @Test
    fun commitPolicyRejectsDeferredAndFailedRelists() {
        assertTrue(shouldCommitRootMtime(RootMtimeDisposition.NO_RELIST, false))
        assertTrue(shouldCommitRootMtime(RootMtimeDisposition.SELECTED, true))
        assertFalse(shouldCommitRootMtime(RootMtimeDisposition.SELECTED, false))
        assertFalse(shouldCommitRootMtime(RootMtimeDisposition.DEFERRED, true))
        assertFalse(shouldCommitRootMtime(RootMtimeDisposition.DEFERRED, false))
    }

    @Test
    fun autoContinuationRequiresCapDeferredWithoutProcessingFailure() {
        assertTrue(shouldAutoContinueRoot(listOf(
            RootContinuationState(1, true), RootContinuationState(0, true))))
        assertFalse(shouldAutoContinueRoot(listOf(
            RootContinuationState(1, true), RootContinuationState(0, false))))
        assertFalse(shouldAutoContinueRoot(listOf(
            RootContinuationState(0, true), RootContinuationState(0, true))))
    }

    @Test
    fun internalContinuationNeverDeliversExternalCallback() {
        assertTrue(shouldDeliverSyncCallback(internalContinuation = false))
        assertFalse(shouldDeliverSyncCallback(internalContinuation = true))
    }

    @Test
    fun massDeleteGuardIsExplicitlyIncompleteAndBlocksContinuation() {
        // 绝对阈值单独触发（未超过 1/5）。
        assertTrue(shouldGuardRootMassDelete(deleteCount = 2001, knownCount = 20_000))
        // 比例阈值单独触发（未超过 2000）。
        assertTrue(shouldGuardRootMassDelete(deleteCount = 101, knownCount = 500))
        assertFalse(shouldGuardRootMassDelete(deleteCount = 100, knownCount = 500))
        assertFalse(shouldGuardRootMassDelete(deleteCount = 0, knownCount = 0))
        assertTrue(shouldGuardRootMassDelete(deleteCount = 1, knownCount = 0))
        assertFalse(shouldAutoContinueRoot(listOf(
            RootContinuationState(deferredDirs = 1, processingOk = false))))
    }
}
