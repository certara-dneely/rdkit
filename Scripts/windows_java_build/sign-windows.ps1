<#
.SYNOPSIS
  Authenticode-sign the Windows DLLs/EXEs of the RDKit build through the Certara Jenkins CodeSigning job.

.DESCRIPTION
  Same flow as d360-tripos-tools/.github/scripts/sign-and-fetch.ps1:
    1. pack every unsigned *.dll / *.exe found under -Root into one flat tar (-UNSIGNED.tar)
    2. upload it to Artifactory staging (jf rt upload) and POST the Jenkins generic-webhook trigger
    3. wait for the CodeSigning build (Jenkins API if credentials are set, else poll Artifactory)
    4. download the signed tar, verify every signature (Get-AuthenticodeSignature = Valid),
       and copy the signed files back over the originals.

  Nothing identifying the Jenkins server lives in this file (the repository is public). Required environment:
    JENKINS_BASE_URL          e.g. https://jenkins.example.com            (repository variable)
    JENKINS_CODESIGN_JOB      e.g. /job/products/job/D360/job/CodeSigning  (repository variable)
    CODESIGN_TRIGGER_TOKEN    generic-webhook-trigger token                (secret)
  Optional but recommended (without them the script falls back to polling Artifactory):
    JENKINS_API_USERID, JENKINS_API_TOKEN
  The JFrog CLI (jf) must already be configured (jfrog/setup-jfrog-cli).
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string[]]$Root,
  [Parameter(Mandatory = $true)][string]$BuildNumber,
  [string]$Label = 'rdkit-windows-x64',
  [string]$ArtifactoryBase = 'https://certara.jfrog.io/artifactory',
  [string]$StagingRepoPath = 'certara-maven-develop-local/com/certara/rdkit/staging',
  [int]$FindTimeoutSeconds = 3600,
  [int]$FindPollSeconds = 30,
  [int]$SignTimeoutSeconds = 3600,
  [int]$SignPollSeconds = 30
)

$ErrorActionPreference = 'Stop'

function Fail([string]$msg, [int]$code = 1) { Write-Host "::error::sign-windows: $msg"; exit $code }
function Info([string]$msg) { Write-Host "sign-windows: $msg" }

foreach ($v in 'JENKINS_BASE_URL', 'JENKINS_CODESIGN_JOB', 'CODESIGN_TRIGGER_TOKEN') {
  if (-not (Get-Item "env:$v" -ErrorAction SilentlyContinue)) { Fail "environment variable $v is not set" }
}
$jenkinsBase = $env:JENKINS_BASE_URL.TrimEnd('/')
$jobPath = '/' + $env:JENKINS_CODESIGN_JOB.Trim('/')
$jenkinsUser = $env:JENKINS_API_USERID
$jenkinsToken = $env:JENKINS_API_TOKEN
$useJenkinsApi = [bool]$jenkinsUser -and [bool]$jenkinsToken
if (-not (Get-Command jf -ErrorAction SilentlyContinue)) { Fail 'JFrog CLI (jf) not found' }
# Windows' own bsdtar: a GNU tar earlier in PATH (Git for Windows) would read 'C:' as a remote host.
$tarExe = Join-Path (Join-Path $env:SystemRoot 'System32') 'tar.exe'

# --- 1. collect the unsigned binaries ---------------------------------------------------------------
$files = @()
foreach ($r in $Root) {
  if (-not (Test-Path $r)) { Fail "root not found: $r" }
  $files += Get-ChildItem -Path $r -Recurse -File -Include *.dll, *.exe
}
$todo = @($files | Where-Object { (Get-AuthenticodeSignature $_.FullName).Status -eq 'NotSigned' })
Info "$($files.Count) binaries found, $($todo.Count) unsigned"
if ($todo.Count -eq 0) { Info 'nothing to sign'; exit 0 }

$dups = $todo | Group-Object { $_.Name.ToLowerInvariant() } | Where-Object Count -gt 1
if ($dups) { Fail ("file name collision (the tar is flat): " + (($dups | ForEach-Object Name) -join ', ')) }

$work = Join-Path $env:RUNNER_TEMP "sign-$BuildNumber"
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
$pack = Join-Path $work 'pack'; $back = Join-Path $work 'signed'
New-Item -ItemType Directory -Force $pack, $back | Out-Null
$todo | ForEach-Object { Copy-Item $_.FullName $pack }
$tar = Join-Path $work "$Label-UNSIGNED.tar"
Push-Location $pack; & $tarExe -cf $tar *; $rc = $LASTEXITCODE; Pop-Location
if ($rc -ne 0) { Fail 'tar failed' }

# --- 2. upload + trigger ---------------------------------------------------------------------------
# A per-build unique token in the staging path is the Jenkins correlation id: concurrent or repeated builds
# must not bind to an earlier CodeSigning job.
$unsignedRepoPath = "$StagingRepoPath/$Label-$BuildNumber-UNSIGNED.tar"
$signedRepoPath = $unsignedRepoPath -replace '-UNSIGNED\.tar$', '-SIGNED.tar'
$artifactUrl = "$ArtifactoryBase/$unsignedRepoPath"
$unsignedSha = (Get-FileHash $tar -Algorithm SHA256).Hash.ToLowerInvariant()
Info "unsigned : $unsignedRepoPath"
Info "signed   : $signedRepoPath (expected; or in place)"
Info ("wait mode: " + $(if ($useJenkinsApi) { 'Jenkins API' } else { 'Artifactory polling (JENKINS_API_USERID/TOKEN not set)' }))

