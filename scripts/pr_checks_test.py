#!/usr/bin/env python3
import importlib.util, os, unittest

spec = importlib.util.spec_from_file_location("pr_checks", os.path.join(os.path.dirname(os.path.abspath(__file__)), "pr_checks.py"))
checks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checks)
HEAD = "abcdef1234567890"
GOOD = "## Why\nx\n## Proof\nGate passed on abcdef12.\n## Review\nAstra approved.\n"


class Merge(unittest.TestCase):
    def test_good_body_passes_and_needs_no_bot(self):
        self.assertEqual(checks.problems(HEAD, GOOD), [])
        self.assertEqual(checks.bot_reasons(GOOD, ["app/apps/app/src/infra/provider-list-query.ts"]), [])

    def test_empty_sections_fail(self):
        self.assertTrue(checks.problems(HEAD, "## Proof\n\n## Review\nok\n"))
        self.assertTrue(checks.problems(HEAD, "## Review\nok\n"))

    def test_proof_from_an_older_commit_fails(self):
        self.assertIn("name the commit", checks.problems("9999999aaa", GOOD)[0])

    def test_sha_outside_proof_does_not_count(self):
        self.assertTrue(checks.problems(HEAD, "## Proof\nran it\n## Review\nabcdef12\n"))

    def test_risky_paths_need_the_bot(self):
        for path in ["app/apps/server/src/mastra-auth/a.ts", "app/x/payment-form.tsx", "commerce/src/api/a.ts", ".sidstack/gate.sh", "db/migrations/1.sql"]:
            self.assertTrue(checks.bot_reasons(GOOD, [path]), path)

    def test_lookalike_paths_do_not(self):
        for path in ["app/src/author-badge.tsx", "app/src/authorized-folders.ts", "app/apps/app/src/domains/commerce/commerce-ui.tsx"]:
            self.assertEqual(checks.bot_reasons(GOOD, [path]), [], path)

    def test_a_skipped_step_needs_the_bot(self):
        self.assertTrue(checks.bot_reasons("## Proof\nabcdef12\n## Review\nBug pass skipped.\n", []))


if __name__ == "__main__":
    unittest.main()
