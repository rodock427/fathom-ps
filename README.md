# fathom-ps

FlexLM license monitoring on PowerShell Universal: a PowerShell port of the monitoring side of
[Fathom](../license_manager). It's agentless: PSU polls `lmstat` and reads `lmgrd` debug logs over SMB.
See [PLAN.md](PLAN.md).

It shares Fathom's Postgres tables, so both can run against one database.

## Layout

| Path | What |
|---|---|
| `Fathom/` | The module: all logic, testable without PSU |
| `Fathom/Sql/schema.sql` | Idempotent DDL, copied verbatim from Fathom's `lm_opdb` |
| `tests/` | Pester tests |
| `build.ps1` | Lint + test; CI runs exactly this |

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
Import-Module ./Fathom/Fathom.psd1
Connect-FathomDatabase          # reads LM_POSTGRES_DSN, the same variable Fathom uses
Initialize-FathomSchema

# Monitor a server, then read what's new in its debug log (safe to run on a schedule)
Register-FathomServer -ServerId licsrv01 -LicenseSpec 27000@licsrv01 -LogPath '\\licsrv01\flexlm$\debug.log'
Get-FathomServer -Enabled | Sync-FathomDebugLog

# Lower level: parse lines yourself. Keep the context's CurrentDate and LineNumber to resume later.
$context = New-FathomParserContext -ServerId licsrv01 -SourceFile '\\licsrv01\flexlm$\debug.log'
[System.IO.File]::ReadLines($context.SourceFile) | ConvertFrom-FathomDebugLog -Context $context

# Live usage snapshot
& lmutil lmstat -a -c 27000@licsrv01 | ConvertFrom-FathomLmstat -ServerId licsrv01
```
