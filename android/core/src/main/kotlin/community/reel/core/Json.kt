package community.reel.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull
import java.time.Instant
import java.time.LocalDate
import java.time.OffsetDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeParseException

/** One JSON configuration for the app's own files and for services. */
val ReelJson = Json {
    ignoreUnknownKeys = true
    isLenient = true
    explicitNulls = false
    encodeDefaults = true
    coerceInputValues = true
}

// Readers for loosely typed answers: addons write numbers as text and text as numbers.

fun JsonElement?.obj(): JsonObject? = this as? JsonObject
fun JsonElement?.arr(): JsonArray? = this as? JsonArray

operator fun JsonElement?.get(path: String, vararg more: String): JsonElement? {
    var value: JsonElement? = (this as? JsonObject)?.get(path)
    for (key in more) value = (value as? JsonObject)?.get(key)
    return value
}

fun JsonElement?.string(): String? {
    val p = this as? JsonPrimitive ?: return null
    if (p is JsonNull) return null
    if (p.isString) return p.content
    // A number written as one: "42", not "42.0".
    p.longOrNull?.let { return it.toString() }
    p.doubleOrNull?.let { return it.toString() }
    return p.content
}

/** An integer however it was written; a value no Int can hold is dropped, not a crash. */
fun JsonElement?.int(): Int? {
    val p = this as? JsonPrimitive ?: return null
    if (p is JsonNull) return null
    if (p.isString) return p.content.trim().toIntOrNull()
    p.longOrNull?.let { return if (it in Int.MIN_VALUE..Int.MAX_VALUE) it.toInt() else null }
    val d = p.doubleOrNull ?: return null
    if (!d.isFinite()) return null
    val truncated = kotlin.math.truncate(d)
    return if (truncated >= Int.MIN_VALUE && truncated <= Int.MAX_VALUE) truncated.toInt() else null
}

fun JsonElement?.long(): Long? {
    val p = this as? JsonPrimitive ?: return null
    if (p is JsonNull) return null
    if (p.isString) return p.content.trim().toLongOrNull() ?: p.content.trim().toDoubleOrNull()?.toLong()
    return p.longOrNull ?: p.doubleOrNull?.takeIf { it.isFinite() }?.toLong()
}

fun JsonElement?.double(): Double? {
    val p = this as? JsonPrimitive ?: return null
    if (p is JsonNull) return null
    return if (p.isString) p.content.trim().toDoubleOrNull() else p.doubleOrNull
}

fun JsonElement?.bool(): Boolean? {
    val p = this as? JsonPrimitive ?: return null
    if (p is JsonNull) return null
    return p.booleanOrNull
}

fun JsonElement?.strings(): List<String> = (this as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content } ?: emptyList()

fun JsonElement?.objects(): List<JsonObject> = (this as? JsonArray)?.mapNotNull { it as? JsonObject } ?: emptyList()

fun parseJson(text: String): JsonElement? = try {
    if (text.isBlank()) null else ReelJson.parseToJsonElement(text)
} catch (e: Exception) {
    null
}

object DateParsing {
    /** ISO-8601 with or without fractional seconds or offset. */
    fun parse(text: String): Instant? {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return null
        try { return Instant.parse(trimmed) } catch (_: DateTimeParseException) {}
        try { return OffsetDateTime.parse(trimmed).toInstant() } catch (_: DateTimeParseException) {}
        return null
    }

    /** A bare date, "2026-11-25", at midnight UTC. */
    fun parseDay(text: String): Instant? = try {
        LocalDate.parse(text.take(10)).atStartOfDay(ZoneOffset.UTC).toInstant()
    } catch (_: DateTimeParseException) {
        null
    }
}
