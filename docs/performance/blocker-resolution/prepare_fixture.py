"""Create the fixed loopback synthetic test database; refuse to overwrite one."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[3]
psql = root / '.dart_tool/waydrop-local-runtime/postgresql-17.11-core/pgsql/bin/psql.exe'
args = [str(psql), '-X', '-q', '-A', '-t', '-h', '127.0.0.1', '-p', '54329',
        '-U', 'waydrop_local', '-v', 'ON_ERROR_STOP=1']

def run(database, text):
    return subprocess.run([*args, '-d', database, '-c', text], check=True,
                          capture_output=True, text=True).stdout.strip()

assert run('postgres', "SELECT inet_server_addr()=inet '127.0.0.1' AND inet_server_port()=54329") == 't'
if run('postgres', "SELECT count(*) FROM pg_database WHERE datname='waydrop_blocker_test'") != '0':
    raise SystemExit('Fixed database already exists. Reuse with native_test.py; nothing overwritten.')
for role, options in [('anon', 'NOLOGIN'), ('authenticated', 'NOLOGIN'), ('service_role', 'NOLOGIN BYPASSRLS')]:
    if run('postgres', f"SELECT count(*) FROM pg_roles WHERE rolname='{role}'") == '0':
        run('postgres', f'CREATE ROLE {role} {options}')
run('postgres', 'CREATE DATABASE waydrop_blocker_test')
subprocess.run([*args, '-d', 'waydrop_blocker_test', '-f',
                str(Path(__file__).with_name('SYNTHETIC_BASE.sql'))], check=True)
