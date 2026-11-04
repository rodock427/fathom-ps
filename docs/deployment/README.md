# Deploying fathom-ps

Pick your operating system, then the level you need. Each level builds on the one before it.

| | [Linux](linux.md) | [Windows](windows.md) |
|---|---|---|
| **1. Dev only**: generated data, fake lmutil and Active Directory | ✅ | ✅ |
| **2. Dev on real servers**: real `lmutil`, optionally the real debug logs and AD | ✅ (no Active Directory) | ✅ |
| **3. Production** | Placeholder | Placeholder (recommended OS) |

**Windows is the production target.** Active Directory lookups need RSAT's ActiveDirectory module,
which only exists on Windows, and the debug logs are read straight from UNC paths. Linux works for
development and for lmstat-only monitoring.

## What changes between levels

| | 1. Dev only | 2. Dev on real servers | 3. Production |
|---|---|---|---|
| PSU | ZIP, run as you with `tools/Start-DevPsu.ps1` | same | Installed as a service under a service account |
| PSU license | Developer license or none | same | Required (per-page roles and Git sync are licensed) |
| Repository | Your clone, used in place | same | PSU Git sync from the remote |
| Postgres | Local container | same | A managed or backed-up server |
| lmstat | Fake (`tests/fakes`), answers from `.dev/` | Real `lmutil` | Real `lmutil` |
| Debug logs | `.dev/debug.log`, generated | The license server's share (optional) | The license server's share |
| Active Directory | Fake | Real, on Windows (optional) | Real (optional) |
| Data | `tools/New-DevData.ps1` | Collected from your servers | Collected from your servers |

## Settings, everywhere

fathom-ps reads its settings from environment variables, and PSU secrets in production.
`tools/Start-DevPsu.ps1` sets all of them for development.

| Setting | What | Dev default |
|---|---|---|
| `LM_POSTGRES_DSN`, or the PSU secret `FathomDsn` | Postgres connection, as a libpq URI: `postgresql://user:password@host:5432/database` | the local container |
| `FATHOM_LMUTIL` | Full path to `lmutil` | the fake |
| `FAKE_LMUTIL_DIR` | Where the fake lmutil finds `<host>.txt` answers | `.dev/` |
| `FATHOM_AD_MODULE` | A module to use instead of ActiveDirectory | the fake |
| PSU secret `FathomSmtpCredential` | Login for an SMTP server, if it needs one | none |
| PSU secret `FathomDirectoryCredential` | Login for Active Directory, if the PSU account can't read it | none |

## What fathom-ps needs to reach

| From the PSU machine to | Port | For |
|---|---|---|
| Each license server | lmgrd's port, usually `27000`–`27009` | lmstat |
| Each license server | the vendor daemon's port: random unless the license file's `VENDOR` line sets `PORT=` | lmstat |
| Each license server | SMB (445) | reading the debug log |
| Postgres | 5432 | everything |
| A domain controller | LDAP/ADWS (389, 9389) | Active Directory lookups |

Fix the vendor daemon's port in the license file if a firewall sits in between; otherwise lmstat
reaches lmgrd but can't get the feature list.
