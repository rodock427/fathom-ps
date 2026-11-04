# Fathom → PowerShell Universal: V1 plan (agentless monitoring)

V1 recreates Fathom's **monitoring** side in PowerShell on PSU, **with nothing installed on license-server hosts**:
- **Live status**: PSU runs `lmutil lmstat -a -c port@host` for each registered server on a schedule. This gives seat limits, in-use counts and up/down.
- **Usage history**: PSU reads each host's `lmgrd` debug log over SMB (`\\licsrv\share\debug.log`), picking up from where it last stopped, and parses new lines into usage events.

It uses the **same Postgres tables** as Fathom for the data both versions share, so they can run side by side.
Orchestration, cost/token/department reporting, the custom push agent and the Docker/K8s runtimes are **out of V1**.

## Shape

```
fathom-ps/
├── Fathom/                    # module: parsing, collection, storage, queries
│   ├── Classes/  Private/  Public/   # one function per file
│   └── Sql/schema.sql         # Fathom's monitoring tables + one PSU-side config table
├── tests/                     # Pester; parity tests reuse license_manager fixtures
├── PSScriptAnalyzerSettings.psd1
├── azure-pipelines.yml        # CI: PSScriptAnalyzer + Pester on every push
└── repository/                # PSU glue only: schedules, scripts, (later) apps
```

## Code style (enforced)

- Approved verbs, `Fathom` noun prefix, `[CmdletBinding()]`, typed and validated parameters.
- No aliases, no positional abuse, splatting for long calls.
- Comments: a one-line `.SYNOPSIS` per public function, plus inline comments only for *why*.
- Clean under PSScriptAnalyzer (including formatting rules), and every phase ships Pester tests.

## Phases

| # | Phase | Done when |
|---|---|---|
| 1 | **Foundation**: module skeleton, Postgres via SimplySql, `schema.sql`, lint/test harness, Azure DevOps CI | CI is green; schema setup is idempotent against Fathom's DB |
| 2 | **Parsers**: FlexLM debug log (with running-date handling) and `lmstat -a` | Parity: Fathom's fixtures produce the same events as the Python parser |
| 3 | **Ingest core**: register monitored servers (`port@host`, log path), track the read position per log (handling rotation and truncation), write `license_events` deduplicated by a deterministic event id | Re-reading a log writes nothing new; a rotated log restarts cleanly |
| 4 | **Collection**: PSU schedules for the log read and the `lmstat` poll, recording live status, seat limits and server up/down | Fixture-driven tests pass; the real `lmutil` and UNC calls are thin, reviewed shims |
| 5 | **Monitoring queries**: live status, usage vs limit over time, denials, server health and last read | Parity with Fathom's `lm_reporting` on seeded data |
| 6 | **UI**: **stop here and present the options** before building anything | You pick |

In dev, log paths are local fixture files. The UNC path is the same code, just a different path.

## Later (not V1)

- **Devolutions Agent fallback** for hosts PSU can't reach over SMB (DMZ, other domains). PSU's own agent, which needs PSU 2026.3 and **one PSU license per computer**.
- **Ansible provisioning**: install PSU on Windows Server, put `lmutil` on it, and set up the service account and share permissions on license hosts. Code deploys via PSU Git sync, not Ansible.
- Fathom push-ingest API compatibility, only if existing `Send-FathomLogs.ps1` installs need it.

## Production prerequisites

- PSU on **Windows Server**, running as a **domain service account** with read access to each host's FlexLM log folder.
- `lmutil.exe` on the PSU host, plus network access to each server's `port@host` (lmgrd and vendor daemon ports).
