package app.septena.android.ui

import app.septena.core.JsonValue
import app.septena.core.RegistryCatalog
import app.septena.core.stringValue

/**
 * Copy a settings surface spells out (`copy` in registry/settings.json), by the
 * surface id (or statusKey) and the copy id, localized, with `{name}` placeholders
 * filled from [args]. Swift reads the same entries through `RegistrySettings.copy`.
 */
internal fun settingsCopy(owner: String, id: String, languageTag: String, vararg args: Pair<String, String>): String {
    val copy = RegistryCatalog.document("settings").fields["copy"] as? JsonValue.ObjectValue
    val entries = (copy?.fields?.get(owner) as? JsonValue.ArrayValue)?.values.orEmpty()
    val entry = entries.firstOrNull { (it as? JsonValue.ObjectValue)?.fields?.get("id").stringValue() == id }
        as? JsonValue.ObjectValue
    val english = entry?.fields?.get("label").stringValue() ?: return id
    var text = RegistryCatalog.localizedString(english, languageTag) ?: english
    for ((name, value) in args) text = text.replace("{$name}", value)
    return text
}

/** A string from registry/plans.json at [path] (object keys), localized; empty when missing. */
internal fun plansText(languageTag: String, vararg path: String): String {
    var node: JsonValue? = RegistryCatalog.document("plans")
    for (key in path) node = (node as? JsonValue.ObjectValue)?.fields?.get(key)
    return registryText(node.stringValue(), languageTag)
}

/** Shared prompt chrome: surfaces.json `prompts.cancelTitle`. */
internal fun promptCancelTitle(languageTag: String): String {
    val prompts = RegistryCatalog.document("surfaces").fields["prompts"] as? JsonValue.ObjectValue
    return registryText(prompts?.fields?.get("cancelTitle").stringValue(), languageTag)
}

/** The plain confirm of a message: surfaces.json `prompts.error.confirmTitle`. */
internal fun promptConfirmTitle(languageTag: String): String {
    val prompts = RegistryCatalog.document("surfaces").fields["prompts"] as? JsonValue.ObjectValue
    val error = prompts?.fields?.get("error") as? JsonValue.ObjectValue
    return registryText(error?.fields?.get("confirmTitle").stringValue(), languageTag)
}

/** A localized registry string (the English text is the key); empty for null. */
internal fun registryText(english: String?, languageTag: String): String =
    english?.let { RegistryCatalog.localizedString(it, languageTag) ?: it }.orEmpty()
