package com.aurum.core

import kotlinx.serialization.Serializable

/** The full set of looks and collections, loaded from `catalog.json`. */
@Serializable
data class LookCatalog(
    val version: Int = 1,
    val collections: List<LookCollection>,
    val looks: List<LookRecipe>,
) {
    sealed class LoadError(message: String) : Exception(message) {
        data class DuplicateLookID(val id: String) : LoadError("Duplicate look id $id")
        data class UnknownCollection(val lookID: String, val collection: String) :
            LoadError("Look $lookID is in unknown collection $collection")
    }

    /** Checks ids are unique and every look belongs to a known collection. */
    fun validate() {
        val seen = HashSet<String>()
        val collectionIDs = collections.map { it.id }.toSet()
        for (look in looks) {
            if (!seen.add(look.id)) throw LoadError.DuplicateLookID(look.id)
            if (look.collection !in collectionIDs) throw LoadError.UnknownCollection(look.id, look.collection)
        }
    }

    private val byId: Map<String, LookRecipe> by lazy { looks.associateBy { it.id } }

    fun look(id: String): LookRecipe? = byId[id]

    fun looks(collectionID: String): List<LookRecipe> = looks.filter { it.collection == collectionID }

    /** The look [offset] places from [lookID] within its collection, wrapping. */
    fun neighbour(lookID: String, offset: Int): LookRecipe? {
        val current = look(lookID) ?: return null
        val siblings = looks(current.collection)
        val index = siblings.indexOfFirst { it.id == lookID }
        if (index < 0 || siblings.isEmpty()) return null
        val count = siblings.size
        return siblings[((index + offset) % count + count) % count]
    }

    /** Ranks looks against a query: name matches above collection and tag matches. */
    fun search(query: String): List<LookRecipe> {
        val terms = expand(query)
        if (terms.isEmpty()) return looks
        val names = HashMap<String, String>()
        for (c in collections) names.putIfAbsent(c.id, c.name.lowercase())
        return looks.mapNotNull { look ->
            val name = look.name.lowercase()
            val collection = names[look.collection] ?: look.collection
            val tags = look.tags.map { it.lowercase() }
            var score = 0
            for (term in terms) {
                if (name.contains(term)) score += 3
                if (collection.contains(term)) score += 2
                if (tags.any { it.contains(term) }) score += 1
            }
            if (score > 0) look to score else null
        }.sortedWith(compareByDescending<Pair<LookRecipe, Int>> { it.second }.thenBy { it.first.name })
            .map { it.first }
    }

    companion object {
        fun decode(json: String): LookCatalog {
            val catalog = AurumJson.format.decodeFromString(serializer(), json)
            catalog.validate()
            return catalog
        }

        /** Words that should find each other, e.g. "90s" finds "retro". */
        val synonyms: Map<String, List<String>> = linkedMapOf(
            "90s" to listOf("retro", "vhs", "camcorder"),
            "y2k" to listOf("2000s", "chrome", "glossy"),
            "warm" to listOf("golden", "sunlit", "amber"),
            "cool" to listOf("blue", "cold", "frost"),
            "bw" to listOf("monochrome", "black and white", "noir"),
            "sparkle" to listOf("glitter", "bling", "diamond", "shimmer"),
            "dreamy" to listOf("haze", "soft", "glow"),
            "moody" to listOf("dark", "noir", "shadow"),
            "film" to listOf("analog", "35mm", "grain"),
        )

        internal fun expand(query: String): List<String> {
            val base = query.lowercase().split(Regex("[^\\p{L}\\p{N}]+")).filter { it.isNotEmpty() }
            val out = base.toMutableList()
            for (word in base) {
                synonyms[word]?.let { out.addAll(it) }
                for ((key, values) in synonyms) if (word in values) out.add(key)
            }
            val seen = HashSet<String>()
            return out.filter { seen.add(it) }
        }
    }
}
