package app.septena.core

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/** Time source for domain code. Views and mutators never read the wall clock directly. */
interface DayClock {
    fun today(): LocalDate
    fun now(): Instant
    fun today(at: Instant): LocalDate = today()
}

class SystemDayClock(private val zone: ZoneId = ZoneId.systemDefault()) : DayClock {
    override fun today(): LocalDate = LocalDate.now(zone)
    override fun now(): Instant = Instant.now()
    override fun today(at: Instant): LocalDate = LocalDate.ofInstant(at, zone)
}
