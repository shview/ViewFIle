package com.viewfile.viewfile.core

/** 旧 reader/握手结果只能作用于它自己所属的当前进程。 */
internal fun shouldHandleWatcherFailure(
    running: Boolean,
    currentProcess: Any?,
    failedProcess: Any,
): Boolean = running && currentProcess === failedProcess

internal data class WatcherDesiredState(
    val running: Boolean,
    val generation: Long,
    val rootMode: Boolean,
)

internal fun isWatcherRequestCurrent(
    state: WatcherDesiredState,
    requestGeneration: Long,
    requireRoot: Boolean,
): Boolean = state.running && state.generation == requestGeneration &&
        (!requireRoot || state.rootMode)

internal const val WATCHER_COORDINATOR_EXECUTOR_COUNT = 1

internal data class GlobalWatcherCoordinatorState(
    val desiredOwner: Any?,
    val epoch: Long,
    val helperMayExist: Boolean,
)

internal data class GlobalWatcherTransition(
    val state: GlobalWatcherCoordinatorState,
    val ticket: Long,
    val ownsGlobalStop: Boolean = false,
)

internal fun planGlobalWatcherStart(
    state: GlobalWatcherCoordinatorState,
    owner: Any,
): GlobalWatcherTransition {
    val ticket = state.epoch + 1
    return GlobalWatcherTransition(
        state.copy(desiredOwner = owner, epoch = ticket),
        ticket,
    )
}

/**
 * A stale instance must still detach its own resources, but it must not advance the
 * process-wide epoch: doing so would cancel a successor that has already been queued.
 */
internal fun planGlobalWatcherStop(
    state: GlobalWatcherCoordinatorState,
    owner: Any,
): GlobalWatcherTransition = if (state.desiredOwner === owner) {
    val ticket = state.epoch + 1
    GlobalWatcherTransition(
        state.copy(desiredOwner = null, epoch = ticket),
        ticket,
        ownsGlobalStop = true,
    )
} else {
    GlobalWatcherTransition(state, state.epoch, ownsGlobalStop = false)
}

internal fun mayUseGlobalWatcherPkill(
    state: GlobalWatcherCoordinatorState,
    owner: Any,
    ticket: Long,
    stopRequest: Boolean,
): Boolean = state.helperMayExist && state.epoch == ticket &&
        (state.desiredOwner === owner || (stopRequest && state.desiredOwner == null))

internal enum class WatcherHelperBackend { SU, SHIZUKU, UNKNOWN }

internal data class WatcherCleanupTarget(
    val backend: WatcherHelperBackend,
    val identityPattern: String,
)

private const val VIEWFILE_PACKAGE_SEGMENT = "/com.viewfile.viewfile"
private const val NATIVE_HELPER_BASENAME = "libvfwatch.so"

/** Android 8 legacy and modern install layouts, with no wildcard crossing path segments. */
internal fun nativeHelperPackageWideIdentityPattern(): String =
    "^/data/app/(~~[-_A-Za-z0-9=]+/)?" +
        "com\\.viewfile\\.viewfile-[-_A-Za-z0-9=]+/" +
        "lib/[-_A-Za-z0-9]+/[l]ibvfwatch\\.so$"

/** Exact app-private helper identity; `[l]` prevents matching the pkill/parent shell itself. */
internal fun nativeHelperIdentityPattern(helperPath: String): String? {
    val normalized = helperPath.replace('\\', '/')
    val packageAt = normalized.indexOf(VIEWFILE_PACKAGE_SEGMENT)
    val packageEnd = packageAt + VIEWFILE_PACKAGE_SEGMENT.length
    val packageBoundaryOk = packageAt >= 0 && packageEnd < normalized.length &&
        normalized[packageEnd] in charArrayOf('-', '/')
    if (!normalized.startsWith('/') || '\'' in normalized ||
        !packageBoundaryOk ||
        !normalized.endsWith("/$NATIVE_HELPER_BASENAME")
    ) return null
    val prefix = normalized.dropLast(NATIVE_HELPER_BASENAME.length)
    val escapedPrefix = buildString(prefix.length + 16) {
        for (ch in prefix) {
            if (ch in "\\.^$*+?()[]{}|") append('\\')
            append(ch)
        }
    }
    return "^" + escapedPrefix + "[l]ibvfwatch\\.so$"
}

internal fun nativeHelperPkillCommand(identityPattern: String): String =
    "pkill -f '${identityPattern}'"

