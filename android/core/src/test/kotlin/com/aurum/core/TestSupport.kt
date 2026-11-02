package com.aurum.core

import java.io.File
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.ZoneOffset
import java.util.UUID

object TestSupport {
    /** The repository root (one level above android/), set by core/build.gradle.kts. */
    val repoRoot: File by lazy {
        System.getProperty("aurum.repoRoot")?.let(::File) ?: File("../..").canonicalFile
    }

    fun repoFile(path: String) = File(repoRoot, path).readText()

    /** The real catalogue shipped with both apps. */
    fun shippedCatalog(): LookCatalog = LookCatalog.decode(repoFile("Looks/catalog.json"))

    /** Fixtures are shared with the Swift tests. */
    fun fixture(name: String) = repoFile("Packages/AurumCore/Tests/AurumCoreTests/Fixtures/$name.json")

    val smallCatalog = LookCatalog(
        collections = listOf(LookCollection("film", "Film", "t"), LookCollection("noir", "Noir", "t")),
        looks = listOf(
            LookRecipe("film.a", "Alpha", "film", Tier.free, tags = listOf("warm"), params = LookParameters()),
            LookRecipe("film.b", "Bravo", "film", Tier.member, tags = listOf("warm", "grain"), params = LookParameters()),
            LookRecipe("film.c", "Charlie", "film", Tier.free, params = LookParameters()),
            LookRecipe("noir.a", "Ink", "noir", Tier.free, tags = listOf("monochrome"), params = LookParameters()),
        ),
    )

    fun document(width: Int = 4000, height: Int = 3000) = EditDocument(
        id = UUID.fromString("00000000-0000-0000-0000-000000000001"),
        source = SourceAsset("asset-1", PixelSize(width, height)),
        createdAt = Instant.ofEpochSecond(1_800_000_000),
    )

    fun id(n: Int): UUID = UUID.fromString("00000000-0000-0000-0000-" + n.toString().padStart(12, '0'))

    /** UTC+3 without daylight saving, as in the Swift tests. */
    val zone: ZoneId = ZoneOffset.ofHours(3)

    fun day(y: Int, m: Int, d: Int, hour: Int = 12, minute: Int = 0): Instant =
        LocalDateTime.of(y, m, d, hour, minute).atZone(zone).toInstant()
}
