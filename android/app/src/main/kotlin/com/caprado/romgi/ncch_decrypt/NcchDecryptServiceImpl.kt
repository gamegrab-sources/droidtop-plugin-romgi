package com.caprado.romgi.ncch_decrypt

import android.os.Handler
import android.os.Looper
import android.util.Log
import java.io.File
import java.io.RandomAccessFile
import java.math.BigInteger
import java.security.MessageDigest
import java.util.concurrent.Executors
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

private const val TAG = "NcchDecryptService"

// Everything below is a from-scratch Kotlin port of the algorithm implemented
// in pyctr (https://github.com/ihaveamac/pyctr, MIT licensed), specifically
// pyctr/crypto/engine.py and pyctr/type/{ncch,cci,exefs}.py. Ported rather
// than vendored because this app targets Android/Kotlin, not Python.
//
// boot9.bin (the user's own ARM9 bootROM dump) is only needed for one thing:
// the 16-byte KeyX for AES keyslot 0x2C ("original NCCH"), read from a fixed
// offset inside its keyblob. Everything else needed for the common case is
// either derived per-file (KeyY, from the NCCH header) or a public constant
// used across the whole 3DS homebrew ecosystem (the extra NCCH keyslots for
// titles released after later system updates) — not a secret unique to any
// console, safe to embed as a literal.

private const val BOOT9_FULL_HASH = "2f88744feed717856386400a44bba4b9ca62e76a32c715d4f309c399bf28166f"
private const val BOOT9_PROT_HASH = "7331f7edece3dd33f2ab4bd0b3a5d607229fd19212c10b734cedcaf78c1a7b98"
private const val KEYBLOB_BASE_OFFSET = 0x5860
private const val KEYX_2C_OFFSET_IN_KEYBLOB = 0x170

// NOTE: declaration order matters here — MASK_128 must be initialized before
// any top-level `val` below it that transitively calls to16ByteArray()
// (Kotlin runs top-level property initializers in file order).
private val MASK_128: BigInteger = BigInteger.ONE.shiftLeft(128).subtract(BigInteger.ONE)
private val KEYSCRAMBLER_CONSTANT = BigInteger("1FF9E9AAC5FE0408024591DC5D52768A", 16)

private fun BigInteger.to16ByteArray(): ByteArray {
    val raw = this.and(MASK_128).toByteArray()
    val out = ByteArray(16)
    if (raw.size >= 16) {
        System.arraycopy(raw, raw.size - 16, out, 0, 16)
    } else {
        System.arraycopy(raw, 0, out, 16 - raw.size, raw.size)
    }
    return out
}

private fun hexToBytes(hex: String): ByteArray =
    BigInteger(hex, 16).to16ByteArray()

private fun rol128(value: BigInteger, bits: Int): BigInteger {
    val r = ((bits % 128) + 128) % 128
    if (r == 0) return value.and(MASK_128)
    return value.shiftLeft(r).or(value.shiftRight(128 - r)).and(MASK_128)
}

/** The 3DS AES key scrambler: normalKey = ROL128((ROL128(keyX, 2) XOR keyY) + C, 87). */
private fun keygenManual(keyX: ByteArray, keyY: ByteArray): ByteArray {
    val x = BigInteger(1, keyX)
    val y = BigInteger(1, keyY)
    val scrambled = rol128(rol128(x, 2).xor(y).add(KEYSCRAMBLER_CONSTANT).and(MASK_128), 87)
    return scrambled.to16ByteArray()
}

/** Public KeyX constants for the "extra" NCCH keyslots, keyed by crypto_method. */
private val EXTRA_KEY_X: Map<Int, BigInteger> = mapOf(
    // crypto_method 0x0A -> keyslot 0x18 (New3DS titles after System Menu 9.3.0-21)
    0x0A to BigInteger("82E9C9BEBFB8BDB875ECC0A07D474374", 16),
    // crypto_method 0x0B -> keyslot 0x1B (New3DS titles after System Menu 9.6.0-24)
    0x0B to BigInteger("45AD04953992C7C893724A9A7BCE6182", 16),
    // crypto_method 0x01 -> keyslot 0x25 (titles after System Menu 7.0.0-13)
    0x01 to BigInteger("CEE7D8AB30C00DAE850EF5E382AC5AF3", 16),
)

