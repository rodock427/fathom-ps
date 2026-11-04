# Dot-sourced by the database tests, after importing Fathom. Their own SQL (seeding, checking)
# goes through SimplySql on a connection of its own, apart from the module's.
$PSDefaultParameterValues['*-Sql*:ConnectionName'] = 'fathom-test'
if ($env:FATHOM_TEST_DSN) {
    $testConnection = & (Get-Module -Name Fathom) { ConvertTo-NpgsqlConnectionString -Dsn $env:FATHOM_TEST_DSN }
    if (Test-SqlConnection -ConnectionName 'fathom-test') {
        Close-SqlConnection -ConnectionName 'fathom-test'
    }
    Open-PostGreConnection -ConnectionName 'fathom-test' -ConnectionString $testConnection
}