jf rt upload $tar $unsignedRepoPath --build-name 'rdkit' --build-number $BuildNumber
if ($LASTEXITCODE -ne 0) { Fail 'jf upload failed' }

$body = @{ url = $artifactUrl } | ConvertTo-Json
Invoke-RestMethod -Uri "$jenkinsBase/generic-webhook-trigger/invoke?token=$($env:CODESIGN_TRIGGER_TOKEN)" `
  -Method Post -Body $body -ContentType 'application/json' | Out-Null
Info 'CodeSigning triggered'

# --- 3. wait ---------------------------------------------------------------------------------------
function Try-Download([string]$repoPath, [string]$dir) {
  jf rt dl $repoPath "$dir/" --flat=true 2>$null | Out-Null
  $p = Join-Path $dir (Split-Path $repoPath -Leaf)
  if ($LASTEXITCODE -eq 0 -and (Test-Path $p)) { return $p } else { return $null }
}

if ($useJenkinsApi) {
  $pair = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${jenkinsUser}:${jenkinsToken}"))
  $headers = @{ Authorization = "Basic $pair" }
  $jobNum = $null
  $endFind = (Get-Date).AddSeconds($FindTimeoutSeconds)
  while (-not $jobNum -and (Get-Date) -lt $endFind) {
    $builds = Invoke-RestMethod -Uri "$jenkinsBase$jobPath/api/json?tree=builds[number,actions[parameters[name,value]]]" -Headers $headers
    foreach ($b in $builds.builds) {
      foreach ($a in $b.actions) {
        foreach ($p in @($a.parameters)) { if ($p.name -eq 'url' -and $p.value -eq $artifactUrl) { $jobNum = $b.number } }
      }
    }
    if (-not $jobNum) { Start-Sleep -Seconds $FindPollSeconds }
  }
  if (-not $jobNum) { Fail "no Jenkins CodeSigning build found for $artifactUrl" }
  Info "Jenkins CodeSigning build #$jobNum"
  $done = $false
  $endSign = (Get-Date).AddSeconds($SignTimeoutSeconds)
  while (-not $done -and (Get-Date) -lt $endSign) {
    Start-Sleep -Seconds $SignPollSeconds
    $data = Invoke-RestMethod -Uri "$jenkinsBase$jobPath/$jobNum/api/json" -Headers $headers
    switch -Regex ($data.result) {
      'FAILURE' { Fail 'Jenkins signing FAILED' 1 }
      'ABORTED' { Fail 'Jenkins signing ABORTED' 2 }
      'SUCCESS' { $done = $true }
    }
  }
  if (-not $done) { Fail 'timed out waiting for signing' 4 }
} else {
  $done = $false
  $endSign = (Get-Date).AddSeconds($SignTimeoutSeconds)
  $probe = Join-Path $work 'probe'
  while (-not $done -and (Get-Date) -lt $endSign) {
    Start-Sleep -Seconds $SignPollSeconds
    Remove-Item -Recurse -Force $probe -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $probe | Out-Null
    if (Try-Download $signedRepoPath $probe) { $done = $true; break }
    $p = Try-Download $unsignedRepoPath $probe     # signed in place?
    if ($p -and (Get-FileHash $p -Algorithm SHA256).Hash.ToLowerInvariant() -ne $unsignedSha) { $done = $true }
  }
  if (-not $done) { Fail 'timed out waiting for the signed artifact in Artifactory' 4 }
}

# --- 4. fetch, verify, copy back ---------------------------------------------------------------------
$dl = Join-Path $work 'dl'
New-Item -ItemType Directory -Force $dl | Out-Null
$signedTar = Try-Download $signedRepoPath $dl
if (-not $signedTar) { $signedTar = Try-Download $unsignedRepoPath $dl }
if (-not $signedTar) { Fail 'could not download the signed tar' }
& $tarExe -xf $signedTar -C $back
if ($LASTEXITCODE -ne 0) { Fail 'could not extract the signed tar' }

$bad = @()
foreach ($f in $todo) {
  $s = Join-Path $back $f.Name
  if (-not (Test-Path $s)) { $bad += "$($f.Name): missing from the signed tar"; continue }
  $sig = Get-AuthenticodeSignature $s
  if ($sig.Status -ne 'Valid') { $bad += "$($f.Name): signature $($sig.Status) ($($sig.StatusMessage))"; continue }
  Copy-Item $s $f.FullName -Force
  Info ("signed {0}  [{1}]" -f $f.Name, $sig.SignerCertificate.Subject)
}
if ($bad) { $bad | ForEach-Object { Write-Host "::error::$_" }; Fail "$($bad.Count) file(s) failed verification" }
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
Info "done: $($todo.Count) file(s) signed"
