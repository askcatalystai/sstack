#!/usr/bin/env python3
import importlib.util, os, unittest

spec = importlib.util.spec_from_file_location("pr_checks", os.path.join(os.path.dirname(os.path.abspath(__file__)), "pr_checks.py"))
checks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checks)
GOOD = "## Why\nx\n## Proof\nGate on abcdef12 passed: 10 passed.\n## Review\nAstra approved.\n"


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

    def test_review_must_say_who_approved(self):
        for review in ["", "Astra", "Astra found two bugs.", "Composer: not approved; changes requested.", "No approval yet.", "Astra's approval is pending.", "Merged without formal approval."]:
            self.assertTrue(checks.problems(pr(body=f"## Proof\nabcdef12\n## Review\n{review}\n")), review)
        for review in ["Sol approved (sol loop).", "Approval from Astra on abcdef12.", "Bug pass skipped; Astra approves."]:
            self.assertEqual(checks.problems(pr(body=f"## Proof\nabcdef12 8 failed, not run\n## Review\n{review}\n")), [], review)


if __name__ == "__main__":
    unittest.main()
