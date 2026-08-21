package com.viewfile.viewfile.core

import org.junit.Assert.assertEquals
import org.junit.Test

class DirectoryStatsTest {
    @Test
    fun singleChainAggregatesDeepestFirst() {
        val r = aggregateDirectoryStats(
            intArrayOf(-1, 0, 1, 2),
            byteArrayOf(1, 1, 1, 0),
            longArrayOf(0, 0, 0, 9),
            intArrayOf(0, 1, 2, 3)
        )
        assertEquals(DirectoryAggregate(1, 3, 9), r[0])
        assertEquals(DirectoryAggregate(1, 2, 9), r[1])
        assertEquals(DirectoryAggregate(1, 1, 9), r[2])
    }

    @Test
    fun siblingsDoNotLeakIntoEachOther() {
        val r = aggregateDirectoryStats(
            intArrayOf(-1, 0, 0, 1, 2),
            byteArrayOf(1, 1, 1, 0, 0),
            longArrayOf(0, 0, 0, 4, 7),
            intArrayOf(0, 1, 3, 2, 4)
        )
        assertEquals(DirectoryAggregate(2, 4, 11), r[0])
        assertEquals(DirectoryAggregate(1, 1, 4), r[1])
        assertEquals(DirectoryAggregate(1, 1, 7), r[2])
    }

    @Test
    fun emptyDirectoryHasZeroStats() {
        val r = aggregateDirectoryStats(
            intArrayOf(-1), byteArrayOf(1), longArrayOf(0), intArrayOf(0)
        )
        assertEquals(DirectoryAggregate(0, 0, 0), r[0])
    }

    @Test
    fun mixedFilesAndDirectoriesCountAndSizeCorrectly() {
        val r = aggregateDirectoryStats(
            intArrayOf(-1, 0, 0, 0, 1, 1),
            byteArrayOf(1, 1, 0, 0, 0, 1),
            longArrayOf(0, 0, 3, 5, 7, 0),
            intArrayOf(0, 1, 4, 5, 2, 3)
        )
        assertEquals(DirectoryAggregate(3, 5, 15), r[0])
        assertEquals(DirectoryAggregate(2, 2, 7), r[1])
        assertEquals(DirectoryAggregate(0, 0, 0), r[5])
    }
}
