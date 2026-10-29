"""Exercise the release gate without network access or real waiting."""

import hashlib
import json
import os
import plistlib
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "verify-release.sh"
REPO = "mixBayes/Tidest"
TAG = "v2.0.4"

MOCK_GH = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
root = pathlib.Path(os.environ["MOCK_ROOT"])
args = sys.argv[1:]
with (root / "calls.jsonl").open("a") as log:
    log.write(json.dumps(args) + "\n")
scenario = json.loads((root / "scenario.json").read_text())
if args[0] == "api":
    endpoint = next(arg for arg in args[1:] if arg.startswith("repos/"))
    if scenario.get("api_error"):
        print("HTTP/2.0 403 Forbidden\n\n{}")
        print("HTTP 403: permission denied", file=sys.stderr)
        sys.exit(4)
    if "/releases/tags/" in endpoint:
        print("false" if scenario.get("not_immutable") else "true")
        sys.exit(0)
    state = root / "api-count"
    index = int(state.read_text()) if state.exists() else 0
    state.write_text(str(index + 1))
    counts = scenario.get("counts", [1])
    count = counts[min(index, len(counts) - 1)]
    if count == "404":
        print('HTTP/2.0 404 Not Found\n\n{"message":"Not Found"}')
        print("gh: Not Found (HTTP 404)", file=sys.stderr)
        sys.exit(1)
    if count == "503":
        print('HTTP/2.0 503 Service Unavailable\n\n{}')
        print("gh: Service Unavailable (HTTP 503)", file=sys.stderr)
        sys.exit(1)
    print("HTTP/2.0 200 OK\r\nContent-Type: application/json\r\n\r\n", end="")
    print(json.dumps({"attestations": [None] * count if isinstance(count, int) else None}))
elif args[:2] == ["release", "verify"] and scenario.get("signature_error"):
    print("failed to verify attestations: invalid signature", file=sys.stderr)
    sys.exit(1)
elif args[:2] == ["release", "verify-asset"] and scenario.get("asset_error"):
    print("asset digest mismatch", file=sys.stderr)
    sys.exit(1)
elif args[:2] == ["attestation", "verify"] and scenario.get("provenance_error"):
    print("source digest mismatch", file=sys.stderr)
    sys.exit(1)
elif args[:2] not in (["release", "verify"], ["release", "verify-asset"], ["attestation", "verify"]):
    sys.exit("Unexpected gh command: " + repr(args))
