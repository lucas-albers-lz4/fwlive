#!/usr/bin/env python3
"""Execute the inline publish guards in disposable Git fixtures (no publication)."""

import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


WORKFLOW = Path(__file__).resolve().parents[1] / ".github/workflows/publish-packages.yml"
def job_steps(name):
    # Restrict extraction to the named job; fail closed if its structure changes.
    match = re.search(rf"^  {re.escape(name)}:\n(.*?)(?=^  \S|\Z)", WORKFLOW.read_text(), re.M | re.S)
    if not match:
        raise AssertionError(f"missing workflow job: {name}")
    return re.split(r"^      - ", match[1], flags=re.M)[1:]


BUILD_STEPS = job_steps("build-publish")
SMOKE_STEPS = job_steps("smoke-from-feed")


def step(name, steps):
    return next(s for s in steps if s.startswith(f"name: {name}\n"))


def script(name, steps):
    block = step(name, steps).split("        run: |\n", 1)[1]
    lines = []
    for line in block.splitlines():
        if line and not line.startswith("          "):
            break
        lines.append(line[10:])
    return "\n".join(lines)


class ReleaseTagValidation(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.envfile = self.root / "github-env"
        self.envfile.touch()
        self.outputfile = self.root / "github-output"
        self.outputfile.touch()
        self.env = dict(os.environ, GITHUB_ENV=str(self.envfile),
                        GITHUB_OUTPUT=str(self.outputfile), TAG="v1.2.3",
                        EVENT_NAME="workflow_dispatch", GITHUB_REF="refs/heads/master",
                        FWLIVE_RELEASE_TAG="v1.2.3", GIT_CONFIG_NOSYSTEM="1",
                        GIT_CONFIG_GLOBAL=os.devnull)

    def run_guard(self, name, job="build-publish", **env):
        steps = BUILD_STEPS if job == "build-publish" else SMOKE_STEPS
        return subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", script(name, steps)],
                              cwd=self.root, env=dict(self.env, **env), capture_output=True, text=True)

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.root, env=self.env,
                                       stderr=subprocess.DEVNULL, text=True).strip()

    def init_repo(self):
        self.git("init", "-q")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "user.name", "Fixture")
        self.git("commit", "--allow-empty", "-qm", "first")
        return self.git("rev-parse", "HEAD")

    def test_order_and_qualified_checkout(self):
        self.assertTrue(BUILD_STEPS[0].startswith("name: Resolve release tag\n"))
        self.assertTrue(BUILD_STEPS[1].startswith("uses: actions/checkout@"))
        self.assertIn("id: release-tag\n", BUILD_STEPS[0])
        self.assertIn("ref: refs/tags/${{ steps.release-tag.outputs.tag }}\n", BUILD_STEPS[1])
        self.assertIn("persist-credentials: false", BUILD_STEPS[1])
        self.assertEqual(BUILD_STEPS[2], step("Verify release tag commit", BUILD_STEPS))
        self.assertGreater(BUILD_STEPS.index(step("Install validation tools", BUILD_STEPS)), 2)
        self.assertIn("npm ci", step("Install validation tools", BUILD_STEPS))

        self.assertTrue(SMOKE_STEPS[0].startswith("name: Resolve release tag\n"))
        self.assertTrue(SMOKE_STEPS[1].startswith("uses: actions/checkout@"))
        self.assertIn("id: smoke-release-tag\n", SMOKE_STEPS[0])
        self.assertIn("ref: refs/tags/${{ steps.smoke-release-tag.outputs.tag }}\n", SMOKE_STEPS[1])
        verify_index = SMOKE_STEPS.index(step("Verify release tag commit", SMOKE_STEPS))
        deps_index = SMOKE_STEPS.index(step("Install lab dependencies", SMOKE_STEPS))
        self.assertLess(verify_index, deps_index)

    def test_dispatch_and_push(self):
        for env in ({}, {"EVENT_NAME": "push", "GITHUB_REF": "refs/tags/v1.2.3", "TAG": "ignored"}):
            with self.subTest(env=env):
                self.envfile.write_text("")
                self.outputfile.write_text("")
                for job in ("build-publish", "smoke-from-feed"):
                    self.envfile.write_text("")
                    self.outputfile.write_text("")
                    result = self.run_guard("Resolve release tag", job=job, **env)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(self.envfile.read_text(), "FWLIVE_RELEASE_TAG=v1.2.3\n")
                    self.assertEqual(self.outputfile.read_text(), "tag=v1.2.3\n")

    def test_invalid_inputs_do_not_write_environment(self):
        for tag in ("", "master", "refs/tags/v1.2.3", "v1.2", "v1.2.3-rc1", "v1234567890.2.3",
                    "v1.2.3\nINJECT=yes", "v1.2.3\r", "v1.2.3\t", "$(touch sentinel)"):
            with self.subTest(tag=tag):
                for job in ("build-publish", "smoke-from-feed"):
                    self.envfile.write_text("")
                    self.outputfile.write_text("")
                    self.assertNotEqual(self.run_guard("Resolve release tag", job=job, TAG=tag).returncode, 0)
                    self.assertEqual(self.envfile.read_text(), "")
                    self.assertEqual(self.outputfile.read_text(), "")
        self.assertFalse((self.root / "sentinel").exists())
        for job in ("build-publish", "smoke-from-feed"):
            self.assertNotEqual(self.run_guard("Resolve release tag", job=job, EVENT_NAME="push").returncode, 0)
            self.assertNotEqual(self.run_guard("Resolve release tag", job=job, EVENT_NAME="schedule").returncode, 0)

    def test_lightweight_annotated_and_collision(self):
        first = self.init_repo()
        self.git("tag", "v1.2.3")
        for job in ("build-publish", "smoke-from-feed"):
            self.assertEqual(self.run_guard("Verify release tag commit", job=job).returncode, 0)
        self.git("tag", "-am", "annotated", "v1.2.4")
        for job in ("build-publish", "smoke-from-feed"):
            self.assertEqual(self.run_guard("Verify release tag commit", job=job, FWLIVE_RELEASE_TAG="v1.2.4").returncode, 0)
        self.git("commit", "--allow-empty", "-qm", "second")
        self.git("branch", "v1.2.3")
        for job in ("build-publish", "smoke-from-feed"):
            self.assertNotEqual(self.run_guard("Verify release tag commit", job=job).returncode, 0)
        # Model the explicit checkout ref, not actions/checkout internals.
        self.git("checkout", "--detach", "refs/tags/v1.2.3")
        self.assertEqual(self.git("rev-parse", "HEAD"), first)
        for job in ("build-publish", "smoke-from-feed"):
            self.assertEqual(self.run_guard("Verify release tag commit", job=job).returncode, 0)

    def test_push_requires_the_triggering_commit(self):
        expected = self.init_repo()
        self.git("tag", "v1.2.3")
        for job in ("build-publish", "smoke-from-feed"):
            self.assertEqual(self.run_guard("Verify release tag commit", job=job,
                                            EVENT_NAME="push", GITHUB_EVENT_NAME="push", GITHUB_SHA=expected).returncode, 0)
            self.assertNotEqual(self.run_guard("Verify release tag commit", job=job,
                                               EVENT_NAME="push", GITHUB_EVENT_NAME="push", GITHUB_SHA="0" * 40).returncode, 0)

    def test_missing_branch_only_and_noncommit_tags(self):
        self.init_repo()
        for job in ("build-publish", "smoke-from-feed"):
            self.assertNotEqual(self.run_guard("Verify release tag commit", job=job).returncode, 0)
        self.git("branch", "v1.2.3")
        for job in ("build-publish", "smoke-from-feed"):
            self.assertNotEqual(self.run_guard("Verify release tag commit", job=job).returncode, 0)
        tree = self.git("rev-parse", "HEAD^{tree}")
        self.git("tag", "v1.2.3", tree)
        for job in ("build-publish", "smoke-from-feed"):
            self.assertNotEqual(self.run_guard("Verify release tag commit", job=job).returncode, 0)


if __name__ == "__main__":
    unittest.main()
