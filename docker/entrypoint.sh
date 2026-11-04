#!/usr/bin/env bash
# Brings the Fathom schema up to date (what Scripts/Initialize-Database.ps1 does after every
# update), then runs PSU.
set -euo pipefail

# A signing key that survives restarts, so sign-ins do too, unless one is given.
if [ -z "${Jwt__SigningKey:-}" ]; then
    mkdir -p /data
    [ -s /data/jwt.key ] || (umask 077; head -c 48 /dev/urandom | base64 -w0 > /data/jwt.key)
    export Jwt__SigningKey="$(cat /data/jwt.key)"
fi

# Postgres may still be starting.
for attempt in $(seq 1 30); do
    if output=$(pwsh -NoProfile -Command 'Import-Module /app/Modules/Fathom/Fathom.psd1; Connect-FathomDatabase; Initialize-FathomSchema; Disconnect-FathomDatabase' 2>&1); then
        break
    fi
    if [ "$attempt" = 30 ]; then
        echo "$output" >&2
        echo "fathom: the database (LM_POSTGRES_DSN) never answered." >&2
        exit 1
    fi
    echo "fathom: waiting for the database ($attempt)..."
    sleep 2
done

cd /home/Universal
exec ./Universal.Server
