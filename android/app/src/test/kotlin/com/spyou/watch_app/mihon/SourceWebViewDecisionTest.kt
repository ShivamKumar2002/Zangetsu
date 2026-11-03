package com.spyou.watch_app.mihon

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The screen has two modes and exactly one of them closes itself. Getting that
 * backwards either strands the user on a solved challenge or dismisses a login
 * half-finished, so the decision lives in a pure function and is pinned here.
 *
 * The Cloudflare cases are the load-bearing ones: that path works today and
 * must keep working byte for byte.
 */
class SourceWebViewDecisionTest {

    // -- Cloudflare mode (stayOpen = false) — today's behaviour --------------

    @Test
    fun `closes once a clearance cookie is present`() {
        assertTrue(
            shouldCloseOnPageFinished(
                stayOpen = false,
                alreadySolved = false,
                cookie = "cf_clearance=abc; other=1",
            ),
        )
    }

    @Test
    fun `stays open until the clearance arrives`() {
        assertFalse(
            shouldCloseOnPageFinished(
                stayOpen = false,
                alreadySolved = false,
                cookie = "__cfduid=x",
            ),
        )
    }

    @Test
    fun `never closes twice`() {
        // onPageFinished fires again for the reload the solve triggers; a
        // second finish() would pop a screen the user has already left.
        assertFalse(
            shouldCloseOnPageFinished(
                stayOpen = false,
                alreadySolved = true,
                cookie = "cf_clearance=abc",
            ),
        )
    }

    @Test
    fun `an empty cookie string is not a solve`() {
        assertFalse(
            shouldCloseOnPageFinished(
                stayOpen = false,
                alreadySolved = false,
                cookie = "",
            ),
        )
    }

    // -- Login mode (stayOpen = true) ---------------------------------------

    @Test
    fun `login mode ignores a clearance cookie, solved or not`() {
        // The whole point: passing Cloudflare mid-login must not dismiss the
        // screen before the user has signed in.
        //
        // Both values of alreadySolved, because only the first one proves the
        // stayOpen guard is doing the work — with alreadySolved = true the
        // second guard answers first and the case would pass with
        // `if (stayOpen) return false` deleted.
        for (alreadySolved in listOf(false, true)) {
            assertFalse(
                "alreadySolved=$alreadySolved",
                shouldCloseOnPageFinished(
                    stayOpen = true,
                    alreadySolved = alreadySolved,
                    cookie = "cf_clearance=abc; session=xyz",
                ),
            )
        }
    }

    // -- Sign-in (login mode with a done cookie) ----------------------------

    @Test
    fun `sign-in is done once a cookie NAMED with the prefix appears`() {
        assertTrue(
            isSignedIn(
                doneCookie = "wordpress_logged_in",
                cookie = "cf_clearance=a; wordpress_logged_in_9f3c=user%7C1%7Ct%7Ch",
            ),
        )
    }

    @Test
    fun `sign-in is not done on a value that merely contains the text`() {
        assertFalse(
            isSignedIn(
                doneCookie = "wordpress_logged_in",
                cookie = "note=wordpress_logged_in; cf_clearance=a",
            ),
        )
    }

    @Test
    fun `plain login mode never signs itself in`() {
        assertFalse(isSignedIn(doneCookie = null, cookie = "wordpress_logged_in_x=1"))
        assertFalse(isSignedIn(doneCookie = "", cookie = "wordpress_logged_in_x=1"))
    }

    @Test
    fun `only the asked-for cookie goes back, not the jar`() {
        assertEquals(
            "wordpress_logged_in_9f3c=user%7C1",
            signInCookie(
                doneCookie = "wordpress_logged_in",
                cookie = "cf_clearance=a; wordpress_logged_in_9f3c=user%7C1; other=b",
            ),
        )
        assertNull(signInCookie(doneCookie = "wordpress_logged_in", cookie = "cf_clearance=a"))
    }
}
