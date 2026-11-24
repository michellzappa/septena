package app.septena.core

import app.septena.core.generated.RegistryEntityEnums
import app.septena.core.generated.RegistryTaskPageBlockIds

/**
 * Who added a task (feature `task.provenance`, block `taskPage.provenance`).
 * Permanent: an agent row keeps its author after the freshness cue clears.
 * Same rule as Swift `SeptenaTask.isAgentAuthored` / `addedByName`.
 */
object TaskProvenance {
    /** True when an agent added the task over MCP. */
    fun isAgentAuthored(source: String?): Boolean = source == RegistryEntityEnums.TaskSource.MCP

    /**
     * The author's name: the agent's connector name (`sourceClient`), else the
     * registry fallback name, or the registry's "You" for a task a person added.
     */
    fun addedByName(source: String?, sourceClient: String?, languageTag: String = "en"): String {
        val block = RegistryCatalog.surface(RegistryTaskPageBlockIds.TASK_PAGE_PROVENANCE)
        if (!isAgentAuthored(source)) {
            val self = block?.fields?.get("selfLabel").stringValue().orEmpty()
            return RegistryCatalog.localizedString(self, languageTag) ?: self
        }
        val name = sourceClient?.trim().orEmpty()
        return name.ifEmpty { block?.fields?.get("agentFallbackName").stringValue().orEmpty() }
    }
}
