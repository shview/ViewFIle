package com.viewfile.viewfile.core

import org.junit.Assert.assertEquals
import org.junit.Test

class NativeRenameProtocolTest {
    @Test
    fun processBuilderArgumentsPreserveSpecialCharacters() {
        assertEquals(
            listOf("/data/app/lib helper.so", "--rename-noreplace", "/a/it's old", "/a/new ; name"),
            NativeRenameProtocol.arguments(
                "/data/app/lib helper.so", "/a/it's old", "/a/new ; name"
            )
        )
    }

    @Test
    fun commandQuotesEveryArgument() {
        assertEquals(
            "'/data/app/lib helper.so' --rename-noreplace '/a/it'\\''s old' '/a/new name'",
            NativeRenameProtocol.command(
                "/data/app/lib helper.so", "/a/it's old", "/a/new name"
            )
        )
    }

    @Test
    fun mapsStableNativeExitCodes() {
        assertEquals("已存在同名项目", NativeRenameProtocol.errorMessage(17))
        assertEquals("重命名失败（不支持跨文件系统）", NativeRenameProtocol.errorMessage(18))
        assertEquals("设备内核不支持安全的无覆盖重命名", NativeRenameProtocol.errorMessage(38))
    }

    @Test
    fun onlyRetriesUnknownResultWhileSourceStillExists() {
        assertEquals(
            NativeRenameProtocol.DirectDecision.SUCCESS,
            NativeRenameProtocol.decideDirectResult(0, sourceExists = false)
        )
        assertEquals(
            NativeRenameProtocol.DirectDecision.CONFLICT,
            NativeRenameProtocol.decideDirectResult(17, sourceExists = true)
        )
        assertEquals(
            NativeRenameProtocol.DirectDecision.RETRY_PRIVILEGED,
            NativeRenameProtocol.decideDirectResult(-1, sourceExists = true)
        )
        assertEquals(
            NativeRenameProtocol.DirectDecision.UNCERTAIN,
            NativeRenameProtocol.decideDirectResult(-1, sourceExists = false)
        )
    }
}
