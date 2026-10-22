package com.zonahbear.cratebox.core

import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** The iOS suite's test fixtures (ios/CrateboxKit/Tests/CrateboxKitTests/Fixtures), shared, not copied. */
object Fixtures {
    val dir: File = File(System.getProperty("cratebox.repo") ?: "../..", "ios/CrateboxKit/Tests/CrateboxKitTests/Fixtures")
    fun file(name: String) = File(dir, name)
    fun bytes(name: String): ByteArray = file(name).readBytes()
    fun text(name: String): String = file(name).readText()
    /** little-endian float32 */
    fun floats(name: String): FloatArray {
        val b = ByteBuffer.wrap(bytes(name)).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
        return FloatArray(b.remaining()).also { b.get(it) }
    }
}
