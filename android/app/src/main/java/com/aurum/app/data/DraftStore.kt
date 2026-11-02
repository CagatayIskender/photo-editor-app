package com.aurum.app.data

import android.content.Context
import android.graphics.Bitmap
import com.aurum.core.EditDocument
import com.aurum.core.LookCatalog
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.withContext
import java.io.File
import java.time.Instant
import java.util.UUID

/** A saved draft as listed in the Vault. */
data class DraftSummary(val id: UUID, val title: String?, val modifiedAt: Instant, val thumbnail: File?)

/**
 * Stores each draft as `<id>.json` (the same JSON the iOS app writes) plus a
 * `<id>.jpg` thumbnail in app storage. The document's source identifier is
 * the photo's content URI, kept readable with a persisted URI permission.
 */
class DraftStore(context: Context, private val catalog: LookCatalog) {
    private val dir = File(context.filesDir, "drafts").apply { mkdirs() }
    private val _drafts = MutableStateFlow<List<DraftSummary>>(emptyList())
    val drafts: StateFlow<List<DraftSummary>> = _drafts

    suspend fun refresh() = withContext(Dispatchers.IO) {
        _drafts.value = dir.listFiles { f -> f.extension == "json" }.orEmpty().mapNotNull { file ->
            val doc = runCatching { EditDocument.decode(file.readText()) }.getOrNull() ?: return@mapNotNull null
            val thumb = File(dir, "${doc.id}.jpg")
            DraftSummary(doc.id, title(doc), doc.modifiedAt, thumb.takeIf { it.isFile })
        }.sortedByDescending { it.modifiedAt }
    }

    suspend fun save(document: EditDocument, thumbnail: Bitmap?) = withContext(Dispatchers.IO) {
        File(dir, "${document.id}.json").writeText(document.encoded())
        if (thumbnail != null) {
            File(dir, "${document.id}.jpg").outputStream().use { thumbnail.compress(Bitmap.CompressFormat.JPEG, 85, it) }
        }
        refresh()
    }

    suspend fun load(id: UUID): EditDocument? = withContext(Dispatchers.IO) {
        runCatching { EditDocument.decode(File(dir, "$id.json").readText()) }.getOrNull()
    }

    suspend fun delete(id: UUID) = withContext(Dispatchers.IO) {
        File(dir, "$id.jpg").delete()
        File(dir, "$id.json").delete()
        refresh()
    }

    /** Names a draft after its looks, for example "Linen + Graphite"; null means untitled. */
    private fun title(doc: EditDocument): String? {
        val names = doc.lookApplications.mapNotNull { catalog.look(it.lookID)?.name }
        return names.takeIf { it.isNotEmpty() }?.joinToString(" + ")
    }
}
