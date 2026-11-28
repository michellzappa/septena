package app.septena.core

import app.septena.core.generated.RegistryRules

/**
 * Back / Forward through the lists one window visited (Ctrl or Cmd with [ and ], #849).
 *
 * The same rules as Apple's `NavigationHistory` (SeptenaCore/NavigationHistory.swift); both run
 * `registry/shell-conformance/navigation-history.json`.
 *
 * - A visit to a new destination pushes the one on screen onto the back stack and clears the
 *   forward stack. A visit to the destination on screen does nothing.
 * - Back and Forward move between the stacks. They never push.
 * - A destination that no longer exists (a deleted area or project) is dropped when Back or
 *   Forward reaches it, and the step goes on past it.
 * - Each stack keeps at most [limit] entries (`registry/rules.json` `navigationHistoryLimit`);
 *   the oldest goes first.
 */
class NavigationHistory<T>(limit: Int = RegistryRules.NAVIGATION_HISTORY_LIMIT.toInt()) {
    val limit: Int = limit.coerceAtLeast(1)
    private val backStack = ArrayDeque<T>()
    private val forwardStack = ArrayDeque<T>()

    var current: T? = null
        private set

    val back: List<T> get() = backStack.toList()
    val forward: List<T> get() = forwardStack.toList()
    val canGoBack: Boolean get() = backStack.isNotEmpty()
    val canGoForward: Boolean get() = forwardStack.isNotEmpty()

    /** The shell showed [entry]. A no-op for the destination already on screen. */
    fun visit(entry: T) {
        if (entry == current) return
        current?.let { push(backStack, it) }
        forwardStack.clear()
        current = entry
    }

    /** The previous destination that still exists, or null. */
    fun goBack(exists: (T) -> Boolean = { true }): T? = step(backStack, forwardStack, exists)

    /** The next destination that still exists, or null. */
    fun goForward(exists: (T) -> Boolean = { true }): T? = step(forwardStack, backStack, exists)

    private fun step(source: ArrayDeque<T>, target: ArrayDeque<T>, exists: (T) -> Boolean): T? {
        while (source.isNotEmpty()) {
            val candidate = source.removeLast()
            if (!exists(candidate) || candidate == current) continue
            current?.let { push(target, it) }
            current = candidate
            return candidate
        }
        return null
    }

    private fun push(stack: ArrayDeque<T>, entry: T) {
        stack.addLast(entry)
        while (stack.size > limit) stack.removeFirst()
    }
}
