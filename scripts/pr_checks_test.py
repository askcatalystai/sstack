#!/usr/bin/env python3
import importlib.util, os, unittest

spec = importlib.util.spec_from_file_location("pr_checks", os.path.join(os.path.dirname(os.path.abspath(__file__)), "pr_checks.py"))
checks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checks)
GOOD = "## Why\nx\n## Proof\nGate on abcdef123456 passed: 10 passed.\n## Review\nApproved-Head: abcdef123456 (Astra)\n"

REVIEW_1021 = """**Risky — updated head requires Astra re-check.** Astra and DeepSeek approved the earlier `e5f919fbb5f0e0237369850cbf86ed9ed7e6b53f` head; those approvals do not cover this merge resolution. Sid will arrange the re-check. Composer was unavailable due to its weekly usage limit.

This is **not wholly mechanical**: pool guard installation must precede the tenant proxy because `protectPgPool` mutates `connect()`; wrapping the proxy again would recurse. The service now guards its raw runtime pool, while the factory guards only SDK-owned pools. Both retain #1014 error handling and idle timeout. The shared installer dispatches app-table repair through main's unchanged catalog-aware helper and retains namespace-qualified runtime policies, extending the bounded advisory lock to runtime-table repair. The other conflict resolutions combine imports and retain both sides' behavior/tests.

The prior SDK snapshot P1 remains fixed by the SECURITY INVOKER trigger and canonical workflow resource/context wrappers. Existing nonblocking follow-ups remain: new lazy tables need explicit RLS initialization before use; schedule dispatch can narrow system scope further; CI needs a dedicated RLS integration database URL. Legacy in-flight snapshots are covered in Deploy above.

Kanzo process#527 status comment could not be posted because the current Mac's local card service at 127.0.0.1:4242 refused the connection. Waiting for Sid-arranged Astra re-check of the updated head; conflict resolution and requested local verification are complete.

Created with gpt-6.1-sol in T3 Code through the Codex harness."""


def pr(**changes):
    return {"state": "OPEN", "isDraft": False, "mergeable": "MERGEABLE", "reviewDecision": "", "statusCheckRollup": [],
            "headRefOid": "abcdef1234567890", "body": GOOD, **changes}


