package app.septena.android.ui

import android.content.Context
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.septena.android.AndroidAppGraph
import app.septena.ui.ChevronLeftGlyph
import app.septena.core.JsonValue
import app.septena.core.RegistryCatalog
import app.septena.core.booleanValue
import app.septena.core.generated.RegistryActionIds
import app.septena.core.generated.RegistryPlatformIds
import app.septena.core.generated.RegistrySettingKeys
import app.septena.core.generated.RegistryTaskDetail
import app.septena.core.stringValue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private data class RegistrySettingRow(
    val kind: String,
    val key: String? = null,
    val page: String? = null,
    val surface: String? = null,
    val statusKey: String? = null,
    val label: String? = null,
    val detail: String? = null,
    val visibility: String = "always",
    val platforms: Set<String> = emptySet(),
    val ownsKeys: List<String> = emptyList(),
)

private data class RegistrySettingsSection(
    val header: String?,
    val footer: String?,
    val platforms: Set<String>,
    val items: List<RegistrySettingRow>,
)

private data class RegistrySettingsPage(
    val id: String,
    val title: String,
    val platforms: Set<String>,
    val sections: List<RegistrySettingsSection>,
)

@Composable
@OptIn(ExperimentalMaterial3Api::class)
internal fun SettingsScreen(graph: AndroidAppGraph, onBack: () -> Unit) {
    val context = LocalContext.current
    val languageTag = LocalConfiguration.current.locales[0].toLanguageTag()
    val dataVersion by graph.sync.dataVersion.collectAsStateWithLifecycle()
    val signedIn by graph.credentials.signedIn.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    val settingDefinitions = remember { registrySettingDefinitions() }
    val rootGroups = remember(languageTag) { registryRootGroups(languageTag) }
    val pages = remember(languageTag) { registrySettingsPages(languageTag).associateBy(RegistrySettingsPage::id) }
    val deviceSettings = remember(context) { AndroidDeviceSettings(context) }
    val pageStack = rememberSaveable { mutableStateListOf<String>() }
    val values = remember { mutableStateMapOf<String, JsonValue>() }
    var loading by remember { mutableStateOf(true) }
    var saveFailed by remember { mutableStateOf(false) }
    var signingOut by remember { mutableStateOf(false) }
    val accessModel = remember(graph) { AccessSettingsModel(graph, scope) }
    val syncState by graph.sync.state.collectAsStateWithLifecycle()
    val plans = remember(graph) { PlanSettingsModel(graph) }

    LaunchedEffect(graph, dataVersion) {
        loading = true
        val loaded = withContext(Dispatchers.IO) {
            settingDefinitions.mapNotNull { (key, definition) ->
                val platforms = definition.array("platforms").mapNotNull(JsonValue?::stringValue)
                if (RegistryPlatformIds.ANDROID !in platforms || definition.fields["ui"].booleanValue() == false) {
                    null
                } else {
                    key to if (definition.string("scope") == "synced") {
                        graph.syncedSettings.value(key)
                    } else {
                        deviceSettings.read(key, definition)
                    }
                }
            }.toMap()
        }
        values.clear()
        values.putAll(loaded)
        loading = false
    }

    fun titleFor(pageId: String?): String = pageId?.let { pages[it]?.title }.orEmpty()
    val currentPageId = pageStack.lastOrNull()

    // The root page shows the agent count (AI & Agents, `agentsStatus`); the
    // Agents and Devices pages show the lists. Each reloads when it opens.
    LaunchedEffect(signedIn, currentPageId) {
        if (currentPageId == null ||
            currentPageId == AccessSettingsModel.AGENTS_PAGE ||
            currentPageId == AccessSettingsModel.DEVICES_PAGE
        ) {
            accessModel.refresh(signedIn)
        }
    }
    // The account card and the Account page show the plan (`planStatus`).
    LaunchedEffect(signedIn) { plans.refresh(signedIn) }
    val pageTitle = if (currentPageId == PlanSettingsModel.PAGE) plans.title(languageTag) else titleFor(currentPageId)
    val currentTitle = pageTitle.takeIf(String::isNotEmpty)
        ?: RegistryCatalog.actionTitle(RegistryActionIds.APP_SETTINGS, languageTag = languageTag).orEmpty()
    val backTitle = RegistryCatalog.surface(RegistryTaskDetail.ID)
        ?.objectAt("controls")?.string("back")?.localized(languageTag).orEmpty()
    val saveTitle = RegistryCatalog.actionTitle(RegistryActionIds.SETTINGS_SAVE, languageTag = languageTag).orEmpty()
    val signOutTitle = RegistryCatalog.actionTitle(RegistryActionIds.ACCOUNT_SIGN_OUT, languageTag = languageTag).orEmpty()
    val saveError = RegistryCatalog.surface(RegistryTaskDetail.ID)
        ?.objectAt("controls")?.string("saveError")?.localized(languageTag).orEmpty()

    fun closeOrPop() {
        if (pageStack.isNotEmpty()) pageStack.removeAt(pageStack.lastIndex) else onBack()
    }

    BackHandler(enabled = true, onBack = ::closeOrPop)

    fun saveSetting(key: String, value: JsonValue) {
        val definition = settingDefinitions[key] ?: return
        scope.launch {
            saveFailed = false
            val result = runCatching {
                withContext(Dispatchers.IO) {
                    if (definition.string("scope") == "synced") {
                        graph.syncedSettingsMutator.set(key, value)
                    } else {
                        deviceSettings.write(key, definition, value)
                    }
                }
            }
            result.onSuccess {
                values[key] = value
                if (definition.string("scope") == "synced") {
                    graph.sync.noteLocalChange()
                    graph.sync.requestSync()
                }
            }.onFailure { saveFailed = true }
        }
    }

    fun signOut() {
        if (signingOut) return
        scope.launch {
            signingOut = true
            runCatching { withContext(Dispatchers.IO) { graph.credentials.signOut() } }
            signingOut = false
            onBack()
        }
    }

    val surfaceEnv = SettingsSurfaceEnv(graph, plans, syncState, signedIn, values, ::saveSetting)

    Scaffold(
        modifier = Modifier.fillMaxSize(),
        topBar = {
            TopAppBar(
                title = { Text(currentTitle) },
                navigationIcon = {
                    IconButton(
                        onClick = ::closeOrPop,
                        enabled = !signingOut,
                        modifier = Modifier.semantics { contentDescription = backTitle },
                    ) {
                        ChevronLeftGlyph(tint = MaterialTheme.colorScheme.onSurface)
                    }
                },
            )
        },
    ) { padding ->
        if (loading) {
            androidx.compose.foundation.layout.Box(
                modifier = Modifier.fillMaxSize().padding(padding),
                contentAlignment = Alignment.Center,
            ) {
                androidx.compose.material3.CircularProgressIndicator()
            }
        } else {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .padding(padding)
                    .padding(horizontal = 16.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                val pageId = currentPageId
                if (pageId == null) {
                    rootGroups.forEach { group ->
                        val visibleItems = group.items.filter { it.isVisible(signedIn) }
                        if (visibleItems.isNotEmpty()) {
                            if (group.header != null) {
                                Text(
                                    group.header,
                                    style = MaterialTheme.typography.titleSmall,
                                    modifier = Modifier.padding(start = 16.dp, top = 14.dp, bottom = 2.dp),
                                )
                            }
                            visibleItems.forEach { item ->
                                SettingsRegistryRow(
                                    item = item,
                                    languageTag = languageTag,
                                    pages = pages,
                                    definitions = settingDefinitions,
                                    values = values,
                                    saveTitle = saveTitle,
                                    signedIn = signedIn,
                                    signingOut = signingOut,
                                    accessModel = accessModel,
                                    surfaceEnv = surfaceEnv,
                                    onPage = { target -> if (target in pages) pageStack.add(target) },
                                    onValueChange = ::saveSetting,
                                    onSignOut = ::signOut,
                                )
                            }
                            HorizontalDivider(modifier = Modifier.padding(top = 4.dp))
                        }
                    }
                } else {
                    val page = pages[pageId]
                    page?.sections.orEmpty().filter { it.platforms.isEmpty() || RegistryPlatformIds.ANDROID in it.platforms }
                        .forEach { section ->
                            val visibleItems = section.items.filter { it.isVisible(signedIn) }
                            if (visibleItems.isNotEmpty()) {
                                if (section.header != null) {
                                    Text(
                                        section.header,
                                        style = MaterialTheme.typography.titleSmall,
                                        modifier = Modifier.padding(start = 16.dp, top = 14.dp, bottom = 2.dp),
                                    )
                                }
                                visibleItems.forEach { item ->
                                    SettingsRegistryRow(
                                        item = item,
                                        languageTag = languageTag,
                                        pages = pages,
                                        definitions = settingDefinitions,
                                        values = values,
                                        saveTitle = saveTitle,
                                        signedIn = signedIn,
                                        signingOut = signingOut,
                                        accessModel = accessModel,
                                        surfaceEnv = surfaceEnv,
                                        onPage = { target -> if (target in pages) pageStack.add(target) },
                                        onValueChange = ::saveSetting,
                                        onSignOut = ::signOut,
                                    )
                                }
                                section.footer?.let { footer ->
                                    Text(
                                        footer,
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
                                    )
                                }
                                HorizontalDivider(modifier = Modifier.padding(top = 4.dp))
                            }
                        }
                }
                if (saveFailed) {
                    Text(saveError, color = MaterialTheme.colorScheme.error)
                }
            }
        }
    }
}

