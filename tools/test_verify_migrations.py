"""Offline regression tests for history integrity and archive preservation."""
import base64
import copy
import hashlib
from pathlib import Path
import tempfile
import unittest

from verify_migrations import ROOT, credential_indicators, normalized_sha, validate


class MigrationGuardTests(unittest.TestCase):
    def setUp(self):
        base = (ROOT / '.dart_tool/waydrop-local-runtime').resolve()
        base.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix='migration-guard-', dir=base)
        self.root = Path(self.temp.name).resolve()
        assert self.root.is_relative_to(base)
        self.addCleanup(self.temp.cleanup)
        self.path = self.root / 'supabase/migrations/20261103000000_example.sql'
        self.path.parent.mkdir(parents=True)
        self.path.write_bytes(b'SELECT 1;\n')
        self.manifest = {'files': [{'version': '20261103000000', 'name': 'example',
            'path': self.path.relative_to(self.root).as_posix(),
            'sha256_lf': normalized_sha(self.path.read_bytes())}]}

    def test_valid_history_and_crlf_checkout(self):
        self.assertEqual(validate(self.root, self.manifest), [])
        self.path.write_bytes(b'SELECT 1;\r\n')
        self.assertEqual(validate(self.root, self.manifest), [])

    def test_unexpected_pending_draft_rejected(self):
        (self.path.parent / '20261104000000_draft.sql').write_bytes(b'SELECT 2;')
        self.assertTrue(validate(self.root, self.manifest))

    def test_duplicate_version_rejected(self):
        (self.path.parent / '20261103000000_other.sql').write_bytes(b'SELECT 2;')
        self.assertTrue(any('Duplicate version' in e for e in validate(self.root, self.manifest)))

    def test_missing_history_rejected(self):
        self.path.unlink()
        self.assertTrue(any('Missing recorded' in e for e in validate(self.root, self.manifest)))

    def test_source_drift_rejected(self):
        self.path.write_bytes(b'SELECT 2;\n')
        self.assertTrue(any('Source drift' in e for e in validate(self.root, self.manifest)))

    def test_path_traversal_rejected(self):
        manifest = copy.deepcopy(self.manifest)
        manifest['files'][0]['path'] = '../outside.sql'
        self.assertTrue(any('Unsafe/noncanonical' in e for e in validate(self.root, manifest)))

    def test_archive_original_bytes_enforced(self):
        path = self.root / 'docs/migration-review/not-applied/example.sql'
        path.parent.mkdir(parents=True)
        path.write_bytes(b'SELECT 2;\r\n')
        self.manifest['review_files'] = [{'path': path.relative_to(self.root).as_posix(),
            'sha256_original_bytes': hashlib.sha256(path.read_bytes()).hexdigest()}]
        self.assertEqual(validate(self.root, self.manifest), [])
        path.write_bytes(b'SELECT 2;\n')
        self.assertTrue(any('Original review source' in e for e in validate(self.root, self.manifest)))

    def test_invalid_utf8_rejected(self):
        self.path.write_bytes(b'\xff')
        self.assertTrue(any('Invalid UTF-8' in e for e in validate(self.root, self.manifest)))

    def test_credentials_detected_without_printing_values(self):
        payload = base64.urlsafe_b64encode(b'{"role":"service_role"}').decode().rstrip('=')
        self.assertEqual(credential_indicators('eyJhbGciOiJIUzI1NiJ9.' + payload + '.signature'), ['service-role JWT'])
        self.assertEqual(credential_indicators('-----BEGIN PRIVATE KEY-----'), ['private-key PEM'])
        self.assertEqual(credential_indicators('sb_secret_' + 'x' * 20), ['secret-key prefix'])
        self.assertEqual(credential_indicators('eyJhbGciOiJIUzI1NiJ9.W10.signature'), [])


if __name__ == '__main__':
    unittest.main()
