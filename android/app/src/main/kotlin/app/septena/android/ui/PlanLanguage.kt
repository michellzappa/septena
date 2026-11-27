package app.septena.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import app.septena.android.R
import app.septena.core.JsonValue
import app.septena.core.RegistryCatalog
import app.septena.core.stringValue

// The premium language (docs/PREMIUM_LANGUAGE.md), the Android side of iOS
// `PlanLanguage.swift`: the plan mark, the wordmark and the benefit rows every
// paid surface draws with. The brand color is the Magic Plus color: Persimmon
// under Colorful, the chosen fruit otherwise.

/** The two paid plans (iOS `PlanTier`). */
internal enum class PlanTier(val id: String) {
    PLUS("plus"),
    PRO("pro"),
}

/** One benefit of a paid plan (plans.json `benefits`). */
internal data class PlanBenefit(val id: String, val icon: String, val title: String, val detail: String)

internal fun planBenefits(tier: PlanTier, languageTag: String): List<PlanBenefit> {
    val benefits = RegistryCatalog.document("plans").fields["benefits"] as? JsonValue.ObjectValue
    val list = (benefits?.fields?.get(tier.id) as? JsonValue.ArrayValue)?.values.orEmpty()
    return list.filterIsInstance<JsonValue.ObjectValue>().map {
        PlanBenefit(
            id = it.fields["id"].stringValue().orEmpty(),
            icon = it.fields["icon"].stringValue().orEmpty(),
            title = registryText(it.fields["title"].stringValue(), languageTag),
            detail = registryText(it.fields["detail"].stringValue(), languageTag),
        )
    }
}

/** The drawable for a registry icon id the premium language uses. */
private fun planIconRes(iconId: String): Int = when (iconId) {
    "plans.plus" -> R.drawable.ic_plan_plus
    "plans.pro" -> R.drawable.ic_plan_pro
    "plans.devices" -> R.drawable.ic_plan_devices
    "plans.agents" -> R.drawable.ic_plan_agents
    "plans.files" -> R.drawable.ic_plan_files
    "plans.history" -> R.drawable.ic_plan_history
    else -> R.drawable.ic_plan_plus
}

/**
 * A benefit tile's color: its semantic color under the multicolor fruit
 * (tokens.json `multicolorGlyphs`), the accent under every other fruit
 * (iOS `AppearancePreferences.glyphSwiftUIColor`).
 */
@Composable
private fun planGlyphColor(iconId: String): Color {
    val fruit = FruitAccents.resolve(LocalAppearance.current.accentId)
    if (!fruit.multicolor) return MaterialTheme.colorScheme.primary
    val tokens = RegistryCatalog.document("tokens")
    val glyphs = (tokens.fields["multicolorGlyphs"] as? JsonValue.ObjectValue)?.fields?.get("glyphs") as? JsonValue.ObjectValue
    val key = glyphs?.fields?.get(iconId).stringValue() ?: return MaterialTheme.colorScheme.primary
    val colors = tokens.fields["colors"] as? JsonValue.ObjectValue
    return registryColor(colors?.fields?.get(key))
}

/** The plan's tile: Plus is a brand tile with an ink glyph, Pro an ink tile with a brand glyph. */
@Composable
internal fun PlanMark(tier: PlanTier, size: Dp = 44.dp) {
    val brand = LocalMagicPlusColors.current
    val ink = MaterialTheme.colorScheme.onSurface
    val (fill, glyph) = when (tier) {
        PlanTier.PLUS -> brand.fill to brand.ink
        PlanTier.PRO -> ink to brand.fill
    }
    Box(
        modifier = Modifier.size(size).background(fill, RoundedCornerShape(size * 0.27f)),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            painterResource(if (tier == PlanTier.PRO) R.drawable.ic_plan_pro else R.drawable.ic_plan_plus),
            contentDescription = null,
            tint = glyph,
            modifier = Modifier.size(size * 0.56f),
        )
    }
}

/** "Septena Plus" / "Septena Pro": the product name in the text color, the plan name in the brand color. */
@Composable
internal fun PlanWordmark(tier: PlanTier, languageTag: String) {
    val full = planCardField(tier.id, "title", languageTag)
    val name = if (tier == PlanTier.PRO) plansText(languageTag, "proName") else plansText(languageTag, "shortName")
    val product = full.replace(name, "").trim()
    val brand = LocalMagicPlusColors.current.fill
    Text(
        buildAnnotatedString {
            if (product.isNotEmpty()) append("$product ")
            withStyle(SpanStyle(color = brand)) { append(name) }
        },
        style = MaterialTheme.typography.titleLarge,
        fontWeight = FontWeight.Bold,
    )
}

/** The plan's head: mark, wordmark and one line under it. */
@Composable
internal fun PlanHead(tier: PlanTier, line: String?, languageTag: String, markSize: Dp = 56.dp) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        PlanMark(tier, markSize)
        Column {
            PlanWordmark(tier, languageTag)
            if (!line.isNullOrEmpty()) {
                Text(line, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium)
            }
        }
    }
}

/** One benefit: a tile in the benefit's color, a title, one line of detail. The text wraps. */
@Composable
internal fun PlanBenefitRow(benefit: PlanBenefit) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Box(
            modifier = Modifier.size(30.dp).background(planGlyphColor(benefit.icon), RoundedCornerShape(8.dp)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(painterResource(planIconRes(benefit.icon)), contentDescription = null, tint = Color.White, modifier = Modifier.size(18.dp))
        }
        Spacer(Modifier.width(12.dp))
        Column {
            Text(benefit.title, fontWeight = FontWeight.SemiBold)
            Text(benefit.detail, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium)
        }
    }
}
