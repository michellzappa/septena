package app.septena.android.ui

import app.septena.core.generated.RegistrySignInMethodIds
import app.septena.transport.AuthMethodEntry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SignInMethodsTest {
    private val order = signInRegistryOrder()

    @Test
    fun registryOrderPutsEmailAboveDeviceOnAndroid() {
        val email = order.indexOf(RegistrySignInMethodIds.EMAIL)
        val device = order.indexOf(RegistrySignInMethodIds.DEVICE)
        assertTrue(email >= 0 && device > email)
    }

    @Test
    fun serverListDecidesAndUnbuiltMethodsStayHidden() {
        val all = setOf(
            RegistrySignInMethodIds.APPLE,
            RegistrySignInMethodIds.GOOGLE,
            RegistrySignInMethodIds.EMAIL,
            RegistrySignInMethodIds.DEVICE,
        )
        assertEquals(
            listOf(RegistrySignInMethodIds.EMAIL, RegistrySignInMethodIds.DEVICE),
            visibleSignInMethods(order, all),
        )
        assertEquals(
            listOf(RegistrySignInMethodIds.DEVICE),
            visibleSignInMethods(order, setOf(RegistrySignInMethodIds.APPLE, RegistrySignInMethodIds.DEVICE)),
        )
    }

    @Test
    fun failedOrEmptyMethodsShowDeviceApprovalOnly() {
        assertEquals(listOf(RegistrySignInMethodIds.DEVICE), visibleSignInMethods(order, null))
        assertEquals(listOf(RegistrySignInMethodIds.DEVICE), visibleSignInMethods(order, emptySet()))
        assertEquals(listOf(RegistrySignInMethodIds.DEVICE), visibleSignInMethodsFromEntries(order, null))
    }

    @Test
    fun oidcProvidersAppearOnlyWhenWebFlowEnabledOnServer() {
        val entries = listOf(
            AuthMethodEntry(RegistrySignInMethodIds.APPLE, web = false),
            AuthMethodEntry(RegistrySignInMethodIds.GOOGLE, web = true),
            AuthMethodEntry(RegistrySignInMethodIds.MICROSOFT, web = true),
            AuthMethodEntry(RegistrySignInMethodIds.EMAIL),
            AuthMethodEntry(RegistrySignInMethodIds.DEVICE),
        )
        assertEquals(
            listOf(
                RegistrySignInMethodIds.GOOGLE,
                RegistrySignInMethodIds.MICROSOFT,
                RegistrySignInMethodIds.EMAIL,
                RegistrySignInMethodIds.DEVICE,
            ),
            visibleSignInMethodsFromEntries(order, entries),
        )
    }

    @Test
    fun emailShapeCheck() {
        assertTrue(looksLikeEmail("you@example.com"))
        assertFalse(looksLikeEmail("you@example"))
        assertFalse(looksLikeEmail("you example@x.com"))
        assertFalse(looksLikeEmail("@example.com"))
        assertFalse(looksLikeEmail("a@b@c.com"))
        assertFalse(looksLikeEmail("you@example."))
    }
}
