# fathom-ps

FlexLM license monitoring on PowerShell Universal: a PowerShell port of the monitoring side of
[Fathom](../license_manager). It's agentless: PSU polls `lmstat` and reads `lmgrd` debug logs over SMB.
See [PLAN.md](PLAN.md).

It shares Fathom's Postgres tables, so both can run against one database.

## Layout

| Path | What |
|---|---|
The repo root **is** the PSU repository (what PSU's Git sync points at).

| Path | What |
|---|---|
| `.universal/` | PSU configuration: scripts and schedules, as code |
| `Scripts/` | The PSU jobs: thin wrappers around the module |
| `Modules/Fathom/` | The module: all logic, testable without PSU. PSU puts `Modules/` on its module path |
| `Modules/Fathom/Sql/schema.sql` | Idempotent DDL, copied verbatim from Fathom's `lm_opdb` |
| `tests/` | Pester tests. `tests/fakes/lmutil` stands in for lmutil |
| `build.ps1` | Lint + test; CI runs exactly this |

## Run in PowerShell Universal

| Schedule | Script | Runs |
|---|---|---|
| Fathom: read debug logs | `Scripts/Sync-DebugLogs.ps1` | every minute |
| Fathom: poll lmstat | `Scripts/Sync-LiveStatus.ps1` | every 5 minutes |

`Scripts/Initialize-Database.ps1` isn't scheduled: run it once after installing **and after every update**. Until it runs, jobs that need new columns fail (and recover by themselves once it has).

Setup on the PSU server:

1. **Database:** a secret variable named `FathomDsn` (Manage > Variables & Secrets), or `LM_POSTGRES_DSN` set on the PSU service. Don't put a role on the secret: scheduled jobs run without roles and couldn't read it.
2. **lmutil:** `FATHOM_LMUTIL` set to its full path, or `lmutil` on the service's `PATH`.
3. **Log access:** the PSU service account needs read access to each server's FlexLM log share.
4. Run `Scripts/Initialize-Database.ps1`, then register servers (see [Use](#use)).

Local dev against the fake lmutil, with `.dev/` holding `debug.log` and `<host>.txt` lmstat answers:

```bash
LM_POSTGRES_DSN=postgresql://license_manager:license_manager@localhost:5432/license_manager \
FATHOM_LMUTIL=$PWD/tests/fakes/lmutil FAKE_LMUTIL_DIR=$PWD/.dev \
  ~/Documents/Projects/General/Powershell/Powershell-Universal/start-psu.sh "$PWD"
```

## Develop

Requires PowerShell 7.4+ and the modules `SimplySql`, `Pester` 6 and `PSScriptAnalyzer`.

```bash
# Throwaway Postgres for the schema tests (same credentials as Fathom's compose file)
podman run -d --name fathom-pg -p 127.0.0.1:5432:5432 \
  -e POSTGRES_USER=license_manager -e POSTGRES_PASSWORD=license_manager -e POSTGRES_DB=license_manager \
  docker.io/library/postgres:16-alpine
podman exec fathom-pg psql -U license_manager -c 'CREATE DATABASE fathom_ps_test'

export FATHOM_TEST_DSN=postgresql://license_manager:license_manager@localhost:5432/fathom_ps_test
./build.ps1            # or -Task Lint / -Task Test
```

Without `FATHOM_TEST_DSN`, the database tests are skipped.

### Parity with Python Fathom

`tests/Parity.Tests.ps1` checks the parsers against golden files produced by Fathom's own
Python parsers. Regenerate them after changing a fixture (needs `../license_manager` with its `.venv`):

```bash
../license_manager/.venv/bin/python tests/fixtures/generate_golden.py
```

## Use

```powershell
Import-Module ./Modules/Fathom/Fathom.psd1
Connect-FathomDatabase          # reads LM_POSTGRES_DSN, the same variable Fathom uses
Initialize-FathomSchema

# Monitor a server, then read what's new in its debug log (safe to run on a schedule)
Register-FathomServer -ServerId licsrv01 -LicenseSpec 27000@licsrv01 -LogPath '\\licsrv01\flexlm$\debug.log'
Get-FathomServer -Enabled | Sync-FathomDebugLog

# Change settings, e.g. drive usage history from lmstat while a log share is out
Set-FathomServer -ServerId licsrv01 -UsageSource Lmstat

# Lower level: parse lines yourself. Keep the context's CurrentDate and LineNumber to resume later.
$context = New-FathomParserContext -ServerId licsrv01 -SourceFile '\\licsrv01\flexlm$\debug.log'
[System.IO.File]::ReadLines($context.SourceFile) | ConvertFrom-FathomDebugLog -Context $context

# Poll lmstat: live usage, history, holders, seats, expiry, daemon health (also safe to schedule)
Get-FathomServer -Enabled | Sync-FathomLiveStatus -LmutilPath 'C:\FlexLM\lmutil.exe'

# Lower level: parse lmstat output yourself
& lmutil lmstat -a -c 27000@licsrv01 | ConvertFrom-FathomLmstat -ServerId licsrv01
```
