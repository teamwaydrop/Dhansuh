"""Offline migration/history guard. Never connects to or mutates a database."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
FILENAME = re.compile(r'^(\d{14})_([A-Za-z0-9_]+)\.sql$')


def normalized_sha(data):
    return hashlib.sha256(data.replace(b'\r\n', b'\n')).hexdigest()


def credential_indicators(text):
    found = []
    if re.search(r'sb_secret_[A-Za-z0-9_-]{16,}', text):
        found.append('secret-key prefix')
    if re.search(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----', text):
        found.append('private-key PEM')
    for token in re.findall(r'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+', text):
        try:
            value = token.split('.')[1]
            body = json.loads(base64.urlsafe_b64decode(value + '=' * (-len(value) % 4)))
            if isinstance(body, dict) and body.get('role') == 'service_role':
                found.append('service-role JWT')
        except (ValueError, UnicodeDecodeError):
            pass
    return sorted(set(found))


def validate(root, manifest, syntax=False):
    root = Path(root).resolve()
    directory = root / 'supabase/migrations'
    errors = []
    files = sorted(directory.glob('*.sql'))
    expected = manifest['files']
    if len(files) != len(expected):
        errors.append(f'Expected {len(expected)} active migrations; found {len(files)}')
    by_version = {}
    for path in files:
        match = FILENAME.fullmatch(path.name)
        if not match:
            errors.append(f'Invalid migration filename: {path.name}')
            continue
        version = match[1]
        if version in by_version:
            errors.append(f'Duplicate version: {version}')
        by_version[version] = path
    if len({r['version'] for r in expected}) != len(expected):
        errors.append('Duplicate manifest versions')
    for record in expected:
        path = root / record['path']
        wanted = directory / f"{record['version']}_{record['name']}.sql"
        if path != wanted or not path.resolve().is_relative_to(directory.resolve()):
            errors.append(f'Unsafe/noncanonical manifest path: {record["version"]}')
            continue
        if not path.is_file():
            errors.append(f'Missing recorded migration: {record["version"]}')
            continue
        data = path.read_bytes()
        if normalized_sha(data) != record['sha256_lf']:
            errors.append(f'Source drift: {path.name}')
        try:
            text = data.decode('utf-8-sig')
        except UnicodeDecodeError:
            errors.append(f'Invalid UTF-8: {path.name}')
            continue
        for indicator in credential_indicators(text):
            errors.append(f'Credential indicator ({indicator}): {path.name}')
        if syntax:
            from pglast.parser import parse_sql_json
            try:
                parse_sql_json(text)
            except Exception:
                errors.append(f'PostgreSQL syntax failure: {path.name}')
    for record in manifest.get('review_files', []):
        path = root / record['path']
        archive = root / 'docs/migration-review'
        if not path.resolve().is_relative_to(archive.resolve()):
            errors.append('Unsafe review archive path')
        elif not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != record['sha256_original_bytes']:
            errors.append(f'Original review source missing/changed: {record["path"]}')
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--syntax', action='store_true', help='Also parse SQL with the optional pinned pglast tool')
    args = parser.parse_args()
    manifest = json.loads((ROOT / 'supabase/migration_manifest.json').read_text(encoding='utf-8'))
    if args.syntax:
        try:
            import pglast  # noqa: F401
        except ImportError:
            parser.error('Install tools/requirements-migration-check.txt for --syntax; no check was skipped')
    errors = validate(ROOT, manifest, args.syntax)
    if errors:
        for error in errors:
            print('FAIL ' + error)
        return 1
    print(f"PASS {len(manifest['files'])} recorded migrations; unique versions, exact names, LF-normalized hashes, no private-key indicators; {len(manifest.get('review_files', []))} preserved originals")
    if args.syntax:
        print('PASS PostgreSQL syntax parsing (not a fresh database replay)')
    print('No database operation performed.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
