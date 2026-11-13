Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$Cs = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class DH {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DD {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dn;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string ds;
        public int sf;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string di;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string dk;
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool EnumDisplayDevices(string l, uint i, ref DD d, uint f);
    public static Dictionary<string, int> Get() {
        var m = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        DD d = new DD(); d.cb = Marshal.SizeOf(d); int a = 1;
        for (uint id = 0; EnumDisplayDevices(null, id, ref d, 0); id++) {
            if ((d.sf & 1) != 0) { m[d.dn] = a; a++; }
            d.cb = Marshal.SizeOf(d);
        }
        return m;
    }
}
'@
Add-Type -TypeDefinition $Cs -ErrorAction SilentlyContinue
$WinMap = @{}
try { $WinMap = [DH]::Get() } catch {}

# Echte mstsc Monitor-IDs & Koordinaten direkt aus mstsc /l lesen
$OutFile = "$env:TEMP\mstsc_l.txt"
$P = Start-Process "mstsc.exe" "/l" -RedirectStandardOutput $OutFile -NoNewWindow -PassThru -ErrorAction SilentlyContinue
if ($P) { $null = $P.WaitForExit(1500); if (-not $P.HasExited) { $P.Kill() } }
$RdpMap = @{}
if (Test-Path $OutFile) {
    Get-Content $OutFile | ForEach-Object {
        $t = $_.Trim(); $c = $t.IndexOf(':'); $o = $t.IndexOf('('); $e = $t.IndexOf(')')
        if ($c -gt 0 -and $o -gt $c -and $e -gt $o) {
            $xy = $t.Substring($o + 1, $e - $o - 1).Split(',')
            if ($xy.Count -ge 2) { $RdpMap["$($xy[0].Trim()),$($xy[1].Trim())"] = [int]$t.Substring(0, $c).Trim() }
        }
    }
    Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
}

$Mons = foreach ($S in [System.Windows.Forms.Screen]::AllScreens) {
    $k = "$($S.Bounds.X),$($S.Bounds.Y)"
    $id = if ($RdpMap.ContainsKey($k)) { $RdpMap[$k] } elseif ($S.DeviceName -match 'DISPLAY(\d+)') { ([int]$Matches[1]) - 1 } else { 0 }
    $wn = if ($WinMap.ContainsKey($S.DeviceName)) { $WinMap[$S.DeviceName] } else { $id + 1 }
    [PSCustomObject]@{ RdpId = $id; WinNum = $wn; W = $S.Bounds.Width; H = $S.Bounds.Height; Px = ($S.Bounds.Width * $S.Bounds.Height); X = $S.Bounds.X; Y = $S.Bounds.Y; Pri = $S.Primary }
}
$Mons = @($Mons | Sort-Object X, Y)
$Sig = "$($Mons.Count)|" + (($Mons | ForEach-Object { "$($_.RdpId)@$($_.X),$($_.Y):$($_.W)x$($_.H)" }) -join ';')

function Start-Rdp([string]$Ids, [int]$Cnt) {
    $mm = if ($Cnt -gt 1) { 1 } else { 0 }
    $rdp = @(
        'screen mode id:i:2',
        "use multimon:i:$mm",
        "selectedmonitors:s:$Ids",
        'smart sizing:i:0',
        'dynamic resolution:i:1',
        'redirectclipboard:i:1',
        'redirectprinters:i:1',
        'redirectcomports:i:0',
        'redirectsmartcards:i:0',
        'redirectwebauthn:i:0',
        'devicestoredirect:s:',
        'drivestoredirect:s:*',
        'redirectdrives:i:1',
        'session bpp:i:32',
        'prompt for credentials on client:i:1',
        'server port:i:3389',
        'allow font smoothing:i:1',
        'promptcredentialonce:i:1',
        'authentication level:i:2',
        'gatewayusagemethod:i:1',
        'gatewayprofileusagemethod:i:1',
        'gatewaycredentialssource:i:0',
        'full address:s:HSGVMLICENSINGRDS.GMBHWILLICH.LOCAL',
        'gatewayhostname:s:rds.huesges-gutachter.de',
        'workspace id:s:HSGVMLicensingRDS.gmbhwillich.local',
        'use redirection server name:i:1',
        'loadbalanceinfo:s:tsv://MS Terminal Services Plugin.1.Hsges_Group_Mor',
        'alternate full address:s:HSGVMLICENSINGRDS.GMBHWILLICH.LOCAL',
        'enablecredsspsupport:i:1',
        'domain:s:GMBHWILLICH'
    )
    $dir = "$env:APPDATA\Huesges"
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $file = "$dir\Huesges_Morpheus_Session.rdp"
    Set-Content -Path $file -Value ($rdp -join "`r`n") -Encoding Unicode -Force

    $cert = Get-ChildItem 'Cert:\LocalMachine\My' -ErrorAction SilentlyContinue | Where-Object { $_.Subject -eq 'CN=Huesges Gruppe RDP' } | Select-Object -First 1
    if ($cert -and (Test-Path "$env:SystemRoot\System32\rdpsign.exe")) {
        Start-Process "$env:SystemRoot\System32\rdpsign.exe" -ArgumentList "/sha256 $($cert.Thumbprint) `"$file`"" -Wait -WindowStyle Hidden
    }
    Start-Process 'mstsc.exe' -ArgumentList "`"$file`""
}

$CfgFile = "$env:APPDATA\Huesges\monitors_v3.txt"
$Shift = ([System.Windows.Forms.Control]::ModifierKeys -band [System.Windows.Forms.Keys]::Shift) -eq [System.Windows.Forms.Keys]::Shift
if ((Test-Path $CfgFile) -and (-not $Shift)) {
    $p = (Get-Content $CfgFile -Raw).Trim() -split '\|\|'
    if ($p.Count -eq 2 -and $p[0] -eq $Sig -and $p[1]) {
        Start-Rdp $p[1] ($p[1] -split ',').Count
        exit
    }
}

$Pre = @($Mons | Sort-Object @{E = { $_.Px }; D = $true }, @{E = { if ($_.WinNum -gt 1) { 1 } else { 0 } }; D = $true }, @{E = { $_.X }; D = $true } | Select-Object -First 2 | ForEach-Object { $_.RdpId })

$F = New-Object System.Windows.Forms.Form
$F.Text = 'Huesges Morpheus Multiscreen'
$F.Size = New-Object System.Drawing.Size(470, (240 + ($Mons.Count * 34)))
$F.StartPosition = 'CenterScreen'
$F.FormBorderStyle = 'FixedDialog'
$F.MaximizeBox = $false
$F.MinimizeBox = $false
$F.TopMost = $true
if (Test-Path 'C:\ProgramData\Huesges\huesges-morpheus.ico') { $F.Icon = New-Object System.Drawing.Icon('C:\ProgramData\Huesges\huesges-morpheus.ico') }

$L = New-Object System.Windows.Forms.Label
$L.Location = '20,15'
$L.Size = '425,38'
$L.Text = 'Bitte 1 oder 2 Bildschirme auswaehlen (von links nach rechts):'
$L.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
$F.Controls.Add($L)

$Cbs = @()
for ($i = 0; $i -lt $Mons.Count; $i++) {
    $m = $Mons[$i]
    $pos = if ($Mons.Count -eq 1) { 'Einzeln' } elseif ($i -eq 0) { 'Links' } elseif ($i -eq ($Mons.Count - 1)) { 'Rechts' } else { 'Mitte' }
    $pri = if ($m.Pri) { ' [Hauptanzeige]' } else { '' }
    $cb = New-Object System.Windows.Forms.CheckBox
    $cb.Location = "25,$(60 + ($i * 34))"
    $cb.Size = '420,28'
    $cb.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $cb.Text = "Bildschirm $($m.WinNum) ($pos) - $($m.W)x$($m.H)$pri"
    $cb.Tag = $m.RdpId
    if ($Pre -contains $m.RdpId) { $cb.Checked = $true }
    $F.Controls.Add($cb)
    $Cbs += $cb
}

$Rem = New-Object System.Windows.Forms.CheckBox
$Rem.Location = "25,$(72 + ($Mons.Count * 34))"
$Rem.Size = '420,24'
$Rem.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
$Rem.Text = 'Auswahl merken (Umschalt-Taste beim Start zum Aendern)'
$Rem.Checked = $true
$F.Controls.Add($Rem)

$BtnId = New-Object System.Windows.Forms.Button
$BtnId.Location = "25,$(112 + ($Mons.Count * 34))"
$BtnId.Size = '175,34'
$BtnId.Text = 'Bildschirme identifizieren'
$BtnId.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$BtnId.Add_Click({
    $osds = foreach ($m in $Mons) {
        $o = New-Object System.Windows.Forms.Form
        $o.FormBorderStyle = 'None'
        $o.StartPosition = 'Manual'
        $o.Location = "$($m.X + 40),$($m.Y + 40)"
        $o.Size = '140,110'
        $o.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
        $o.TopMost = $true
        $o.ShowInTaskbar = $false
        $lb = New-Object System.Windows.Forms.Label
        $lb.Dock = 'Fill'
        $lb.TextAlign = 'MiddleCenter'
        $lb.ForeColor = 'White'
        $lb.Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$Cs = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class DH {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DD {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dn;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string ds;
        public int sf;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string di;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string dk;
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool EnumDisplayDevices(string l, uint i, ref DD d, uint f);
    public static Dictionary<string, int> Get() {
        var m = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        DD d = new DD(); d.cb = Marshal.SizeOf(d); int a = 1;
        for (uint id = 0; EnumDisplayDevices(null, id, ref d, 0); id++) {
            if ((d.sf & 1) != 0) { m[d.dn] = a; a++; }
            d.cb = Marshal.SizeOf(d);
        }
        return m;
    }
}
'@
Add-Type -TypeDefinition $Cs -ErrorAction SilentlyContinue
$WinMap = @{}
try { $WinMap = [DH]::Get() } catch {}

# Echte mstsc Monitor-IDs & Koordinaten direkt aus mstsc /l lesen
$OutFile = "$env:TEMP\mstsc_l.txt"
$P = Start-Process "mstsc.exe" "/l" -RedirectStandardOutput $OutFile -NoNewWindow -PassThru -ErrorAction SilentlyContinue
if ($P) { $null = $P.WaitForExit(1500); if (-not $P.HasExited) { $P.Kill() } }
$RdpMap = @{}
if (Test-Path $OutFile) {
    Get-Content $OutFile | ForEach-Object {
        $t = $_.Trim(); $c = $t.IndexOf(':'); $o = $t.IndexOf('('); $e = $t.IndexOf(')')
        if ($c -gt 0 -and $o -gt $c -and $e -gt $o) {
            $xy = $t.Substring($o + 1, $e - $o - 1).Split(',')
            if ($xy.Count -ge 2) { $RdpMap["$($xy[0].Trim()),$($xy[1].Trim())"] = [int]$t.Substring(0, $c).Trim() }
        }
    }
    Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
}

$Mons = foreach ($S in [System.Windows.Forms.Screen]::AllScreens) {
    $k = "$($S.Bounds.X),$($S.Bounds.Y)"
    $id = if ($RdpMap.ContainsKey($k)) { $RdpMap[$k] } elseif ($S.DeviceName -match 'DISPLAY(\d+)') { ([int]$Matches[1]) - 1 } else { 0 }
    $wn = if ($WinMap.ContainsKey($S.DeviceName)) { $WinMap[$S.DeviceName] } else { $id + 1 }
    [PSCustomObject]@{ RdpId = $id; WinNum = $wn; W = $S.Bounds.Width; H = $S.Bounds.Height; Px = ($S.Bounds.Width * $S.Bounds.Height); X = $S.Bounds.X; Y = $S.Bounds.Y; Pri = $S.Primary }
}
$Mons = @($Mons | Sort-Object X, Y)
$Sig = "$($Mons.Count)|" + (($Mons | ForEach-Object { "$($_.RdpId)@$($_.X),$($_.Y):$($_.W)x$($_.H)" }) -join ';')

function Start-Rdp([string]$Ids, [int]$Cnt) {
    $mm = if ($Cnt -gt 1) { 1 } else { 0 }
    $rdp = @(
        'screen mode id:i:2',
        "use multimon:i:$mm",
        "selectedmonitors:s:$Ids",
        'smart sizing:i:0',
        'dynamic resolution:i:1',
        'redirectclipboard:i:1',
        'redirectprinters:i:1',
        'redirectcomports:i:0',
        'redirectsmartcards:i:0',
        'redirectwebauthn:i:0',
        'devicestoredirect:s:',
        'drivestoredirect:s:*',
        'redirectdrives:i:1',
        'session bpp:i:32',
        'prompt for credentials on client:i:1',
        'server port:i:3389',
        'allow font smoothing:i:1',
        'promptcredentialonce:i:1',
        'authentication level:i:2',
        'gatewayusagemethod:i:1',
        'gatewayprofileusagemethod:i:1',
        'gatewaycredentialssource:i:0',
        'full address:s:HSGVMLICENSINGRDS.GMBHWILLICH.LOCAL',
        'gatewayhostname:s:rds.huesges-gutachter.de',
        'workspace id:s:HSGVMLicensingRDS.gmbhwillich.local',
        'use redirection server name:i:1',
        'loadbalanceinfo:s:tsv://MS Terminal Services Plugin.1.Hsges_Group_Mor',
        'alternate full address:s:HSGVMLICENSINGRDS.GMBHWILLICH.LOCAL',
        'enablecredsspsupport:i:1',
        'domain:s:GMBHWILLICH'
    )
    $dir = "$env:APPDATA\Huesges"
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $file = "$dir\Huesges_Morpheus_Session.rdp"
    Set-Content -Path $file -Value ($rdp -join "`r`n") -Encoding Unicode -Force

    $cert = Get-ChildItem 'Cert:\LocalMachine\My' -ErrorAction SilentlyContinue | Where-Object { $_.Subject -eq 'CN=Huesges Gruppe RDP' } | Select-Object -First 1
    if ($cert -and (Test-Path "$env:SystemRoot\System32\rdpsign.exe")) {
        Start-Process "$env:SystemRoot\System32\rdpsign.exe" -ArgumentList "/sha256 $($cert.Thumbprint) `"$file`"" -Wait -WindowStyle Hidden
    }
    Start-Process 'mstsc.exe' -ArgumentList "`"$file`""
}

$CfgFile = "$env:APPDATA\Huesges\monitors_v3.txt"
$Shift = ([System.Windows.Forms.Control]::ModifierKeys -band [System.Windows.Forms.Keys]::Shift) -eq [System.Windows.Forms.Keys]::Shift
if ((Test-Path $CfgFile) -and (-not $Shift)) {
    $p = (Get-Content $CfgFile -Raw).Trim() -split '\|\|'
    if ($p.Count -eq 2 -and $p[0] -eq $Sig -and $p[1]) {
        Start-Rdp $p[1] ($p[1] -split ',').Count
        exit
    }
}

$Pre = @($Mons | Sort-Object @{E = { $_.Px }; D = $true }, @{E = { if ($_.WinNum -gt 1) { 1 } else { 0 } }; D = $true }, @{E = { $_.X }; D = $true } | Select-Object -First 2 | ForEach-Object { $_.RdpId })

$F = New-Object System.Windows.Forms.Form
$F.Text = 'Huesges Morpheus Multiscreen'
$F.Size = New-Object System.Drawing.Size(470, (240 + ($Mons.Count * 34)))
$F.StartPosition = 'CenterScreen'
$F.FormBorderStyle = 'FixedDialog'
$F.MaximizeBox = $false
$F.MinimizeBox = $false
$F.TopMost = $true
if (Test-Path 'C:\ProgramData\Huesges\huesges-morpheus.ico') { $F.Icon = New-Object System.Drawing.Icon('C:\ProgramData\Huesges\huesges-morpheus.ico') }

$L = New-Object System.Windows.Forms.Label
$L.Location = '20,15'
$L.Size = '425,38'
$L.Text = 'Bitte 1 oder 2 Bildschirme auswaehlen (von links nach rechts):'
$L.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
$F.Controls.Add($L)

$Cbs = @()
for ($i = 0; $i -lt $Mons.Count; $i++) {
    $m = $Mons[$i]
    $pos = if ($Mons.Count -eq 1) { 'Einzeln' } elseif ($i -eq 0) { 'Links' } elseif ($i -eq ($Mons.Count - 1)) { 'Rechts' } else { 'Mitte' }
    $pri = if ($m.Pri) { ' [Hauptanzeige]' } else { '' }
    $cb = New-Object System.Windows.Forms.CheckBox
    $cb.Location = "25,$(60 + ($i * 34))"
    $cb.Size = '420,28'
    $cb.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $cb.Text = "Bildschirm $($m.WinNum) ($pos) - $($m.W)x$($m.H)$pri"
    $cb.Tag = $m.RdpId
    if ($Pre -contains $m.RdpId) { $cb.Checked = $true }
    $F.Controls.Add($cb)
    $Cbs += $cb
}

$Rem = New-Object System.Windows.Forms.CheckBox
$Rem.Location = "25,$(72 + ($Mons.Count * 34))"
$Rem.Size = '420,24'
$Rem.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
$Rem.Text = 'Auswahl merken (Umschalt-Taste beim Start zum Aendern)'
$Rem.Checked = $true
$F.Controls.Add($Rem)

$BtnId = New-Object System.Windows.Forms.Button
$BtnId.Location = "25,$(112 + ($Mons.Count * 34))"
$BtnId.Size = '175,34'
$BtnId.Text = 'Bildschirme identifizieren'
$BtnId.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$BtnId.Add_Click({
    $osds = foreach ($m in $Mons) {
        $o = New-Object System.Windows.Forms.Form
        $o.FormBorderStyle = 'None'
        $o.StartPosition = 'Manual'
        $o.Location = "$($m.X + 40),$($m.Y + 40)"
        $o.Size = '140,110'
        $o.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
        $o.TopMost = $true
        $o.ShowInTaskbar = $false
        $lb = New-Object System.Windows.Forms.Label
        $lb.Dock = 'Fill'
        $lb.TextAlign = 'MiddleCenter'
        $lb.ForeColor = 'White'
        $lb.Font = New-Object System.Drawing.Font('Segoe UI', 36, [System.Drawing.FontStyle]::Bold)
        $lb.Text = "$($m.WinNum)"
        $o.Controls.Add($lb)
        $o.Show()
        $o
    }
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Seconds 2
    foreach ($o in $osds) { $o.Close(); $o.Dispose() }
})
$F.Controls.Add($BtnId)

$BtnGo = New-Object System.Windows.Forms.Button
$BtnGo.Location = "215,$(112 + ($Mons.Count * 34))"
$BtnGo.Size = '225,34'
$BtnGo.Text = 'Verbinden'
$BtnGo.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
$BtnGo.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$BtnGo.ForeColor = 'White'
$BtnGo.FlatStyle = 'Flat'
$BtnGo.Add_Click({
    $sel = @($Cbs | Where-Object { $_.Checked })
    if ($sel.Count -eq 0 -or $sel.Count -gt 2) {
        [System.Windows.Forms.MessageBox]::Show('Bitte 1 oder 2 Bildschirme auswaehlen.', 'Hinweis', 'OK', 'Warning')
        return
    }
    $ids = ($sel | Sort-Object { $_.Location.Y } | ForEach-Object { $_.Tag }) -join ','
    if ($Rem.Checked) {
        if (-not (Test-Path "$env:APPDATA\Huesges")) { New-Item -ItemType Directory -Path "$env:APPDATA\Huesges" -Force | Out-Null }
        Set-Content -Path $CfgFile -Value "$Sig||$ids" -Encoding ASCII -Force
    } else {
        Remove-Item $CfgFile -Force -ErrorAction SilentlyContinue
    }
    Start-Rdp $ids $sel.Count
    $F.Close()
})
$F.Controls.Add($BtnGo)
$F.AcceptButton = $BtnGo
[void]$F.ShowDialog()Font = New-Object System.Drawing.Font('Segoe UI', 36, [System.Drawing.FontStyle]::Bold)
        $lb.Text = "$($m.WinNum)"
        $o.Controls.Add($lb)
        $o.Show()
        $o
    }
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Seconds 2
    foreach ($o in $osds) { $o.Close(); $o.Dispose() }
})
$F.Controls.Add($BtnId)

$BtnGo = New-Object System.Windows.Forms.Button
$BtnGo.Location = "215,$(112 + ($Mons.Count * 34))"
$BtnGo.Size = '225,34'
$BtnGo.Text = 'Verbinden'
$BtnGo.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
$BtnGo.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$BtnGo.ForeColor = 'White'
$BtnGo.FlatStyle = 'Flat'
$BtnGo.Add_Click({
    $sel = @($Cbs | Where-Object { $_.Checked })
    if ($sel.Count -eq 0 -or $sel.Count -gt 2) {
        [System.Windows.Forms.MessageBox]::Show('Bitte 1 oder 2 Bildschirme auswaehlen.', 'Hinweis', 'OK', 'Warning')
        return
    }
    $ids = ($sel | Sort-Object { $_.Location.Y } | ForEach-Object { $_.Tag }) -join ','
    if ($Rem.Checked) {
        if (-not (Test-Path "$env:APPDATA\Huesges")) { New-Item -ItemType Directory -Path "$env:APPDATA\Huesges" -Force | Out-Null }
        Set-Content -Path $CfgFile -Value "$Sig||$ids" -Encoding ASCII -Force
    } else {
        Remove-Item $CfgFile -Force -ErrorAction SilentlyContinue
    }
    Start-Rdp $ids $sel.Count
    $F.Close()
})
$F.Controls.Add($BtnGo)
$F.AcceptButton = $BtnGo
[void]$F.ShowDialog()
