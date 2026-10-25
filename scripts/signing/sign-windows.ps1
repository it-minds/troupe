<#
  Sign, or check, every PE file under each path with an Authenticode signature.

    sign-windows.ps1 PATH...
    sign-windows.ps1 -Verify PATH...

  A PATH is a file or a directory. In a directory each PE file is found by its header,
  not by its name, so the ERTS executables and DLLs and every NIF are signed, not only the
  program a person starts: Smart App Control checks every one. It is what
  Troupe.Release.OSSigning runs on troupe-daemon's release before it is packed and on
  troupe's Burrito payload before Burrito wraps it, what native.yml runs on the finished
  troupe.exe, and the desktop build's sign command (tauri.signing.conf.json). A file
  named explicitly is signed whatever it is, so an .msi can be.

  TROUPE_SIGN_TOOL picks the signer:
    artifact-signing  Microsoft Artifact Signing through artifact-signing-cli, with
                      AZURE_ENDPOINT, AZURE_CODE_SIGNING_NAME and AZURE_CERT_PROFILE_NAME,
                      and the AZURE_TENANT_ID, AZURE_CLIENT_ID and AZURE_CLIENT_SECRET the
                      tool reads itself: a release.
    signtool          signtool with a certificate file, TROUPE_SIGN_PFX and
                      TROUPE_SIGN_PFX_PASSWORD: the signing test's self-signed certificate
                      (test-certificate.ps1). TROUPE_SIGN_TIMESTAMP_URL adds a timestamp.
  A file that already carries a valid signature, one Microsoft made say, is left as it is.

  -Verify signs nothing. Every PE file must carry a valid signature; it prints the count,
  adds it to the job's summary under TROUPE_SIGN_LABEL, and fails naming any that does not.
#>
param(
  [switch] $Verify,
  [Parameter(Position = 0, ValueFromRemainingArguments = $true)] [string[]] $Path
)

$ErrorActionPreference = "Stop"
$Description = "Troupe"
$BatchSize = 16

if (-not $Path -or $Path.Count -eq 0) { throw "usage: sign-windows.ps1 [-Verify] PATH..." }

# A PE file: "MZ", and at the offset in its header the signature "PE\0\0".
function Test-PE([string] $File) {
  $fs = [IO.File]::OpenRead($File)
  try {
    if ($fs.Length -lt 64) { return $false }
    $head = New-Object byte[] 64
    [void]$fs.Read($head, 0, 64)
    if ($head[0] -ne 0x4D -or $head[1] -ne 0x5A) { return $false }
    $offset = [BitConverter]::ToInt32($head, 0x3C)
    if ($offset -lt 64 -or ($offset + 4) -gt $fs.Length) { return $false }
    [void]$fs.Seek($offset, [IO.SeekOrigin]::Begin)
    $sig = New-Object byte[] 4
    [void]$fs.Read($sig, 0, 4)
    return ($sig[0] -eq 0x50 -and $sig[1] -eq 0x45 -and $sig[2] -eq 0 -and $sig[3] -eq 0)
  } finally {
    $fs.Dispose()
  }
}

$files = New-Object System.Collections.Generic.List[string]
foreach ($p in $Path) {
  if (Test-Path -LiteralPath $p -PathType Container) {
    Get-ChildItem -LiteralPath $p -Recurse -File | ForEach-Object {
      if (Test-PE $_.FullName) { $files.Add($_.FullName) }
    }
  } elseif (Test-Path -LiteralPath $p -PathType Leaf) {
    $files.Add((Resolve-Path -LiteralPath $p).ProviderPath)
  } else {
    throw "sign-windows: $p is not there"
  }
}
if ($files.Count -eq 0) { throw "sign-windows: no PE file under $($Path -join ', ')" }

function Get-Status([string] $File) { (Get-AuthenticodeSignature -LiteralPath $File).Status.ToString() }

