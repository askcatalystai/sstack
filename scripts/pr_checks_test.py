#!/usr/bin/env python3
import importlib.util, os, unittest

spec = importlib.util.spec_from_file_location("pr_checks", os.path.join(os.path.dirname(os.path.abspath(__file__)), "pr_checks.py"))
checks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checks)
GOOD = "## Why\nx\n## Proof\nGate on abcdef12 passed: 10 passed.\n## Review\nAstra approved abcdef12.\n"

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
        for body in ["## Review\nAstra approved.\n", "## Proof\nran it, passed\n## Review\nAstra approved abcdef12\n"]:
            self.assertTrue(checks.problems(pr(body=body)), body)

    def test_review_must_name_the_current_head(self):
        for review in ["Astra approved.", "Astra approved 9999999.", "Astra approved abcdef."]:
            with self.subTest(review=review):
                self.assertIn("## Review must name the approved head (abcdef12)",
                              checks.problems(pr(body=f"## Proof\nabcdef12\n## Review\n{review}\n")))
        for head in ["abcdef1", "abcdef12", "abcdef1234567890"]:
            self.assertEqual(checks.problems(pr(body=f"## Proof\nabcdef12\n## Review\nAstra approved {head}.\n")), [])

    def test_pending_review_blocks_other_approval(self):
        for pending in ["requires Astra re-check", "requires a new re-check", "needs re-review",
                        "re-review pending", "not reviewed yet", "RE-REVIEW IS PENDING"]:
            for review in [f"Astra approved abcdef12. Updated head {pending}.",
                           f"{pending}. Astra approved abcdef12."]:
                with self.subTest(review=review):
                    self.assertIn("## Review must say who approved this change",
                                  checks.problems(pr(body=f"## Proof\nabcdef12\n## Review\n{review}\n")))

    def test_1021_review_does_not_approve_the_updated_head(self):
        body = f"## Proof\n3ed9f4f309a9da8f0954ac53271ca708b56e3b45\n## Review\n{REVIEW_1021}\n"
        failures = checks.problems(pr(headRefOid="3ed9f4f309a9da8f0954ac53271ca708b56e3b45", body=body))
        self.assertIn("## Review must name the approved head (3ed9f4f3)", failures)
        self.assertIn("## Review must say who approved this change", failures)
        # Naming the current head must not override the outstanding re-check.
        self.assertIn("## Review must say who approved this change",
                      checks.problems(pr(headRefOid="3ed9f4f309a9da8f0954ac53271ca708b56e3b45", body=body + "\nCurrent head: 3ed9f4f309a9da8f0954ac53271ca708b56e3b45\n")))

    def test_review_must_say_who_approved(self):
        for review in ["", "Astra", "Astra found two bugs.", "Composer: not approved; changes requested.", "No approval yet.", "Astra's approval is pending.", "Merged without formal approval."]:
            self.assertTrue(checks.problems(pr(body=f"## Proof\nabcdef12\n## Review\n{review} abcdef12\n")), review)
        for review in ["Sol approved abcdef12 (sol loop).", "Approval from Astra on abcdef12.", "Bug pass skipped; Astra approves abcdef12."]:
            self.assertEqual(checks.problems(pr(body=f"## Proof\nabcdef12 8 failed, not run\n## Review\n{review}\n")), [], review)


if __name__ == "__main__":
    unittest.main()
