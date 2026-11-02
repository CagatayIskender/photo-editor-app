package com.aurum.app.data

import android.content.Context
import com.aurum.core.AurumJson
import com.aurum.core.Preset
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.withContext
import kotlinx.serialization.builtins.ListSerializer
import java.io.File
import java.util.UUID

/** The user's presets, stored as one JSON array in the same shape iOS uses. */
class PresetStore(context: Context) {
    private val file = File(context.filesDir, "presets.json")
    private val serializer = ListSerializer(Preset.serializer())
    private val _presets = MutableStateFlow<List<Preset>>(emptyList())
    val presets: StateFlow<List<Preset>> = _presets

    suspend fun refresh() = withContext(Dispatchers.IO) {
        _presets.value = if (file.isFile) {
            runCatching { AurumJson.format.decodeFromString(serializer, file.readText()) }.getOrDefault(emptyList())
        } else emptyList()
    }

    suspend fun add(preset: Preset) = write(_presets.value.filter { it.id != preset.id } + preset)

    suspend fun delete(id: UUID) = write(_presets.value.filter { it.id != id })

    private suspend fun write(list: List<Preset>) = withContext(Dispatchers.IO) {
        file.writeText(AurumJson.encodeCanonical(serializer, list))
        _presets.value = list
    }
}
