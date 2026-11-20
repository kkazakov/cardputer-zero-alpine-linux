# flash-cpz.ps1 — CPZ-Alpine flasher for Windows (called by flash-cpz.bat).
#
# Verifies the SHA-256, writes the decompressed image to a physical disk,
# and preserves the existing CPZ-Alpine partition table (CPZDATA p3 at
# 4 GiB) when the card already has it. A blank/foreign card gets a clean
# install; that first flash has no CPZDATA partition (use the Linux
# flasher once if you want /cfg persistence).
$ErrorActionPreference = "Stop"
Set-Location -LiteralPath (Split-Path -Parent $MyInvocation.MyCommand.Path)

function Fail([string]$msg) {
    Write-Host "ERROR: $msg" -ForegroundColor Red
    exit 1
}

function Le32([byte[]]$b, [int]$o) {
    return [BitConverter]::ToUInt32($b, $o)
}

function Test-CpzMbr([byte[]]$b, [uint64]$totalSectors) {
    if ($b.Length -lt 512) { return $false }
    if ($b[510] -ne 0x55 -or $b[511] -ne 0xAA) { return $false }
    $p1s = Le32 $b 454; $p1n = Le32 $b 458
    $p2s = Le32 $b 470; $p2n = Le32 $b 474
    $p3t = [int]$b[482]
    $p3s = Le32 $b 486; $p3n = Le32 $b 490
    return ($p1s -eq 16384 -and $p1n -eq 524288 -and
            $p2s -eq 540672 -and $p2n -eq 3145728 -and
            $p3t -eq 0x83 -and $p3s -eq 8388608 -and $p3n -gt 0 -and
            ([uint64]$p3s + [uint64]$p3n) -le $totalSectors)
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fail "run flash-cpz.bat as Administrator"
}

$img = Get-ChildItem -Filter "cpz-alpine-*.img.gz" |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $img) { Fail "no cpz-alpine-*.img.gz in this folder" }
$ImagePath = $img.FullName
$shaPath = "$ImagePath.sha256"
if (-not (Test-Path -LiteralPath $shaPath)) { Fail "missing $shaPath" }

Write-Host "image:   $($img.Name)"
Write-Host "checking SHA-256..."
$expected = ((Get-Content -LiteralPath $shaPath -TotalCount 1) -split '\s+')[0].ToLower()
$actual = (Get-FileHash -LiteralPath $ImagePath -Algorithm SHA256).Hash.ToLower()
if ($actual -ne $expected) { Fail "checksum mismatch - refusing to flash" }
Write-Host "checksum OK" -ForegroundColor Green

Write-Host ""
Write-Host "Physical disks:"
Get-Disk | Sort-Object Number |
    Format-Table Number, FriendlyName,
        @{N='SizeGB'; E={[math]::Round($_.Size / 1GB, 1)}},
        BusType, IsBoot, IsSystem -AutoSize

$reply = Read-Host "Disk number to overwrite (NOT your system disk)"
if ($reply -notmatch '^\d+$') { Fail "invalid disk number" }
$n = [int]$reply
$disk = Get-Disk -Number $n
if ($disk.IsBoot -or $disk.IsSystem) { Fail "refusing the boot/system disk" }
if ($disk.BusType -notin @('USB', 'SD', 'MMC')) {
    Fail "this is a $($disk.BusType) disk; attach the card through a USB/SD reader"
}
if ($disk.Size -lt 2GB) { Fail "disk is smaller than 2 GiB" }

Write-Host ""
Write-Host "Target: Disk $n - $($disk.FriendlyName) - $([math]::Round($disk.Size/1GB,1)) GB"
Write-Host "ALL DATA ON THIS DISK WILL BE OVERWRITTEN." -ForegroundColor Yellow
$confirm = Read-Host "Type ERASE to continue"
if ($confirm -ne "ERASE") { Fail "aborted" }

$physical = "\\.\PhysicalDrive$n"
$totalSectors = [uint64]($disk.Size / 512)

# Read the current MBR before diskpart touches it.
$mbr = New-Object byte[] 512
$reader = [System.IO.File]::Open($physical,
    [System.IO.FileMode]::Open,
    [System.IO.FileAccess]::Read,
    [System.IO.FileShare]::ReadWrite)
try { [void]$reader.Read($mbr, 0, 512) } finally { $reader.Dispose() }
$preserve = Test-CpzMbr $mbr $totalSectors

if ($preserve) {
    Write-Host "CPZ-Alpine layout found: preserving CPZDATA and the partition table." -ForegroundColor Green
} else {
    Write-Host "No CPZ-Alpine layout found: clean install." -ForegroundColor Yellow
    Write-Host "NOTE: a clean install has no CPZDATA partition, so /cfg persistence"
    Write-Host "      is unavailable until you flash once with flash-cpz.sh on Linux."
}

Write-Host "clearing the old partition table..."
$dp = "select disk $n`r`nclean"
$dp | & diskpart.exe | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "diskpart could not clean Disk $n" }

Write-Host "writing $($img.Name) to $physical ..."
$raw = [System.IO.File]::Open($physical,
    [System.IO.FileMode]::Open,
    [System.IO.FileAccess]::ReadWrite,
    [System.IO.FileShare]::None)
$gz = New-Object System.IO.Compression.GZipStream(
    [System.IO.File]::OpenRead($ImagePath),
    [System.IO.Compression.CompressionMode]::Decompress)
$buf = New-Object byte[] (4 * 1024 * 1024)
try {
    while (($read = $gz.Read($buf, 0, $buf.Length)) -gt 0) {
        $raw.Write($buf, 0, $read)
    }
    $raw.Flush()
    if ($preserve) {
        Write-Host "restoring the original partition table (CPZDATA entry)..."
        [void]$raw.Seek(0, [System.IO.SeekOrigin]::Begin)
        $raw.Write($mbr, 0, 512)
        $raw.Flush()
    }
} finally {
    $gz.Dispose()
    $raw.Dispose()
}

Update-HostStorageCache -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "done. Remove and re-insert the card; cancel any Windows format prompt." -ForegroundColor Green
Write-Host "Insert it into the CardputerZero and power on."
Read-Host "Press Enter to close" | Out-Null