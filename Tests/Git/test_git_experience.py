"""Behavioral experiments use local repositories and remotes; no personal Git config."""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("lazygit_config", ROOT / "Scripts/Git/lazygit_config.py")
YAML_HELPER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(YAML_HELPER)


class YamlTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="git experience ")
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "config.yml"

    def publish(self, result):
        import base64
        after = result["Change"]["After"]
        if after is not None:
            self.path.write_bytes(base64.b64decode(after))

    def test_preserves_comments_and_removes_only_our_key(self):
        self.path.write_text('# personal comment\ngui:\n  theme: {}\n', encoding="utf-8")
        result = YAML_HELPER.prepare(self.path)
        self.publish(result)
        self.assertIn("# personal comment", self.path.read_text(encoding="utf-8"))
        self.assertEqual(result["Change"]["After"], YAML_HELPER.prepare(self.path, result["State"])["Change"]["After"])
        with self.path.open("a", encoding="utf-8") as file:
            file.write("customCommands: []\n")
        removed = YAML_HELPER.prepare(self.path, result["State"], remove=True)
        import base64
        text = base64.b64decode(removed["After"]).decode("utf-8")
        self.assertIn("customCommands: []", text)
        self.assertNotIn("diffRenderers", text)
        self.assertIn("# personal comment", text)

    def test_preserves_existing_renderer_and_replaces_reversibly(self):
        self.path.write_text('git:\n  diffRenderers:\n    - command: other\n', encoding="utf-8")
        original = self.path.read_bytes()
        self.assertFalse(YAML_HELPER.prepare(self.path)["State"]["Managed"])
        result = YAML_HELPER.prepare(self.path, replace=True)
        self.publish(result)
        removed = YAML_HELPER.prepare(self.path, result["State"], remove=True)
        import base64
        self.assertEqual(original, base64.b64decode(removed["After"]))

    def test_refuses_renderer_drift(self):
        result = YAML_HELPER.prepare(self.path)
        self.publish(result)
        self.path.write_text('git:\n  diffRenderers: []\n', encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "DRIFT"):
            YAML_HELPER.prepare(self.path, result["State"], remove=True)

    def test_rejects_duplicate_keys_and_invalid_shapes(self):
        for text in ('git: {}\ngit: {}\n', 'git: []\n', '[1, 2]\n', 'git: ['):
            with self.subTest(text=text):
                self.path.write_text(text, encoding="utf-8")
                with self.assertRaises(Exception):
                    YAML_HELPER.prepare(self.path)

    def test_missing_file_returns_to_missing(self):
        result = YAML_HELPER.prepare(self.path)
        self.publish(result)
        self.assertIsNone(YAML_HELPER.prepare(self.path, result["State"], remove=True)["After"])

    def test_rejects_shared_git_mapping_without_changing_another_section(self):
        text = 'defaults: &shared\n  autoFetch: false\ngit: *shared\n'
        self.path.write_text(text, encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "shared by YAML aliases"):
            YAML_HELPER.prepare(self.path)
        self.assertEqual(text, self.path.read_text(encoding="utf-8"))


class GitBehaviorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="git experience ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo = self.root / "repo"
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        self.env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=str(self.root / "global"),
                        GIT_AUTHOR_NAME="Test", GIT_AUTHOR_EMAIL="test@example.invalid",
                        GIT_COMMITTER_NAME="Test", GIT_COMMITTER_EMAIL="test@example.invalid",
                        GIT_TERMINAL_PROMPT="0", GIT_EDITOR="true", GIT_SEQUENCE_EDITOR="true")
        self.git("init", "-b", "main", str(self.repo), cwd=self.root)
        self.write("file.txt", "base\n")
        self.commit("base")
        self.base = self.git("rev-parse", "HEAD").stdout.strip()

    def git(self, *args, cwd=None, ok=True):
        result = subprocess.run([shutil.which("git"), *args], cwd=cwd or self.repo,
                                env=self.env, text=True, encoding="utf-8", capture_output=True, timeout=20)
        if ok and result.returncode:
            self.fail(f"git {args}: {result.stderr}")
        return result

    def write(self, name, text):
        (self.repo / name).write_text(text, encoding="utf-8")

    def commit(self, message):
        self.git("add", ".")
        self.git("commit", "-m", message)

    def profile(self):
        settings = json.loads((ROOT / "Scripts/Git/GitExperience.settings.json").read_text(encoding="utf-8"))["settings"]
        for key, value in settings.items():
            self.git("config", "--global", key, value)

    def test_new_branch_push_sets_upstream_and_prunes_without_deleting_local_tags(self):
        remote = self.root / "remote.git"
        self.git("init", "--bare", str(remote), cwd=self.root)
        self.git("remote", "add", "origin", str(remote))
        self.assertNotEqual(0, self.git("push", ok=False).returncode)
        self.profile()
        self.git("push")
        self.assertEqual("origin/main", self.git("rev-parse", "--abbrev-ref", "@{upstream}").stdout.strip())
        self.git("push", "origin", "HEAD:temporary")
        self.git("fetch")
        self.git("tag", "private-tag")
        self.git("update-ref", "-d", "refs/heads/temporary", cwd=remote)
        self.git("fetch")
        self.assertNotEqual(0, self.git("rev-parse", "--verify", "refs/remotes/origin/temporary", ok=False).returncode)
        self.git("rev-parse", "--verify", "refs/tags/private-tag")

    def test_force_if_includes_rejects_unseen_remote_commit_after_fetch(self):
        self.profile()
        remote = self.root / "remote.git"
        self.git("init", "--bare", str(remote), cwd=self.root)
        self.git("remote", "add", "origin", str(remote))
        self.git("push")
        peer = self.root / "peer"
        self.git("clone", "-b", "main", str(remote), str(peer), cwd=self.root)
        (peer / "peer.txt").write_text("other person's work\n", encoding="utf-8")
        self.git("add", ".", cwd=peer)
        self.git("commit", "-m", "unseen", cwd=peer)
        self.git("push", cwd=peer)
        self.git("commit", "--amend", "-m", "rewritten")
        self.git("fetch")
        result = self.git("push", "--force-with-lease", ok=False)
        self.assertNotEqual(0, result.returncode)
        self.assertIn("remote ref updated since checkout", result.stderr)
        # Control: disabling only the new check permits the same overwrite (local disposable remote).
        self.git("-c", "push.useForceIfIncludes=false", "push", "--force-with-lease")

    def test_conflict_context_and_recorded_resolution_autostaging(self):
        self.profile()
        self.git("checkout", "-b", "topic")
        self.write("file.txt", "topic\n")
        self.commit("topic")
        self.git("checkout", "main")
        self.write("file.txt", "main\n")
        self.commit("main")
        original = self.git("rev-parse", "HEAD").stdout.strip()
        self.assertNotEqual(0, self.git("merge", "topic", ok=False).returncode)
        self.assertIn("|||||||", (self.repo / "file.txt").read_text(encoding="utf-8"))
        self.write("file.txt", "combined\n")
        self.commit("resolved")
        # Discard only disposable fixture history so exactly the same conflict recurs.
        self.git("reset", "--hard", original)
        self.git("merge", "topic", ok=False)
        self.assertEqual("combined\n", (self.repo / "file.txt").read_text(encoding="utf-8"))
        self.assertEqual("", self.git("ls-files", "--unmerged").stdout)
        self.assertIn("combined", self.git("show", ":file.txt").stdout)

    def test_autostash_autosquash_and_worktree_ref_exclusion(self):
        self.profile()
        self.git("checkout", "-b", "topic")
        self.write("topic.txt", "one\n")
        self.commit("feature")
        feature = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("branch", "stack")
        self.git("branch", "checked-out")
        worktree = self.root / "worktree"
        self.git("worktree", "add", str(worktree), "checked-out")
        self.write("topic.txt", "two\n")
        self.git("add", ".")
        self.git("commit", "--fixup", feature)
        self.write("file.txt", "uncommitted\n")
        self.git("rebase", "-i", self.base)
        self.assertEqual("1", self.git("rev-list", "--count", f"{self.base}..HEAD").stdout.strip())
        self.assertEqual("uncommitted\n", (self.repo / "file.txt").read_text(encoding="utf-8"))
        self.assertEqual(feature, self.git("rev-parse", "checked-out").stdout.strip())
        self.assertEqual(self.git("rev-parse", "HEAD").stdout, self.git("rev-parse", "stack").stdout)

    def test_autostash_restoration_conflict_preserves_stash(self):
        self.profile()
        self.git("checkout", "-b", "topic")
        self.write("topic.txt", "feature\n")
        self.commit("feature")
        self.git("checkout", "main")
        self.write("file.txt", "upstream\n")
        self.commit("upstream")
        self.git("checkout", "topic")
        self.write("file.txt", "uncommitted\n")
        self.git("rebase", "main")
        self.assertTrue(self.git("ls-files", "--unmerged").stdout)
        self.assertIn("uncommitted", self.git("show", "stash@{0}:file.txt").stdout)

    def test_diff_algorithms_produce_valid_patches(self):
        before = "alpha {\n  common\n  first\n}\nbeta {\n  common\n  second\n}\n"
        after = "beta {\n  common\n  second\n}\nalpha {\n  common\n  changed\n}\n"
        self.write("code.txt", before)
        self.commit("before")
        self.write("code.txt", after)
        for algorithm in ("myers", "histogram"):
            patch = self.git("-c", f"diff.algorithm={algorithm}", "diff", "--no-ext-diff", "--no-color").stdout
            self.assertTrue(patch)
            patch_path = self.root / "change.patch"
            patch_path.write_text(patch, encoding="utf-8")
            self.git("apply", "--reverse", "--check", str(patch_path))


if __name__ == "__main__":
    unittest.main(verbosity=2)
