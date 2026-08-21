package com.viewfile.viewfile.core

internal const val MAX_DIRTY_SYNC_SCOPE = 256
internal const val MAX_SCOPED_ROOT_SHELL_CALLS = 16

enum class WatcherMode { MEDIA, SU, SHIZUKU }

internal fun expectedWatcherMode(
    rootIndex: Boolean,
    rootTier: Boolean,
    shizukuTier: Boolean,
): WatcherMode = when {
    !rootIndex -> WatcherMode.MEDIA
    rootTier -> WatcherMode.SU
    shizukuTier -> WatcherMode.SHIZUKU
    else -> WatcherMode.MEDIA
}

internal fun shouldReuseWatcher(
    running: Boolean,
    watchedDirCount: Int,
    actualMode: WatcherMode,
    expectedMode: WatcherMode,
): Boolean = running && watchedDirCount > 0 && actualMode == expectedMode

internal data class DirtyScopePlan(
    val full: Boolean,
    val requestedCount: Int,
    val targets: List<String>,
)

/** Normalize display paths, de-duplicate exact events, then add each parent for self-delete. */
internal fun planDirtyScope(
    dirtyDirectories: Set<String>?,
    cap: Int = MAX_DIRTY_SYNC_SCOPE,
): DirtyScopePlan {
    if (dirtyDirectories == null) return DirtyScopePlan(true, 0, emptyList())
    val normalized = dirtyDirectories.asSequence()
        .map { normalizeDirtyPath(it) }
        .filter { it.isNotEmpty() }
        .distinct()
        .sortedWith(compareBy<String> { it.length }.thenBy { it })
        .toList()
    if (normalized.isEmpty() || normalized.size > cap) {
        return DirtyScopePlan(true, normalized.size, emptyList())
    }
    val targets = LinkedHashSet<String>()
    // Do not drop a dirty descendant merely because its ancestor is also dirty: scoped
    // reconciliation is direct-children-only, so both levels carry distinct information.
    for (path in normalized) {
        dirtyParent(path)?.let(targets::add)
        targets.add(path)
    }
    if (targets.size > cap) return DirtyScopePlan(true, normalized.size, emptyList())
    return DirtyScopePlan(false, normalized.size,
        targets.sortedWith(compareBy<String> { it.length }.thenBy { it }))
}

internal fun normalizeDirtyPath(path: String): String {
    val trimmed = path.trim().replace(Regex("/+"), "/").trimEnd('/')
    return if (trimmed.isEmpty()) "/" else trimmed
}

internal fun dirtyParent(path: String): String? {
    if (path == "/") return null
    return path.substringBeforeLast('/').ifEmpty { "/" }
}

internal fun dirtyTargetsInArea(targets: List<String>, area: String): List<String> =
    targets.filter { it == area || it.startsWith("$area/") }

internal fun allDirtyTargetsRouted(targets: Collection<String>, roots: Collection<String>): Boolean {
    val routed = targets.filter { path ->
        roots.any { root -> path == root || path.startsWith("$root/") }
    }
    return targets.all { path ->
        path in routed || routed.any { child -> child.startsWith("$path/") }
    }
}

internal fun shouldEscalateScopedRoot(targetCount: Int): Boolean =
    targetCount > MAX_SCOPED_ROOT_SHELL_CALLS

internal class ScopedRootCallBudget(
    private val maximum: Int = MAX_SCOPED_ROOT_SHELL_CALLS,
) {
    private var used = 0
    fun tryAcquire(): Boolean {
        if (used >= maximum) return false
        used++
        return true
    }
    internal fun usedCalls(): Int = used
}

internal fun isSyncScopeComplete(
    traversalCompleted: Boolean,
    fuseOk: Boolean,
    rootProcessing: Collection<Boolean>,
): Boolean = traversalCompleted && fuseOk && rootProcessing.all { it }

internal fun shouldGuardScopedRelist(missingChildren: Int, knownChildren: Int): Boolean =
    missingChildren > 2000 ||
        (knownChildren >= 20 && missingChildren > knownChildren / 5)

internal data class ScopedChildDelta(
    val added: Set<String>,
    val removed: Set<String>,
)

internal fun planScopedChildDelta(
    knownChildren: Set<String>,
    actualChildren: Set<String>,
): ScopedChildDelta = ScopedChildDelta(
    added = actualChildren - knownChildren,
    removed = knownChildren - actualChildren,
)

/** Main-thread-owned bounded accumulator. null is the sticky full-sync marker. */
internal class DirtyScopeAccumulator(
    private val cap: Int = MAX_DIRTY_SYNC_SCOPE,
) {
    private val paths = LinkedHashSet<String>()
    private var full = false

    fun add(path: String?) {
        if (full) return
        if (path == null) {
            full = true
            paths.clear()
            return
        }
        paths.add(path)
        if (paths.size > cap) {
            full = true
            paths.clear()
        }
    }

    fun take(): Set<String>? {
        val result = if (full) null else paths.toSet()
        full = false
        paths.clear()
        return result
    }

    internal fun retainedPathCount(): Int = paths.size
    internal fun requiresFull(): Boolean = full
}

internal data class WatcherSyncLaunch(
    val dirtyDirectories: Set<String>?,
    val recoveryAttempt: Boolean,
)

