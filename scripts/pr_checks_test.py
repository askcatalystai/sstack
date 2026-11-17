#!/usr/bin/env python3
import importlib.util, os, unittest

spec = importlib.util.spec_from_file_location("pr_checks", os.path.join(os.path.dirname(os.path.abspath(__file__)), "pr_checks.py"))
checks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checks)
GOOD = "## Why\nx\n## Proof\nGate on abcdef12 passed: 10 passed.\n## Review\nApproved-Head: abcdef12 (Astra)\n"

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
        for body in ["## Review\nApproved-Head: abcdef12 (Astra)\n", "## Proof\nran it, passed\n## Review\nApproved-Head: abcdef12 (Astra)\n"]:
            self.assertTrue(any("name the commit" in p for p in checks.problems(pr(body=body))), body)

    def test_matching_approval_trailers_pass(self):
        for review in [
            "Approved-Head: abcdef1 (Astra)",
            "Approved-Head: ABCDEF12 (Astra; final call Claude)",
            "  - Approved-Head: abcdef1234567890 (Claude)",
            "* Approved-Head: abcdef12 Astra",
            "Approved-Head: 9999999 (Muse)\nApproved-Head: abcdef12 (Astra)",
        ]:
            with self.subTest(review=review):
                self.assertEqual(checks.problems(pr(body=f"## Proof\nabcdef12\n## Review\n{review}\n")), [])

    def test_missing_stale_or_malformed_trailers_fail(self):
        for review in [
            "", "Not reviewed yet", "Astra approved abcdef12",
            "Astra approved 9999999; current head abcdef12",
            "Approval for abcdef12 was not granted", "Review is pending.",
            "Approved-Head: 9999999 (Astra)",
            "Approved-Head: abcdef19 (Astra)",
            "Approved-Head: abcdef1234567890a (Astra)",
            "Approved-Head: abcdef (Astra)",
            "Approved-Head: abcdef12z (Astra)",
            "Approved-Head: abcdef12", "Approved-Head: abcdef12   ",
            "Approved-Head: abcdef12\n(Astra)",
        ]:
            with self.subTest(review=review):
                self.assertEqual(checks.problems(pr(body=f"## Proof\nabcdef12\n## Review\n{review}\n")),
                                 ["## Review must contain `Approved-Head: abcdef12` naming who approved this head."])

    def test_hidden_approval_trailers_do_not_count(self):
        for review in [
            "<!-- Approved-Head: abcdef12 (Astra) -->",
            "<!--\nApproved-Head: abcdef12 (Astra)\n-->",
            "~~Approved-Head: abcdef12 (Astra)~~",
            "~~\nApproved-Head: abcdef12 (Astra)\n~~",
            "```text\nApproved-Head: abcdef12 (Astra)\n```",
            "~~~\nApproved-Head: abcdef12 (Astra)\n~~~",
            "````markdown\n```\nApproved-Head: abcdef12 (Astra)\n````",
            "```\nApproved-Head: abcdef12 (Astra)",
        ]:
            with self.subTest(review=review):
                self.assertTrue(checks.problems(pr(body=f"## Proof\nabcdef12\n## Review\n{review}\n")))
        # A Review heading in an example block cannot supply the real approval.
        self.assertTrue(checks.problems(pr(body="## Proof\nabcdef12\n```\n## Review\nApproved-Head: abcdef12 (Astra)\n```")))

    def test_withdrawal_overrides_all_approval_trailers(self):
        for withdrawn in ["Approval-Withdrawn:", "- Approval-Withdrawn: Astra", "  * Approval-Withdrawn: superseded"]:
            for review in [f"{withdrawn}\nApproved-Head: abcdef12 (Astra)",
                           f"Approved-Head: abcdef12 (Astra)\n{withdrawn}"]:
                with self.subTest(review=review):
                    self.assertTrue(checks.problems(pr(body=f"## Proof\nabcdef12\n## Review\n{review}\n")))
        for hidden in ["<!-- Approval-Withdrawn: -->", "~~Approval-Withdrawn:~~", "```\nApproval-Withdrawn:\n```"]:
            self.assertEqual(checks.problems(pr(body=GOOD + hidden)), [])
        self.assertEqual(checks.problems(pr(body="## Status\nApproval-Withdrawn: example outside Review\n" + GOOD)), [])

    def test_1021_review_without_a_trailer_fails(self):
        head = "3ed9f4f309a9da8f0954ac53271ca708b56e3b45"
        self.assertEqual(checks.problems(pr(headRefOid=head, body=f"## Proof\n{head}\n## Review\n{REVIEW_1021}\n")),
                         ["## Review must contain `Approved-Head: 3ed9f4f3` naming who approved this head."])

    def test_free_text_does_not_override_the_trailer(self):
        for notes in ['Quotes #1021: "requires Astra re-check".', "Validated pending orders.",
                      "required re-check completed", "Review is pending.", "Approval was not granted."]:
            with self.subTest(notes=notes):
                self.assertEqual(checks.problems(pr(body=GOOD.replace("Gate on", notes + "\nGate on"))), [])
                self.assertEqual(checks.problems(pr(body=GOOD + notes)), [])


if __name__ == "__main__":
    unittest.main()
