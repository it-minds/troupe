<#
  A code-signing certificate made here, for the signing test, and never for a release:
  CN "Troupe signing test", self-signed, two days long.

    test-certificate.ps1 [-Trust] [-OutDir DIR]

  Writes the certificate with its key as a .pfx under DIR (RUNNER_TEMP, or TEMP), and sets
  TROUPE_SIGN_PFX, TROUPE_SIGN_PFX_PASSWORD and TROUPE_SIGN_THUMBPRINT for the job's later
  steps through GITHUB_ENV (printing them otherwise). Made in memory: no certificate store
  is touched unless -Trust is given.

  -Trust adds the certificate to the machine's Root and TrustedPublisher stores, so that a
  signature made with it reads as Valid, as a release's does. For a CI runner, which is
  thrown away after the job; never for a person's machine.
#>
param(
  [switch] $Trust,
  [string] $OutDir = $(if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP })
)

$ErrorActionPreference = "Stop"
$X509 = "System.Security.Cryptography.X509Certificates"

$rsa = [System.Security.Cryptography.RSA]::Create(3072)
$request = New-Object "$X509.CertificateRequest" -ArgumentList @(
  "CN=Troupe signing test", $rsa,
  [System.Security.Cryptography.HashAlgorithmName]::SHA256,
  [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
$request.CertificateExtensions.Add((New-Object "$X509.X509BasicConstraintsExtension" -ArgumentList @($false, $false, 0, $true)))
$request.CertificateExtensions.Add((New-Object "$X509.X509KeyUsageExtension" -ArgumentList @(
  [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature, $true)))
$usages = New-Object System.Security.Cryptography.OidCollection
[void]$usages.Add((New-Object System.Security.Cryptography.Oid -ArgumentList "1.3.6.1.5.5.7.3.3"))
$request.CertificateExtensions.Add((New-Object "$X509.X509EnhancedKeyUsageExtension" -ArgumentList @($usages, $true)))

$now = [DateTimeOffset]::UtcNow
$cert = $request.CreateSelfSigned($now.AddMinutes(-5), $now.AddDays(2))

$password = [Guid]::NewGuid().ToString("N")
New-Item -ItemType Directory -Force $OutDir | Out-Null
$pfx = Join-Path $OutDir "troupe-signing-test.pfx"
[IO.File]::WriteAllBytes($pfx, $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $password))

if ($Trust) {
  $public = New-Object "$X509.X509Certificate2" -ArgumentList (, $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))
  foreach ($name in @("Root", "TrustedPublisher")) {
    $store = New-Object "$X509.X509Store" -ArgumentList @($name, "LocalMachine")
    $store.Open("ReadWrite")
    try { $store.Add($public) } finally { $store.Close() }
  }
  Write-Host "trusted on this machine: $($cert.Thumbprint)"
}

$vars = [ordered]@{
  TROUPE_SIGN_PFX = $pfx
  TROUPE_SIGN_PFX_PASSWORD = $password
  TROUPE_SIGN_THUMBPRINT = $cert.Thumbprint
}
if ($env:GITHUB_ENV) {
  Write-Host "::add-mask::$password"
  foreach ($k in $vars.Keys) { Add-Content -Path $env:GITHUB_ENV -Value "$k=$($vars[$k])" }
  Write-Host "the self-signed certificate $($cert.Thumbprint) is in $pfx"
} else {
  foreach ($k in $vars.Keys) { Write-Host "$k=$($vars[$k])" }
}