/**
 * Single-flight watcher-sync coalescer. Full scope dominates dirty paths.
 * A failed scoped run gets exactly one immediate full recovery; failed full
 * remains sticky until a later event/lifecycle/manual kick, never busy-loops.
 */
internal class WatcherSyncCoalescer {
    private var running = false
    private var pending = false
    private var pendingFull = false
    private val pendingDirty = LinkedHashSet<String>()

    fun submit(
        dirtyDirectories: Set<String>?,
        allowLaunch: Boolean = true,
    ): WatcherSyncLaunch? {
        merge(dirtyDirectories)
        return if (running || !allowLaunch) null else take(recoveryAttempt = false)
    }

    fun complete(
        launch: WatcherSyncLaunch,
        successfulAndComplete: Boolean,
        allowTrailing: Boolean,
    ): WatcherSyncLaunch? {
        check(running)
        running = false
        if (!successfulAndComplete) merge(null)
        if (!allowTrailing) return null
        if (!successfulAndComplete &&
            (launch.recoveryAttempt || launch.dirtyDirectories == null)
        ) return null
        return take(recoveryAttempt = !successfulAndComplete)
    }

    /** Retry sticky work after a later lifecycle/manual/event trigger. */
    fun kick(): WatcherSyncLaunch? = if (running) null else take(recoveryAttempt = false)

    private fun merge(dirtyDirectories: Set<String>?) {
        pending = true
        if (dirtyDirectories == null) {
            pendingFull = true
            pendingDirty.clear()
        } else if (!pendingFull) {
            pendingDirty.addAll(dirtyDirectories)
            if (pendingDirty.size > MAX_DIRTY_SYNC_SCOPE) {
                pendingFull = true
                pendingDirty.clear()
            }
        }
    }

    private fun take(recoveryAttempt: Boolean): WatcherSyncLaunch? {
        if (!pending) return null
        val scope = if (pendingFull) null else pendingDirty.toSet()
        pending = false
        pendingFull = false
        pendingDirty.clear()
        running = true
        return WatcherSyncLaunch(scope, recoveryAttempt)
    }

    internal fun isRunning(): Boolean = running
    internal fun hasPendingFull(): Boolean = pending && pendingFull
}

internal data class RoutedWatcherSync<C>(
    val launch: WatcherSyncLaunch,
    val config: C,
)

internal data class RoutedWatcherSyncCompletion<C>(
    val notifyConfig: C?,
    val trailing: RoutedWatcherSync<C>?,
)

/** Binds every newly launched scope to the latest foreground configuration. */
internal class WatcherSyncConfigRouter<C> {
    private val coalescer = WatcherSyncCoalescer()
    private var config: C? = null
    private var desiredForeground = false

    fun updateConfig(config: C?, desiredForeground: Boolean): RoutedWatcherSync<C>? {
        this.config = config
        this.desiredForeground = desiredForeground
        return kick()
    }

    fun offer(dirtyDirectories: Set<String>?): RoutedWatcherSync<C>? {
        val current = config
        val launch = coalescer.submit(
            dirtyDirectories,
            allowLaunch = desiredForeground && current != null,
        ) ?: return null
        return RoutedWatcherSync(launch, current!!)
    }

    fun complete(
        work: RoutedWatcherSync<C>,
        successfulAndComplete: Boolean,
        allowTrailing: Boolean,
    ): RoutedWatcherSyncCompletion<C> {
        val current = config.takeIf { desiredForeground }
        val next = coalescer.complete(
            work.launch,
            successfulAndComplete,
            allowTrailing = allowTrailing && current != null,
        )
        return RoutedWatcherSyncCompletion(
            notifyConfig = current,
            trailing = if (next == null || current == null) null
                else RoutedWatcherSync(next, current),
        )
    }

    fun kick(): RoutedWatcherSync<C>? {
        val current = config
        if (!desiredForeground || current == null) return null
        val launch = coalescer.kick() ?: return null
        return RoutedWatcherSync(launch, current)
    }
}

internal data class WatcherForegroundState(
    val latestIntent: Long = Long.MIN_VALUE,
    val desiredForeground: Boolean = false,
    val ensuredIntent: Long = Long.MIN_VALUE,
)

internal data class WatcherForegroundTransition(
    val state: WatcherForegroundState,
    val accepted: Boolean,
    val ensureWatcher: Boolean,
    val stopWatcher: Boolean,
)

/** Monotonic lifecycle ids make delivery reordering latest-intent-wins. */
internal fun applyWatcherForegroundIntent(
    state: WatcherForegroundState,
    intent: Long,
    foreground: Boolean,
): WatcherForegroundTransition {
    if (intent < state.latestIntent) {
        return WatcherForegroundTransition(state, false, false, false)
    }
    if (foreground) {
        val ensure = !state.desiredForeground || state.ensuredIntent != intent
        return WatcherForegroundTransition(
            state.copy(latestIntent = intent, desiredForeground = true,
                ensuredIntent = if (ensure) intent else state.ensuredIntent),
            true, ensure, false,
        )
    }
    val stop = state.desiredForeground || intent > state.latestIntent
    return WatcherForegroundTransition(
        state.copy(latestIntent = intent, desiredForeground = false),
        true, false, stop,
    )
}