class Ready(unittest.TestCase):
    def test_a_good_pr_passes(self):
        self.assertEqual(checks.problems(pr()), [])

    def test_github_state_blocks(self):
        for change in [{"state": "CLOSED"}, {"isDraft": True}, {"mergeable": "CONFLICTING"}, {"mergeable": "UNKNOWN"}, {"reviewDecision": "CHANGES_REQUESTED"}]:
            self.assertTrue(checks.problems(pr(**change)), change)

    def test_checks_must_have_passed(self):
        for check in [{"name": "a", "conclusion": "FAILURE"}, {"name": "a", "status": "IN_PROGRESS", "conclusion": ""}, {"context": "a", "state": "PENDING"}, {"name": "a"}]:
            self.assertTrue(checks.problems(pr(statusCheckRollup=[check])), check)
        self.assertEqual(checks.problems(pr(statusCheckRollup=[{"name": "a", "conclusion": "SUCCESS"}, {"context": "b", "state": "SUCCESS"}])), [])

    def test_required_context_needs_success(self):
        self.assertTrue(checks.problems(pr(), ["Harness"]))
        for state in ["PENDING", "FAILURE", "CANCELLED", "SKIPPED", "NEUTRAL", "EXPECTED", ""]:
            for check in [{"name": "Harness", "conclusion": state}, {"context": "Harness", "state": state}]:
                self.assertTrue(checks.problems(pr(statusCheckRollup=[check]), ["Harness"]), check)
        for check in [{"name": "Harness", "conclusion": "SUCCESS"}, {"context": "Harness", "state": "SUCCESS"}]:
            self.assertEqual(checks.problems(pr(statusCheckRollup=[check]), ["Harness"]), [])

    def test_missing_fields_fail_rather_than_pass(self):
        healthy = pr()
        for field in ["state", "isDraft", "mergeable", "reviewDecision", "statusCheckRollup", "headRefOid"]:
            broken = dict(healthy)
            del broken[field]
            with self.assertRaises(KeyError):
                checks.problems(broken)

    def test_proof_must_name_the_head_commit(self):
        self.assertTrue(any("name the commit" in p for p in checks.problems(pr(headRefOid="9999999aaa"))))
        for body in ["## Review\nApproved-Head: abcdef123456 (Astra)\n", "## Proof\nran it, passed\n## Review\nApproved-Head: abcdef123456 (Astra)\n"]:
            self.assertTrue(any("name the commit" in p for p in checks.problems(pr(body=body))), body)

    def test_matching_final_trailers_pass(self):
        for review in [
            "Approved-Head: abcdef123456 (Astra)",
            "Prose: the `<div>` parser was reviewed.\n- Approved-Head: ABCDEF1234567890 (Astra; final call Claude)\n\n",
            "Plain <div> mentioned in prose.\n* Approved-Head: abcdef123456 (Astra)",
            "Approved-Head: 999999999999 (Muse)\nApproved-Head: abcdef123456 (Astra)",
            "```html\n<div>\n```\nApproved-Head: abcdef123456 (Astra)",
            "<details>old notes</details>\nApproved-Head: abcdef123456 (Astra)",
        ]:
            with self.subTest(review=review):
                self.assertEqual(checks.problems(pr(body=f"## Proof\nabcdef123456\n## Review\n{review}\n")), [])

    def test_malformed_nonfinal_or_stale_trailers_fail(self):
        for review in [
            "", "Not reviewed yet", "Astra approved abcdef123456",
            "Astra approved 9999999; current head abcdef123456",
            "Approval for abcdef123456 was not granted", "Review is pending.",
            "Approved-Head: 999999999999 (Astra)",
            "Approved-Head: abcdef1234569 (Astra)",
            "Approved-Head: abcdef1234567890a (Astra)",
            "Approved-Head: abcdef1 (Astra)", "Approved-Head: abcdef12345 (Astra)",
            "Approved-Head: abcdef123456z (Astra)", "Approved-Head: abcdef123456",
            "Approved-Head: abcdef123456\n(Astra)",
            "Approved-Head: abcdef123456 (Astra)\nMore notes.",
        ]:
            with self.subTest(review=review):
                self.assertIn("## Review must end with `Approved-Head: <12+ hex of head> (<who>)`", checks.problems(pr(body=f"## Proof\nabcdef123456\n## Review\n{review}\n")))

    def test_approvers_cannot_contain_markdown_or_empty_names(self):
        for name in ["", "x", ".", "\\", "Al", "A B C", "abc123", "~~Astra~~", "<!-- Astra -->",
                     "`Astra`", "*Astra*", "[](https://example.com)", "[Astra](https://example.com)"]:
            with self.subTest(name=name):
                self.assertIn("## Review must end with `Approved-Head: <12+ hex of head> (<who>)`", checks.problems(pr(body=f"## Proof\nabcdef123456\n## Review\nApproved-Head: abcdef123456 ({name})\n")))

    def test_trailer_indentation_and_hidden_wrappers_fail(self):
        for review in [
            "    Approved-Head: abcdef123456 (Astra)", "\tApproved-Head: abcdef123456 (Astra)",
            " - Approved-Head: abcdef123456 (Astra)",
            "~~Approved-Head: abcdef123456 (Astra)~~",
            "<!-- Approved-Head: abcdef123456 (Astra) -->",
            "```\nApproved-Head: abcdef123456 (Astra)\n```",
            "<div hidden>\nApproved-Head: abcdef123456 (Astra)\n</div>",
        ]:
            with self.subTest(review=review):
                self.assertTrue(checks.problems(pr(body=f"## Proof\nabcdef123456\n## Review\n{review}\n")))

    def test_unbalanced_code_before_trailer_fails(self):
        for prefix, error in [
            ("```text\n", "trailer is inside a code fence"), ("~~~\n", "trailer is inside a code fence"),
            ("`multiline span\n", "unbalanced backtick"),
        ]:
            with self.subTest(prefix=prefix):
                body = f"## Proof\nabcdef123456\n{prefix}## Review\nApproved-Head: abcdef123456 (Astra)\n"
                self.assertTrue(any(error in p for p in checks.problems(pr(body=body))))
        review = "`multiline span\nApproved-Head: abcdef123456 (Astra)"
        self.assertTrue(any("unbalanced backtick" in p for p in checks.problems(pr(body=f"## Proof\nabcdef123456\n## Review\n{review}\n"))))

    def test_unclosed_html_or_comment_before_trailer_fails(self):
        for opening in ["<!--", "<details>", "<div hidden>", '<div style="display:none">', "<table>", "<pre>"]:
            with self.subTest(opening=opening):
                body = f"## Proof\nabcdef123456\n## Review\n{opening}\nApproved-Head: abcdef123456 (Astra)\n"
                self.assertTrue(any("unclosed HTML" in p for p in checks.problems(pr(body=body))))

    def test_withdrawal_anywhere_in_review_vetoes(self):
        for withdrawn in ["Approval-Withdrawn:", "- Approval-Withdrawn: Astra", "  * Approval-Withdrawn: superseded"]:
            body = f"## Proof\nabcdef123456\n## Review\n{withdrawn}\nApproved-Head: abcdef123456 (Astra)\n"
            self.assertIn("PR contains Approval-Withdrawn:", checks.problems(pr(body=body)))
        self.assertIn("PR contains Approval-Withdrawn:", checks.problems(pr(body="## Status\nApproval-Withdrawn: outside Review\n" + GOOD)))

    def test_fences_require_matching_character_length_and_indent(self):
        for prefix in ["   ~~~\n", "```\n~~~\n", "````\n```\n", "~~~~\n~~~\n",
                       "~~~\n~~~ not a closer\n"]:
            with self.subTest(prefix=prefix):
                body = GOOD.replace("## Review\n", "## Review\n" + prefix)
                self.assertIn("trailer is inside a code fence", checks.problems(pr(body=body)))
        for prefix in ["   ~~~\n`literal\n   ~~~~\n", "````\n~~~\n`````\n"]:
            self.assertEqual(checks.problems(pr(body=GOOD.replace("## Review\n", "## Review\n" + prefix))), [])

    def test_html_closers_cannot_cancel_future_or_code_hidden_openers(self):
        for notes in ["</div>\n<div>\n", "```\n</div>\n```\n<div>\n",
                      "`\n</div>\n`\n<div>\n"]:
            with self.subTest(notes=notes):
                self.assertTrue(any("unclosed HTML <div>" in p for p in checks.problems(pr(body=GOOD.replace("## Review\n", "## Review\n" + notes)))))
        for notes in ["`\n<div>\n`\n", "``\n<div>\n``\n", "<div>\n</div>\n"]:
            self.assertEqual(checks.problems(pr(body=GOOD.replace("## Review\n", "## Review\n" + notes))), [])

    def test_duplicate_review_is_rejected(self):
        self.assertIn("duplicate ## Review", checks.problems(pr(body=GOOD + "## Review\nNot reviewed yet\n")))

    def test_setext_headings_are_section_boundaries(self):
        for underline in ["---", "==="]:
            with self.subTest(underline=underline):
                body = GOOD.replace("Approved-Head:", f"Other section\n{underline}\nApproved-Head:")
                self.assertIn("## Review must end with `Approved-Head: <12+ hex of head> (<who>)`", checks.problems(pr(body=body)))
                self.assertEqual(checks.problems(pr(body=GOOD.replace("## Review", f"Review\n{underline}"))), [])
                self.assertEqual(checks.problems(pr(body=GOOD + f"Other section\n{underline}\nNotes\n")), [])

    def test_raw_withdrawal_vetoes_even_inside_code(self):
        for prefix in ["Approval-Withdrawn: Astra\n", "## Status\nApproval-Withdrawn: Astra\n"]:
            self.assertIn("PR contains Approval-Withdrawn:", checks.problems(pr(body=prefix + GOOD)))
        for prefix in ["```\nApproval-Withdrawn: Astra\n```\n", "   ~~~\nApproval-Withdrawn: Astra\n   ~~~\n",
                       "`\nApproval-Withdrawn: Astra\n`\n", "    Approval-Withdrawn: Astra\n"]:
            self.assertIn("PR contains Approval-Withdrawn:", checks.problems(pr(body=prefix + GOOD)))

    def test_withdrawal_cannot_hide_behind_backticks(self):
        prefix = "`\nApproval-Withdrawn: Astra `\n"
        self.assertIn("PR contains Approval-Withdrawn:", checks.problems(pr(body=prefix + GOOD)))

    def test_withdrawal_cannot_hide_behind_a_fence_in_a_comment(self):
        prefix = "<!--\n```\n-->\nApproval-Withdrawn: Astra\n```\n-->\n"
        self.assertIn("PR contains Approval-Withdrawn:", checks.problems(pr(body=prefix + GOOD)))
        self.assertIn("PR contains Approval-Withdrawn:", checks.problems(pr(body="<!--\nApproval-Withdrawn: Astra\n-->\n" + GOOD)))

    def test_known_false_rejects_remain_fail_closed(self):
        body = "```markdown\n## Review\nexample\n```\n" + GOOD
        self.assertIn("duplicate ## Review", checks.problems(pr(body=body)))
        body = GOOD.replace("## Review\n", "## Review\n`` ` ``\n")
        self.assertIn("## Review approval trailer follows an unbalanced backtick", checks.problems(pr(body=body)))

    def test_1021_review_without_a_trailer_fails(self):
        head = "3ed9f4f309a9da8f0954ac53271ca708b56e3b45"
        self.assertIn("## Review must end with `Approved-Head: <12+ hex of head> (<who>)`", checks.problems(pr(headRefOid=head, body=f"## Proof\n{head}\n## Review\n{REVIEW_1021}\n")))

    def test_free_text_does_not_override_final_trailer(self):
        for notes in ['Quotes #1021: "requires Astra re-check".', "Validated pending orders.",
                      "required re-check completed", "Review is pending.", "Approval was not granted."]:
            with self.subTest(notes=notes):
                self.assertEqual(checks.problems(pr(body=GOOD.replace("Gate on", notes + "\nGate on"))), [])
                self.assertEqual(checks.problems(pr(body=GOOD.replace("## Review\n", "## Review\n" + notes + "\n"))), [])


if __name__ == "__main__":
    unittest.main()
