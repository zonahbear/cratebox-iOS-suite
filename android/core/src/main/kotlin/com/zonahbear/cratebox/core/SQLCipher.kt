// SQLCipher 4 page codec (default settings: 4096-byte pages, PBKDF2-HMAC-SHA512 with 256 000 rounds,
// AES-256-CBC, a 16-byte IV and a 64-byte HMAC-SHA512 in each page's reserved 80 bytes). A port of
// SQLCipher.swift on javax.crypto (Android has it too).
//
// rekordbox's OneLibrary database on a USB stick (PIONEER/rekordbox/exportLibrary.db) is a SQLite file
// encrypted this way, with one key for every stick (pyrekordbox, MIT licence, documents it). Cratebox decrypts
// the whole file to a temporary plain SQLite database, reads (or edits) that, and encrypts it again page by
// page. Decrypting and re-encrypting with the same salt and IVs gives back the identical file (see the tests).
package com.zonahbear.cratebox.core

import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

class SQLCipherError(message: String, val page: Int? = null) : Exception(message) {
    override fun equals(other: Any?) = other is SQLCipherError && other.message == message
    override fun hashCode() = message.hashCode()
    companion object {
        fun tooSmall() = SQLCipherError("the database file is too small to be SQLCipher")
        fun badHMAC(page: Int) = SQLCipherError("page $page failed its integrity check (wrong key, or the file is damaged)", page)
        fun notSQLite() = SQLCipherError("the decrypted data isn't a SQLite database")
    }
}

/** keys for a file, from its passphrase and the salt in its first 16 bytes (slow: 256 000 rounds) */
class SQLCipherCodec(passphrase: String, val salt: ByteArray) {
    val key: ByteArray = pbkdf2(passphrase.toByteArray(Charsets.UTF_8), salt, 256_000, 32)
    val hmacKey: ByteArray = pbkdf2(key, ByteArray(salt.size) { (salt[it].toInt() xor 0x3a).toByte() }, 2, 32)

