#!/usr/bin/env python3
import importlib.util, os, tempfile, unittest

spec = importlib.util.spec_from_file_location("pr_checks", os.path.join(os.path.dirname(os.path.abspath(__file__)), "pr_checks.py"))
checks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checks)
GOOD = "## Why\nx\n## Proof\nGate on abcdef12 passed: 10 passed.\n## Review\nAstra approved.\n"


def write(path, data):
    with open(path, "wb") as file:
        file.write(data)


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
        with tempfile.NamedTemporaryFile(suffix=".png") as image:
            image.write(checks.PNG_SIGNATURE)
            image.flush()
            self.assertEqual(checks.problems(pr(body=GOOD.replace("10 passed.", f"10 passed. {image.name}")), ui), [])
        self.assertEqual(checks.problems(pr(body=GOOD.replace("10 passed.", "10 passed. No visible change: types only.")), ui), [])
        self.assertEqual(checks.problems(pr(), ["app/apps/app/src/a.test.tsx", "app/apps/app/src/a.ts"]), [])

    def test_a_screenshot_word_without_a_path_is_not_a_screenshot(self):
        self.assertTrue(checks.problems(pr(body=GOOD.replace("10 passed.", "10 passed. No screenshot available.")), ["app/apps/app/src/a.css"]))

    def test_shared_ui_packages_need_a_screenshot(self):
        for path in ["app/packages/ui/src/button.tsx", "app/packages/apps-catalog/src/a.css"]:
            self.assertTrue(checks.problems(pr(), [path]), path)
        self.assertEqual(checks.problems(pr(), ["app/packages/ui/src/button.test.tsx", "app/packages/contracts/src/a.tsx"]), [])

    def test_a_named_screenshot_must_be_a_real_png(self):
        with tempfile.TemporaryDirectory() as folder:
            real, fake = os.path.join(folder, "real.png"), os.path.join(folder, "fake.png")
            write(real, checks.PNG_SIGNATURE + b"data")
            write(fake, b"not an image")
            for proof in [real, f"{real}, (after)", f"({real})", f"`{real}`", "https://example.com/a.png", "[after.png](https://example.com/a.png)", f"![after.png]({real})", f"[{real}]({real} \"after\")"]:
                self.assertEqual(checks.problems(pr(body=GOOD.replace("10 passed.", f"10 passed. {proof}"))), [], proof)
            for proof in [fake, "/no/such/image.png", "[after.png](/no/such/image.png)"]:
                self.assertTrue(any("not a PNG" in p for p in checks.problems(pr(body=GOOD.replace("10 passed.", f"10 passed. {proof}")))), proof)

    def test_home_relative_screenshots_expand(self):
        with tempfile.TemporaryDirectory() as home:
            os.environ["HOME"], before = home, os.environ["HOME"]
            try:
                write(os.path.join(home, "a.png"), checks.PNG_SIGNATURE)
                self.assertEqual(checks.problems(pr(body=GOOD.replace("10 passed.", "10 passed. ~/a.png (after)."))), [])
            finally:
                os.environ["HOME"] = before

    def test_failure_lines_are_found_and_do_not_block(self):
        for line in ["abcdef12 8 failed", "12 passed, 2 fail", "2 summary tests failed", "1 failure", "1,024 failing", "pnpm typecheck failed (exit 2).", "lint exit 1", "exited with code 3", "0 failures, 2 failed", "failed at 5,018 ms", "Gate exit 0 but typecheck failed.", "Tests: 0 passed 2 failed.", "500px shot timed out; same row layout."]:
            self.assertEqual(checks.failure_lines(line), [line], line)
        for line in ["0 failed", "12 passed, 0 failed", "12 passed and 0 failed", "no tests failed", "nothing failed", "did not fail", "exit 0", "3 stale copy checks fixed", "failover works"]:
            self.assertEqual(checks.failure_lines(line), [], line)
        for result in ["8 failed", "1 failure in suite", "2 summary tests failed", "1,024 failing", "pnpm typecheck failed (exit 2).", "10 tests passed. pnpm typecheck failed (exit 2)."]:
            self.assertEqual(checks.problems(pr(body=f"## Proof\nabcdef12 {result}\n## Review\nAstra approved.\n")), [], result)

    def test_any_reviewer_counts_if_it_gives_an_outcome(self):
        self.assertEqual(checks.problems(pr(body=GOOD.replace("Astra approved.", "Sol approved (sol loop)."))), [])

    def test_saying_nothing_was_skipped_does_not_need_the_bot(self):
        self.assertEqual(checks.bot_reasons(pr(body=GOOD.replace("Astra approved.", "Astra approved. No steps skipped.")), []), [])

    def test_a_review_that_did_not_run_needs_the_bot(self):
        self.assertTrue(checks.bot_reasons(pr(body=GOOD.replace("Astra approved.", "Astra review not run.")), []))

    def test_risky_paths_need_the_bot(self):
        for path in ["app/apps/server/src/mastra-auth/a.ts", "app/x/payment-form.tsx", "commerce/src/api/a.ts", ".sidstack/gate.sh", "db/migrations/1.sql", "db/data.ts", "app/packages/persistence/src/a.ts", "app/src/schema.ts", "scripts/sid-merge.sh", "scripts/pr_checks.py"]:
            self.assertTrue(checks.bot_reasons(pr(), [path]), path)

    def test_lookalike_paths_do_not(self):
        for path in ["app/src/author-badge.tsx", "app/src/authorized-folders.ts", "app/apps/app/src/domains/commerce/commerce-ui.tsx", "app/src/dbg.ts", "app/src/schematic.tsx", "docs/sid-merge.md"]:
            self.assertEqual(checks.bot_reasons(pr(), [path]), [], path)

    def test_a_skipped_step_needs_the_bot(self):
        self.assertTrue(checks.bot_reasons(pr(body="## Proof\nabcdef12 passed\n## Review\nBug pass skipped.\n"), []))


if __name__ == "__main__":
    unittest.main()
