# fathom-ps on Windows

[Deployment overview](README.md) · [Linux](linux.md)

Windows 10/11 for development, Windows Server for production. Run the commands in **PowerShell 7**
(`pwsh`), not Windows PowerShell 5.1.

- [1. Dev only](#1-dev-only)
- [2. Dev on real license servers](#2-dev-on-real-license-servers)
- [3. Production (placeholder)](#3-production-placeholder)
- [Troubleshooting](#troubleshooting)

## 1. Dev only

Everything runs on your machine: generated usage data, a fake `lmutil`, a fake Active Directory.
About 20 minutes.

### Install the tools

```powershell
winget install --exact --id Microsoft.PowerShell
winget install --exact --id Git.Git
```

Open a new PowerShell 7 window so both are on `PATH`, then install the modules at the versions CI
uses. `Universal` must match the PSU server's version.

```powershell
Install-PSResource -TrustRepository -Name SimplySql -Version 2.2.0.106
Install-PSResource -TrustRepository -Name Pester -Version 6.2.0
Install-PSResource -TrustRepository -Name PSScriptAnalyzer -Version 1.25.0
Install-PSResource -TrustRepository -Name Universal -Version 2026.2.3
```

### Get PowerShell Universal

The ZIP runs as your own user: no service, nothing installed system-wide, and it can read file
shares with your own access, which level 2 relies on.

```powershell
$version = '2026.2.3.0'
Invoke-WebRequest "https://cdn.devolutions.net/download/Devolutions.PowerShellUniversal.win-x64.$version.zip" -OutFile psu.zip
Expand-Archive psu.zip -DestinationPath C:\PSU
Get-ChildItem C:\PSU -Recurse | Unblock-File
Remove-Item psu.zip
```

### Start Postgres

Either in a container, with [Podman Desktop](https://podman-desktop.io) or Docker Desktop:

```powershell
podman run -d --name fathom-pg -p 127.0.0.1:5432:5432 `
  -e POSTGRES_USER=license_manager -e POSTGRES_PASSWORD=license_manager -e POSTGRES_DB=license_manager `
  docker.io/library/postgres:16-alpine
podman exec fathom-pg psql -U license_manager -c 'CREATE DATABASE fathom_ps_test'
```

Or installed natively. The installer asks for a password for the `postgres` superuser:

```powershell
winget install --exact --id PostgreSQL.PostgreSQL.16
$psql = 'C:\Program Files\PostgreSQL\16\bin\psql.exe'
& $psql -U postgres -c "CREATE ROLE license_manager LOGIN PASSWORD 'license_manager'"
& $psql -U postgres -c 'CREATE DATABASE license_manager OWNER license_manager'
& $psql -U postgres -c 'CREATE DATABASE fathom_ps_test OWNER license_manager'
```

### Generate data and start PSU

```powershell
git clone https://github.com/rodock427/fathom-ps.git
Set-Location fathom-ps
$env:LM_POSTGRES_DSN = 'postgresql://license_manager:license_manager@localhost:5432/license_manager'

./tools/New-DevData.ps1                      # a dev license server with the last 7 days of use
./tools/Start-DevPsu.ps1 -PsuPath C:\PSU     # foreground; Ctrl+C stops it
```

1. Open http://localhost:5000 and create the admin account it asks for.
2. Open http://localhost:5000/fathom. As PSU's Administrator you see every page.
3. To see what each tier sees, add local accounts under Security > Identities with the role
   `FathomReader`, `FathomOperator` or `FathomAdmin`.

Re-run `New-DevData.ps1` before a demo to bring the data up to now; `-Big` adds a 400-feature
server for scale testing.

### Lint and test

```powershell
$env:FATHOM_TEST_DSN = 'postgresql://license_manager:license_manager@localhost:5432/fathom_ps_test'
./build.ps1
```

The tests that drive the fake lmutil through a Unix shell are skipped on Windows; CI runs them on Linux.

## 2. Dev on real license servers

The same dev setup, polling your real license servers. Either **lmstat only** (seat counts,
holders, expiry, up/down), or **lmstat plus the debug log** (adding denials and exact session
history), and optionally real Active Directory.

Keep real data apart from the generated data in its own database:

```powershell
podman exec fathom-pg psql -U license_manager -c 'CREATE DATABASE fathom_real'    # or: & $psql -U postgres -c 'CREATE DATABASE fathom_real OWNER license_manager'
$env:LM_POSTGRES_DSN = 'postgresql://license_manager:license_manager@localhost:5432/fathom_real'
Import-Module ./Modules/Fathom; Connect-FathomDatabase; Initialize-FathomSchema; Disconnect-FathomDatabase
```

### lmstat

1. **Get `lmutil.exe`.** It ships with the vendor's FlexLM license server tools, for example in
   Autodesk's Network License Manager folder, or with Flexera's `lmadmin`. Copy it somewhere
   like `C:\FlexLM\lmutil.exe`.
2. **Check it works on its own** before involving PSU:

   ```powershell
   & C:\FlexLM\lmutil.exe lmstat -a -c 27000@licsrv01
   ```

   You should see `license server UP`, the vendor daemon `UP`, and `Users of ...` lines.
3. **Start PSU with it:**

   ```powershell
   ./tools/Start-DevPsu.ps1 -PsuPath C:\PSU -LmutilPath C:\FlexLM\lmutil.exe
   ```

4. **Add the server** in Administration > Add a server: an id (`licsrv01`), a name, and the license
   server as `port@host` (`27000@licsrv01`). Leave the debug log empty for lmstat only.
5. Within 5 minutes the first poll lands: Server detail shows the server `Healthy`, and Overview its
   free seats. Usage history builds up from then on, a sample every 5 minutes.

### The debug log (optional)

Dev PSU runs as you, so it reads the share holding lmgrd's debug log (the file lmgrd writes with
`-l`) with your own access. Check you can:

```powershell
Test-Path '\\licsrv01\flexlm$\debug.log'
```

Then edit the server in Administration and set its debug log to that UNC path. The next minute's
read starts at the top of the log; a large first read is done in chunks and can take a few minutes.
After that, Server detail shows `Debug log: Synced`, denials appear for operators, and usage history
comes from the log wherever the log covers it.

### Active Directory (optional)

Install RSAT's ActiveDirectory module (as an administrator), and check it can find you:

```powershell
Add-WindowsCapability -Online -Name 'Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0'   # Windows 10/11
Get-ADUser $env:USERNAME
```

Start PSU with `-RealDirectory`. Then, in Administration > Active Directory, turn lookups on, save,
and click **Look up now**. Each FlexLM username and host Fathom has seen is looked up, and every
attribute AD returns is listed, to choose which are recorded and shown.

```powershell
./tools/Start-DevPsu.ps1 -PsuPath C:\PSU -LmutilPath C:\FlexLM\lmutil.exe -RealDirectory
```

### Import an old log (optional)

To load history from a copy or an old log, use **Import log** on the server in Administration and
give a path the PSU machine can read. It's added once as a job (see Automation > Jobs), and nothing
watches the file afterwards, so a copy never shows as stale. Running it again carries on from where
it stopped and adds nothing twice, but two different files covering the same dates are counted twice.
History from the log is used where the log has lines, and lmstat everywhere else.

### A large or slow server

If a poll shows `Timeout`, raise **lmstat time limit** under Edit in Administration (60 seconds by
default). A poll that times out keeps nothing, because a cut-off answer is only part of the server.
**Poll every** sets how often that server is polled, in steps of the 5-minute schedule. A server
already being polled is skipped, never polled twice at once. Servers are polled one after another,
so one slow server holds up those behind it, and a run that goes past 5 minutes uses up the next.

### Check it's right

- **Server detail > Health:** `Healthy`, with a recent lmstat poll and, if you added the log, `Synced`.
- **No `LogDrifted` alert.** It means the log's seat count disagrees with lmstat, usually because the
  log was missing lines. Fathom then uses lmstat for usage history until they agree.
- **Compare with the source:** the seats in use on Overview should match `lmutil lmstat -a` run by hand.
- **People** (with AD): a holder's department and display name next to their FlexLM username.

## 3. Production (placeholder)

The outline, to be written up:

- [ ] **Windows Server**, with a **PSU license**: per-page roles and Git sync are licensed features
- [ ] A **domain service account** (a gMSA if you can) with read access to each license server's log
      share, and to AD
- [ ] PSU from the MSI as a service under that account: `SERVICEACCOUNT`, `SERVICEACCOUNTPASSWORD`
      ([downloads](https://devolutions.net/download-center/powershell-universal/); the MSI's
      parameters are in PSU's docs under *Installation*)
- [ ] PSU Git sync from the repo, with `GitBranch` set to `main` (PSU defaults to `master`)
- [ ] Postgres: a managed instance or a backed-up server, with its own `fathom` user
- [ ] PSU secret `FathomDsn` (no role on it, or scheduled jobs can't read it)
- [ ] `lmutil.exe` on the server, and `FATHOM_LMUTIL` as a machine environment variable, then restart the service:
      `[Environment]::SetEnvironmentVariable('FATHOM_LMUTIL', 'C:\FlexLM\lmutil.exe', 'Machine')`
- [ ] `Scripts/Initialize-Database.ps1` after installing and after every update
- [ ] RSAT: `Install-WindowsFeature RSAT-AD-PowerShell`, if using Active Directory
- [ ] Windows sign-in, with each Fathom role mapped to an AD group (Security > Roles, claim type
      `groupsid`); the built-in Reader/Operator/Execute roles stay unassigned
- [ ] HTTPS with a certificate from your CA
- [ ] Firewall: the [ports fathom-ps needs](README.md#what-fathom-ps-needs-to-reach), and HTTPS in
- [ ] Alerts: SMTP settings, a test message, then switch sending on
- [ ] Later: Ansible to provision all of this (see PLAN.md)

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Start-DevPsu.ps1` "cannot be loaded" | Files from the internet are blocked: `Get-ChildItem -Recurse \| Unblock-File` in the clone and in `C:\PSU` |
| lmstat says the server is UP but lists no features, or times out | The vendor daemon's port is blocked; see [ports](README.md#what-fathom-ps-needs-to-reach) |
| Log status `Unreachable` | Your account can't read the share, or the path changed: `Test-Path` the UNC path |
| "Directory lookups need the ActiveDirectory module" | RSAT isn't installed, or PSU wasn't started with `-RealDirectory` |
| `/fathom` says you're not authorized | Your account has no Fathom role, and isn't PSU's Administrator |
