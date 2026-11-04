# fathom-ps

**FlexLM license monitoring on PowerShell Universal.** What's free right now, who holds it, what's
about to expire, and whether you're paying for the right number of seats.

A PowerShell port of the monitoring side of [Fathom](../license_manager), and agentless: nothing is
installed on the license servers. PSU polls `lmstat` and reads the `lmgrd` debug logs over SMB.

- **Live and historical usage** per feature, from `lmstat` and the debug logs, using whichever source is trustworthy for each stretch of time.
- **Renewal numbers**: peak and typical use against seats, time at capacity, denials, active users.
- **Three access tiers**: totals for everyone, individuals for license admins and managers.
- **Email alerts** and **Active Directory details**, both built in and off until you turn them on.

**Contents:** [How it works](#how-it-works) · [The app](#the-app) · [Set up on PSU](#set-up-on-a-psu-server) ·
[Alerts](#alerts) · [Active Directory](#active-directory) · [Local development](#local-development) ·
[Module](#the-module) · [Layout](#layout)

## How it works

```mermaid
flowchart LR
    subgraph hosts [License servers]
        lmgrd[lmgrd and vendor daemons]
        log[(debug log share)]
    end
    subgraph psu [PowerShell Universal]
        poll[Poll lmstat<br/>every 5 min]
        read[Read debug logs<br/>every minute]
        alerts[Alerts<br/>every 5 min]
        lookup[AD lookups<br/>hourly]
        app[Fathom app<br/>/fathom]
    end
    ad[(Active Directory)]
    pg[(Postgres)]
    mail[Email digest]

    lmgrd -- lmutil --> poll
    log -- SMB --> read
    ad --> lookup
    poll --> pg
    read --> pg
    lookup --> pg
    pg --> alerts --> mail
    pg --> app
```

All logic lives in the `Fathom` module. The PSU jobs and app pages are thin wrappers around it, and it
stores everything in Postgres, next to Fathom's own tables.

## The app

At `/fathom`, signed in. Each tier includes the ones before it; PSU's own `Administrator` gets everything.

| Page | FathomReader | FathomOperator | FathomAdmin |
|---|---|---|---|
| **Overview** | Free seats, server health, current alerts, licenses expiring soon | + denials in the last 24 hours | same |
| **Server detail** | Charts of use against seats for the 8 busiest features (or any one), all features with their peaks, health, uptime; 24 hours to a year | + who holds a seat, denials, recent log activity | same |
| **Capacity and renewal** | | Peak, typical (P95), time at capacity, denials, users denied, active users, underused features; export to CSV or Excel | same |
| **People** | | Who holds a seat now (long sessions flagged), one user's last 90 days, their Active Directory details | same |
| **Administration** | | | Add, edit, pause and poll servers; alert settings; Active Directory settings and attributes |

**Individual data never reaches a browser that shouldn't see it.** Pages are hidden from roles below
their tier, and each page checks the tier again in its own script. `tests/App.Tests.ps1` renders every
page as each role and fails if a reader's page carries a username.

**Roles.** The app uses its own roles, `FathomReader`, `FathomOperator` and `FathomAdmin`. PSU's
built-in `Reader` and `Operator` would also open the PSU admin console (and `Operator` can edit
scripts), so `.universal/roles.ps1` gives the built-in roles to nobody. Local accounts keep
roles assigned to them directly.

## Set up on a PSU server

**Prerequisites:** PSU on Windows Server, with a **PSU license**: the developer license is for
non-production use, and the app's per-page roles are a licensed feature. Run the service as a
**domain service account** that can read each license server's FlexLM log folder. Put `lmutil.exe`
on the PSU server, with network access to each server's `port@host` (lmgrd and vendor daemon ports).

1. **Repository.** Point PSU's Git sync at this repo; the root is the PSU repository.
2. **Database.** Add a secret variable `FathomDsn` (Manage > Variables & Secrets), or set
   `LM_POSTGRES_DSN` on the PSU service. Don't put a role on the secret: scheduled jobs run
   without roles and couldn't read it.
3. **lmutil.** Set `FATHOM_LMUTIL` to its full path, or put `lmutil` on the service's `PATH`.
4. **Schema.** Run `Scripts/Initialize-Database.ps1` once, **and again after every update**.
   Until it has, jobs that need new columns fail; they recover by themselves once it has.
5. **Servers.** Add them in Administration, or with `Register-FathomServer` (see [The module](#the-module)).
6. **Who sees what.** Map each Fathom role to a directory group: Security > Roles, set the claim
   type and value (with Windows sign-in, the group's SID).
7. **Optional:** [alerts](#alerts) and [Active Directory](#active-directory).

| Schedule | Script | Runs |
|---|---|---|
| Fathom: read debug logs | `Scripts/Sync-DebugLogs.ps1` | every minute |
| Fathom: poll lmstat | `Scripts/Sync-LiveStatus.ps1` | every 5 minutes |
| Fathom: alerts | `Scripts/Send-Alerts.ps1` | every 5 minutes, 2 minutes after each poll |
| Fathom: directory | `Scripts/Sync-Directory.ps1` | hourly |

## Alerts

**Off until enabled.** Alerts are still evaluated and recorded meanwhile (`Get-FathomAlert` shows
what would be sent), so switching them on mails whatever is active at that moment.

| Rule | Severity | When |
|---|---|---|
| ServerDown | Critical | lmstat failing for `DownMinutes` (10) |
| DaemonDown | Warning | a vendor daemon down for `DownMinutes` |
| AtCapacity | Warning | every seat of a feature taken for `CapacityMinutes` (30) |
| Expiring | Info, Warning in the last 7 days, Critical once expired | within `ExpiryDays` (30) |
| Stale | Warning | no fresh poll, a log gone quiet while seats are in use, or an unreachable log |
| LogDrifted | Warning | the log's seat count disagrees with lmstat |

One digest email per run: new alerts, a reminder every `RepeatHours` (24) for those still active,
and the resolution of any that were mailed. A failed send is retried on the next run. Set it up in
Administration, or:

```powershell
Set-FathomAlertSetting -SmtpServer smtp.corp.example -SmtpPort 587 -From fathom@corp.example -To licensing@corp.example
Send-FathomAlert -Test
Set-FathomAlertSetting -Enabled $true
```

For an SMTP server that needs a login, add a secret variable `FathomSmtpCredential` (a PSCredential).

## Active Directory

**Off until turned on** in Administration. It needs RSAT's ActiveDirectory module on the PSU server,
and read access to AD for the service account (or a secret variable `FathomDirectoryCredential`).

Every hour Fathom looks up each FlexLM username and host it has seen (live, in the lmstat history,
or in the last 90 days of log events) with `Get-ADUser` / `Get-ADComputer -Properties *`, and again
every `RefreshHours` (24).

- **Every attribute** the directory returns is listed in Administration, except binary ones such
  as photos. The list holds names only, never values.
- **Recorded** attributes have their values stored. Display name, department, title, email, manager
  and office (for hosts: description, OS and location) start recorded; everything else starts off.
  Turning recording off deletes that attribute's values at once; turning it on fills them in at the
  next lookup.
- **Shown** attributes appear to operators and admins on the People page: in a user's lookup, and as
  columns of who holds a seat now. Showing an attribute records it.

Directory data is about individuals, so readers never see it.

## Local development

Needs PowerShell 7.4+, Podman (or Docker), and the modules `SimplySql`, `Pester` 6,
`PSScriptAnalyzer` and `Universal` (PSU's own, for rendering app pages in tests).

```bash
# Postgres, plus an empty database for the tests
podman run -d --name fathom-pg -p 127.0.0.1:5432:5432 \
  -e POSTGRES_USER=license_manager -e POSTGRES_PASSWORD=license_manager -e POSTGRES_DB=license_manager \
  docker.io/library/postgres:16-alpine
podman exec fathom-pg psql -U license_manager -c 'CREATE DATABASE fathom_ps_test'
export LM_POSTGRES_DSN=postgresql://license_manager:license_manager@localhost:5432/license_manager

# A dev license server with the last 7 days of realistic use, ending now (-Big adds 400 features)
./tools/New-DevData.ps1

# PSU against this repo, with the fake lmutil and fake Active Directory
FATHOM_LMUTIL=$PWD/tests/fakes/lmutil FAKE_LMUTIL_DIR=$PWD/.dev \
FATHOM_AD_MODULE=$PWD/tests/fakes/ActiveDirectory/ActiveDirectory.psm1 \
  ~/Documents/Projects/General/Powershell/Powershell-Universal/start-psu.sh "$PWD"
```

`New-DevData.ps1` simulates the fake-AD users at their workstations and writes it as a real debug log
(`.dev/debug.log`) plus the matching lmstat answer (`.dev/licsrv.txt`). Run it again before a demo to
bring the data up to date; `-Remove` takes it away. Alert mail goes to `.dev/mail/`. Everything in
`.dev/` is git-ignored.

**Lint and test:**

```bash
export FATHOM_TEST_DSN=postgresql://license_manager:license_manager@localhost:5432/fathom_ps_test
./build.ps1            # or -Task Lint, -Task Test
```

Without `FATHOM_TEST_DSN` the database tests are skipped. CI (`azure-pipelines.yml`) runs exactly
`build.ps1` against a Postgres service container.

**Parity with Python Fathom.** `tests/Parity.Tests.ps1` and `tests/Metrics.Tests.ps1` check the
parsers and the usage numbers against golden files that Fathom's own Python code produced.
Regenerate them after changing a fixture (needs `../license_manager` with its `.venv`):

```bash
../license_manager/.venv/bin/python tests/fixtures/generate_golden.py
FATHOM_TEST_DSN=... ../license_manager/.venv/bin/python tests/fixtures/generate_metric_golden.py
```

## The module

Everything the jobs and pages do is a `Fathom` command, so it all works from a console too.

```powershell
Import-Module ./Modules/Fathom/Fathom.psd1
Connect-FathomDatabase          # PSU's FathomDsn secret, else LM_POSTGRES_DSN

# Monitor a server, then collect (both are safe to run on a schedule)
Register-FathomServer -ServerId licsrv01 -LicenseSpec 27000@licsrv01 -LogPath '\\licsrv01\flexlm$\debug.log'
Get-FathomServer -Enabled | Sync-FathomDebugLog
Get-FathomServer -Enabled | Sync-FathomLiveStatus

# Drive usage history from lmstat while a log share is out
Set-FathomServer -ServerId licsrv01 -UsageSource Lmstat

# Parse without a database
& lmutil lmstat -a -c 27000@licsrv01 | ConvertFrom-FathomLmstat -ServerId licsrv01
```

<details>
<summary><b>Queries behind the screens</b></summary>

Each returns plain objects; the app decides who sees which.

| Command | Tier | Answers |
|---|---|---|
| `Get-FathomAvailability` | Reader | Free seats per feature, from each server's latest poll |
| `Get-FathomServerHealth` | Reader | Healthy, Degraded, Down, Stale or Drifted; freshness; the usage source in effect |
| `Get-FathomExpiry` | Reader | Features expiring within N days |
| `Get-FathomUsageHistory` | Reader | Peak in use against seats per time bucket |
| `Get-FathomServerUptime` | Reader | Uptime and outages from the poll history |
| `Get-FathomAlert` | Reader | The alerts in effect right now |
| `Get-FathomCapacityReport` | Operator | Peak, 95th percentile, time at capacity, denials, active users, underused |
| `Get-FathomLicenseHolder` | Operator | Who holds a seat now, flagging long sessions |
| `Get-FathomDenial`, `Get-FathomUserUsage`, `Get-FathomActivity` | Operator | Denials, one user's history, recent log events |
| `Get-FathomDirectoryObject` | Operator | What Active Directory says about users or hosts |

`Get-Help <command>` has the details for every command.

</details>

<details>
<summary><b>How usage is counted</b></summary>

- **Usage source.** With `Auto` (the default) each time bucket uses the debug log where the log
  covers it, and lmstat to fill the gaps, such as while a log share was unreachable. A log whose
  seat count has drifted from lmstat isn't used. `Set-FathomServer -UsageSource Log|Lmstat` forces one.
- **Matches Fathom.** Peak concurrency and denial rate from the debug log equal Python Fathom's
  `peak_concurrency` and `denial_rate` exactly.
- **One deliberate difference:** the parser moves the date on when the clock wraps past midnight
  (Fathom waits for the next `TIMESTAMP` line), so after-midnight lines aren't dated a day early.
- **Shared tables.** The tables both apps use (`license_events`, `live_status`, `feature_inventory`,
  `_ingest_manifest`) match Fathom's, so both can run against one database. The rest are fathom-ps's
  own: Fathom's directory tables follow a different model and are left alone.

</details>

## Layout

The repo root **is** the PSU repository, which is what PSU's Git sync points at.

| Path | What |
|---|---|
| `.universal/` | PSU configuration as code: scripts, schedules, the app, roles |
| `Apps/Fathom/` | The app: `Fathom.ps1` lists the pages, `Pages/` has one script each, `Common.ps1` their helpers |
| `Scripts/` | The PSU jobs |
| `Modules/Fathom/` | The module: all the logic, testable without PSU. PSU puts `Modules/` on its module path |
| `Modules/Fathom/Sql/schema.sql` | Idempotent schema: Fathom's shared tables plus fathom-ps's own |
| `tests/` | Pester tests, fixtures, and fakes for `lmutil` and Active Directory |
| `tools/New-DevData.ps1` | Generates local dev data |
| `build.ps1` | Lint and test; CI runs exactly this |
| `PLAN.md` | The V1 plan, design decisions and what's next |
