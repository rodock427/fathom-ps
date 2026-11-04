# fathom-ps in a container

[Deployment overview](README.md) · [Linux](linux.md) · [Windows](windows.md)

The image is PSU's own (`devolutions/powershell-universal`, 2026.2.3 on Ubuntu 24.04) plus SimplySql and
this repo, baked in as PSU's repository. `compose.yaml` runs it next to Postgres. Podman is shown;
`docker` and `docker compose` take exactly the same commands.

| Inside the container | |
|---|---|
| `/app` | This repo: PSU's repository (scripts, schedules, the app, the module) |
| `/data` (volume) | PSU's own database and signing key, and generated demo data (`/data/dev`) |
| Port 5000 | PSU: the admin console at `/`, the app at `/fathom` |
| On every start | The Fathom schema is brought up to date before PSU starts, so updates need no extra step |

## 1. Dev only

Needs Podman with `podman-compose` (`sudo apt-get install -y podman podman-compose`), or Docker.

```bash
git clone https://github.com/rodock427/fathom-ps.git && cd fathom-ps
echo "PSU_ADMIN_PASSWORD=$(openssl rand -base64 18)" > .env     # the admin account's password; .env is git-ignored
podman compose up -d --build
podman compose exec fathom pwsh /app/tools/New-DevData.ps1 -Force    # a dev license server with the last 7 days of use
```

Open http://localhost:5000/fathom and sign in as `admin` with the password in `.env`. The stack
starts in demo mode, with the fake `lmutil` and fake Active Directory, so everything works offline.

- **After changing code:** `podman compose up -d --build`. The database and PSU's data are kept.
- **Fresh data for a demo:** run the `New-DevData.ps1` line again.
- **Another port:** `FATHOM_PORT=8080` in `.env`.
- **Start over:** `podman compose down -v` deletes both volumes, and with them all data.

## 2. Dev on real license servers

Active Directory isn't available here (the ActiveDirectory module is Windows-only), but lmstat and
the debug logs are.

1. **lmutil.** Put FlexLM's Linux `lmutil` in `./flexlm/` next to `compose.yaml`, and check it on the
   host first: `./flexlm/lmutil lmstat -a -c 27000@licsrv01`. The image already has the LSB loader it asks for.
2. **Debug logs (optional).** Mount each license server's log share on the host, read-only, as in
   the [Linux guide](linux.md#the-debug-log-optional), for example at `/mnt/licsrv01`.
3. **In `compose.yaml`,** uncomment the two volume lines under `fathom` (and add one per log share):

   ```yaml
       volumes:
         - data:/data
         - ./flexlm:/opt/flexlm:ro
         - /mnt/licsrv01:/logs/licsrv01:ro
   ```

4. **In `.env`,** switch from the fakes to the real `lmutil`, and set the license servers' time zone.
   The empty values turn the fakes off:

   ```bash
   FATHOM_LMUTIL=/opt/flexlm/lmutil
   FAKE_LMUTIL_DIR=
   FATHOM_AD_MODULE=
   TZ=America/New_York
   ```

   `TZ` matters: lmgrd writes its debug log in the license server's local time, and Fathom stamps
   lmstat polls with the container's. The container runs in UTC unless told otherwise, which
   would put log events and lmstat samples hours apart.

5. `podman compose up -d`, then add the server in Administration: `27000@licsrv01`, and for the
   debug log the path *inside* the container, `/logs/licsrv01/debug.log`.

The checks in the [Linux guide](linux.md#check-its-right) apply as they are. If generated demo data is
already in the database, `podman compose exec fathom pwsh /app/tools/New-DevData.ps1 -Force -Remove`
takes it out first.

## 3. Production (placeholder)

The outline, to be written up:

- [ ] **A PSU license.** Adding one in the admin console writes `.universal/licenses.ps1` inside the
      container, which a rebuild discards. Copy it out once (`podman cp <container>:/app/.universal/licenses.ps1 .`,
      with the name from `podman compose ps`) and mount it back as a file.
- [ ] **Configuration comes from Git, not the admin console:** console edits to the repository live in the
      container and are lost on rebuild. Change the repo, rebuild, redeploy.
- [ ] **Postgres:** a managed instance, or the `db` service with its volume backed up. Use a real password
      (`POSTGRES_PASSWORD` in `.env`).
- [ ] **Back up** the `data` volume too: PSU's own database (accounts, roles, job history).
- [ ] **HTTPS:** a reverse proxy in front of port 5000.
- [ ] **Sign-in:** OIDC with Fathom roles mapped to groups (no Windows authentication in a Linux container).
- [ ] **An image registry and pinned tags,** instead of building on the server.
- [ ] **Alerts:** SMTP settings, a test message, then switch sending on.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `podman compose` says "set PSU_ADMIN_PASSWORD in .env" | Create `.env` with that line (step 1). Compose refuses to start without it, so no stack starts with an open setup wizard |
| The `fathom` container restarts with "the database never answered" | Postgres is down or the DSN is wrong: `podman compose logs db` |
| The admin password in `.env` doesn't work | It only applies the first time PSU starts with an empty `data` volume. Change it in the admin console, or `podman compose down -v` to start over |
| lmstat says the server is UP but lists no features | The vendor daemon's port is blocked; see [ports](README.md#what-fathom-ps-needs-to-reach) |
| Everyone has to sign in again after the container restarts | Expected: PSU keeps the keys for its sign-in cookies in memory, as a native PSU does across restarts. Accounts and data are kept |