if ($Verify) {
  $bad = @()
  $by = @{}
  foreach ($f in $files) {
    $s = Get-AuthenticodeSignature -LiteralPath $f
    if ($s.Status -ne "Valid") { $bad += "${f}: $($s.Status) $($s.StatusMessage)"; continue }
    $name = $s.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
    if ($by.ContainsKey($name)) { $by[$name]++ } else { $by[$name] = 1 }
  }
  if ($bad.Count -gt 0) {
    $bad | ForEach-Object { [Console]::Error.WriteLine($_) }
    throw "sign-windows: $($bad.Count) of $($files.Count) PE files do not carry a valid signature"
  }
  $signers = ($by.Keys | Sort-Object | ForEach-Object { "$($by[$_]) by $_" }) -join ", "
  Write-Host "verified: $($files.Count) files under $($Path -join ', ') carry a valid signature ($signers)"
  if ($env:GITHUB_STEP_SUMMARY -and $env:TROUPE_SIGN_LABEL) {
    Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value "- $($env:TROUPE_SIGN_LABEL): $($files.Count) files signed ($signers)"
  }
  exit 0
}

$todo = @($files | Where-Object { (Get-Status $_) -ne "Valid" })
$already = $files.Count - $todo.Count

function Find-SignTool {
  if ($env:TROUPE_SIGNTOOL) { return $env:TROUPE_SIGNTOOL }
  $kits = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin"
  $found = Get-ChildItem -Path $kits -Directory -Filter "10.*" -ErrorAction SilentlyContinue |
    Sort-Object { [version]$_.Name } -Descending |
    ForEach-Object { Join-Path $_.FullName "x64\signtool.exe" } |
    Where-Object { Test-Path $_ } | Select-Object -First 1
  if (-not $found) { throw "sign-windows: no signtool.exe under $kits; set TROUPE_SIGNTOOL" }
  return $found
}

function Require([string[]] $Names) {
  $missing = @($Names | Where-Object { -not [Environment]::GetEnvironmentVariable($_) })
  if ($missing.Count -gt 0) { throw "sign-windows: $($missing -join ', ') not set" }
}

$tool = $env:TROUPE_SIGN_TOOL
switch ($tool) {
  "artifact-signing" {
    Require @("AZURE_ENDPOINT", "AZURE_CODE_SIGNING_NAME", "AZURE_CERT_PROFILE_NAME", "AZURE_TENANT_ID", "AZURE_CLIENT_ID", "AZURE_CLIENT_SECRET")
    $run = {
      param($batch)
      & artifact-signing-cli -e $env:AZURE_ENDPOINT -a $env:AZURE_CODE_SIGNING_NAME -c $env:AZURE_CERT_PROFILE_NAME -d $Description @batch
    }
  }
  "signtool" {
    Require @("TROUPE_SIGN_PFX", "TROUPE_SIGN_PFX_PASSWORD")
    $signtool = Find-SignTool
    $run = {
      param($batch)
      $a = @("sign", "/fd", "SHA256", "/f", $env:TROUPE_SIGN_PFX, "/p", $env:TROUPE_SIGN_PFX_PASSWORD, "/d", $Description)
      if ($env:TROUPE_SIGN_TIMESTAMP_URL) { $a += @("/tr", $env:TROUPE_SIGN_TIMESTAMP_URL, "/td", "SHA256") }
      & $signtool @a @batch
    }
  }
  default { throw "sign-windows: TROUPE_SIGN_TOOL is '$tool'; it is artifact-signing or signtool" }
}

for ($i = 0; $i -lt $todo.Count; $i += $BatchSize) {
  $batch = @($todo[$i..([Math]::Min($i + $BatchSize, $todo.Count) - 1)])
  & $run $batch
  if ($LASTEXITCODE -ne 0) { throw "sign-windows: $tool exited $LASTEXITCODE signing $($batch -join ', ')" }
}

# Signed means a signature is there and holds: a tool that exits 0 and signs nothing is
# caught here, not on somebody's machine. Valid is asked of the release's signatures; the
# test's certificate is trusted on its runner, so its signatures are Valid there too.
$failed = @($todo | Where-Object { (Get-Status $_) -ne "Valid" })
if ($failed.Count -gt 0) {
  $failed | ForEach-Object { [Console]::Error.WriteLine("${_}: $(Get-Status $_)") }
  throw "sign-windows: $($failed.Count) files carry no valid signature after $tool signed them"
}
Write-Host "signed $($todo.Count) of $($files.Count) PE files under $($Path -join ', ') with $tool ($already already signed)"
