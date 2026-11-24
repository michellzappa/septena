package app.septena.android.ui

import android.content.Context
import android.content.SharedPreferences
import app.septena.core.JsonValue
import app.septena.core.RegistryCatalog
import app.septena.core.booleanValue
import app.septena.core.stringValue
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Device-scope settings (registry/settings.json scope "device"), in SharedPreferences. */
class AndroidDeviceSettings(context: Context) {
    internal val preferences = context.getSharedPreferences("septena-device-settings", Context.MODE_PRIVATE)
    private val _changes = MutableStateFlow(0L)

    /** Increments whenever a device setting changes so open lists reload immediately. */
    val changes: StateFlow<Long> = _changes.asStateFlow()

    // SharedPreferences holds listeners weakly; keep a strong reference here.
    private val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, _ ->
        _changes.value += 1
    }

    init {
        preferences.registerOnSharedPreferenceChangeListener(listener)
    }

    fun read(key: String, definition: JsonValue.ObjectValue): JsonValue {
        val storageKey = definition.string("storageKey") ?: key
        if (!preferences.contains(storageKey)) return definition.fields["default"] ?: JsonValue.Null
        return when (definition.string("type")) {
            "bool" -> JsonValue.BooleanValue(preferences.getBoolean(storageKey, false))
            "int" -> JsonValue.IntegerValue(preferences.getInt(storageKey, 0).toLong())
            "string", "enum" -> JsonValue.StringValue(preferences.getString(storageKey, "").orEmpty())
            else -> definition.fields["default"] ?: JsonValue.Null
        }
    }

    fun write(key: String, definition: JsonValue.ObjectValue, value: JsonValue) {
        val storageKey = definition.string("storageKey") ?: key
        val editor = preferences.edit()
        when (value) {
            is JsonValue.BooleanValue -> editor.putBoolean(storageKey, value.value)
            is JsonValue.IntegerValue -> editor.putInt(storageKey, value.value.toInt())
            is JsonValue.DecimalValue -> editor.putInt(storageKey, value.value.toInt())
            is JsonValue.StringValue -> editor.putString(storageKey, value.value)
            JsonValue.Null -> editor.remove(storageKey)
            else -> error("Unsupported device setting type for '$key'")
        }
        check(editor.commit()) { "Could not save device setting '$key'" }
    }

    /** A bool setting by key, its registry default when unset. */
    fun bool(key: String): Boolean {
        val definition = RegistryCatalog.document("settings").fields["keys"]
            .let { (it as? JsonValue.ObjectValue)?.fields?.get(key) as? JsonValue.ObjectValue }
            ?: return false
        return read(key, definition).booleanValue() ?: false
    }

    private fun JsonValue.ObjectValue.string(key: String): String? = fields[key].stringValue()
}