'''


class VerifyReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.assets = self.root / "assets"
        self.assets.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        MOCK_ROOT=str(self.root), GITHUB_REPOSITORY=REPO,
                        GIT_AUTHOR_NAME="Test", GIT_AUTHOR_EMAIL="test@example.com",
                        GIT_COMMITTER_NAME="Test", GIT_COMMITTER_EMAIL="test@example.com")
        self.git("init", "-q")
        self.git("commit", "--allow-empty", "-qm", "release source")
        self.commit = self.git("rev-parse", "HEAD").strip()
        self.git("tag", "-a", TAG, "-m", TAG)
        self.tag_digest = self.git("rev-parse", f"refs/tags/{TAG}").strip()
        # Verification may run from main after the release. It must use the tag's commit.
        self.git("commit", "--allow-empty", "-qm", "later verification tools")
        self.info = dict(version="2.0.4", tag=TAG, commit=self.commit, repository=REPO)
        self.write_assets()
        for name, contents in {
            "gh": MOCK_GH,
            "sleep": '#!/bin/sh\nprintf "%s\\n" "$*" >> "$MOCK_ROOT/sleeps"\n',
        }.items():
            path = self.bin / name
            path.write_text(contents)
            path.chmod(0o755)

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.root, env=self.env,
                                       text=True, stderr=subprocess.PIPE)

    def write_assets(self):
        (self.assets / "Tidest-2.0.4.dmg").write_bytes(b"test disk image")
        (self.assets / "BUILD-INFO.json").write_text(json.dumps(self.info))
        (self.assets / "provenance.sigstore.json").write_text("test bundle")
        sums = []
        names = ["Tidest-2.0.4.dmg", "BUILD-INFO.json"]
        if (self.assets / "appcast.xml").exists():
            names.append("appcast.xml")
        for name in names:
            digest = hashlib.sha256((self.assets / name).read_bytes()).hexdigest()
            sums.append(f"{digest}  {name}\n")
        (self.assets / "SHA256SUMS").write_text("".join(sums))

    def enable_update_feed(self):
        config = self.root / "Config" / "Info.plist"
        config.parent.mkdir(exist_ok=True)
        config.write_bytes(plistlib.dumps({"SUFeedURL": "https://example.com/appcast.xml"}))
        self.git("add", "Config/Info.plist")
        self.git("commit", "-qm", "include updater")
        self.commit = self.git("rev-parse", "HEAD").strip()
        self.git("tag", "-af", TAG, "-m", TAG)
        self.tag_digest = self.git("rev-parse", f"refs/tags/{TAG}").strip()
        self.info["commit"] = self.commit

    def test_new_release_verifies_feed_and_its_source(self):
        self.enable_update_feed()
        (self.assets / "appcast.xml").write_text("signed test feed")
        self.write_assets()
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertTrue(any(call[:3] == ["release", "verify-asset", TAG] and call[3] == "appcast.xml" for call in self.calls))
        self.assertTrue(any(call[:3] == ["attestation", "verify", "appcast.xml"] for call in self.calls))

    def test_new_release_cannot_omit_feed_even_if_checksums_omit_it(self):
        self.enable_update_feed()
        self.write_assets()
        result = self.run_gate()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("Missing release asset: appcast.xml", result.stdout)
        self.assertFalse(any(call[0] == "attestation" for call in self.calls))

    def test_new_release_checks_feed_digest(self):
        self.enable_update_feed()
        (self.assets / "appcast.xml").write_text("signed test feed")
        self.write_assets()
        (self.assets / "appcast.xml").write_text("tampered")
        result = self.run_gate()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("appcast.xml: FAILED", result.stdout)

    def test_older_release_does_not_require_feed_added_later(self):
        config = self.root / "Config" / "Info.plist"
        config.parent.mkdir()
        config.write_bytes(plistlib.dumps({"SUFeedURL": "https://example.com/appcast.xml"}))
        self.git("add", "Config/Info.plist")
        self.git("commit", "-qm", "updater added after release")
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertFalse(any("appcast.xml" in call for call in self.calls))

    def run_gate(self, tag=TAG, **scenario):
        (self.root / "scenario.json").write_text(json.dumps(scenario))
        result = subprocess.run(["bash", str(SCRIPT), tag, str(self.assets)],
                                cwd=self.root, env=self.env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        calls_file = self.root / "calls.jsonl"
        self.calls = [json.loads(line) for line in calls_file.read_text().splitlines()] if calls_file.exists() else []
        self.proof_calls = [call for call in self.calls if call[0] == "api" and "--include" in call]
        sleep_file = self.root / "sleeps"
        self.sleeps = sleep_file.read_text().splitlines() if sleep_file.exists() else []
        return result

    def test_ready_proof_verifies_every_asset_and_exact_tag_source(self):
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertFalse(self.sleeps)
        self.assertIn(f"sha1:{self.tag_digest}?predicate_type=release", self.proof_calls[0][2])
        assets = [call[3] for call in self.calls if call[:2] == ["release", "verify-asset"]]
        self.assertEqual(assets, ["Tidest-2.0.4.dmg", "BUILD-INFO.json", "SHA256SUMS", "provenance.sigstore.json"])
        provenance = [call for call in self.calls if call[:2] == ["attestation", "verify"]]
        self.assertEqual(len(provenance), 3)
        for call in provenance:
            self.assertEqual(call[call.index("--source-digest") + 1], self.commit)
            self.assertEqual(call[call.index("--source-ref") + 1], f"refs/tags/{TAG}")
            self.assertEqual(call[call.index("--signer-workflow") + 1], f"{REPO}/.github/workflows/release.yml")
            self.assertIn("--deny-self-hosted-runners", call)

    def test_only_empty_proof_lists_are_retried(self):
        result = self.run_gate(counts=[0, 0, 1])
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.sleeps, ["10", "10"])
        self.assertEqual(len(self.proof_calls), 3)

    def test_missing_proof_http_404_is_retried(self):
        result = self.run_gate(counts=["404", 1])
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.sleeps, ["10"])
        self.assertEqual(len(self.proof_calls), 2)

    def test_missing_proof_times_out_without_running_verification(self):
        result = self.run_gate(counts=[0])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("after 120 seconds", result.stdout)
        self.assertEqual(len(self.proof_calls), 13)
        self.assertEqual(len(self.sleeps), 12)
        self.assertTrue(all(call[0] == "api" for call in self.calls))

    def test_api_error_is_immediate(self):
        result = self.run_gate(api_error=True)
        self.assertEqual(result.returncode, 4)
        self.assertIn("HTTP 403", result.stdout)
        self.assertEqual(len(self.calls), 1)
        self.assertFalse(self.sleeps)

    def test_invalid_response_is_immediate(self):
        result = self.run_gate(counts=["null"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Invalid attestation response", result.stdout)
        self.assertEqual(len(self.proof_calls), 1)
        self.assertFalse(self.sleeps)

    def test_server_error_is_not_treated_as_missing_proof(self):
        result = self.run_gate(counts=["503"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("HTTP 503", result.stdout)
        self.assertEqual(len(self.proof_calls), 1)
        self.assertFalse(self.sleeps)

    def test_mutable_or_draft_release_is_rejected_before_waiting(self):
        result = self.run_gate(not_immutable=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must be a published immutable release", result.stdout)
        self.assertFalse(self.proof_calls)
        self.assertFalse(self.sleeps)

    def test_invalid_signature_is_not_retried(self):
        result = self.run_gate(signature_error=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid signature", result.stdout)
        self.assertEqual(len(self.calls), 3)
        self.assertFalse(self.sleeps)

    def test_release_asset_mismatch_stops_before_provenance(self):
        result = self.run_gate(asset_error=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("asset digest mismatch", result.stdout)
        self.assertFalse(any(call[0] == "attestation" for call in self.calls))

    def test_provenance_mismatch_stops_immediately(self):
        result = self.run_gate(provenance_error=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("source digest mismatch", result.stdout)
        self.assertEqual(sum(call[0] == "attestation" for call in self.calls), 1)

    def test_checksums_are_enforced(self):
        (self.assets / "Tidest-2.0.4.dmg").write_bytes(b"corrupted")
        result = self.run_gate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FAILED", result.stdout)
        self.assertFalse(any(call[0] == "attestation" for call in self.calls))

    def test_build_info_cannot_claim_a_different_commit(self):
        self.info["commit"] = self.git("rev-parse", "HEAD").strip()
        self.write_assets()
        result = self.run_gate()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Verified v2.0.4:", result.stdout)

    def test_invalid_tag_is_rejected_before_api_access(self):
        result = self.run_gate(tag="--latest")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.calls)


if __name__ == "__main__":
    unittest.main(verbosity=2)
