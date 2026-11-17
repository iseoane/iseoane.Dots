"""Regression tests for engram sync recovery guards.

Covers the failure seen on 2026-11-10: an interrupted merge left conflict
markers in .engram/manifest.json and the next push committed them, breaking
`engram sync` on every machine. Each case runs against sync.sh and sync.ps1.

Run: python -m unittest discover -s engram/tests
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
SCRIPTS = HERE.parent
MANIFEST = '.engram/manifest.json'
IS_WINDOWS = sys.platform == 'win32'


def find_bash():
    if IS_WINDOWS:
        candidate = Path(os.environ.get('ProgramFiles', r'C:\Program Files')) / 'Git' / 'bin' / 'bash.exe'
        if candidate.exists():
            return str(candidate)
    return shutil.which('bash')


BASH = find_bash()
PWSH = shutil.which('pwsh')


def git(where, *args, check=True):
    return subprocess.run(['git', '-C', str(where), *args], check=check,
                          capture_output=True, text=True)


def write_manifest(repo, ids):
    folder = repo / '.engram' / 'chunks'
    folder.mkdir(parents=True, exist_ok=True)
    for ident in ids:
        (folder / f'{ident}.jsonl.gz').write_bytes(ident.encode())
    (repo / MANIFEST).write_text(json.dumps(
        {'version': 2, 'chunks': [{'id': i, 'created_at': i} for i in ids]}, indent=2) + '\n',
        encoding='utf-8')


def commit_all(repo, msg):
    git(repo, 'add', '-A')
    git(repo, 'commit', '-q', '-m', msg)


class SyncRecoveryMixin:
    runner = None  # 'sh' | 'ps1'

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.remote = self.tmp / 'remote.git'
        self.local = self.tmp / 'local'
        self.other = self.tmp / 'other'
        self.log = self.tmp / 'sync.log'
        subprocess.run(['git', 'init', '-q', '--bare', '--initial-branch=main', str(self.remote)], check=True)
        for clone in (self.local, self.other):
            subprocess.run(['git', 'clone', '-q', str(self.remote), str(clone)], check=True,
                           capture_output=True)
            git(clone, 'config', 'user.email', 'test@example.com')
            git(clone, 'config', 'user.name', 'Test')
            git(clone, 'config', 'core.autocrlf', 'false')
            git(clone, 'checkout', '-q', '-B', 'main')
        write_manifest(self.local, ['a'])
        commit_all(self.local, 'base')
        git(self.local, 'push', '-q', 'origin', 'main')
        git(self.other, 'pull', '-q', 'origin', 'main')
        self.fake_engram = self.make_fake_engram()

    def make_fake_engram(self):
        bindir = self.tmp / 'bin'
        bindir.mkdir()
        if self.runner == 'ps1':
            path = bindir / 'engram.cmd'
            path.write_text('@echo off\r\nif defined FAKE_ENGRAM_FAIL (\r\n'
                            '  echo engram: parse manifest: boom 1>&2\r\n  exit /b 1\r\n)\r\nexit /b 0\r\n')
        else:
            path = bindir / 'engram'
            path.write_text('#!/usr/bin/env bash\nif [[ -n "${FAKE_ENGRAM_FAIL:-}" ]]; then\n'
                            '  echo "engram: parse manifest: boom" >&2; exit 1\nfi\nexit 0\n')
            path.chmod(0o755)
        return path

    def run_sync(self, cmd, extra_env=None):
        env = dict(os.environ,
                   ENGRAM_SYNC_DIR=str(self.local),
                   ENGRAM_BIN=str(self.fake_engram),
                   ENGRAM_LOCK=str(self.tmp / 'sync.lock'),
                   ENGRAM_LOG=str(self.log),
                   ENGRAM_FETCH_RETRIES='1')
        env.update(extra_env or {})
        if self.runner == 'ps1':
            argv = [PWSH, '-NoProfile', '-File', str(SCRIPTS / 'sync.ps1'), cmd]
        else:
            argv = [BASH, str(SCRIPTS / 'sync.sh'), cmd]
        result = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stderr)
        return self.log.read_text(encoding='utf-8') if self.log.exists() else ''

    def leave_merge_half_done(self):
        """Diverge manifest on both sides and stop with a conflicted merge."""
        write_manifest(self.other, ['a', 'b'])
        commit_all(self.other, 'other side')
        git(self.other, 'push', '-q', 'origin', 'main')
        write_manifest(self.local, ['a', 'c'])
        commit_all(self.local, 'local side')
        git(self.local, 'fetch', '-q', 'origin')
        merged = git(self.local, 'merge', '--no-edit', 'origin/main', check=False)
        self.assertNotEqual(merged.returncode, 0, 'fixture must produce a conflict')
        self.assertIn('<<<<<<<', (self.local / MANIFEST).read_text(encoding='utf-8'))

    def remote_manifest(self):
        return git(self.local, 'show', f'origin/main:{MANIFEST}').stdout

    def test_push_aborts_half_done_merge_and_never_commits_markers(self):
        self.leave_merge_half_done()
        log = self.run_sync('push')
        self.assertIn('merge a medias detectado', log)
        git(self.local, 'fetch', '-q', 'origin')
        remote = self.remote_manifest()
        self.assertNotIn('<<<<<<<', remote)
        ids = {c['id'] for c in json.loads(remote)['chunks']}
        self.assertEqual(ids, {'a', 'b', 'c'})
        self.assertFalse((self.local / '.git' / 'MERGE_HEAD').exists())

    def test_push_refuses_committed_broken_manifest(self):
        (self.local / MANIFEST).write_text('<<<<<<< HEAD\n{}\n=======\n{}\n>>>>>>> x\n', encoding='utf-8')
        commit_all(self.local, 'broken')
        head_before = git(self.local, 'rev-parse', 'HEAD').stdout
        log = self.run_sync('push')
        self.assertIn('manifest.json', log)
        self.assertIn('requiere', log)
        self.assertNotIn('Push OK', log)
        self.assertEqual(git(self.local, 'rev-parse', 'HEAD').stdout, head_before)
        self.assertNotIn('<<<<<<<', self.remote_manifest())

    def test_engram_stderr_reaches_log(self):
        log = self.run_sync('push', {'FAKE_ENGRAM_FAIL': '1'})
        self.assertIn('parse manifest: boom', log)


@unittest.skipUnless(BASH and shutil.which('flock'), 'bash/flock not available (sync.sh is the Linux/macOS path)')
class SyncShRecoveryTest(SyncRecoveryMixin, unittest.TestCase):
    runner = 'sh'


@unittest.skipUnless(PWSH, 'pwsh not available')
class SyncPs1RecoveryTest(SyncRecoveryMixin, unittest.TestCase):
    runner = 'ps1'


if __name__ == '__main__':
    unittest.main()
