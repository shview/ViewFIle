package com.viewfile.viewfile.core

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeWatcherSourceContractTest {
    @Test
    fun watchModeSetsDedicatedCommBeforeCreatingInotifyButRenameDoesNot() {
        val source = File("src/main/cpp/vfwatch.c").readText()
        val renameDispatch = source.indexOf("return rename_noreplace(argv[2], argv[3]);")
        val watchName = source.indexOf("prctl(PR_SET_NAME, WATCH_COMM")
        val failClosed = source.indexOf("return 1;", watchName)
        val inotifyStart = source.indexOf("inotify_init1(IN_CLOEXEC)")

        assertTrue(renameDispatch >= 0)
        assertTrue(watchName > renameDispatch)
        assertTrue(failClosed > watchName && failClosed < inotifyStart)
        assertTrue(inotifyStart > watchName)
        assertTrue(source.contains("#define WATCH_COMM \"vf.viewfile.vfw\""))
        assertTrue(source.contains("_Static_assert(sizeof(WATCH_COMM) <= 16"))
    }
}
