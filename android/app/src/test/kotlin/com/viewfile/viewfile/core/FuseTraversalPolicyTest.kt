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
}
