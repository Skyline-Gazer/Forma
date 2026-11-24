#!/usr/bin/env python3
"""Installer regression tests. All sources, installs and faults live under mkdtemp."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

INSTALLER = Path(__file__).with_name("install_skills.sh")
NAME = "forma-test-skill"
UPSTREAM = "https://example.invalid/forma-test-skill"


class InstallerTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix="forma-skills-test-")
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.shims = self.root / "shims"
        self.shims.mkdir()
        # Do not inherit user Git exclusions, URLs, hooks, or config.
        self.env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1",
                        GIT_CONFIG_COUNT="0", PYTHONPATH=str(self.shims))
        self.git = shutil.which("git")
        self.env.update(FORMA_TEST_GIT=self.git, FORMA_TEST_CP=shutil.which("cp"))
        self.upstream = self.root / "upstream"
        self.upstream.mkdir()
        skill = self.upstream / "nested" / NAME
        (skill / "references").mkdir(parents=True)
        (skill / "SKILL.md").write_text(f"---\nname: {NAME}\ndescription: Fixture\n---\n# Test skill\n")
        (skill / "references" / "guide.md").write_text("# Test reference\n")
        (self.upstream / ".gitignore").write_text("personal.txt\n")
        (self.upstream / "LICENSE").write_text("MIT License\nPermission is hereby granted, free of charge\n")
        self.git_run(self.upstream, "init", "-q")
        self.git_run(self.upstream, "add", ".")
        self.git_run(self.upstream, "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                     "-c", "commit.gpgsign=false", "commit", "-qm", "Synthetic fixture")
        commit = self.git_run(self.upstream, "rev-parse", "HEAD").stdout.strip()

        (self.root / "scripts").mkdir()
        self.installer = self.root / "scripts" / INSTALLER.name
        shutil.copyfile(INSTALLER, self.installer)
        (self.root / "skills.lock.json").write_text(json.dumps({
            "schema": 1, "install_dir": ".agents/skills",
            "skills": [{"name": NAME, "upstream": UPSTREAM, "commit": commit,
                        "skill_path": f"nested/{NAME}", "license_file": "LICENSE",
                        "license_header": "MIT License"}],
        }))
        self.env.update(FORMA_TEST_REPO=str(self.upstream), FORMA_TEST_URL=UPSTREAM,
                        PATH=str(self.shims) + os.pathsep + self.env["PATH"])
        self.shim("git", """\
if [ "$3" = fetch ]; then
    exec "$FORMA_TEST_GIT" -c "url.$FORMA_TEST_REPO.insteadOf=$FORMA_TEST_URL" "$@"
fi
exec "$FORMA_TEST_GIT" "$@"
""")
        self.shim("cp", """\
if [ "${FORMA_TEST_FAULT-}" = staging ] && [ "$1" = -Rp ]; then
    printf 'partial staging\n' > "$3/SKILL.md"
    exit 71
fi
exec "$FORMA_TEST_CP" "$@"
""")
        (self.shims / "sitecustomize.py").write_text("""\
import os
from pathlib import Path

rename = os.rename

def injected_rename(source, target):
    fault = os.environ.get('FORMA_TEST_FAULT')
    if Path(source).name.startswith('stage-') and fault in ('replacement', 'rollback'):
        raise OSError('injected replacement failure')
    if Path(source).name == 'previous' and fault == 'rollback':
        raise OSError('injected rollback failure')
    rename(source, target)

