package app.septena.android.ui

import app.septena.core.TaskRefRecord
import app.septena.core.TaskRefResolver
import app.septena.core.TaskRefTarget
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TaskRefResolverTest {
    private fun ref(
        kind: String,
        key: String,
        url: String? = null,
        rawId: String? = null,
        account: String? = null,
    ) = TaskRefRecord(
        id = "ref-1",
        taskId = "t1",
        key = key,
        kind = kind,
        role = "about",
        title = null,
        subtitle = null,
        date = null,
        url = url,
        rawId = rawId,
        account = account,
        position = 0.0,
    )

    @Test
    fun resolvesGithubIssueAndStarlingsDoorAndSeptenaTask() {
        assertEquals(
            TaskRefTarget.Url("https://github.com/michellzappa/septena/issues/296"),
            TaskRefResolver.target(ref("issue", "issue:michellzappa/septena#296")) { false },
        )
        assertEquals(
            TaskRefTarget.Url("https://septena.starlings.work/docs/document/abc"),
            TaskRefResolver.target(ref("door", "door:septena.starlings.work|document:abc")) { false },
        )
        assertEquals(
            TaskRefTarget.Task("t2"),
            TaskRefResolver.target(ref("task", "task:t2")) { it == "t2" },
        )
        assertNull(
            TaskRefResolver.target(ref("task", "task:missing")) { false },
        )
    }

    @Test
    fun resolvesEmailToGmailSearchAndBlocksNonWebSchemes() {
        assertEquals(
            TaskRefTarget.Url("https://mail.google.com/mail/u/0/?authuser=mz%40example.com#search/rfc822msgid%3Aabc%40mail.com"),
            TaskRefResolver.target(
                ref("email", "email:abc@mail.com", rawId = "abc@mail.com", account = "mz@example.com"),
            ) { false },
        )
        assertNull(
            TaskRefResolver.target(ref("url", "url:javascript:alert(1)", url = "javascript:alert(1)")) { false },
        )
    }
}
