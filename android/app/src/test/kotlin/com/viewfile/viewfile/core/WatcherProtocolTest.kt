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
        assertNull(WatcherProtocol.parseReady("E"))
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
        assertTrue(WatcherProtocol.isEvent("E"))
        assertFalse(WatcherProtocol.isEvent("event"))
    }
}
