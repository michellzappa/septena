package app.septena.core

/** Canonical Area/Project/Tag ordering matching Apple `TaskStructureOrder` and Web `orderByPosition`. */
class StructureOrderTest {
    private data class Item(val id: String, val title: String, val position: Double?)

    fun positionZeroAndNullSinkToBottom() {
        val areas = listOf(
            Item("a_zero", "Alpha Unset", 0.0),
            Item("a_two", "Work", 2.0),
            Item("a_none", "Beta Unset", null),
            Item("a_one", "Personal", 1.0),
        )
        val ordered = StructureOrder.orderByPosition(areas, Item::position, Item::title)
        assertEquals(
            listOf("a_one", "a_two", "a_zero", "a_none"),
            ordered.map(Item::id),
            "Explicit positive positions come first; position 0 and null sink to bottom alphabetically",
        )
    }

    fun allUnpositionedFallsBackToCaseInsensitiveAlphabetical() {
        val areas = listOf(
            Item("a_w", "Work", 0.0),
            Item("a_a", "admin", null),
            Item("a_h", "Home", 0.0),
        )
        val ordered = StructureOrder.orderByPosition(areas, Item::position, Item::title)
        assertEquals(
            listOf("a_a", "a_h", "a_w"),
            ordered.map(Item::id),
            "All-zero/null items sort case-insensitively by title",
        )
    }

    fun tiedPositionsBreakByTitle() {
        val projects = listOf(
            Item("p_b", "Launch", 1.0),
            Item("p_a", "Audit", 1.0),
            Item("p_c", "Zeroed", 0.0),
        )
        val ordered = StructureOrder.orderByPosition(projects, Item::position, Item::title)
        assertEquals(
            listOf("p_a", "p_b", "p_c"),
            ordered.map(Item::id),
            "Equal explicit positions tie-break alphabetically; 0 still sinks",
        )
    }

    fun nextAppendPositionAndReorderAreOneBased() {
        assertEquals(0L, StructureOrder.nextAppendPosition(emptyList()), "Empty group starts unset (0)")
        assertEquals(0L, StructureOrder.nextAppendPosition(listOf(0.0, null)), "Unpositioned group stays unset (0)")
        assertEquals(0L, StructureOrder.nextAppendPosition(listOf(1.0, 2.0, 0.0)), "Mixed group appends unset so it does not jump ahead of 0 rows")
        assertEquals(4L, StructureOrder.nextAppendPosition(listOf(1.0, 3.0, 2.0)), "Fully positioned group appends at max + 1")
        assertEquals(listOf(1L, 2L, 3L), (0 until 3).map(StructureOrder::reorderPosition), "Explicit reorders are 1-based")
    }
}
