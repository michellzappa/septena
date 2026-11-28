package app.septena.core

import app.septena.core.generated.RegistrySurfaceIds

/**
 * The phone top bar from registry/surfaces.json `topBar`: the buttons each
 * screen shows, in order, as groups. Android draws a group as plain icons side
 * by side; the order is the same as on every other platform.
 */
object TopBar {
    /** A top-bar button id (`topBar.items[].button`). */
    object Button {
        const val SETTINGS = "settings"
        const val BACK = "back"
        const val MORE = "more"
        const val STAR = "star"
        const val SEARCH = "search"
    }

    /** A registry screen id (`topBar.screens[].screen`). */
    enum class Screen(val id: String) { LISTS_HOME("listsHome"), LIST("list") }

    fun leading(screen: Screen): List<List<String>> = groups(screen, "leading")
    fun trailing(screen: Screen): List<List<String>> = groups(screen, "trailing")

    /** The buttons of one side, flattened in order, for shells that draw no capsules. */
    fun order(screen: Screen, side: String): List<String> = groups(screen, side).flatten()

    private fun groups(screen: Screen, side: String): List<List<String>> {
        val surface = RegistryCatalog.surface(RegistrySurfaceIds.TOP_BAR)?.fields.orEmpty()
        val entry = (surface["screens"] as? JsonValue.ArrayValue)?.values.orEmpty()
            .mapNotNull { it as? JsonValue.ObjectValue }
            .firstOrNull { it.fields["screen"].stringValue() == screen.id }
            ?: return emptyList()
        return (entry.fields[side] as? JsonValue.ArrayValue)?.values.orEmpty().map { group ->
            (group as? JsonValue.ArrayValue)?.values.orEmpty().mapNotNull { it.stringValue() }
        }
    }
}
