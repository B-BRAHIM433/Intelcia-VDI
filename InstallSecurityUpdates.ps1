    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
    Write-Host "[VDI] Etape InstallSecurityUpdates demarree (script compile OK)"
    Write-Host "=== INSTALLATION MISES A JOUR WINDOWS ==="
    $buildBefore = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").CurrentBuildNumber
    $verBefore   = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").DisplayVersion
    $edition     = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").EditionID
    $ubr         = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").UBR
    $ubrBefore   = [int]$ubr
    Write-Host "Systeme: Windows 11 $verBefore (Build $buildBefore.$ubr) - $edition"
    function Get-DefenderSignatureVersion {
    try {
    $reg = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Defender\Signature Updates" -ErrorAction Stop
    if ($reg.AVSignatureVersion) { return $reg.AVSignatureVersion }
    } catch {}
    try {
    $st = Get-MpComputerStatus -ErrorAction Stop
    if ($st.AntivirusSignatureVersion) { return $st.AntivirusSignatureVersion }
    } catch {}
    return $null
    }
    function Get-DefenderTransition {
    try {
    $events = Get-WinEvent -FilterHashtable @{
    LogName = 'Microsoft-Windows-Windows Defender/Operational'; Id = 2000
    } -MaxEvents 5 -ErrorAction Stop
    } catch { return $null }
    if (-not $events) { return $null }
    $latest = $events | Sort-Object TimeCreated -Descending | Select-Object -First 1
    try {
    [xml]$xml = $latest.ToXml()
    $data = @{}
    foreach ($d in $xml.Event.EventData.Data) {
    if ($d.Name) { $data[$d.Name] = $d.'#text' }
    }
    $curKey  = $data.Keys | Where-Object { $_ -match '(Current|New).*(Signature|intelligence)' } | Select-Object -First 1
    $prevKey = $data.Keys | Where-Object { $_ -match '(Previous|Old).*(Signature|intelligence)' } | Select-Object -First 1
    $cur  = if ($curKey)  { $data[$curKey] }  else { $null }
    $prev = if ($prevKey) { $data[$prevKey] } else { $null }
    if (-not $cur -or -not $prev) {
    $sig = $data.Values | Where-Object { $_ -match '^1\.\d{2,3}\.\d+\.\d+$' } | Select-Object -Unique
    if (@($sig).Count -ge 2) {
    $sorted = $sig | Sort-Object { [version]$_ }
    $prev = $sorted[0]; $cur = $sorted[-1]
    }
    }
    if ($cur -and $prev -and ($cur -ne $prev)) { return @{ Previous = $prev; Current = $cur } }
    } catch {}
    return $null
    }
    $defenderVersionAtStart = Get-DefenderSignatureVersion
    if (-not $defenderVersionAtStart) { $defenderVersionAtStart = "N/A" }
    Write-Host "Defender version initiale: $defenderVersionAtStart"
    function Test-PendingReboot {
    $keys = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
    )
    foreach ($k in $keys) { if (Test-Path $k) { return $true } }
    $pfr = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" `
    -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
    if ($pfr) { return $true }
    return $false
    }
    if (Test-PendingReboot) {
    Write-Host "AVERTISSEMENT: redemarrage en attente detecte sur l'image source (AMI non 'propre')."
    Write-Host "  -> wusa peut renvoyer 2359302 faussement. Verification CBS post-installation active."
    }
    try {
    reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v "SkipMachineOOBE" /t REG_DWORD /d 1 /f | Out-Null
    reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v "SkipUserOOBE"    /t REG_DWORD /d 1 /f | Out-Null
    reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\OOBE"       /v "DisablePrivacyExperience" /t REG_DWORD /d 1 /f | Out-Null
    reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v "HideEULAPage"    /t REG_DWORD /d 1 /f | Out-Null
    reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v "EnableFirstLogonAnimation" /t REG_DWORD /d 0 /f | Out-Null
    Write-Host "OOBE supprime"
    } catch { Write-Host "Avertissement OOBE: $_" }
    try {
    $RegPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
    if (-not (Test-Path $RegPath)) { New-Item -Path $RegPath -Force | Out-Null }
    Set-ItemProperty -Path $RegPath -Name "TargetReleaseVersion"    -Value 1            -Type DWord  -Force
    Set-ItemProperty -Path $RegPath -Name "ProductVersion"           -Value "Windows 11" -Type String -Force
    Set-ItemProperty -Path $RegPath -Name "TargetReleaseVersionInfo" -Value $verBefore   -Type String -Force
    Write-Host "Verrouillage feature upgrade OK ($verBefore protege contre 24H2/25H2)"
    } catch { Write-Host "Avertissement verrouillage: $_" }
    $catalogHeaders = @{
    "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0"
    "Referer"    = "https://www.catalog.update.microsoft.com/"
    }
    function Search-CatalogKB {
    param([string]$Query)
    try {
    $url  = "https://www.catalog.update.microsoft.com/Search.aspx?q=" + [Uri]::EscapeDataString($Query)
    $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -Headers $catalogHeaders -TimeoutSec 30
    Write-Host "  Catalog: $($resp.Content.Length) chars recus"
    $linkPattern = "<a\s+id='([a-f0-9\-]{36})_link'[^>]*>\s*([^<]+)\s*</a>"
    $linkMatches = [regex]::Matches($resp.Content, $linkPattern,
    [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $results = @()
    foreach ($m in $linkMatches) {
    $guid  = $m.Groups[1].Value.Trim()
    $title = $m.Groups[2].Value.Trim() -replace '\s+', ' '
    if ($title -and $guid) {
    $results += [PSCustomObject]@{ GUID = $guid; Title = $title }
    }
    }
    Write-Host "  Entrees trouvees: $($results.Count)"
    return $results
    } catch {
    Write-Host "  ERREUR catalog: $_"
    return @()
    }
    }
    function Get-MSUDownloadUrl {
    param([string]$GUID)
    try {
    $body = "updateIDs=%5B%7B%22size%22%3A0%2C%22languages%22%3A%22%22%2C%22uidInfo%22%3A%22$GUID%22%2C%22updateID%22%3A%22$GUID%22%7D%5D"
    $h    = $catalogHeaders.Clone()
    $h["Content-Type"] = "application/x-www-form-urlencoded"
    $resp = Invoke-WebRequest -Uri "https://www.catalog.update.microsoft.com/DownloadDialog.aspx" `
    -Method POST -Body $body -Headers $h -UseBasicParsing -TimeoutSec 30
    $urls = [regex]::Matches($resp.Content, 'https://[^"''<>\s]+\.msu') |
    Select-Object -ExpandProperty Value -Unique
    return $urls
    } catch {
    Write-Host "  Erreur GetURL: $_"
    return @()
    }
    }
    function Find-LatestCumulativeKB {
    param([string]$Version, [string]$BuildNumber)
    Write-Host "Recherche catalog pour Windows 11 $Version (Build $BuildNumber)..."
    $query   = "Cumulative Update for Windows 11 Version $Version for x64"
    $results = Search-CatalogKB -Query $query
    if ($results.Count -eq 0) {
    $query   = "Cumulative Update for Windows 11 version $Version for x64"
    $results = Search-CatalogKB -Query $query
    }
    if ($results.Count -eq 0) {
    $query   = "Cumulative Update Windows 11 $Version x64"
    $results = Search-CatalogKB -Query $query
    }
    if ($results.Count -eq 0) { return @() }
    Write-Host "  Premiers resultats:"
    $results | Select-Object -First 5 | ForEach-Object {
    Write-Host "    $($_.GUID) | $($_.Title)"
    }
    $currentMajor      = [int]($Version -replace "H.*","")
    $currentMinor      = [int]($Version -replace "\d+H","")
    $currentVersionNum = $currentMajor * 10 + $currentMinor
    $filtered = $results | Where-Object {
    $title = $_.Title
    if ($title -match "Preview|Pr.version|ARM64|Insider") { return $false }
    if ($title -notmatch "KB\d{6,}") { return $false }
    $versionMatch = [regex]::Matches($title, "(\d{2})H(\d)")
    foreach ($vm in $versionMatch) {
    $titleVersionNum = [int]$vm.Groups[1].Value * 10 + [int]$vm.Groups[2].Value
    if ($titleVersionNum -gt $currentVersionNum) { return $false }
    }
    return $true
    }
    Write-Host "  Apres filtrage: $($filtered.Count) KBs disponibles"
    if ($filtered.Count -eq 0) { return @() }
    $enriched = $filtered | ForEach-Object {
    $kbMatch   = [regex]::Match($_.Title, "KB(\d{6,})")
    $dateMatch = [regex]::Match($_.Title, "^(\d{4}-\d{2})")
    $isNet     = $_.Title -match "\.NET|Framework"
    $isDynamic = $_.Title -match "Dynamic Update|Safe OS|Setup Dynamic|Servicing Stack"
    [PSCustomObject]@{
    GUID      = $_.GUID
    Title     = $_.Title
    KBNumber  = if ($kbMatch.Success)  { $kbMatch.Groups[1].Value } else { "" }
    YearMonth = if ($dateMatch.Success) { $dateMatch.Groups[1].Value } else { "0000-00" }
    IsNet     = $isNet
    IsDynamic = $isDynamic
    }
    }
    return $enriched | Sort-Object YearMonth -Descending
    }
    function Get-TargetUBR {
    param([string]$KBNumber, [string]$BuildNumber)
    try {
    $url  = "https://support.microsoft.com/en-us/help/$KBNumber"
    $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -Headers $catalogHeaders -TimeoutSec 20
    $match = [regex]::Match($resp.Content, "$BuildNumber\.(\d{4,})")
    if ($match.Success) {
    Write-Host "  UBR cible depuis support.microsoft.com: $BuildNumber.$($match.Groups[1].Value)"
    return [int]$match.Groups[1].Value
    }
    } catch { Write-Host "  Support page inaccessible pour KB$KBNumber" }
    return 0
    }
    function Test-ValidMSU {
    param([string]$Path, [bool]$IsNet)
    if (-not (Test-Path $Path)) { return $false }
    $sizeMB = [math]::Round((Get-Item $Path).Length / 1MB, 1)
    $minMB  = if ($IsNet) { 10 } else { 100 }
    if ($sizeMB -lt $minMB) {
    Write-Host "  REJET: fichier trop petit ($sizeMB MB < $minMB MB) - stub/redirect probable"
    return $false
    }
    try {
    $fs   = [System.IO.File]::OpenRead($Path)
    $buf  = New-Object byte[] 16
    $read = $fs.Read($buf, 0, 16); $fs.Close()
    $head = [System.Text.Encoding]::ASCII.GetString($buf, 0, $read)
    if ($head -match '^\s*<[a-zA-Z!?/]') {
    Write-Host "  REJET: contenu HTML/texte ($sizeMB MB) - page de redirection ou erreur"
    return $false
    }
    $magic = if ($read -ge 4) { $head.Substring(0,4) } else { "" }
    if ($magic -eq 'MSCF') {
    Write-Host "  Validation OK: $sizeMB MB (container CAB/MSCF)"
    } else {
    $hex = (0..([Math]::Min(3,$read-1)) | ForEach-Object { $buf[$_].ToString('X2') }) -join ' '
    Write-Host "  Validation OK: $sizeMB MB (container non-CAB, en-tete $hex - normal pour msu recent)"
    }
    } catch {
    Write-Host "  Avertissement lecture en-tete: $_ - on continue (verification CBS apres wusa)"
    }
    return $true
    }
    function Test-CumulativeCommitted {
    param([int]$TargetUBR, [int]$BaselineUBR, [string]$BuildNumber)
    $ubrTarget = if ($TargetUBR -gt 0) { $TargetUBR } else { $BaselineUBR + 1 }
    try {
    $ubrNow = [int](Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").UBR
    if ($ubrNow -ge $ubrTarget) {
    Write-Host "  CBS: UBR courant $BuildNumber.$ubrNow >= cible $ubrTarget (commitee)"
    return $true
    }
    } catch {}
    try {
    $cbs = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages"
    $hit = Get-ChildItem $cbs -ErrorAction SilentlyContinue | Where-Object {
    ($_.PSChildName -match "RollupFix.*$BuildNumber\.(\d+)\.") -and ([int]$matches[1] -ge $ubrTarget)
    } | Select-Object -First 1
    if ($hit) {
    Write-Host "  CBS: paquet RollupFix au UBR cible enregistre ($($hit.PSChildName)) - commitera au reboot"
    return $true
    }
    } catch { Write-Host "  Verification CBS registre echouee: $_" }
    return $false
    }
    $updateResults = @()
    $lastKBNumber  = ""
    $latestWinKB   = $null
    $latestNetKB   = $null
    $mainKbRequired  = $false
    $mainKbSucceeded = $false
    $mainTargetUBR   = 0
    $rebootRequired  = $false
    $currentMajor      = [int]($verBefore -replace "H.*","")
    $currentMinor      = [int]($verBefore -replace "\d+H","")
    $currentVersionNum = $currentMajor * 10 + $currentMinor
    $allKBs = Find-LatestCumulativeKB -Version $verBefore -BuildNumber $buildBefore
    if ($null -eq $allKBs -or $allKBs.Count -eq 0) {
    Write-Host "Catalog inaccessible ou aucune KB trouvee"
    } else {
    $latestWinKB = $allKBs | Where-Object { -not $_.IsNet -and -not $_.IsDynamic } |
    Sort-Object YearMonth -Descending | Select-Object -First 1
    $latestNetKB = $allKBs | Where-Object { $_.IsNet -and -not $_.IsDynamic } |
    Sort-Object YearMonth -Descending | Select-Object -First 1
    if ($latestWinKB -and $latestWinKB.KBNumber) {
    $mainTargetUBR = Get-TargetUBR -KBNumber $latestWinKB.KBNumber -BuildNumber $buildBefore
    }
    $installedKBs = @()
    try {
    $hotfixKBs = (Get-HotFix -ErrorAction SilentlyContinue).HotFixID
    $installedKBs += $hotfixKBs
    Write-Host "KBs via Get-HotFix: $($hotfixKBs.Count)"
    } catch { Write-Host "Get-HotFix inaccessible" }
    try {
    $dismOutput = dism /online /get-packages /format:table 2>$null
    $dismKBs = $dismOutput | Where-Object { $_ -match "KB\d{6,}" } |
    ForEach-Object {
    $m = [regex]::Match($_, "KB(\d{6,})")
    if ($m.Success) { "KB$($m.Groups[1].Value)" }
    } | Where-Object { $_ } | Sort-Object -Unique
    $newFromDism = $dismKBs | Where-Object { $installedKBs -notcontains $_ }
    $installedKBs += $newFromDism
    Write-Host "KBs via DISM: $($dismKBs.Count) (dont $($newFromDism.Count) nouvelles)"
    } catch { Write-Host "DISM inaccessible" }
    Write-Host "Total KBs installees detectees: $($installedKBs.Count)"
    $kbsToInstall = @()
    if ($latestWinKB -and $latestWinKB.KBNumber) {
    $mainKbRequired = $true
    $kbId = "KB$($latestWinKB.KBNumber)"
    if (($installedKBs -contains $kbId) -and -not (Test-PendingReboot)) {
    Write-Host "Windows cumulative $kbId deja installee (verifie, pas de reboot pending) - skip"
    $mainKbSucceeded = $true
    $updateResults += [PSCustomObject]@{ Label=$kbId; Type="WinCumulative"; Status="DEJA PRESENTE" }
    } else {
    $kbsToInstall += $latestWinKB
    Write-Host "Windows cumulative a installer: $kbId ($($latestWinKB.YearMonth))"
    }
    }
    if ($latestNetKB -and $latestNetKB.KBNumber) {
    $kbId = "KB$($latestNetKB.KBNumber)"
    if ($installedKBs -contains $kbId) {
    Write-Host ".NET Framework $kbId deja installee - skip"
    $updateResults += [PSCustomObject]@{ Label=$kbId; Type="NET"; Status="DEJA PRESENTE" }
    } else {
    $kbsToInstall += $latestNetKB
    Write-Host ".NET Framework a installer: $kbId ($($latestNetKB.YearMonth))"
    }
    }
    if ($kbsToInstall.Count -eq 0) {
    Write-Host "Systeme deja a jour - aucune KB a installer"
    } else {
    Write-Host "$($kbsToInstall.Count) KB(s) a installer (max 2 par groupe)"
    Write-Host "Nettoyage pre-installation..."
    Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
    Remove-Item "C:\Windows\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
    Start-Service wuauserv -ErrorAction SilentlyContinue
    Remove-Item "C:\Windows\Temp\*.tmp" -Force -ErrorAction SilentlyContinue
    $freeGB = [math]::Round((Get-PSDrive C).Free / 1GB, 1)
    Write-Host "Espace disque disponible: $freeGB GB"
    $null = New-Item -Path "C:\Windows\Temp\KBUpdates" -ItemType Directory -Force
    foreach ($kb in $kbsToInstall) {
    $kbLabel = "KB$($kb.KBNumber)"
    $kbType  = if ($kb.IsNet) { "NET" } else { "WinCumulative" }
    Write-Host ""
    Write-Host "=== $kbLabel ($($kb.YearMonth)) ==="
    if ($kb.IsNet) { Write-Host "  Type: .NET Framework" } else { Write-Host "  Type: Windows Cumulative" }
    $urls = Get-MSUDownloadUrl -GUID $kb.GUID
    $downloadUrl = $urls | Where-Object { $_ -match "x64" } | Select-Object -First 1
    if (-not $downloadUrl) { $downloadUrl = $urls | Select-Object -First 1 }
    if (-not $downloadUrl) {
    Write-Host "  URL introuvable pour $kbLabel - ignore"
    $updateResults += [PSCustomObject]@{ Label=$kbLabel; Type=$kbType; Status="ECHEC (URL introuvable)" }
    continue
    }
    $msuPath = "C:\Windows\Temp\KBUpdates\$kbLabel.msu"
    $freeGB = [math]::Round((Get-PSDrive C).Free / 1GB, 1)
    Write-Host "  Espace disque disponible: $freeGB GB"
    if ($freeGB -lt 8) {
    Write-Host "  ATTENTION: Espace disque faible ($freeGB GB) - nettoyage..."
    Remove-Item "C:\Windows\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "C:\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
    $null = New-Item -Path "C:\Windows\Temp\KBUpdates" -ItemType Directory -Force
    $freeGB = [math]::Round((Get-PSDrive C).Free / 1GB, 1)
    Write-Host "  Espace apres nettoyage: $freeGB GB"
    }
    $valid = $false
    foreach ($method in @('BITS','WebClient','IWR')) {
    Remove-Item $msuPath -Force -ErrorAction SilentlyContinue
    Write-Host "  Telechargement via $method..."
    try {
    switch ($method) {
    'BITS' {
    Import-Module BitsTransfer -ErrorAction SilentlyContinue
    Start-BitsTransfer -Source $downloadUrl -Destination $msuPath -TransferType Download -ErrorAction Stop
    }
    'WebClient' {
    (New-Object System.Net.WebClient).DownloadFile($downloadUrl, $msuPath)
    }
    'IWR' {
    Invoke-WebRequest $downloadUrl -OutFile $msuPath -UseBasicParsing -TimeoutSec 3600
    }
    }
    } catch { Write-Host "  $method echec: $_"; continue }
    if (Test-ValidMSU -Path $msuPath -IsNet $kb.IsNet) { $valid = $true; break }
    }
    if (-not $valid) {
    Write-Host "  ECHEC: aucune methode n'a produit un MSU valide pour $kbLabel"
    $updateResults += [PSCustomObject]@{ Label=$kbLabel; Type=$kbType; Status="ECHEC (telechargement invalide)" }
    Remove-Item $msuPath -Force -ErrorAction SilentlyContinue
    continue
    }
    Write-Host "  Installation $kbLabel (peut prendre 20-40 min pour 24H2)..."
    $wusaJob = Start-Job -ScriptBlock {
    param($msu)
    $p = Start-Process "wusa.exe" -ArgumentList "`"$msu`" /quiet /norestart" -Wait -PassThru -NoNewWindow
    return $p.ExitCode
    } -ArgumentList $msuPath
    $maxWait  = 7200; $waited = 0; $exitCode = -1
    while ($waited -lt $maxWait) {
    $jobState = (Get-Job $wusaJob.Id -ErrorAction SilentlyContinue).State
    if ($jobState -eq "Completed") {
    $exitCode = Receive-Job $wusaJob -ErrorAction SilentlyContinue
    if ($null -eq $exitCode) { $exitCode = 0 }
    break
    } elseif ($jobState -eq "Failed" -or $null -eq $jobState) {
    Write-Host "  wusa job echoue ou introuvable"; break
    }
    Start-Sleep 60; $waited += 60
    Write-Host "  Installation en cours... ($waited s ecoules)"
    }
    Remove-Job $wusaJob -Force -ErrorAction SilentlyContinue
    Remove-Item $msuPath -Force -ErrorAction SilentlyContinue
    $claimed = switch ($exitCode) {
    0       { "INSTALLED" }
    3010    { "INSTALLED (reboot requis)" }
    2359302 { "CLAIMED_ALREADY" }
    -1      { "TIMEOUT" }
    default { "FAILED($exitCode)" }
    }
    Write-Host "  wusa code retour: $exitCode -> $claimed"
    if (-not $kb.IsNet) {
    if ($exitCode -in @(0, 3010)) {
    if ($exitCode -eq 3010) {
    $status = "INSTALLEE (reboot requis pour commit)"
    $rebootRequired = $true
    } else {
    $status = "INSTALLEE"
    }
    $mainKbSucceeded = $true
    $lastKBNumber = $kbLabel
    Write-Host "  $kbLabel installee (code $exitCode)"
    } elseif ($exitCode -eq 2359302) {
    $committed = Test-CumulativeCommitted -TargetUBR $mainTargetUBR -BaselineUBR $ubrBefore -BuildNumber $buildBefore
    if ($committed) {
    $status = "DEJA PRESENTE (verifie CBS)"
    $mainKbSucceeded = $true
    $lastKBNumber = $kbLabel
    Write-Host "  $kbLabel confirmee dans le store CBS"
    } else {
    $status = "ECHEC (2359302 mais ABSENTE du store CBS - AMI source corrompue)"
    Write-Host "  VERIFICATION ECHOUEE: $kbLabel signalee installee mais absente -> image invalide"
    }
    } else {
    $status = "ECHEC ($claimed)"
    }
    $updateResults += [PSCustomObject]@{ Label=$kbLabel; Type=$kbType; Status=$status }
    } else {
    if ($exitCode -in @(0, 3010, 2359302)) {
    $status = if ($exitCode -eq 2359302) { "DEJA PRESENTE" } else { "INSTALLEE" }
    } else {
    $status = "ECHEC ($claimed)"
    }
    $updateResults += [PSCustomObject]@{ Label=$kbLabel; Type=$kbType; Status=$status }
    }
    }
    Remove-Item "C:\Windows\Temp\KBUpdates" -Recurse -Force -ErrorAction SilentlyContinue
    }
    }
    Write-Host ""
    Write-Host "Stabilisation Windows Update apres wusa.exe..."
    try {
    $wuPid = (Get-Process TiWorker,MoUsoCoreWorker,UsoClient,wuauclt -ErrorAction SilentlyContinue).Id
    if ($wuPid) { $wuPid | ForEach-Object { taskkill /PID $_ /F 2>$null } }
    } catch {}
    sc.exe stop wuauserv 2>$null | Out-Null
    sc.exe stop bits    2>$null | Out-Null
    Start-Sleep 12
    sc.exe start bits    2>$null | Out-Null
    Start-Sleep 5
    sc.exe start wuauserv 2>$null | Out-Null
    Start-Sleep 20
    Write-Host "Service WU stabilise"
    Write-Host "Recherche mises a jour Defender via Windows Update..."
    try {
    $RegPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
    Remove-ItemProperty -Path $RegPath -Name "TargetReleaseVersion"    -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $RegPath -Name "ProductVersion"           -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $RegPath -Name "TargetReleaseVersionInfo" -ErrorAction SilentlyContinue
    Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
    Start-Sleep 5
    Start-Service wuauserv -ErrorAction SilentlyContinue
    Start-Sleep 20
    $s   = New-Object -ComObject Microsoft.Update.Session
    $r   = $s.CreateUpdateSearcher()
    $r.ServerSelection = 2
    $res = $r.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
    $catalogInstalledKBs = $updateResults | ForEach-Object {
    $m = [regex]::Match($_.Label, "KB(\d{6,})")
    if ($m.Success) { "KB$($m.Groups[1].Value)" }
    } | Where-Object { $_ }
    $wuColl = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $res.Updates) {
    if ($u.Title -match "\d\dH\d") {
    $vm = [regex]::Match($u.Title, "(\d{2})H(\d)")
    if ($vm.Success) {
    $titleVer = [int]$vm.Groups[1].Value * 10 + [int]$vm.Groups[2].Value
    if ($titleVer -gt $currentVersionNum) {
    Write-Host "  [IGNORE feature upgrade]: $($u.Title)"; continue
    }
    }
    }
    $wuKB = [regex]::Match($u.Title, "KB(\d{6,})")
    if ($wuKB.Success -and $catalogInstalledKBs -contains "KB$($wuKB.Groups[1].Value)") {
    Write-Host "  [SKIP deja installee via catalog]: $($u.Title)"; continue
    }
    try { if (-not $u.EulaAccepted) { $u.AcceptEula() } } catch {}
    $wuColl.Add($u) | Out-Null
    Write-Host "  [WU]: $($u.Title)"
    }
    if ($wuColl.Count -gt 0) {
    $dl = $s.CreateUpdateDownloader(); $dl.Updates = $wuColl; $dl.Download() | Out-Null
    $inst = $s.CreateUpdateInstaller(); $inst.Updates = $wuColl
    $instResult = $inst.Install()
    for ($i = 0; $i -lt $wuColl.Count; $i++) {
    $rc = $instResult.GetUpdateResult($i).ResultCode
    $st = switch ($rc) {
    2 { "INSTALLEE" }
    3 { "INSTALLEE (avertissements)" }
    4 { "ECHEC" }
    5 { "ANNULEE" }
    default { "INCONNU($rc)" }
    }
    $updateResults += [PSCustomObject]@{ Label=$wuColl.Item($i).Title; Type="WU"; Status=$st }
    }
    Write-Host "$($wuColl.Count) update(s) WU traitee(s)"
    if ($instResult.RebootRequired) { Write-Host "Redemarrage requis apres updates WU" }
    } else {
    Write-Host "Aucune update WU supplementaire"
    }
    } catch { Write-Host "WU standard: $_" }
    try {
    $verFinal = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").DisplayVersion
    $RegPath  = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
    if (-not (Test-Path $RegPath)) { New-Item -Path $RegPath -Force | Out-Null }
    Set-ItemProperty -Path $RegPath -Name "TargetReleaseVersion"    -Value 1            -Type DWord  -Force
    Set-ItemProperty -Path $RegPath -Name "ProductVersion"           -Value "Windows 11" -Type String -Force
    Set-ItemProperty -Path $RegPath -Name "TargetReleaseVersionInfo" -Value $verFinal    -Type String -Force
    Write-Host "Verrouillage feature upgrade remis sur $verFinal"
    } catch {}
    $verAfter = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").DisplayVersion
    $bldAfter = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").CurrentBuildNumber
    $ubrAfter = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").UBR
    $targetUBR = if ($mainTargetUBR -gt 0) { $mainTargetUBR } else { $ubrAfter }
    $mainWindowsKB = "N/A"
    if ($latestWinKB -and $latestWinKB.KBNumber) {
    $mainWindowsKB = "KB$($latestWinKB.KBNumber)"
    } elseif ($lastKBNumber -ne "") {
    $mainWindowsKB = $lastKBNumber
    }
    $defenderBeforeForJson = $defenderVersionAtStart
    try {
    @{
    LatestKB              = if ($mainWindowsKB -ne "N/A") { $mainWindowsKB } else { "N/A" }
    TargetUBR             = $targetUBR
    BuildNum              = $bldAfter
    DefenderVersionBefore = $defenderBeforeForJson
    RebootRequired        = $rebootRequired
    BaselineUBR           = $ubrBefore
    } | ConvertTo-Json | Out-File "C:\Windows\Temp\vdi_kb_info.json" -Encoding UTF8
    Write-Host "KB info saved: $mainWindowsKB / Build $bldAfter.$targetUBR / Defender before: $defenderBeforeForJson / Reboot: $rebootRequired"
    } catch { Write-Host "Avertissement sauvegarde KB info: $_" }
    Write-Host "UPDATES_SUMMARY_START"
    Write-Host "Systeme : Windows 11 $verAfter (Build $bldAfter.$targetUBR) - $edition"
    Write-Host "MAIN_KB=$mainWindowsKB"
    $installed = $updateResults | Where-Object { $_.Status -match "INSTALL|DEJA PRESENTE" }
    $failed    = $updateResults | Where-Object { $_.Status -match "ECHEC|ANNUL|TIMEOUT" }
    if ($updateResults.Count -gt 0) {
    Write-Host "Mises a jour traitees ($($updateResults.Count)):"
    $updateResults | ForEach-Object { Write-Host "  - $($_.Label) [$($_.Type)] : $($_.Status)" }
    } else {
    Write-Host "Systeme deja a jour - aucune mise a jour a installer"
    }
    $defNow = Get-DefenderSignatureVersion
    if (-not $defNow) { $defNow = "N/A" }
    $defTrans = Get-DefenderTransition
    if ($defTrans) {
    Write-Host "  - Defender definitions : $($defTrans.Previous) -> $($defTrans.Current) [MIS A JOUR]"
    } elseif ($defenderVersionAtStart -ne "N/A" -and $defNow -ne "N/A" -and $defenderVersionAtStart -ne $defNow) {
    Write-Host "  - Defender definitions : $defenderVersionAtStart -> $defNow [MIS A JOUR]"
    } elseif ($defNow -ne "N/A") {
    Write-Host "  - Defender definitions : $defNow (deja a jour)"
    } else {
    Write-Host "  - Defender definitions : version indisponible"
    }
    if ($failed.Count -gt 0) {
    Write-Host "ECHECS detectes ($($failed.Count)):"
    $failed | ForEach-Object { Write-Host "  ! $($_.Label) : $($_.Status)" }
    }
    Write-Host "UPDATES_SUMMARY_END"
    if ($mainKbRequired -and -not $mainKbSucceeded) {
    Write-Host "ECHEC CRITIQUE: KB cumulative principale ($mainWindowsKB) non installee/commitee. Build invalide."
    exit 1
    }
    exit 0
