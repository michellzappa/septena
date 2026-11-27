package app.septena.core

import app.septena.core.generated.RegistryActionIds
import app.septena.core.generated.RegistrySurfaceIds

data class QuickFindCopy(
    val title: String,
    val backTitle: String,
    val searchPrompt: String,
    val emptyTitle: String,
    val emptyDetail: String,
    val noResultsTitle: String,
    val noResultsDetail: String,
    val completedLabel: String,
) {
    fun subtitleFor(result: QuickFindResult, languageTag: String): String? =
        result.subtitle ?: when (val key = result.subtitleKey) {
            QuickFindSubtitle.Completed -> completedLabel
            is QuickFindSubtitle.Destination -> RegistryCatalog.destinationTitle(key.id, languageTag)
            null -> null
        }

    companion object {
        fun fromRegistry(languageTag: String): QuickFindCopy {
            val surface = RegistryCatalog.surface(RegistrySurfaceIds.QUICK_FIND)
            fun copy(vararg path: String): String {
                var value: JsonValue? = surface
                path.forEach { key ->
                    value = (value as? JsonValue.ObjectValue)?.fields?.get(key)
                }
                val source = value.stringValue().orEmpty()
                return RegistryCatalog.localizedString(source, languageTag).orEmpty()
            }
            return QuickFindCopy(
                title = RegistryCatalog.actionTitle(
                    RegistryActionIds.APP_QUICK_FIND,
                    languageTag = languageTag,
                ).orEmpty(),
                backTitle = copy("controls", "back"),
                searchPrompt = copy("placeholder"),
                emptyTitle = copy("emptyState", "title"),
                emptyDetail = copy("emptyState", "detail"),
                noResultsTitle = copy("noResults", "title"),
                noResultsDetail = copy("noResults", "detail"),
                completedLabel = copy("completed", "label"),
            )
        }
    }
}
