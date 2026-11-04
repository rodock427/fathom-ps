# Fathom → PowerShell Universal: V1 plan (agentless monitoring)

> **Status: V1 is complete** (phases 1–8), plus scale fixes for servers with hundreds of features and
> Active Directory enrichment. The [README](README.md) describes what's built; this file keeps the
> design decisions and what's next.

V1 recreates Fathom's **monitoring** side in PowerShell on PSU, **with nothing installed on license-server hosts**:
- **Live status**: PSU runs `lmutil lmstat -a -c port@host` for each registered server on a schedule. This gives seat limits, in-use counts and up/down.
- **Usage history**: PSU reads each host's `lmgrd` debug log over SMB (`\\licsrv\share\debug.log`), picking up from where it last stopped, and parses new lines into usage events.

It uses the **same Postgres tables** as Fathom for the data both versions share, so they can run side by side.
Orchestration, cost/token/department reporting, the custom push agent and the Docker/K8s runtimes are **out of V1**.

## Shape

The repo root is the PSU repository, because PSU's Git sync syncs the whole folder.

```
fathom-ps/
├── .universal/                # PSU config as code: scripts, schedules, the app, roles
├── Apps/Fathom/               # the PSU app: one script per page
├── Scripts/                   # PSU jobs: thin wrappers around the module
├── Modules/Fathom/            # module: parsing, collection, storage, queries (PSU auto-loads Modules/)
│   ├── Private/  Public/      # one function per file
│   └── Sql/schema.sql         # Fathom's monitoring tables + PSU-side tables
├── tests/                     # Pester; parity tests reuse license_manager fixtures
├── tools/                     # dev helpers: New-DevData.ps1 generates local dev data
├── PSScriptAnalyzerSettings.psd1
└── azure-pipelines.yml        # CI: PSScriptAnalyzer + Pester on every push
```

## Code style (enforced)

- Approved verbs, `Fathom` noun prefix, `[CmdletBinding()]`, typed and validated parameters.
- No aliases, no positional abuse, splatting for long calls.
- Comments: a one-line `.SYNOPSIS` per public function, plus inline comments only for *why*.
- Clean under PSScriptAnalyzer (including formatting rules), and every phase ships Pester tests.

## Phases

All done. One gap: the Azure DevOps pipeline is written but not yet connected, so "CI is green"
means `build.ps1` passes locally.

| # | Phase | Done when |
|---|---|---|
| 1 | **Foundation**: module skeleton, Postgres via SimplySql, `schema.sql`, lint/test harness, Azure DevOps CI | CI is green; schema setup is idempotent against Fathom's DB |
| 2 | **Parsers**: FlexLM debug log (with running-date handling) and `lmstat -a` | Parity: Fathom's fixtures produce the same events as the Python parser |
| 3 | **Ingest core**: register monitored servers (`port@host`, log path), track the read position per log (handling rotation and truncation), write `license_events` deduplicated by a deterministic event id | Re-reading a log writes nothing new; a rotated log restarts cleanly |
| 4 | **Collection**: PSU schedules for the log read and the `lmstat` poll, recording live status, seat limits and server up/down | Fixture-driven tests pass; the real `lmutil` and UNC calls are thin, reviewed shims |
| 5 | **Fuller `lmstat` capture**: usage history (every snapshot), current holders, expiry dates, vendor daemon status, data freshness; `Set-FathomServer` | An lmstat-only server has a usage history; a holder's session start and a feature's expiry are stored |
| 6 | **Queries** behind the screens below | Parity with Fathom's `lm_reporting` where they overlap (peak concurrency, denial rate) |
| 7 | **Alerts**: rules + notifier, **shipped switched off** | Each rule fires on seeded data; nothing is sent until enabled |
| 8 | **UI**: a PSU App, three role tiers | Each role sees exactly its tier |

In dev, log paths are local files (`tools/New-DevData.ps1` generates them). The UNC path is the same code, just a different path.

## What V1 tracks, and why

| Audience | Their question | Answered by |
|---|---|---|
| Everyone | Is a seat free right now? | Free seats per feature (lmstat) |
| License admins | Is it up? Who holds the seat? Anything expiring? Is monitoring still working? | Server + vendor daemon health, current holders and since when, expiry, freshness |
| Managers / procurement | Too many seats or too few, for the renewal? | Peak and typical (95th percentile) concurrency vs seats over months, time at capacity, denials (unmet demand), monthly active users, unused features |

Sources: **lmstat** (every server) gives availability, holders, expiry, daemon status and the usage history.
**Debug logs** (where the share is reachable) add denials, queueing and exact session lengths.
An lmstat-only server shows capacity but not unmet demand.

**Usage source, per server:** `Auto` (default), `Log` or `Lmstat`. `Auto` uses the debug log while it's
healthy and falls back to the lmstat history when it isn't (share unreachable, or no new lines while
lmstat shows seats in use). Log health is recorded on every read to make that call.

Deliberately not tracked: per-host breakdowns, feature versions, borrowed licenses.
Retention: keep everything (multi-year trends drive renewals). Volume is modest for typical servers;
one with hundreds of features writes about 42M lmstat samples a year, hence the hourly rollup under Later.

## Screens and access

Totals are for everyone. Anything about an individual is for license admins and managers. The
[README](README.md#the-app) has the screens as built.

Roles are the app's own `FathomReader`, `FathomOperator` and `FathomAdmin`, mapped to directory groups.
Not PSU's built-in Reader and Operator: those open the PSU admin console, and Operator can edit scripts.

## Alerts (built in, off by default)

Rules: server or vendor daemon down, a feature at full capacity for a while, a license expiring within 30 days, data gone stale, a debug log that disagrees with lmstat.
The alert schedule runs, but a setting gates sending (off by default), so it can be switched on later without a deploy.
Channel: email, one digest per run. A Teams workflow webhook could be added later.

## Later (not V1)

- **Devolutions Agent fallback** for hosts PSU can't reach over SMB (DMZ, other domains). PSU's own agent, which needs PSU 2026.3 and **one PSU license per computer**.
- **Ansible provisioning**: install PSU on Windows Server, put `lmutil` on it, and set up the service account and share permissions on license hosts. Code deploys via PSU Git sync, not Ansible.
- Fathom push-ingest API compatibility, only if existing `Send-FathomLogs.ps1` installs need it.
- **Grafana office-TV dashboard**, reading Postgres directly through a read-only database user.
- ~~Directory enrichment via the ActiveDirectory module~~ (done: every attribute cataloged, admins choose what's recorded and shown). Still to come on top of it: department / manager scoping and "my own usage".
- **Hourly usage rollup** for year-long views on servers with hundreds of features (today a year at 5-minute samples is ~42M rows per big server).
- **Monthly renewal report** as an Excel export (ImportExcel).

## Production prerequisites

- A **PSU license**. The developer license is for non-production use, and the app's per-page roles are a licensed feature.
- PSU on **Windows Server**, running as a **domain service account** with read access to each host's FlexLM log folder.
- `lmutil.exe` on the PSU host, plus network access to each server's `port@host` (lmgrd and vendor daemon ports).
- For Active Directory details (optional): RSAT's ActiveDirectory module on the PSU host, and read access to AD.
- Connect `azure-pipelines.yml` to Azure DevOps.