    companion object {
        const val PAGE_SIZE = 4096; const val RESERVE = 80; const val SALT_LEN = 16; const val IV_LEN = 16; const val HMAC_LEN = 64
        private val header = "SQLite format 3\u0000".toByteArray(Charsets.UTF_8)

        /** the OneLibrary key (kept masked so it doesn't sit in the binary as plain text) */
        val oneLibraryPassphrase: String by lazy {
            val masked = intArrayOf(0x31, 0x4a, 0x06, 0x10, 0x01, 0x0c, 0x1d, 0x4c, 0x4b, 0x6d, 0x67, 0x75, 0x18, 0x1c, 0x1f, 0x22, 0x00, 0x57, 0x17, 0x14, 0x18, 0x0d, 0x13, 0x4b, 0x65, 0x36, 0x2e, 0x16, 0x5e, 0x56, 0x37, 0x1f,
                0x03, 0x47, 0x11, 0x10, 0x0d, 0x1a, 0x58, 0x6d, 0x63, 0x77, 0x4a, 0x42, 0x18, 0x77, 0x04, 0x04, 0x0e, 0x53, 0x56, 0x06, 0x4d, 0x4f, 0x6d, 0x35, 0x2c, 0x52, 0x5e, 0x5d, 0x3a, 0x03, 0x0d, 0x07)
            val mask = "Cratebox USB //".toByteArray(Charsets.UTF_8)
            String(ByteArray(masked.size) { (masked[it] xor mask[it % mask.size].toInt()).toByte() }, Charsets.UTF_8)
        }

        fun isPlainSQLite(b: ByteArray) = b.size >= 16 && b.copyOfRange(0, 16).contentEquals(header)

        // ---- primitives ----
        internal fun le32(v: Int) = byteArrayOf((v and 0xff).toByte(), ((v shr 8) and 0xff).toByte(), ((v shr 16) and 0xff).toByte(), ((v ushr 24) and 0xff).toByte())
        private val rng = SecureRandom()
        internal fun random(n: Int) = ByteArray(n).also { rng.nextBytes(it) }

        /** PBKDF2-HMAC-SHA512 over raw bytes (the JCE's PBEKeySpec takes chars, and the HMAC key's "password" is binary) */
        internal fun pbkdf2(pass: ByteArray, salt: ByteArray, rounds: Int, length: Int): ByteArray {
            val mac = Mac.getInstance("HmacSHA512")
            mac.init(SecretKeySpec(pass, "HmacSHA512"))
            val out = ByteArray(length)
            var block = 1; var at = 0
            while (at < length) {
                mac.update(salt); mac.update(le32(Integer.reverseBytes(block)))
                var u = mac.doFinal()
                val t = u.copyOf()
                for (r in 1 until rounds) { u = mac.doFinal(u); for (i in t.indices) t[i] = (t[i].toInt() xor u[i].toInt()).toByte() }
                val n = minOf(t.size, length - at)
                t.copyInto(out, at, 0, n); at += n; block += 1
            }
            return out
        }
        internal fun hmac(key: ByteArray, data: ByteArray): ByteArray {
            val mac = Mac.getInstance("HmacSHA512")
            mac.init(SecretKeySpec(key, "HmacSHA512"))
            return mac.doFinal(data)
        }
        /** no padding: every page's encrypted part is a whole number of AES blocks */
        internal fun aes(encrypt: Boolean, key: ByteArray, iv: ByteArray, input: ByteArray): ByteArray {
            val c = Cipher.getInstance("AES/CBC/NoPadding")
            c.init(if (encrypt) Cipher.ENCRYPT_MODE else Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), IvParameterSpec(iv))
            return c.doFinal(input)
        }
    }

    /** the encrypted file → a plain SQLite database (same size: each page's reserved bytes come back as zeros,
     *  which SQLite ignores since the header still says 80 reserved bytes) */
    fun decrypt(data: ByteArray): ByteArray {
        val P = PAGE_SIZE; val R = RESERVE
        if (data.size < P || data.size % P != 0) throw SQLCipherError.tooSmall()
        val out = ByteArray(data.size)
        for (p in 0 until data.size / P) {
            val o = p * P; val start = if (p == 0) SALT_LEN else 0
            val body = data.copyOfRange(o + start, o + P - R + IV_LEN)
            val mac = data.copyOfRange(o + P - R + IV_LEN, o + P)
            val calc = hmac(hmacKey, body + le32(p + 1))
            if (!calc.contentEquals(mac)) throw SQLCipherError.badHMAC(p + 1)
            val iv = data.copyOfRange(o + P - R, o + P - R + IV_LEN)
            val plain = aes(false, key, iv, data.copyOfRange(o + start, o + P - R))
            if (p == 0) header.copyInto(out, 0)
            plain.copyInto(out, o + start)
        }
        if (!isPlainSQLite(out)) throw SQLCipherError.notSQLite()
        return out
    }

    /** a plain SQLite database (with 80 reserved bytes per page) → the encrypted file. `ivs` only for tests (to
     *  compare against a known file); normally every page gets a fresh random IV. */
    fun encrypt(plain: ByteArray, ivs: List<ByteArray>? = null): ByteArray {
        val P = PAGE_SIZE; val R = RESERVE
        if (plain.size < P || plain.size % P != 0) throw SQLCipherError.tooSmall()
        if ((plain[20].toInt() and 0xff) != R) throw SQLCipherError.notSQLite()        // the header's reserved bytes
        val out = java.io.ByteArrayOutputStream(plain.size)
        for (p in 0 until plain.size / P) {
            val o = p * P; val start = if (p == 0) SALT_LEN else 0
            val iv = ivs?.get(p) ?: random(IV_LEN)
            val enc = aes(true, key, iv, plain.copyOfRange(o + start, o + P - R))
            val body = enc + iv
            val mac = hmac(hmacKey, body + le32(p + 1))
            if (p == 0) out.write(salt)
            out.write(body); out.write(mac)
        }
        return out.toByteArray()
    }
}
