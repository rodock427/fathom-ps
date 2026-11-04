<#
.SYNOPSIS
    Stand-in for lmutil, for Windows (via lmutil.cmd); tests/fakes/lmutil is the same in bash.
.DESCRIPTION
    "lmstat -a -c <port>@<host>" prints $env:FAKE_LMUTIL_DIR/<host>.txt. Host "hang" never answers;
    an unknown host fails the way lmutil does when it can't reach a server.
#>
$spec = ''
for ($i = 0; $i -lt $args.Count; $i++) {
    if ($args[$i] -eq '-c' -and $i + 1 -lt $args.Count) { $spec = $args[$i + 1] }
}
$hostName = $spec.Split('@')[-1]

if ($hostName -eq 'hang') {
    Start-Sleep -Seconds 60
    exit 0
}
$answer = Join-Path -Path ([string] $env:FAKE_LMUTIL_DIR) -ChildPath "$hostName.txt"
if ($hostName -and (Test-Path -LiteralPath $answer)) {
    Get-Content -LiteralPath $answer -Raw
    exit 0
}
'lmutil - Copyright (c) 1989-2021 Flexera. All Rights Reserved.'
'Error getting status: Cannot connect to license server system. (-15,570:111 "Connection refused")'
exit 1