private val ZERO_KEY = ByteArray(16)
private val FIXED_SYSTEM_KEY = hexToBytes("527CE630A9CA305F3696F3CDE954194B")

class Boot9InvalidError(message: String) : Exception(message)
class SeedRequiredError(message: String) : Exception(message)
class SeedMismatchError(message: String) : Exception(message)

private data class ExeFsEntry(val name: String, val offset: Int, val size: Int)

/**
 * seeddb.bin format (see pyctr/crypto/seeddb.py): a 4-byte little-endian
 * entry count, padded to a 0x10-byte header, followed by that many 0x20-byte
 * entries — each an 8-byte little-endian Program ID, a 16-byte seed, and
 * 8 bytes of padding. This is a community-maintained database of per-title
 * seeds (originally served by Nintendo's CDN per-console, aggregated across
 * many consoles into one shared file) — not a secret extracted from any one
 * console, but still the user's own file to supply, never bundled here.
 */
private fun loadSeeddb(file: File): Map<Long, ByteArray> {
    val data = file.readBytes()
    if (data.size < 0x10) throw SeedMismatchError("seeddb file is too small to be valid")
    var count = 0L
    for (i in 3 downTo 0) count = (count shl 8) or (data[i].toLong() and 0xFF)
    val seeds = mutableMapOf<Long, ByteArray>()
    var offset = 0x10
    for (i in 0 until count) {
        if (offset + 0x20 > data.size) break
        var programId = 0L
        for (j in 7 downTo 0) programId = (programId shl 8) or (data[offset + j].toLong() and 0xFF)
        seeds[programId] = data.copyOfRange(offset + 8, offset + 8 + 16)
        offset += 0x20
    }
    return seeds
}

class NcchDecryptServiceImpl : NcchDecryptHostApi {

