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
    def test_a_good_pr_passes_and_needs_no_bot(self):
        self.assertEqual(checks.problems(pr(), ["app/apps/app/src/infra/provider-list-query.ts"]), [])
        self.assertEqual(checks.bot_reasons(pr(), ["app/apps/app/src/infra/provider-list-query.ts"]), [])

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

    def test_empty_or_hollow_sections_fail(self):
        for body in ["## Proof\n\n## Review\nAstra\n", "## Review\nAstra\n", "## Proof\nabcdef12\n## Review\nAstra\n", "## Proof\nabcdef12 passed\n## Review\nx\n", "## Proof\nabcdef12. Tests not run. No screenshot available.\n## Review\nAstra approved.\n"]:
            self.assertTrue(checks.problems(pr(body=body)), body)

    def test_proof_from_an_older_commit_fails(self):
        self.assertTrue(any("name the commit" in p for p in checks.problems(pr(headRefOid="9999999aaa"))))

    def test_sha_outside_proof_does_not_count(self):
        self.assertTrue(checks.problems(pr(body="## Proof\nran it, passed\n## Review\nAstra abcdef12\n")))

    def test_ui_changes_need_a_screenshot(self):
        ui = ["app/apps/app/src/react-app/shell/x.tsx"]
        self.assertTrue(checks.problems(pr(), ui))
        self.assertTrue(checks.problems(pr(), ["app/apps/app/src/a.css"]))
        self.assertEqual(checks.problems(pr(body=GOOD.replace("10 passed.", "10 passed. /tmp/a.png")), ui), [])
        self.assertEqual(checks.problems(pr(body=GOOD.replace("10 passed.", "10 passed. No visible change: types only.")), ui), [])
        self.assertEqual(checks.problems(pr(), ["app/apps/app/src/a.test.tsx", "app/apps/app/src/a.ts"]), [])

    def test_a_screenshot_word_without_a_path_is_not_a_screenshot(self):
        self.assertTrue(checks.problems(pr(body=GOOD.replace("10 passed.", "10 passed. No screenshot available.")), ["app/apps/app/src/a.css"]))

    def test_any_reviewer_counts_if_it_gives_an_outcome(self):
        self.assertEqual(checks.problems(pr(body=GOOD.replace("Astra approved.", "Sol approved (sol loop)."))), [])

    def test_saying_nothing_was_skipped_does_not_need_the_bot(self):
        self.assertEqual(checks.bot_reasons(pr(body=GOOD.replace("Astra approved.", "Astra approved. No steps skipped.")), []), [])

    def test_a_review_that_did_not_run_needs_the_bot(self):
        self.assertTrue(checks.bot_reasons(pr(body=GOOD.replace("Astra approved.", "Astra review not run.")), []))

    def test_risky_paths_need_the_bot(self):
        for path in ["app/apps/server/src/mastra-auth/a.ts", "app/x/payment-form.tsx", "commerce/src/api/a.ts", ".sidstack/gate.sh", "db/migrations/1.sql"]:
            self.assertTrue(checks.bot_reasons(pr(), [path]), path)

    def test_lookalike_paths_do_not(self):
        for path in ["app/src/author-badge.tsx", "app/src/authorized-folders.ts", "app/apps/app/src/domains/commerce/commerce-ui.tsx"]:
            self.assertEqual(checks.bot_reasons(pr(), [path]), [], path)

    def test_a_skipped_step_needs_the_bot(self):
        self.assertTrue(checks.bot_reasons(pr(body="## Proof\nabcdef12 passed\n## Review\nBug pass skipped.\n"), []))


if __name__ == "__main__":
    unittest.main()
