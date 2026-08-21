package com.viewfile.viewfile.core

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FuseTraversalPolicyTest {
    @Test
    fun unchangedMtimeSkipsOnlyCurrentDiff() {
        assertFalse(shouldDiffFuseDirectory(1000L, 1000L, forceRelist = false))
    }

    @Test
    fun changedMissingOrForcedDirectoryRequiresDiff() {
        assertTrue(shouldDiffFuseDirectory(1000L, 2000L, forceRelist = false))
        assertTrue(shouldDiffFuseDirectory(null, 2000L, forceRelist = false))
        assertTrue(shouldDiffFuseDirectory(1000L, 1000L, forceRelist = true))
    }

    @Test
    fun watcherRefreshDependsOnlyOnDirectoryAddsOrRemovals() {
        assertFalse(directorySetChanged(0))
        assertTrue(directorySetChanged(1))
        assertTrue(directorySetChanged(42))
    }

    @Test
    fun missingListingOrIncompleteChildMarksFuseTraversalIncomplete() {
        assertFalse(fuseListingAvailable(null))
        assertTrue(fuseListingAvailable(emptyArray<Any>()))
        assertFalse(combineFuseTraversalResult(false, true))
        assertFalse(combineFuseTraversalResult(true, false))
        assertFalse(combineFuseTraversalResult(false, false))
        assertTrue(combineFuseTraversalResult(true, true))
    }

    @Test
    fun fuseMtimeCommitsOnlyAfterSuccessfulDiff() {
        assertFalse(shouldCommitFuseMtime(FuseMtimeStage.BEFORE_DIFF))
        assertTrue(shouldCommitFuseMtime(FuseMtimeStage.DIFF_SUCCEEDED))
    }
}