@Composable
private fun SettingsRegistryRow(
    item: RegistrySettingRow,
    languageTag: String,
    pages: Map<String, RegistrySettingsPage>,
    definitions: Map<String, JsonValue.ObjectValue>,
    values: Map<String, JsonValue>,
    saveTitle: String,
    signedIn: Boolean,
    signingOut: Boolean,
    accessModel: AccessSettingsModel,
    surfaceEnv: SettingsSurfaceEnv,
    onPage: (String) -> Unit,
    onValueChange: (String, JsonValue) -> Unit,
    onSignOut: () -> Unit,
) {
    when (item.kind) {
        "pageLink" -> {
            val target = item.page ?: return
            val page = pages[target]
            val title = when (item.statusKey) {
                PlanSettingsModel.PLAN_STATUS_KEY -> surfaceEnv.plans.title(languageTag)
                else -> item.label ?: page?.title ?: return
            }
            if (item.surface == ACCOUNT_PROFILE_CARD) {
                AccountProfileCard(
                    name = values[RegistrySettingKeys.WELCOME_NAME].stringValue().orEmpty(),
                    signedIn = signedIn,
                    plans = surfaceEnv.plans,
                    syncState = surfaceEnv.syncState,
                    languageTag = languageTag,
                    onClick = { onPage(target) },
                )
                return
            }
            val status = when (item.statusKey) {
                AccessSettingsModel.AGENTS_STATUS_KEY -> accessModel.agentsStatus(languageTag)
                PlanSettingsModel.PLAN_STATUS_KEY -> surfaceEnv.plans.statusLine(languageTag)
                SYNC_STATUS_KEY -> syncStatusLine(signedIn, surfaceEnv.syncState, languageTag)
                AI_MODE_STATUS_KEY -> optionTitle(definitions[RegistrySettingKeys.AI_MODE], values[RegistrySettingKeys.AI_MODE], languageTag)
                else -> null
            }
            ListItem(
                headlineContent = { Text(title) },
                modifier = Modifier.fillMaxWidth().clickable { onPage(target) },
                trailingContent = {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        status?.let { Text(it, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                        Text("›", color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                },
            )
        }
        "setting" -> {
            val key = item.key ?: return
            val definition = definitions[key] ?: return
            val label = item.label ?: return
            if (key == RegistrySettingKeys.TEXT_SIZE_STEP) {
                TextSizeSettingRow(label, languageTag)
                return
            }
            if (key == RegistrySettingKeys.AI_MODE) {
                // Where AI runs: each mode with what it means (AiModeSettings.kt), as on iPhone.
                val current = (values[key] ?: definition.fields["default"]).stringValue().orEmpty()
                AiModePicker(current, languageTag) { onValueChange(key, JsonValue.StringValue(it)) }
                return
            }
            RegistrySettingControl(
                key = key,
                label = label,
                detail = item.detail,
                definition = definition,
                value = values[key] ?: definition.fields["default"] ?: JsonValue.Null,
                saveTitle = saveTitle,
                languageTag = languageTag,
                onValueChange = { onValueChange(key, it) },
            )
        }
        "customSurface" -> {
            when (item.surface) {
                "sync_account_status" -> {
                    if (signedIn) {
                        val accountId by surfaceEnv.graph.credentials.userId.collectAsStateWithLifecycle()
                        accountId?.takeIf(String::isNotBlank)?.let { id ->
                            AccountIdRow(accountId = id, languageTag = languageTag)
                        }
                        TextButton(onClick = onSignOut, enabled = !signingOut) {
                            Text(RegistryCatalog.actionTitle(RegistryActionIds.ACCOUNT_SIGN_OUT, languageTag = languageTag).orEmpty())
                        }
                    }
                }
                "access_devices" -> AccessDevicesList(accessModel, signedIn, languageTag)
                "access_agents" -> AccessAgentsList(accessModel, signedIn, languageTag, surfaceEnv.plans)
                APPEARANCE_PICKER_SURFACE -> AppearancePicker(languageTag)
                "account_profile_editor" -> {
                    val key = item.ownsKeys.firstOrNull() ?: return
                    val definition = definitions[key] ?: return
                    RegistrySettingControl(
                        key = key,
                        label = item.label ?: return,
                        detail = item.detail,
                        definition = definition,
                        value = values[key] ?: definition.fields["default"] ?: JsonValue.Null,
                        saveTitle = saveTitle,
                        languageTag = languageTag,
                        onValueChange = { onValueChange(key, it) },
                    )
                }
                else -> if (item.surface != null && item.surface in SETTINGS_SURFACES) {
                    SettingsCustomSurface(item.surface, item.label, item.detail, surfaceEnv, languageTag)
                }
            }
        }
    }
}

@Composable
private fun RegistrySettingControl(
    key: String,
    label: String,
    detail: String?,
    definition: JsonValue.ObjectValue,
    value: JsonValue,
    saveTitle: String,
    languageTag: String,
    onValueChange: (JsonValue) -> Unit,
) {
    when (definition.string("type")) {
        "bool" -> {
            val checked = value.booleanValue() ?: false
            ListItem(
                headlineContent = { Text(label) },
                supportingContent = detail?.let { { Text(it) } },
                trailingContent = {
                    Switch(checked = checked, onCheckedChange = { onValueChange(JsonValue.BooleanValue(it)) })
                },
                modifier = Modifier.fillMaxWidth().clickable {
                    onValueChange(JsonValue.BooleanValue(!checked))
                },
            )
        }
        "enum" -> {
            val options = definition.array("options").mapNotNull { raw ->
                val option = raw as? JsonValue.ObjectValue ?: return@mapNotNull null
                val optionValue = option.string("value") ?: return@mapNotNull null
                val title = option.string("title")?.localized(languageTag) ?: return@mapNotNull null
                optionValue to title
            }
            RegistrySettingPicker(
                key = key,
                label = label,
                detail = detail,
                value = value.stringValue().orEmpty(),
                options = options,
                onSelect = { onValueChange(JsonValue.StringValue(it)) },
            )
        }
        "int" -> {
            val options = definition.array("options").mapNotNull { raw ->
                val option = raw as? JsonValue.ObjectValue ?: return@mapNotNull null
                val optionValue = option.string("value") ?: return@mapNotNull null
                val title = option.string("title")?.localized(languageTag) ?: return@mapNotNull null
                optionValue to title
            }
            if (options.isNotEmpty()) {
                RegistrySettingPicker(
                    key = key,
                    label = label,
                    detail = detail,
                    value = value.number()?.toLong()?.toString().orEmpty(),
                    options = options,
                    onSelect = { selected -> selected.toLongOrNull()?.let { onValueChange(JsonValue.IntegerValue(it)) } },
                )
            } else {
                val min = definition.number("min")?.toFloat() ?: 0f
                val max = definition.number("max")?.toFloat() ?: 1f
                var draft by remember(key, value) { mutableFloatStateOf(value.number()?.toFloat() ?: min) }
                ListItem(
                    headlineContent = { Text(label) },
                    supportingContent = detail?.let { { Text(it) } },
                    trailingContent = { Text(draft.toInt().toString(), color = MaterialTheme.colorScheme.onSurfaceVariant) },
                )
                Slider(
                    value = draft.coerceIn(min, max),
                    onValueChange = { draft = it },
                    onValueChangeFinished = { onValueChange(JsonValue.IntegerValue(draft.toLong())) },
                    valueRange = min..max,
                )
            }
        }
        "string" -> {
            val maxLength = definition.number("maxLength")?.toInt() ?: 200
            var draft by remember(key, value) { mutableStateOf(value.stringValue().orEmpty()) }
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                OutlinedTextField(
                    value = draft,
                    onValueChange = { draft = it.take(maxLength) },
                    label = { Text(label) },
                    supportingText = detail?.let { { Text(it) } },
                    modifier = Modifier.weight(1f),
                    singleLine = true,
                )
                TextButton(
                    onClick = { onValueChange(JsonValue.StringValue(draft.trim())) },
                    enabled = draft != value.stringValue().orEmpty(),
                ) {
                    Text(saveTitle)
                }
            }
        }
        else -> {
            ListItem(
                headlineContent = { Text(label) },
                supportingContent = detail?.let { { Text(it) } },
            )
        }
    }
}

@Composable
private fun RegistrySettingPicker(
    key: String,
    label: String,
    detail: String?,
    value: String,
    options: List<Pair<String, String>>,
    onSelect: (String) -> Unit,
) {
    var expanded by rememberSaveable(key) { mutableStateOf(false) }
    val selectedTitle = options.firstOrNull { it.first == value }?.second.orEmpty()
    ListItem(
        headlineContent = { Text(label) },
        supportingContent = detail?.let { { Text(it) } },
        trailingContent = {
            Column(horizontalAlignment = Alignment.End) {
                TextButton(onClick = { expanded = true }) { Text(selectedTitle) }
                DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                    options.forEach { (optionValue, title) ->
                        DropdownMenuItem(
                            text = { Text(title) },
                            onClick = {
                                expanded = false
                                onSelect(optionValue)
                            },
                        )
                    }
                }
            }
        },
    )
}

/** The title of a setting's current option (`statusKey: aiMode`), or null. */
private fun optionTitle(definition: JsonValue.ObjectValue?, value: JsonValue?, languageTag: String): String? {
    val selected = (value ?: definition?.fields?.get("default")).stringValue() ?: return null
    val option = definition?.array("options")?.firstOrNull {
        (it as? JsonValue.ObjectValue)?.string("value") == selected
    } as? JsonValue.ObjectValue
    return option?.string("title")?.localized(languageTag)
}

private const val ACCOUNT_PROFILE_CARD = "account_profile_card"
private const val AI_MODE_STATUS_KEY = "aiMode"

@Composable
private fun AccountIdRow(accountId: String, languageTag: String) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var copied by remember(accountId) { mutableStateOf(false) }
    val label = settingsCopy("sync_account_status", "accountIdLabel", languageTag)
    val footer = settingsCopy("sync_account_status", "accountIdFooter", languageTag)
    val copyLabel = settingsCopy("sync_account_status", if (copied) "copied" else "copy", languageTag)
    ListItem(
        headlineContent = { Text(label) },
        supportingContent = {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(
                    text = accountId,
                    fontFamily = FontFamily.Monospace,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.MiddleEllipsis,
                )
                if (footer.isNotBlank()) {
                    Text(
                        text = footer,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        },
        trailingContent = {
            TextButton(
                onClick = {
                    copyToClipboard(context, label, accountId)
                    copied = true
                    scope.launch {
                        delay(2_000L)
                        copied = false
                    }
                },
            ) {
                Text(copyLabel)
            }
        },
    )
}

private fun registrySettingDefinitions(): Map<String, JsonValue.ObjectValue> =
    RegistryCatalog.document("settings").objectAt("keys")?.fields.orEmpty()
        .mapNotNull { (key, value) -> (value as? JsonValue.ObjectValue)?.let { key to it } }
        .toMap()

private fun registryRootGroups(languageTag: String): List<RegistrySettingsSection> =
    RegistryCatalog.document("settings").array("rootGroups").mapNotNull { raw ->
        val group = raw as? JsonValue.ObjectValue ?: return@mapNotNull null
        val items = group.array("items").mapNotNull { it.asSettingsItem(languageTag) }
            .filter { it.platforms.isEmpty() || RegistryPlatformIds.ANDROID in it.platforms }
        RegistrySettingsSection(
            header = group.string("header")?.localized(languageTag),
            footer = null,
            platforms = group.array("platforms").mapNotNull(JsonValue?::stringValue).toSet(),
            items = items,
        ).takeIf { it.platforms.isEmpty() || RegistryPlatformIds.ANDROID in it.platforms }
    }

private fun registrySettingsPages(languageTag: String): List<RegistrySettingsPage> =
    RegistryCatalog.document("settings").array("pages").mapNotNull { raw ->
        val page = raw as? JsonValue.ObjectValue ?: return@mapNotNull null
        val sections = page.array("sections").mapNotNull { sectionRaw ->
            val section = sectionRaw as? JsonValue.ObjectValue ?: return@mapNotNull null
            val items = section.array("items").mapNotNull { it.asSettingsItem(languageTag) }
                .filter { it.platforms.isEmpty() || RegistryPlatformIds.ANDROID in it.platforms }
            RegistrySettingsSection(
                header = section.string("header")?.localized(languageTag),
                footer = section.string("footer")?.localized(languageTag),
                platforms = section.array("platforms").mapNotNull(JsonValue?::stringValue).toSet(),
                items = items,
            ).takeIf { it.platforms.isEmpty() || RegistryPlatformIds.ANDROID in it.platforms }
        }
        RegistrySettingsPage(
            id = page.string("id") ?: return@mapNotNull null,
            title = page.string("title")?.localized(languageTag) ?: return@mapNotNull null,
            platforms = page.array("platforms").mapNotNull(JsonValue?::stringValue).toSet(),
            sections = sections,
        ).takeIf { it.platforms.isEmpty() || RegistryPlatformIds.ANDROID in it.platforms }
    }

private fun JsonValue?.asSettingsItem(languageTag: String): RegistrySettingRow? {
    val item = this as? JsonValue.ObjectValue ?: return null
    return RegistrySettingRow(
        kind = item.string("kind") ?: return null,
        key = item.string("key"),
        page = item.string("page"),
        surface = item.string("surface"),
        statusKey = item.string("statusKey"),
        label = item.string("label")?.localized(languageTag),
        detail = item.string("detail")?.localized(languageTag),
        visibility = item.string("visibility") ?: "always",
        platforms = item.array("platforms").mapNotNull(JsonValue?::stringValue).toSet(),
        ownsKeys = item.array("ownsKeys").mapNotNull(JsonValue?::stringValue),
    )
}

private fun RegistrySettingRow.isVisible(signedIn: Boolean): Boolean = when (visibility) {
    "signedIn" -> signedIn
    "signedOut" -> !signedIn
    "debugOnly" -> false
    else -> true
} && (platforms.isEmpty() || RegistryPlatformIds.ANDROID in platforms)

private fun String.localized(languageTag: String): String =
    RegistryCatalog.localizedString(this, languageTag) ?: this

private fun JsonValue.ObjectValue.objectAt(key: String): JsonValue.ObjectValue? =
    fields[key] as? JsonValue.ObjectValue

private fun JsonValue.ObjectValue.array(key: String): List<JsonValue?> =
    (fields[key] as? JsonValue.ArrayValue)?.values.orEmpty()

private fun JsonValue.ObjectValue.string(key: String): String? = fields[key].stringValue()

private fun JsonValue.ObjectValue.number(key: String): Double? = fields[key].number()

private fun JsonValue?.number(): Double? = when (this) {
    is JsonValue.IntegerValue -> value.toDouble()
    is JsonValue.DecimalValue -> value
    else -> null
}