os.rename = injected_rename
""")
        self.base = self.root / ".agents"
        self.dest = self.base / "skills" / NAME
        self.backup = self.base / f".backup-{NAME}"

    def git_run(self, cwd, *args):
        return subprocess.run([self.git, "-C", cwd, *args], env=self.env, text=True,
                              capture_output=True, check=True, timeout=10)

    def shim(self, name, content):
        path = self.shims / name
        path.write_text("#!/bin/sh\nset -eu\n" + content)
        path.chmod(0o700)

    def legacy(self):
        self.dest.parent.mkdir(parents=True)
        self.git_run(self.root, "clone", "-q", str(self.upstream), str(self.dest))
        self.git_run(self.dest, "remote", "set-url", "origin", UPSTREAM)
        return self.dest / "nested" / NAME / "SKILL.md"

    def install(self, *args, fault="", failure=None):
        result = subprocess.run(["sh", self.installer, *args], cwd=self.root, text=True,
                                env=dict(self.env, FORMA_TEST_FAULT=fault),
                                capture_output=True, timeout=20)
        self.assertFalse(list(self.base.glob(".install.*")), result.stderr)
        if failure is None:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn(failure, result.stderr)
        return result.stderr

    def test_failed_staging_preserves_old_install(self):
        old = self.legacy()
        before = old.read_bytes()
        self.install(fault="staging", failure="cannot copy skill subtree")
        self.assertEqual(old.read_bytes(), before)
        self.assertFalse((self.dest / "SKILL.md").exists())
        self.assertFalse(self.backup.exists())

    def test_failed_replacement_restores_old_install(self):
        old = self.legacy()
        before = old.read_bytes()
        self.install(fault="replacement", failure="injected replacement failure")
        self.assertEqual(old.read_bytes(), before)
        self.assertTrue((self.dest / ".git").is_dir())
        self.assertFalse(self.backup.exists())

    def test_failed_rollback_preserves_and_reports_backup_on_retry(self):
        old = self.legacy()
        before = old.read_bytes()
        err = self.install(fault="rollback", failure="injected rollback failure")
        self.assertIn(str(self.backup), err)
        saved = self.backup / "previous" / old.relative_to(self.dest)
        self.assertEqual(saved.read_bytes(), before)
        self.assertFalse(self.dest.exists())
        for args in ((), ("--check-only",)):
            self.install(*args, failure=f"outstanding install transaction at {self.backup}")
            self.assertEqual(saved.read_bytes(), before)
            self.assertFalse(self.dest.exists())

    def test_previous_pid_backup_is_reported_and_preserved(self):
        old = self.legacy()
        before = old.read_bytes()
        recovery = self.backup.with_name(f"{self.backup.name}.1234")
        self.dest.rename(recovery)
        self.install(failure=f"outstanding install transaction at {recovery}")
        self.assertEqual((recovery / old.relative_to(self.dest)).read_bytes(), before)
        self.assertFalse(self.dest.exists())

    def test_dirty_legacy_install_is_preserved(self):
        old = self.legacy()
        old.write_text("local edit\n")
        self.install(failure="was modified locally")
        self.assertEqual(old.read_text(), "local edit\n")
        self.assertFalse((self.dest / "SKILL.md").exists())

    def test_ignored_user_file_is_preserved(self):
        self.legacy()
        personal = self.dest / "personal.txt"
        personal.write_text("local notes\n")
        self.install(failure="was modified locally")
        self.assertEqual(personal.read_text(), "local notes\n")
        self.assertFalse((self.dest / "SKILL.md").exists())

    def test_clean_legacy_migration_and_repeatable_check(self):
        old = self.legacy()
        before = old.read_bytes()
        self.install("--check-only", failure="not a host-visible install")
        self.install()
        entry = self.dest / "SKILL.md"
        self.assertEqual(entry.read_bytes(), before)
        self.assertEqual((self.dest / "references" / "guide.md").read_text(), "# Test reference\n")
        self.assertFalse(old.exists())
        self.assertFalse(self.backup.exists())
        original = entry.stat()
        self.install()
        self.install("--check-only")
        self.assertEqual((entry.stat().st_ino, entry.stat().st_mtime_ns),
                         (original.st_ino, original.st_mtime_ns))

    def test_modified_host_install_is_refused_and_preserved(self):
        self.install()
        notes = self.root / "notes"
        notes.mkdir()
        linked = self.dest / "extra"
        linked.symlink_to(notes, target_is_directory=True)
        self.install("--check-only", failure="symlink escapes the skill root")
        self.install(failure="is not a host-visible install")
        self.assertEqual(linked.readlink(), notes)


if __name__ == "__main__":
    unittest.main()