internal fun nativeHelperIdentityMatches(identityPattern: String, commandLine: String): Boolean =
    runCatching { Regex(identityPattern).containsMatchIn(commandLine.trimStart()) }
        .getOrDefault(false)

internal fun requiredCleanupBackends(
    backend: WatcherHelperBackend,
): List<WatcherHelperBackend> = when (backend) {
    WatcherHelperBackend.SU -> listOf(WatcherHelperBackend.SU)
    WatcherHelperBackend.SHIZUKU -> listOf(WatcherHelperBackend.SHIZUKU)
    WatcherHelperBackend.UNKNOWN -> listOf(
        WatcherHelperBackend.SU,
        WatcherHelperBackend.SHIZUKU,
    )
}

internal data class WatcherCleanupResult(
    val required: Boolean,
    val succeeded: Boolean,
)

/** pkill: 0=matched/killed, 1=no match; every other exit means cleanup is uncertain. */
internal fun isSafePkillExit(code: Int): Boolean = code == 0 || code == 1

internal fun isNativeHelperCleanupSafe(exitCodes: List<Int>): Boolean =
    exitCodes.isNotEmpty() && exitCodes.all(::isSafePkillExit)

/** A claimed-but-uncertain cleanup must never be followed by another native helper. */
internal fun shouldLaunchRootHelper(cleanup: WatcherCleanupResult): Boolean =
    !cleanup.required || cleanup.succeeded

internal fun shouldKeepCleanupPending(cleanup: WatcherCleanupResult): Boolean =
    cleanup.required && !cleanup.succeeded

internal enum class WatcherPostCleanupMode { ROOT_HELPER, MEDIA_FALLBACK }

internal fun postCleanupMode(cleanup: WatcherCleanupResult): WatcherPostCleanupMode =
    if (shouldLaunchRootHelper(cleanup)) WatcherPostCleanupMode.ROOT_HELPER
    else WatcherPostCleanupMode.MEDIA_FALLBACK

internal data class WatcherOrphanPreflightState(
    val completedIdentities: Set<String> = emptySet(),
)

internal fun needsWatcherOrphanPreflight(
    state: WatcherOrphanPreflightState,
    identityPattern: String,
): Boolean = identityPattern !in state.completedIdentities

internal fun completeWatcherOrphanPreflight(
    state: WatcherOrphanPreflightState,
    identityPattern: String,
): WatcherOrphanPreflightState =
    state.copy(completedIdentities = state.completedIdentities + identityPattern)

internal enum class WatcherPreflightMethod {
    DIRECT_PKILL,
    SHIZUKU_VERIFY_THEN_PKILL,
    FAIL_CLOSED,
}

internal enum class WatcherVisibilityCleanupResult { ABSENT, CLEARED, UNVERIFIABLE }

internal fun isWatcherVisibilityCleanupSafe(
    result: WatcherVisibilityCleanupResult,
): Boolean = result == WatcherVisibilityCleanupResult.ABSENT ||
    result == WatcherVisibilityCleanupResult.CLEARED

internal fun watcherCleanupFromVisibility(
    result: WatcherVisibilityCleanupResult,
): WatcherCleanupResult = WatcherCleanupResult(
    required = true,
    succeeded = isWatcherVisibilityCleanupSafe(result),
)

/** SU can prove/clean either prior backend; Shizuku must verify absence after its attempt. */
internal fun watcherPreflightMethod(
    recordedBackend: WatcherHelperBackend?,
    currentBackend: WatcherHelperBackend,
): WatcherPreflightMethod = if (currentBackend == WatcherHelperBackend.SU) {
    WatcherPreflightMethod.DIRECT_PKILL
} else if (currentBackend == WatcherHelperBackend.SHIZUKU &&
    recordedBackend != WatcherHelperBackend.SU
) {
    // A fresh install may establish trust only by proving the package-wide identity absent
    // (or visibly clearing it). A persisted SU helper remains a higher-privilege uncertainty.
    WatcherPreflightMethod.SHIZUKU_VERIFY_THEN_PKILL
} else {
    // A recorded SU helper cannot be disproved by absence in a lower-privilege Shizuku view.
    WatcherPreflightMethod.FAIL_CLOSED
}

internal fun effectiveWatcherCleanupBackend(
    recordedBackend: WatcherHelperBackend,
    currentBackend: WatcherHelperBackend?,
): WatcherHelperBackend = if (currentBackend == WatcherHelperBackend.SU) {
    WatcherHelperBackend.SU
} else recordedBackend
