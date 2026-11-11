# Build and test the core on Windows with the Swift toolchain.
#
#   powershell -File tools\win-swift.ps1 build
#   powershell -File tools\win-swift.ps1 test
#   powershell -File tools\win-swift.ps1 bench     (release build, then runs the benchmark)
#
# The build folder is kept on C: because the repository may sit on a FAT32 drive.
param([Parameter(Position = 0)] [string] $Command = "test")

$scratch = "C:\Dev\sihema-build"
$u = [Environment]::GetEnvironmentVariable('Path', 'User'); $m = [Environment]::GetEnvironmentVariable('Path', 'Machine'); $env:Path = "$m;$u"
foreach ($n in 'SDKROOT', 'SWIFTFLAGS', 'INCLUDE', 'LIB') {
    $v = [Environment]::GetEnvironmentVariable($n, 'User'); if ($v) { Set-Item "env:$n" $v }
}
Set-Location (Split-Path -Parent $PSScriptRoot)

function Show($lines) {
    # hide the Windows SDK module warnings, keep ours
    $lines | Where-Object { $_ -notmatch 'WinSDK|wchar_t|^\s*[|`]|SwiftDriver|Failed frontend|builtin-Swift' } | Select-Object -Last 150
}

switch ($Command) {
    "build" { Show (swift build --scratch-path $scratch 2>&1 | ForEach-Object { "$_" }) }
    "test"  { Show (swift test --scratch-path $scratch 2>&1 | ForEach-Object { "$_" }) }
    "bench" {
        Show (swift build -c release --scratch-path $scratch 2>&1 | ForEach-Object { "$_" })
        $exe = Get-ChildItem $scratch -Recurse -Filter SihemaBench.exe | Where-Object { $_.FullName -match 'Release' } | Select-Object -First 1
        & $exe.FullName --lines 1000000 --dexel-moves 20000
    }
    default { "Unknown command: $Command" }
}
