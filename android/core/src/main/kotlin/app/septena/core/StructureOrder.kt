package app.septena.core

import java.util.Locale
import kotlin.math.ceil

/**
 * Canonical sidebar / picker order for Areas, Projects, and Tags, mirroring
 * Apple `TaskStructureOrder.positionOrdered` and Web `orderByPosition`:
 *
 * - Base fallback order is case-insensitive alphabetical by title/name.
 * - Explicitly positioned items (`position != null && position.isFinite() && position != 0.0`)
 *   sort ascending by `position`.
 * - Unpositioned items (`position == null` or `0`) sink to the bottom in alphabetical
 *   order, never ahead of explicitly positioned items.
 * - Reorder writes use 1-based positions (`1..N`) so the first item is never `0`
 *   (which Apple and Web treat as unset).
 */
object StructureOrder {
    fun <T> orderByPosition(
        items: Iterable<T>,
        position: (T) -> Double?,
        label: (T) -> String,
    ): List<T> {
        val alpha = items.sortedWith(
            compareBy<T>({ label(it).lowercase(Locale.ROOT) }, { label(it) }),
        )
        val hasExplicitPosition = alpha.any { isExplicitPosition(position(it)) }
        if (!hasExplicitPosition) return alpha
        return alpha
            .withIndex()
            .sortedWith(
                compareBy<IndexedValue<T>>(
                    { effectivePosition(position(it.value)) },
                    { it.index },
                ),
            )
            .map { it.value }
    }

    /**
     * Position to write when appending a newly created Area or Project without an
     * explicit insert index:
     * - If the existing group is non-empty and every member already carries an explicit
     *   positive position, return `max + 1` so the new item lands at the bottom.
     * - Otherwise return `0` (matching Apple's default unset position) so unpositioned
     *   groups stay alphabetically sorted and the new item never jumps ahead of `0` rows.
     */
    fun nextAppendPosition(existingPositions: Iterable<Double?>): Long {
        var count = 0
        var allPositive = true
        var maxPos = 0L
        for (raw in existingPositions) {
            count += 1
            if (raw == null || !raw.isFinite() || raw <= 0.0) {
                allPositive = false
            } else {
                val whole = ceil(raw).toLong()
                if (whole > maxPos) maxPos = whole
            }
        }
        return if (count > 0 && allPositive) maxPos + 1L else 0L
    }

    /** 1-based positions (`1..N`) for an explicit reorder, matching Apple `AreasBackend`/`ProjectsBackend`. */
    fun reorderPosition(index: Int): Long = (index + 1).toLong()

    private fun isExplicitPosition(raw: Double?): Boolean =
        raw != null && raw.isFinite() && raw != 0.0

    private fun effectivePosition(raw: Double?): Double =
        if (isExplicitPosition(raw)) raw!! else Double.MAX_VALUE
}
