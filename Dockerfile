# fathom-ps on PowerShell Universal. Build: podman build -t fathom-ps .   (docker build works the same)
# PSU's own image, at the version the tests run against.
ARG PSU_TAG=2026.2.3-ubuntu-24.04
FROM docker.io/devolutions/powershell-universal:${PSU_TAG}

# SimplySql for the Fathom module. The image ships PSU's host without its execute bit, and has no
# LSB loader, which FlexLM's Linux lmutil asks for.
RUN pwsh -NoProfile -Command "Install-PSResource -Name SimplySql -Version 2.2.0.106 -Scope AllUsers -TrustRepository -Quiet" \
    && chmod +x /home/Universal/PowerShellUniversal.Host /home/Universal/Hosts/*/PowerShellUniversal.Host \
    && ln -s /lib64/ld-linux-x86-64.so.2 /lib64/ld-lsb-x86-64.so.3

# This repo is PSU's repository. PSU's own database and the signing key live in /data.
COPY . /app
COPY docker/entrypoint.sh /usr/local/bin/fathom-entrypoint
RUN chmod +x /usr/local/bin/fathom-entrypoint /app/tests/fakes/lmutil
ENV Data__RepositoryPath=/app \
    Data__ConnectionString="Data Source=/data/psu.db" \
    UniversalDashboard__AssetsFolder=/data/UniversalDashboard
VOLUME ["/data"]
EXPOSE 5000
ENTRYPOINT ["/usr/local/bin/fathom-entrypoint"]
