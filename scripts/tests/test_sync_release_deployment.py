"""Check that deployment synchronization writes only the verified release record."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "sync-release-deployment.sh"
COMMIT = "a" * 40
TAG = "v2.0.4"
REPO = "mixBayes/Tidest"
DEPLOYMENT = dict(id=7324084585, ref=TAG, sha=COMMIT, environment="release")

MOCK_GH = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
root = pathlib.Path(os.environ["MOCK_ROOT"])
args = sys.argv[1:]
with (root / "calls.jsonl").open("a") as log:
    log.write(json.dumps(args) + "\n")
scenario = json.loads((root / "scenario.json").read_text())
method = args[args.index("--method") + 1]
endpoint = next(arg for arg in args if arg.startswith("repos/"))
if method == "GET":
    if scenario.get("read_error"):
        print("HTTP 403: permission denied", file=sys.stderr)
        sys.exit(4)
    for page in scenario["pages"]:
        print(json.dumps(page))
elif method == "POST":
    if scenario.get("write_error"):
        print("HTTP 403: write denied", file=sys.stderr)
        sys.exit(4)
    fields = dict(args[i + 1].split("=", 1) for i, arg in enumerate(args) if arg in ("-f", "-F"))
    print(json.dumps(dict(state="success", deployment_url="https://api.github.com/" + endpoint.removesuffix("/statuses"), log_url=fields["log_url"])))
else:
    sys.exit("Unexpected command: " + repr(args))
'''


class SyncReleaseDeploymentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        gh = self.root / "gh"
        gh.write_text(MOCK_GH)
        gh.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{self.root}:{os.environ['PATH']}",
                        MOCK_ROOT=str(self.root), GITHUB_REPOSITORY=REPO,
                        GITHUB_REF="refs/heads/main", GITHUB_RUN_ID="456",
                        GITHUB_RUN_ATTEMPT="2", GITHUB_STEP_SUMMARY=str(self.root / "summary.md"))

    def run_sync(self, pages=None, commit=COMMIT, **scenario):
        scenario["pages"] = [[DEPLOYMENT]] if pages is None else pages
        (self.root / "scenario.json").write_text(json.dumps(scenario))
        result = subprocess.run(["bash", str(SCRIPT), TAG, commit], cwd=self.root,
                                env=self.env, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT)
        log = self.root / "calls.jsonl"
        self.calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        self.posts = [call for call in self.calls if "POST" in call]
        return result

    def test_updates_existing_record_and_links_current_verification(self):
        result = self.run_sync()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(len(self.posts), 1)
        query, post = self.calls
        for value in (f"ref={TAG}", f"sha={COMMIT}", "environment=release", "--paginate"):
            self.assertIn(value, query)
        self.assertIn(f"repos/{REPO}/deployments/7324084585/statuses", post)
        self.assertIn("state=success", post)
        self.assertIn("auto_inactive=false", post)
        self.assertIn(f"log_url=https://github.com/{REPO}/actions/runs/456/attempts/2", post)
        self.assertIn(f"environment_url=https://github.com/{REPO}/releases/tag/{TAG}", post)
        self.assertIn("Original workflow history is retained", (self.root / "summary.md").read_text())

    def test_reads_all_pages_before_choosing_a_record(self):
        result = self.run_sync(pages=[[], [DEPLOYMENT]])
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(len(self.posts), 1)

    def test_no_matching_deployment_is_not_created(self):
        result = self.run_sync(pages=[[]])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Expected exactly one matching release deployment", result.stdout)
        self.assertFalse(self.posts)

    def test_ambiguous_deployments_are_not_changed(self):
        result = self.run_sync(pages=[[DEPLOYMENT, dict(DEPLOYMENT, id=123)]])
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.posts)

    def test_tag_commit_and_environment_must_all_match(self):
        records = [dict(DEPLOYMENT, ref="v2.0.3"),
                   dict(DEPLOYMENT, sha="b" * 40),
                   dict(DEPLOYMENT, environment="staging")]
        result = self.run_sync(pages=[records])
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.posts)

    def test_api_read_failure_never_writes(self):
        result = self.run_sync(read_error=True)
        self.assertEqual(result.returncode, 4)
        self.assertIn("permission denied", result.stdout)
        self.assertFalse(self.posts)

    def test_api_write_failure_is_reported_without_retry(self):
        result = self.run_sync(write_error=True)
        self.assertEqual(result.returncode, 4)
        self.assertIn("write denied", result.stdout)
        self.assertEqual(len(self.posts), 1)

    def test_missing_verified_commit_never_calls_api(self):
        result = self.run_sync(commit="not-a-commit")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.calls)

    def test_only_main_can_update_deployment_status(self):
        self.env["GITHUB_REF"] = "refs/tags/v2.0.4"
        result = self.run_sync()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Run deployment status updates from main", result.stdout)
        self.assertFalse(self.calls)


if __name__ == "__main__":
    unittest.main(verbosity=2)
