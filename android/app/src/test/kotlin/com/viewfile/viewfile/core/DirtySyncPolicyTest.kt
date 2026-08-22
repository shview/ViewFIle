package com.viewfile.viewfile.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DirtySyncPolicyTest {
    @Test
    fun watcherReuseRequiresExactExpectedMode() {
        assertEquals(WatcherMode.MEDIA,
            expectedWatcherMode(rootIndex = false, rootTier = true, shizukuTier = false))
        assertEquals(WatcherMode.SU,
            expectedWatcherMode(rootIndex = true, rootTier = true, shizukuTier = true))
        assertEquals(WatcherMode.SHIZUKU,
            expectedWatcherMode(rootIndex = true, rootTier = false, shizukuTier = true))
        assertTrue(shouldReuseWatcher(true, 10, WatcherMode.SU, WatcherMode.SU))
        assertFalse(shouldReuseWatcher(true, 10, WatcherMode.MEDIA, WatcherMode.SU))
        assertFalse(shouldReuseWatcher(true, 10, WatcherMode.SU, WatcherMode.MEDIA))
        assertFalse(shouldReuseWatcher(true, 10, WatcherMode.SU, WatcherMode.SHIZUKU))
        assertFalse(shouldReuseWatcher(true, 10, WatcherMode.SHIZUKU, WatcherMode.SU))
        assertFalse(shouldReuseWatcher(true, 0, WatcherMode.SU, WatcherMode.SU))
    }

    @Test
    fun lifecycleLatestIntentWinsAcrossColdStopResumeAndStaleStop() {
        var state = WatcherForegroundState()
        val cold = applyWatcherForegroundIntent(state, 0, foreground = true)
        assertTrue(cold.ensureWatcher)
        state = cold.state

        val stop = applyWatcherForegroundIntent(state, 1, foreground = false)
        assertTrue(stop.stopWatcher)
        state = stop.state

        val resume = applyWatcherForegroundIntent(state, 2, foreground = true)
        assertTrue(resume.ensureWatcher)
        state = resume.state

        val staleStop = applyWatcherForegroundIntent(state, 1, foreground = false)
        assertFalse(staleStop.accepted)
        assertTrue(staleStop.state.desiredForeground)
    }

    @Test
    fun stopDuringHandshakeAndMediaFallbackResumeGetNewEnsureIntent() {
        val starting = applyWatcherForegroundIntent(
            WatcherForegroundState(), 10, foreground = true)
        val stopped = applyWatcherForegroundIntent(starting.state, 11, foreground = false)
        assertTrue(stopped.stopWatcher)
        val resumed = applyWatcherForegroundIntent(stopped.state, 12, foreground = true)
        assertTrue(resumed.ensureWatcher)

        // A completed start that fell back to MediaStore is retried once on the next resume id.
        val mediaFallback = starting.state
        val nextResume = applyWatcherForegroundIntent(mediaFallback, 13, foreground = true)
        assertTrue(nextResume.ensureWatcher)
        val duplicate = applyWatcherForegroundIntent(nextResume.state, 13, foreground = true)
        assertFalse(duplicate.ensureWatcher)
    }

    @Test
    fun dirtyScopeNormalizesAncestorsAddsParentsAndCapsToFull() {
        val plan = planDirtyScope(setOf(
            "/storage/emulated/0/DCIM/Camera/",
            "/storage/emulated/0/DCIM",
            "/data/data/pkg/files",
        ))
        assertFalse(plan.full)
        assertEquals(3, plan.requestedCount)
        assertTrue("/storage/emulated/0" in plan.targets)
        assertTrue("/storage/emulated/0/DCIM" in plan.targets)
        assertTrue("/data/data/pkg" in plan.targets)
        assertTrue("/data/data/pkg/files" in plan.targets)
        assertTrue("/storage/emulated/0/DCIM/Camera" in plan.targets)

        assertTrue(planDirtyScope(null).full)
        assertTrue(planDirtyScope(emptySet()).full)
        assertTrue(planDirtyScope((0..256).map { "/d$it" }.toSet()).full)
    }

    @Test
    fun scopedFixtureCoversCreateRenameDeleteAndGuard() {
        val delta = planScopedChildDelta(
            knownChildren = setOf("kept", "old-name", "deleted-dir"),
            actualChildren = setOf("kept", "new-name", "new-subtree"),
        )
        assertEquals(setOf("new-name", "new-subtree"), delta.added)
        assertEquals(setOf("old-name", "deleted-dir"), delta.removed)
        assertFalse(shouldGuardScopedRelist(4, 20))
        assertTrue(shouldGuardScopedRelist(5, 20))
        assertTrue(shouldGuardScopedRelist(2001, 10_000))
    }

    @Test
    fun areaRoutingUsesDisplayPaths() {
        val targets = listOf(
            "/storage/emulated/0/Android/data/pkg",
            "/data/data/pkg/files",
            "/storage/emulated/0/DCIM",
        )
        assertEquals(listOf("/storage/emulated/0/Android/data/pkg"),
            dirtyTargetsInArea(targets, "/storage/emulated/0/Android"))
        assertEquals(listOf("/data/data/pkg/files"),
            dirtyTargetsInArea(targets, "/data/data"))
    }

    @Test
    fun dirtyAccumulatorIsBoundedAndFullMarkerIsStickyUntilTake() {
        val accumulator = DirtyScopeAccumulator(cap = 256)
        repeat(256) { accumulator.add("/d$it") }
        assertFalse(accumulator.requiresFull())
        assertEquals(256, accumulator.retainedPathCount())
        accumulator.add("/overflow")
        assertTrue(accumulator.requiresFull())
        assertEquals(0, accumulator.retainedPathCount())
        accumulator.add("/ignored-after-full")
        assertEquals(null, accumulator.take())
        accumulator.add("/next")
        assertEquals(setOf("/next"), accumulator.take())
    }

    @Test
    fun watcherSyncCoalescesAndRunsOneRecoveryWithoutBusyLoop() {
        val coalescer = WatcherSyncCoalescer()
        val first = coalescer.submit(setOf("/a"))!!
        assertEquals(setOf("/a"), first.dirtyDirectories)
        assertEquals(null, coalescer.submit(setOf("/b")))
        assertEquals(null, coalescer.submit(null)) // full dominates while first runs

        val recovery = coalescer.complete(first,
            successfulAndComplete = false, allowTrailing = true)!!
        assertEquals(null, recovery.dirtyDirectories)
        assertTrue(recovery.recoveryAttempt)

        assertEquals(null, coalescer.complete(recovery,
            successfulAndComplete = false, allowTrailing = true))
        assertTrue(coalescer.hasPendingFull())
        val later = coalescer.kick()!!
        assertEquals(null, later.dirtyDirectories)
        assertFalse(later.recoveryAttempt)
    }

    @Test
    fun watcherSyncSuccessfulRunGetsAtMostOneMergedTrailingRun() {
        val coalescer = WatcherSyncCoalescer()
        val first = coalescer.submit(setOf("/a"))!!
        coalescer.submit(setOf("/b"))
        coalescer.submit(setOf("/c"))
        val trailing = coalescer.complete(first,
            successfulAndComplete = true, allowTrailing = true)!!
        assertEquals(setOf("/b", "/c"), trailing.dirtyDirectories)
        assertEquals(null, coalescer.complete(trailing,
            successfulAndComplete = true, allowTrailing = true))

        val stopped = WatcherSyncCoalescer()
        val active = stopped.submit(setOf("/active"))!!
        stopped.submit(setOf("/while-backgrounding"))
        assertEquals(null, stopped.complete(active,
            successfulAndComplete = true, allowTrailing = false))
        assertEquals(setOf("/while-backgrounding"), stopped.kick()!!.dirtyDirectories)
    }

    @Test
    fun burstTrailingSettleAndRecoveryCausesAreFinite() {
        val coalescer = WatcherSyncCoalescer()
        val first = coalescer.submit(setOf("/burst"))!!
        repeat(100) { coalescer.submit(setOf("/burst/file-$it")) }
        val trailing = coalescer.complete(first, true, allowTrailing = true)!!
        assertEquals(WatcherSyncCause.TRAILING, trailing.cause)
        assertEquals(100, trailing.dirtyDirectories!!.size)
        assertEquals(null, coalescer.complete(trailing, true, allowTrailing = true))

        val settle = coalescer.submit(
            setOf("/burst"), cause = WatcherSyncCause.SETTLE)!!
        assertEquals(WatcherSyncCause.SETTLE, settle.cause)
        val recovery = coalescer.complete(settle, false, allowTrailing = true)!!
        assertEquals(WatcherSyncCause.RECOVERY, recovery.cause)
        assertEquals(null, recovery.dirtyDirectories)
        assertEquals(null, coalescer.complete(recovery, true, allowTrailing = true))
    }

    @Test
    fun quietSettleUsesLatestDirtyOrCompletionAndScopedUnionIsBounded() {
        assertEquals(WATCHER_SETTLE_QUIET_MS,
            watcherQuietRemainingMs(lastActivityAt = 200, now = 200))
        assertEquals(500,
            watcherQuietRemainingMs(lastActivityAt = 1_000, now = 3_000))
        assertEquals(setOf("/a", "/b"), mergeWatcherScopes(setOf("/a"), setOf("/b")))
        assertEquals(null, mergeWatcherScopes(null, setOf("/b")))
        assertEquals(null, mergeWatcherScopes(
            (0 until MAX_DIRTY_SYNC_SCOPE).map { "/d$it" }.toSet(), setOf("/overflow")))
    }

    @Test
    fun sustainedRawActivityDefersSettleUntilOneFinalQuietRun() {
        var lastActivity = 0L
        var settleRuns = 0
        // 33 seconds at 50ms/event; a dispatched EVENT every 2s must not make raw activity quiet.
        for (now in 0L..33_000L step 50L) {
            lastActivity = acceptWatcherActivityAt(7, 7, lastActivity, now)!!
            if (now % WATCHER_DISPATCH_QUIET_MS == 0L && now > 0L) {
                assertTrue(watcherQuietRemainingMs(lastActivity, now) > 0L)
            }
        }
        assertTrue(watcherQuietRemainingMs(lastActivity, 35_499L) > 0L)
        if (watcherQuietRemainingMs(lastActivity, 35_500L) == 0L) settleRuns++
        assertEquals(1, settleRuns)
        // Once consumed there is no periodic task: 95s idle cannot create another run.
        assertEquals(1, settleRuns)
    }

    @Test
    fun timerRaceOldSourceAndPauseResumeUseMonotonicActivity() {
        val active = 9L
        var last = acceptWatcherActivityAt(active, active, 0L, 2_499L)!!
        // Timer for the old 2.5s deadline fires one millisecond later; it must defer.
        assertEquals(2_499L, watcherQuietRemainingMs(last, 2_500L))
        // A stale watcher cannot extend the new watcher's deadline.
        assertEquals(null, acceptWatcherActivityAt(active, 8L, last, 9_000L))
        assertEquals(0L, watcherQuietRemainingMs(last, 4_999L))
        // Resume establishes a fresh activity baseline and therefore a fresh quiet interval.
        last = acceptWatcherActivityAt(active, active, last, 10_000L)!!
        assertEquals(WATCHER_SETTLE_QUIET_MS,
            watcherQuietRemainingMs(last, 10_000L))
    }

    @Test
    fun settleFixtureConvergesPartialCreateAndRenameDeleteBursts() {
        val expected = (0 until 100).map { "file-$it" }.toSet()
        val firstVisible = (0 until 81).map { "file-$it" }.toSet()
        val first = planScopedChildDelta(emptySet(), firstVisible)
        assertEquals(81, first.added.size)
        val settle = planScopedChildDelta(firstVisible, expected)
        assertEquals(19, settle.added.size)
        assertTrue(settle.removed.isEmpty())

        val before = setOf("keep", "old-name", "deleted")
        val burstPartial = setOf("keep", "new-name", "deleted")
        val final = setOf("keep", "new-name")
        assertEquals(setOf("new-name"), planScopedChildDelta(before, burstPartial).added)
        val settled = planScopedChildDelta(burstPartial, final)
        assertTrue(settled.added.isEmpty())
        assertEquals(setOf("deleted"), settled.removed)
    }

    @Test
    fun rootScopeHasStrictShellCallBoundAndUnknownTargetsAreRejected() {
        assertFalse(shouldEscalateScopedRoot(MAX_SCOPED_ROOT_SHELL_CALLS))
        assertTrue(shouldEscalateScopedRoot(MAX_SCOPED_ROOT_SHELL_CALLS + 1))
        val budget = ScopedRootCallBudget()
        repeat(MAX_SCOPED_ROOT_SHELL_CALLS) { assertTrue(budget.tryAcquire()) }
        assertFalse(budget.tryAcquire())
        assertEquals(MAX_SCOPED_ROOT_SHELL_CALLS, budget.usedCalls())
        val roots = listOf("/storage/emulated/0", "/data/data")
        assertTrue(allDirtyTargetsRouted(
            listOf("/storage/emulated", "/storage/emulated/0/DCIM"), roots))
        assertFalse(allDirtyTargetsRouted(
            listOf("/storage/emulated/0/DCIM", "/unrouted/path"), roots))
        assertTrue(isSyncScopeComplete(true, true, listOf(true, true)))
        assertFalse(isSyncScopeComplete(false, true, listOf(true))) // scan-priority abort
        assertFalse(isSyncScopeComplete(true, false, emptyList()))
        assertFalse(isSyncScopeComplete(true, true, listOf(true, false)))
    }

    @Test
    fun healthyWatcherConfigUpdateRoutesNextDirtyToNewConfig() {
        val router = WatcherSyncConfigRouter<String>()
        assertEquals(null, router.updateConfig("old", desiredForeground = true))
        assertEquals(null, router.updateConfig("new", desiredForeground = true))
        val work = router.offer(setOf("/dirty"))!!
        assertEquals("new", work.config)
    }

    @Test
    fun activeSyncConfigUpdateRoutesNotificationAndTrailingToNewConfig() {
        val router = WatcherSyncConfigRouter<String>()
        router.updateConfig("old", desiredForeground = true)
        val active = router.offer(setOf("/first"))!!
        assertEquals("old", active.config)
        router.offer(setOf("/during"))
        router.updateConfig("new", desiredForeground = true)
        val completion = router.complete(active,
            successfulAndComplete = true, allowTrailing = true)
        assertEquals("new", completion.notifyConfig)
        assertEquals("new", completion.trailing!!.config)
        assertEquals(setOf("/during"), completion.trailing.launch.dirtyDirectories)
    }

    @Test
    fun stoppedRouterKeepsPendingButCannotLaunchWithoutConfig() {
        val router = WatcherSyncConfigRouter<String>()
        router.updateConfig("old", desiredForeground = true)
        router.updateConfig(null, desiredForeground = false)
        assertEquals(null, router.offer(setOf("/paused")))
        val resumed = router.updateConfig("new", desiredForeground = true)!!
        assertEquals("new", resumed.config)
        assertEquals(setOf("/paused"), resumed.launch.dirtyDirectories)
    }
}
