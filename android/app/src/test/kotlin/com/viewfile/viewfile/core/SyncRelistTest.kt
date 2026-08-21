package com.viewfile.viewfile.core

import org.junit.Assert.assertEquals
import org.junit.Test

class SyncRelistTest {
    @Test
    fun keepsEmptyParentsAndGroupsOnlyExpectedChildren() {
        val grouped = groupRelistedChildren(
            listOf("/a", "/b"),
            listOf("/a" to "one", "/a" to "two", "/unexpected" to "ignored")
        )
        assertEquals(listOf("one", "two"), grouped["/a"])
        assertEquals(emptyList<String>(), grouped["/b"])
        assertEquals(setOf("/a", "/b"), grouped.keys)
    }
}
