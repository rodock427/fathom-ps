# fathom-ps on Linux

[Deployment overview](README.md) · [Windows](windows.md)

Tested on Ubuntu with PowerShell 7.6, PSU 2026.2.3 and Postgres 16 in Podman. Docker works
the same: swap `podman` for `docker`.

- [1. Dev only](#1-dev-only)
- [2. Dev on real license servers](#2-dev-on-real-license-servers)
- [3. Production (placeholder)](#3-production-placeholder)
- [Troubleshooting](#troubleshooting)

## 1. Dev only

Everything runs on your machine: generated usage data, a fake `lmutil`, a fake Active Directory.
About 15 minutes.

### Install the tools

```bash
# PowerShell 7 (Ubuntu; other distros: https://learn.microsoft.com/powershell/scripting/install/install-other-linux)
source /etc/os-release
wget -q "https://packages.microsoft.com/config/ubuntu/$VERSION_ID/packages-microsoft-prod.deb"
sudo dpkg -i packages-microsoft-prod.deb && rm packages-microsoft-prod.deb
sudo apt-get update && sudo apt-get install -y powershell git podman unzip
```

The PowerShell modules, at the versions CI uses. `Universal` must match the PSU server's version.

```bash
pwsh -c 'Install-PSResource -TrustRepository -Name SimplySql -Version 2.2.0.106
         Install-PSResource -TrustRepository -Name Pester -Version 6.2.0
         Install-PSResource -TrustRepository -Name PSScriptAnalyzer -Version 1.25.0
         Install-PSResource -TrustRepository -Name Universal -Version 2026.2.3'
```

### Get PowerShell Universal

The ZIP runs as your own user, with nothing installed system-wide.

```bash
PSU_VERSION=2026.2.3.0
wget -O psu.zip "https://cdn.devolutions.net/download/Devolutions.PowerShellUniversal.linux-x64.$PSU_VERSION.zip"
mkdir -p ~/psu && unzip -q psu.zip -d ~/psu && rm psu.zip
```

### Start Postgres

```bash
podman run -d --name fathom-pg -p 127.0.0.1:5432:5432 \
  -e POSTGRES_USER=license_manager -e POSTGRES_PASSWORD=license_manager -e POSTGRES_DB=license_manager \
  docker.io/library/postgres:16-alpine
podman exec fathom-pg psql -U license_manager -c 'CREATE DATABASE fathom_ps_test'   # for the tests
```

After a reboot, `podman start fathom-pg` brings it back with its data.

### Generate data and start PSU

```bash
git clone https://github.com/rodock427/fathom-ps.git && cd fathom-ps
export LM_POSTGRES_DSN=postgresql://license_manager:license_manager@localhost:5432/license_manager

pwsh ./tools/New-DevData.ps1                      # a dev license server with the last 7 days of use
pwsh ./tools/Start-DevPsu.ps1 -PsuPath ~/psu      # foreground; Ctrl+C stops it
```

1. Open http://localhost:5000 and create the admin account it asks for.
2. Open http://localhost:5000/fathom. As PSU's Administrator you see every page.
3. To see what each tier sees, add local accounts under Security > Identities with the role
   `FathomReader`, `FathomOperator` or `FathomAdmin`.

Re-run `New-DevData.ps1` before a demo to bring the data up to now; `-Big` adds a 400-feature
server for scale testing.

### Lint and test

```bash
export FATHOM_TEST_DSN=postgresql://license_manager:license_manager@localhost:5432/fathom_ps_test
pwsh ./build.ps1
```

## 2. Dev on real license servers

The same dev setup, polling your real license servers. Either **lmstat only** (seat counts,
holders, expiry, up/down), or **lmstat plus the debug log** (adding denials and exact session
history). Active Directory stays on the fake: the ActiveDirectory module is Windows-only.

Keep real data apart from the generated data in its own database:

```bash
podman exec fathom-pg psql -U license_manager -c 'CREATE DATABASE fathom_real'
export LM_POSTGRES_DSN=postgresql://license_manager:license_manager@localhost:5432/fathom_real
pwsh -c 'Import-Module ./Modules/Fathom; Connect-FathomDatabase; Initialize-FathomSchema'
```

### lmstat

1. **Get `lmutil` for Linux.** It ships with the vendor's FlexLM license server tools for Linux
   (the same `lmutil` that `lmstat` comes from); copy it somewhere like `~/flexlm/lmutil` and
   `chmod +x` it.
2. **Check it works on its own** before involving PSU:

   ```bash
   ~/flexlm/lmutil lmstat -a -c 27000@licsrv01
   ```

   You should see `license server UP`, the vendor daemon `UP`, and `Users of ...` lines. If the shell
   says `No such file or directory` for a file that's clearly there, see [Troubleshooting](#troubleshooting).
3. **Start PSU with it:**

   ```bash
   pwsh ./tools/Start-DevPsu.ps1 -PsuPath ~/psu -LmutilPath ~/flexlm/lmutil
   ```

4. **Add the server** in Administration > Add a server: an id (`licsrv01`), a name, and the license
   server as `port@host` (`27000@licsrv01`). Leave the debug log empty for lmstat only.
5. Within 5 minutes the first poll lands: Server detail shows the server `Healthy`, and Overview its
   free seats. Usage history builds up from then on, a sample every 5 minutes.

### The debug log (optional)

Linux can't open `\\server\share` paths, so mount the share that holds lmgrd's debug log (the file
lmgrd writes with `-l`), read-only:

```bash
sudo apt-get install -y cifs-utils
sudo install -m 600 /dev/null /etc/fathom-smb.cred
sudoedit /etc/fathom-smb.cred        # username=..., password=..., domain=...
sudo mkdir -p /mnt/licsrv01
sudo mount -t cifs '//licsrv01/flexlm$' /mnt/licsrv01 \
  -o ro,vers=3.0,credentials=/etc/fathom-smb.cred,uid=$(id -u),gid=$(id -g)
ls /mnt/licsrv01                     # the debug log should be listed
```

Then edit the server in Administration and set its debug log to `/mnt/licsrv01/debug.log` (your
file name). The next minute's read starts at the top of the log; a large first read is done in
chunks and can take a few minutes. After that, Server detail shows `Debug log: Synced`, denials
appear for operators, and usage history comes from the log wherever the log covers it.

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

## 3. Production (placeholder)

Windows Server is the recommended production platform: see the [Windows guide](windows.md#3-production-placeholder).
Linux suits lmstat-only monitoring without Active Directory. The outline, to be written up:

- [ ] PSU installed as a systemd service under its own user (PSU's docs have a script: *Installation > Linux Service*)
- [ ] A PSU license
- [ ] Postgres: a managed instance or a backed-up server, with its own `fathom` user
- [ ] PSU secret `FathomDsn`; `FATHOM_LMUTIL` set in the service's environment
- [ ] PSU Git sync from the repo, with `GitBranch` set to `main` (PSU defaults to `master`)
- [ ] `Scripts/Initialize-Database.ps1` after installing and after every update
- [ ] CIFS mounts in `/etc/fstab` with a service credential, for debug logs
- [ ] Sign-in through OIDC (no Windows authentication on Linux), with Fathom roles mapped to groups
- [ ] HTTPS in front of PSU (a reverse proxy, or Kestrel with a certificate)
- [ ] Alerts: SMTP settings, a test message, then switch sending on

## Troubleshooting

| Symptom | Fix |
|---|---|
| `lmutil: No such file or directory`, though the file exists | FlexLM's Linux builds ask for the LSB loader. Link it: `sudo ln -s /lib64/ld-linux-x86-64.so.2 /lib64/ld-lsb-x86-64.so.3` |
| lmstat says the server is UP but lists no features, or times out | The vendor daemon's port is blocked; see [ports](README.md#what-fathom-ps-needs-to-reach) |
| PSU logs `Permission denied` starting `PowerShellUniversal.Host` | The ZIP lost execute bits. `Start-DevPsu.ps1` fixes this; by hand: `chmod +x` that file and `Universal.Server` |
| Log status `Unreachable` | The mount dropped or the path changed: `ls` the path as your user |
| `/fathom` says you're not authorized | Your account has no Fathom role, and isn't PSU's Administrator |
