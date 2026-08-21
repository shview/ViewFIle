package com.viewfile.viewfile.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WatcherProtocolTest {
    @Test
    fun parsesExactReadyHandshake() {
        assertEquals(WatcherProtocol.Ready(12, 12), WatcherProtocol.parseReady("R 12 12"))
        assertNull(WatcherProtocol.parseReady("D 1"))
        assertNull(WatcherProtocol.parseReady("R 12"))
        assertNull(WatcherProtocol.parseReady("R -1 0"))
        assertNull(WatcherProtocol.parseReady(" R 12 12"))
    }

    @Test
    fun acceptsOnlyCompleteExpectedCoverageWithinCap() {
        assertTrue(WatcherProtocol.coversExpected(12, WatcherProtocol.Ready(12, 12)))
        assertFalse(WatcherProtocol.coversExpected(12, WatcherProtocol.Ready(12, 11)))
        assertFalse(WatcherProtocol.coversExpected(12, WatcherProtocol.Ready(11, 11)))
        assertFalse(
            WatcherProtocol.coversExpected(
                WatcherProtocol.MAX_WATCH + 1,
                WatcherProtocol.Ready(WatcherProtocol.MAX_WATCH + 1, WatcherProtocol.MAX_WATCH)
            )
        )
    }

    @Test
    fun parsesOnlyBoundedExactDirtyOrdinals() {
        assertEquals(0, WatcherProtocol.parseDirtyOrdinal("D 0", 2))
        assertEquals(1, WatcherProtocol.parseDirtyOrdinal("D 1", 2))
        assertNull(WatcherProtocol.parseDirtyOrdinal("D 2", 2))
        assertNull(WatcherProtocol.parseDirtyOrdinal("D -1", 2))
        assertNull(WatcherProtocol.parseDirtyOrdinal("D  1", 2))
        assertNull(WatcherProtocol.parseDirtyOrdinal(" D 1", 2))
        assertNull(WatcherProtocol.parseDirtyOrdinal("E", 2))
        assertNull(WatcherProtocol.parseDirtyOrdinal("D nope", 2))
    }

    @Test
    fun filtersOnlyViewFileDatabaseDirectories() {
        assertFalse(WatcherEventFilter.shouldTriggerSync(
            "/data/data/com.viewfile.viewfile/databases"))
        assertFalse(WatcherEventFilter.shouldTriggerSync(
            "/data/user/0/com.viewfile.viewfile/databases/aux"))
        assertFalse(WatcherEventFilter.shouldTriggerSync(
            "/data/data/com.viewfile.viewfile/databases/"))
        assertTrue(WatcherEventFilter.shouldTriggerSync(
            "/data/data/com.viewfile.viewfile/files"))
        assertTrue(WatcherEventFilter.shouldTriggerSync(
            "/data/data/com.other.app/databases"))
        assertTrue(WatcherEventFilter.shouldTriggerSync("/storage/emulated/0"))
    }

    @Test
    fun staleReaderAndStoppedHandshakeCannotAffectSuccessor() {
        val oldProcess = Any()
        val successor = Any()
        assertTrue(shouldHandleWatcherFailure(true, oldProcess, oldProcess))
        assertFalse(shouldHandleWatcherFailure(false, oldProcess, oldProcess))
        assertFalse(shouldHandleWatcherFailure(true, successor, oldProcess))
        assertFalse(shouldHandleWatcherFailure(true, null, oldProcess))
    }

    @Test
    fun generationSupersedesHandshakeRefreshAndBackgroundFallback() {
        val starting = WatcherDesiredState(running = true, generation = 1, rootMode = true)
        assertTrue(isWatcherRequestCurrent(starting, 1, requireRoot = true))

        val stoppedDuringHandshake = WatcherDesiredState(false, 2, rootMode = true)
        assertFalse(isWatcherRequestCurrent(stoppedDuringHandshake, 1, requireRoot = true))

        val refreshed = WatcherDesiredState(true, 2, rootMode = true)
        assertFalse(isWatcherRequestCurrent(refreshed, 1, requireRoot = true))
        assertTrue(isWatcherRequestCurrent(refreshed, 2, requireRoot = true))

        val mediaMode = WatcherDesiredState(true, 3, rootMode = false)
        assertFalse(isWatcherRequestCurrent(mediaMode, 3, requireRoot = true))
        assertTrue(isWatcherRequestCurrent(mediaMode, 3, requireRoot = false))
    }

    @Test
    fun processCoordinatorSerializesInstancesAndRestrictsGlobalPkill() {
        assertEquals(1, WATCHER_COORDINATOR_EXECUTOR_COUNT)
        val oldOwner = Any()
        val newOwner = Any()
        val afterNewStart = GlobalWatcherCoordinatorState(newOwner, 2, helperMayExist = true)
        assertFalse(mayUseGlobalWatcherPkill(
            afterNewStart, oldOwner, ticket = 1, stopRequest = true))
        assertTrue(mayUseGlobalWatcherPkill(
            afterNewStart, newOwner, ticket = 2, stopRequest = false))

        val latestStop = GlobalWatcherCoordinatorState(null, 3, helperMayExist = true)
        assertTrue(mayUseGlobalWatcherPkill(
            latestStop, newOwner, ticket = 3, stopRequest = true))
        assertFalse(mayUseGlobalWatcherPkill(
            latestStop, oldOwner, ticket = 1, stopRequest = true))
    }

    @Test
    fun staleOldStopAfterNewStartDoesNotCancelNewOwnerEpoch() {
        val oldOwner = Any()
        val newOwner = Any()
        val oldRunning = GlobalWatcherCoordinatorState(oldOwner, 1, helperMayExist = true)
        val newStart = planGlobalWatcherStart(oldRunning, newOwner)
        val staleOldStop = planGlobalWatcherStop(newStart.state, oldOwner)

        assertEquals(2, staleOldStop.ticket)
        assertEquals(2, staleOldStop.state.epoch)
        assertTrue(staleOldStop.state.desiredOwner === newOwner)
        assertFalse(staleOldStop.ownsGlobalStop)
        assertFalse(mayUseGlobalWatcherPkill(
            staleOldStop.state, oldOwner, staleOldStop.ticket, stopRequest = false))
    }

    @Test
    fun oldStopBeforeNewStartPreservesStopThenStartOrdering() {
        val oldOwner = Any()
        val newOwner = Any()
        val oldRunning = GlobalWatcherCoordinatorState(oldOwner, 1, helperMayExist = true)
        val oldStop = planGlobalWatcherStop(oldRunning, oldOwner)
        val newStart = planGlobalWatcherStart(oldStop.state, newOwner)

        assertTrue(oldStop.ownsGlobalStop)
        assertEquals(2, oldStop.ticket)
        assertNull(oldStop.state.desiredOwner)
        assertEquals(3, newStart.ticket)
        assertTrue(newStart.state.desiredOwner === newOwner)
    }

    @Test
    fun pkillExitCodesAreFailClosedAndControlRootLaunch() {
        assertTrue(isSafePkillExit(0))
        assertTrue(isSafePkillExit(1))
        for (code in listOf(2, 126, 127, -1)) assertFalse(isSafePkillExit(code))
        assertTrue(isNativeHelperCleanupSafe(listOf(0)))
        assertTrue(isNativeHelperCleanupSafe(listOf(1)))
        assertTrue(isNativeHelperCleanupSafe(listOf(0, 1)))
        assertFalse(isNativeHelperCleanupSafe(listOf(0, 2)))
        assertFalse(isNativeHelperCleanupSafe(emptyList()))
        assertEquals(listOf(WatcherHelperBackend.SU),
            requiredCleanupBackends(WatcherHelperBackend.SU))
        assertEquals(listOf(WatcherHelperBackend.SHIZUKU),
            requiredCleanupBackends(WatcherHelperBackend.SHIZUKU))
        assertEquals(listOf(WatcherHelperBackend.SU, WatcherHelperBackend.SHIZUKU),
            requiredCleanupBackends(WatcherHelperBackend.UNKNOWN))

        assertTrue(shouldLaunchRootHelper(
            WatcherCleanupResult(required = false, succeeded = true)))
        assertTrue(shouldLaunchRootHelper(
            WatcherCleanupResult(required = true, succeeded = true)))
        val failedCleanup = WatcherCleanupResult(required = true, succeeded = false)
        assertFalse(shouldLaunchRootHelper(failedCleanup))
        assertTrue(shouldKeepCleanupPending(failedCleanup))
        assertEquals(WatcherPostCleanupMode.MEDIA_FALLBACK, postCleanupMode(failedCleanup))
        val completedCleanup = WatcherCleanupResult(required = true, succeeded = true)
        assertFalse(shouldKeepCleanupPending(completedCleanup))
        assertEquals(WatcherPostCleanupMode.ROOT_HELPER, postCleanupMode(completedCleanup))
    }

    @Test
    fun pkillPatternMatchesHelperButNotItsOwnShellCommand() {
        val helperPath =
            "/data/app/~~id/com.viewfile.viewfile-AbC/lib/arm64/libvfwatch.so"
        val identity = nativeHelperIdentityPattern(helperPath)!!
        val command = nativeHelperPkillCommand(identity)
        assertTrue(nativeHelperIdentityMatches(identity, helperPath))
        assertFalse(nativeHelperIdentityMatches(identity,
            "/data/app/~~id/com.other.app-AbC/lib/arm64/libvfwatch.so"))
        assertFalse(nativeHelperIdentityMatches(identity, command))
        assertFalse(nativeHelperIdentityMatches(identity, "sh -c $command"))
        assertFalse(nativeHelperIdentityMatches(identity, "su -c ${shq(command)}"))
        assertFalse(nativeHelperIdentityMatches(identity,
            "ps -A | grep libvfwatch.so"))
        assertFalse(nativeHelperIdentityMatches(identity, "cat $helperPath"))
        assertTrue(nativeHelperIdentityMatches(identity, "  $helperPath"))
        assertFalse(nativeHelperIdentityMatches(identity, "$helperPath --diagnostic"))
        assertNull(nativeHelperIdentityPattern("/data/local/tmp/libvfwatch.so"))
        assertNull(nativeHelperIdentityPattern(
            "/data/app/~~id/com.viewfile.viewfile.evil/lib/arm64/libvfwatch.so"))

        val packageWide = nativeHelperPackageWideIdentityPattern()
        val oldInstall =
            "/data/app/com.viewfile.viewfile-1/lib/arm/libvfwatch.so"
        val newInstall =
            "/data/app/~~A_b-9==/com.viewfile.viewfile-X_y-2==/lib/arm64/libvfwatch.so"
        assertTrue(nativeHelperIdentityMatches(packageWide, oldInstall))
        assertTrue(nativeHelperIdentityMatches(packageWide, newInstall))
        assertFalse(nativeHelperIdentityMatches(packageWide,
            "/data/app/com.viewfile.viewfile.evil-1/lib/arm/libvfwatch.so"))
        assertFalse(nativeHelperIdentityMatches(packageWide,
            "/data/app/com.other.app-1/lib/arm/libvfwatch.so"))
        assertFalse(nativeHelperIdentityMatches(packageWide,
            "/data/app/com.viewfile.viewfile-1/lib/arm/libother.so"))
        val wideCommand = nativeHelperPkillCommand(packageWide)
        assertFalse(nativeHelperIdentityMatches(packageWide, wideCommand))
        assertFalse(nativeHelperIdentityMatches(packageWide, "cat $oldInstall"))
        // Cleared prefs + changed install hash: exact current identity misses old, package-wide finds it.
        assertFalse(nativeHelperIdentityMatches(identity, oldInstall))
    }

    @Test
    fun firstNativeStartPreflightsOrphanAndRetriesOnlyAfterFailure() {
        val identity = nativeHelperIdentityPattern(
            "/data/app/~~id/com.viewfile.viewfile-AbC/lib/arm64/libvfwatch.so")!!
        val initial = WatcherOrphanPreflightState()
        assertTrue(needsWatcherOrphanPreflight(initial, identity))

        val failed = WatcherCleanupResult(required = true, succeeded = false)
        assertEquals(WatcherPostCleanupMode.MEDIA_FALLBACK, postCleanupMode(failed))
        // Failure does not complete the state, so refresh retries the cleanup.
        assertTrue(needsWatcherOrphanPreflight(initial, identity))

        val completed = completeWatcherOrphanPreflight(initial, identity)
        assertFalse(needsWatcherOrphanPreflight(completed, identity))
        assertEquals(WatcherPostCleanupMode.ROOT_HELPER,
            postCleanupMode(WatcherCleanupResult(required = true, succeeded = true)))

        // Cleared state + current root can directly prove cleanup. Fresh Shizuku must verify;
        // a persisted SU helper with only current Shizuku remains fail-closed.
        assertEquals(WatcherPreflightMethod.DIRECT_PKILL,
            watcherPreflightMethod(recordedBackend = null,
                currentBackend = WatcherHelperBackend.SU))
        assertEquals(WatcherPreflightMethod.SHIZUKU_VERIFY_THEN_PKILL,
            watcherPreflightMethod(recordedBackend = WatcherHelperBackend.SHIZUKU,
                currentBackend = WatcherHelperBackend.SHIZUKU))
        assertEquals(WatcherPreflightMethod.FAIL_CLOSED,
            watcherPreflightMethod(recordedBackend = WatcherHelperBackend.SU,
                currentBackend = WatcherHelperBackend.SHIZUKU))
        assertEquals(WatcherPreflightMethod.SHIZUKU_VERIFY_THEN_PKILL,
            watcherPreflightMethod(recordedBackend = null,
                currentBackend = WatcherHelperBackend.SHIZUKU))
        assertTrue(isWatcherVisibilityCleanupSafe(
            WatcherVisibilityCleanupResult.ABSENT))
        assertTrue(isWatcherVisibilityCleanupSafe(
            WatcherVisibilityCleanupResult.CLEARED))
        assertFalse(isWatcherVisibilityCleanupSafe(
            WatcherVisibilityCleanupResult.UNVERIFIABLE))
        assertEquals(WatcherPostCleanupMode.ROOT_HELPER, postCleanupMode(
            watcherCleanupFromVisibility(WatcherVisibilityCleanupResult.ABSENT)))
        assertEquals(WatcherPostCleanupMode.ROOT_HELPER, postCleanupMode(
            watcherCleanupFromVisibility(WatcherVisibilityCleanupResult.CLEARED)))
        // Covers ps failure and a visible helper that remains after an unprivileged kill.
        assertEquals(WatcherPostCleanupMode.MEDIA_FALLBACK, postCleanupMode(
            watcherCleanupFromVisibility(WatcherVisibilityCleanupResult.UNVERIFIABLE)))
        assertEquals(WatcherHelperBackend.SU, effectiveWatcherCleanupBackend(
            recordedBackend = WatcherHelperBackend.SHIZUKU,
            currentBackend = WatcherHelperBackend.SU))
        assertEquals(WatcherHelperBackend.SU, effectiveWatcherCleanupBackend(
            recordedBackend = WatcherHelperBackend.SU,
            currentBackend = WatcherHelperBackend.SHIZUKU))
    }
}