    private val executor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "ncch-decrypt").apply { isDaemon = true }
    }
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun decryptCci(
        cciPath: String,
        boot9Path: String,
        seeddbPath: String?,
        callback: (Result<Unit>) -> Unit,
    ) {
        executor.execute {
            try {
                doDecrypt(File(cciPath), File(boot9Path), seeddbPath?.let { File(it) })
                mainHandler.post { callback(Result.success(Unit)) }
            } catch (e: Exception) {
                Log.e(TAG, "decryption failed: $cciPath", e)
                mainHandler.post { callback(Result.failure(e)) }
            }
        }
    }

    // --- Top-level CCI walk --------------------------------------------------

    private fun doDecrypt(cciFile: File, boot9File: File, seeddbFile: File?) {
        val keyX2C = readKeyX2CFromBoot9(boot9File)
        val seeds: Map<Long, ByteArray>? = seeddbFile?.let { loadSeeddb(it) }

        RandomAccessFile(cciFile, "rw").use { raf ->
            // NCSD header starts at 0x100 (the first 0x100 bytes are an RSA
            // signature this tool doesn't need).
            raf.seek(0x100)
            val ncsdHeader = ByteArray(0x100)
            raf.readFully(ncsdHeader)
            if (String(ncsdHeader, 0, 4, Charsets.US_ASCII) != "NCSD") {
                throw Exception("not a CCI file (NCSD magic not found)")
            }

            // Partition table at header+0x20..0x60: 8 entries of 8 bytes
            // (offset, size), both in 0x200-byte media units.
            for (i in 0 until 8) {
                val entryOffset = 0x20 + i * 8
                val partOffsetUnits = readLeUInt32(ncsdHeader, entryOffset)
                if (partOffsetUnits == 0L) continue // unpopulated partition slot
                val partOffset = partOffsetUnits * 0x200
                decryptNcchPartition(raf, partOffset, keyX2C, seeds)
            }
        }
    }

    private fun readKeyX2CFromBoot9(boot9File: File): ByteArray {
        val data = boot9File.readBytes()
        if (data.size != 0x8000 && data.size != 0x10000) {
            throw Boot9InvalidError("boot9 file has an unexpected size (${data.size} bytes) — " +
                "expected a 0x8000 (protected-only) or 0x10000 (full) ARM9 bootROM dump")
        }
        val digest = MessageDigest.getInstance("SHA-256").digest(data)
        val hex = digest.joinToString("") { "%02x".format(it) }
        val keyblobOffset = when (hex) {
            BOOT9_FULL_HASH -> KEYBLOB_BASE_OFFSET + 0x8000
            BOOT9_PROT_HASH -> KEYBLOB_BASE_OFFSET
            else -> throw Boot9InvalidError("boot9 file does not match a known ARM9 bootROM hash")
        }
        val absOffset = keyblobOffset + KEYX_2C_OFFSET_IN_KEYBLOB
        return data.copyOfRange(absOffset, absOffset + 16)
    }

    // --- Per-NCCH-partition decryption ---------------------------------------

    private fun decryptNcchPartition(
        raf: RandomAccessFile,
        partOffset: Long,
        keyX2C: ByteArray,
        seeds: Map<Long, ByteArray>?,
    ) {
        val header = ByteArray(0x200)
        raf.seek(partOffset)
        raf.readFully(header)
        if (String(header, 0x100, 4, Charsets.US_ASCII) != "NCCH") {
            throw Exception("partition at 0x${partOffset.toString(16)} is not a valid NCCH")
        }

        val flags = header.copyOfRange(0x188, 0x190)
        val cryptoMethod = flags[3].toInt() and 0xFF
        val fixedCryptoKey = (flags[7].toInt() and 0x01) != 0
        val noRomfs = (flags[7].toInt() and 0x02) != 0
        val noCrypto = (flags[7].toInt() and 0x04) != 0
        val usesSeed = (flags[7].toInt() and 0x20) != 0

        if (noCrypto) return // already plaintext, nothing to do

        val originalKeyY = header.copyOfRange(0x0, 0x10)
        val seedVerify = header.copyOfRange(0x114, 0x118)
        val partitionIdBytesBE = header.copyOfRange(0x108, 0x110).reversedArray()
        val programIdBytes = header.copyOfRange(0x118, 0x120)
        var programIdLE = 0L
        for (i in 7 downTo 0) programIdLE = (programIdLE shl 8) or (programIdBytes[i].toLong() and 0xFF)

        // Only the "extra" keyslot (used for RomFS and part of ExeFS) is
        // seeded — the main keyslot (ExHeader, and all of ExeFS when there's
        // no extra keyslot) always uses the header's own KeyY, seed or not.
        var extraKeyY = originalKeyY
        if (usesSeed) {
            val seed = seeds?.get(programIdLE)
                ?: throw SeedRequiredError(
                    "this title uses seed crypto and needs a matching seeddb.bin entry, which isn't configured/found")
            val verifyHash = MessageDigest.getInstance("SHA-256").digest(seed + programIdBytes)
            if (!verifyHash.copyOfRange(0, 4).contentEquals(seedVerify)) {
                throw SeedMismatchError("the seed for this title does not match its NCCH header (wrong seeddb entry?)")
            }
            extraKeyY = MessageDigest.getInstance("SHA-256").digest(originalKeyY + seed).copyOfRange(0, 16)
        }

        val mainKeyNormal: ByteArray
        val extraKeyNormal: ByteArray
        val hasExtraKeyslot: Boolean
        if (fixedCryptoKey) {
            val useFixedSystemKey = (programIdLE and (0x10L shl 32)) != 0L
            mainKeyNormal = if (useFixedSystemKey) FIXED_SYSTEM_KEY else ZERO_KEY
            extraKeyNormal = mainKeyNormal
            hasExtraKeyslot = false
        } else {
            mainKeyNormal = keygenManual(keyX2C, originalKeyY)
            val extraKeyX = if (cryptoMethod == 0x00) {
                keyX2C
            } else {
                (EXTRA_KEY_X[cryptoMethod]
                    ?: throw Exception("unknown NCCH crypto_method 0x${cryptoMethod.toString(16)}")).to16ByteArray()
            }
            extraKeyNormal = keygenManual(extraKeyX, extraKeyY)
            // A seeded extra KeyY always differs from the main (non-seeded)
            // KeyY, so seeding alone forces the ExeFS split path even when
            // crypto_method is 0 (same keyslot, different derived key).
            hasExtraKeyslot = cryptoMethod != 0x00 || usesSeed
        }

        val extheaderSize = readLeUInt32(header, 0x180)
        val exefsOffsetUnits = readLeUInt32(header, 0x1A0)
        val exefsSizeUnits = readLeUInt32(header, 0x1A4)
        val romfsOffsetUnits = readLeUInt32(header, 0x1B0)
        val romfsSizeUnits = readLeUInt32(header, 0x1B4)

        // Extended Header: fixed 4 media units (0x800 bytes) starting right
        // after the NCCH header, if present at all.
        if (extheaderSize == 0x400L) {
            decryptSectionStreaming(raf, partOffset + 0x200, 0x800L, partitionIdBytesBE, 1, mainKeyNormal)
        }

        if (exefsOffsetUnits != 0L) {
            decryptExeFs(
                raf,
                partOffset + exefsOffsetUnits * 0x200,
                exefsSizeUnits * 0x200,
                partitionIdBytesBE,
                mainKeyNormal,
                extraKeyNormal,
                hasExtraKeyslot,
            )
        }

        if (!noRomfs && romfsOffsetUnits != 0L) {
            decryptSectionStreaming(
                raf,
                partOffset + romfsOffsetUnits * 0x200,
                romfsSizeUnits * 0x200,
                partitionIdBytesBE,
                3,
                extraKeyNormal,
            )
        }

        // Patch this partition's flags to mark it plaintext: clear
        // fixed_crypto_key (bit 0), set no_crypto (bit 2). no_crypto takes
        // precedence over every other crypto flag for any downstream reader,
        // so this alone makes the partition self-consistently decrypted.
        // crypto_method is zeroed too for cleanliness, though it's inert
        // once no_crypto is set.
        val patchedFlags = flags.copyOf()
        patchedFlags[3] = 0
        patchedFlags[7] = (((patchedFlags[7].toInt() and 0xFF) and 0x01.inv()) or 0x04).toByte()
        raf.seek(partOffset + 0x188)
        raf.write(patchedFlags)
    }

    // --- Section decryption ---------------------------------------------------

    /** Streams a section in fixed-size chunks — used for ExHeader/RomFS, which use a single keyslot throughout. */
    private fun decryptSectionStreaming(
        raf: RandomAccessFile,
        fileOffset: Long,
        sectionSize: Long,
        partitionIdBytesBE: ByteArray,
        sectionId: Int,
        key: ByteArray,
    ) {
        if (sectionSize <= 0) return

        val cipher = Cipher.getInstance("AES/CTR/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), IvParameterSpec(buildCounter(partitionIdBytesBE, sectionId)))

        // Read and write positions are tracked separately (rather than
        // assuming decrypted.size == toRead on every call) since some JCA
        // providers buffer up to a block internally in update() and only
        // flush it on doFinal(); writePos never overtakes readPos, so this
        // is safe regardless of that buffering behavior.
        val bufSize = 1 shl 20 // 1 MiB, a multiple of the AES block size
        val buffer = ByteArray(bufSize)
        var readPos = fileOffset
        var writePos = fileOffset
        var remaining = sectionSize
        while (remaining > 0) {
            val toRead = minOf(remaining, bufSize.toLong()).toInt()
            raf.seek(readPos)
            raf.readFully(buffer, 0, toRead)
            readPos += toRead
            remaining -= toRead

            val decrypted = if (remaining <= 0) cipher.doFinal(buffer, 0, toRead) else cipher.update(buffer, 0, toRead)
            if (decrypted.isNotEmpty()) {
                raf.seek(writePos)
                raf.write(decrypted)
                writePos += decrypted.size
            }
        }
    }

    /**
     * ExeFS needs special handling when it uses two keyslots: the header plus
     * "icon"/"banner" file contents are always encrypted with the main
     * keyslot, while every other file (in practice just ".code") uses the
     * extra keyslot. ExeFS is always small (code + icon + banner, not the
     * bulk game data — that's RomFS), so it's safe to fully buffer.
     */
    private fun decryptExeFs(
        raf: RandomAccessFile,
        fileOffset: Long,
        sectionSize: Long,
        partitionIdBytesBE: ByteArray,
        mainKey: ByteArray,
        extraKey: ByteArray,
        hasExtraKeyslot: Boolean,
    ) {
        if (sectionSize <= 0) return
        val size = sectionSize.toInt()

        raf.seek(fileOffset)
        val encrypted = ByteArray(size)
        raf.readFully(encrypted)

        val counter = buildCounter(partitionIdBytesBE, 2)
        val mainDecrypted = ctrTransform(encrypted, counter, mainKey)

        val finalBytes: ByteArray
        if (!hasExtraKeyslot) {
            finalBytes = mainDecrypted
        } else {
            val entries = parseExeFsEntries(mainDecrypted.copyOfRange(0, 0x200))
            val extraDecrypted = ctrTransform(encrypted, counter, extraKey)

            val boundaries = sortedSetOf(0, size)
            for (entry in entries) {
                if (entry.name != "icon" && entry.name != "banner") {
                    boundaries.add((entry.offset + 0x200).coerceIn(0, size))
                    boundaries.add((entry.offset + entry.size + 0x200).coerceIn(0, size))
                }
            }
            val points = boundaries.toList()
            val out = ByteArray(size)
            var useExtra = false // the first (lowest-offset) range is always main
            for (i in 0 until points.size - 1) {
                val start = points[i]
                val end = points[i + 1]
                val source = if (useExtra) extraDecrypted else mainDecrypted
                System.arraycopy(source, start, out, start, end - start)
                useExtra = !useExtra
            }
            finalBytes = out
        }

        raf.seek(fileOffset)
        raf.write(finalBytes)
    }

    private fun parseExeFsEntries(header: ByteArray): List<ExeFsEntry> {
        val entries = mutableListOf<ExeFsEntry>()
        for (i in 0 until 10) {
            val base = i * 0x10
            val nameBytes = header.copyOfRange(base, base + 8)
            val nameEnd = nameBytes.indexOf(0).let { if (it < 0) 8 else it }
            val name = String(nameBytes, 0, nameEnd, Charsets.US_ASCII)
            val offset = readLeUInt32(header, base + 8).toInt()
            val size = readLeUInt32(header, base + 12).toInt()
            if (name.isNotEmpty() && size > 0) {
                entries.add(ExeFsEntry(name, offset, size))
            }
        }
        return entries
    }

    // --- Small helpers ---------------------------------------------------------

    /** Initial AES-CTR counter block for a section: partitionId (8 bytes) ++ sectionId (1 byte) ++ zeros. */
    private fun buildCounter(partitionIdBytesBE: ByteArray, sectionId: Int): ByteArray {
        val counter = ByteArray(16)
        System.arraycopy(partitionIdBytesBE, 0, counter, 0, 8)
        counter[8] = sectionId.toByte()
        return counter
    }

    private fun ctrTransform(data: ByteArray, counter: ByteArray, key: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/CTR/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), IvParameterSpec(counter))
        return cipher.doFinal(data)
    }

    private fun readLeUInt32(data: ByteArray, offset: Int): Long {
        return (data[offset].toLong() and 0xFF) or
            ((data[offset + 1].toLong() and 0xFF) shl 8) or
            ((data[offset + 2].toLong() and 0xFF) shl 16) or
            ((data[offset + 3].toLong() and 0xFF) shl 24)
    }
}
