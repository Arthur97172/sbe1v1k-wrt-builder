# SBE1V1K 恢复模式刷机脚本（Windows / PowerShell 5.1+）
#
# 全程只与本机直连的路由器交换 DHCP / TFTP / SSH 流量，不访问互联网。
# 用户只需要：确认有线网卡、确认要刷的固件；其余地址配置与流程自动化。
#
# 直接双击 flash-sbe1v1k.cmd 即可；命令行参数：
#   .\flash-sbe1v1k.ps1 [-Iface 名称] [-SecondIface 名称] [-Firmware 路径] [-DryRun]

#Requires -Version 5.1
param(
    [string]$Iface = "",
    [string]$SecondIface = "",
    [string]$Firmware = "",
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

try { chcp 65001 | Out-Null } catch { }
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Tool      = Join-Path $ScriptDir 'bin\sbe-flash-tool_windows_amd64.exe'
$Assets    = Join-Path $ScriptDir 'assets'

$RecoveryHostIp = '172.16.252.252'
$RecoveryMask   = '255.255.0.0'
$RecoveryPrefix = 16
$DeviceIp       = '192.168.1.1'
$LanHostIp      = '192.168.1.2'
$LanMask        = '255.255.255.0'
$FirmwareDir    = 'firmware'

# ---------------------------------------------------------------- 输出与交互

function Step($msg) { Write-Host ""; Write-Host "==> $msg" -ForegroundColor White }
function Info($msg) { Write-Host "[信息] $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "[完成] $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "[注意] $msg" -ForegroundColor Yellow }
function Err($msg)  { Write-Host "[错误] $msg" -ForegroundColor Red }

function Die($msg) {
    Err $msg
    $script:Died = $true
    Throw 'abort'
}

function Stop-Clean($code) {
    Invoke-Cleanup
    exit $code
}

function Confirm-Action($question) {
    $ans = Read-Host "$question [y/N]"
    return ($ans -eq 'y' -or $ans -eq 'Y' -or $ans -eq 'yes')
}

function Read-Choice($prompt) {
    return (Read-Host $prompt)
}

# ---------------------------------------------------------------- 管理员权限

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin) -and -not $DryRun) {
    Info "需要管理员权限来配置网络、开放 DHCP/TFTP 端口，正在请求提权…"
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Iface)       { $argList += @('-Iface', "`"$Iface`"") }
    if ($SecondIface) { $argList += @('-SecondIface', "`"$SecondIface`"") }
    if ($Firmware)    { $argList += @('-Firmware', "`"$Firmware`"") }
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList $argList | Out-Null
    } catch {
        Err "提权失败，请右键以管理员身份运行"
    }
    exit
}

# ---------------------------------------------------------------- 环境检查

Step "环境检查"

if (-not (Test-Path $Tool))              { Die "缺少工具程序：$Tool" }
if (-not (Test-Path (Join-Path $Assets 'initramfs.itb'))) { Die "缺少 $Assets\initramfs.itb" }
if (-not (Test-Path (Join-Path $Assets 'rtq7300t_boot_auto_upgrade_fw.img'))) {
    Die "缺少启动器 $Assets\rtq7300t_boot_auto_upgrade_fw.img"
}

$sumsFile = Join-Path $Assets 'SHA256SUMS'
if (Test-Path $sumsFile) {
    $bad = $false
    foreach ($line in Get-Content $sumsFile) {
        if ($line -match '^([0-9a-fA-F]{64})\s+\*?(.+)$') {
            $want = $Matches[1].ToLower()
            $file = Join-Path $Assets $Matches[2].Trim()
            if (-not (Test-Path $file)) { Err "缺少素材：$file"; $bad = $true; continue }
            $got = (Get-FileHash -Algorithm SHA256 -Path $file).Hash.ToLower()
            if ($got -ne $want) { Err "校验失败：$file"; $bad = $true }
        }
    }
    if ($bad) { Die "assets 内有文件损坏，请重新下载整个 openwrt-flash 目录" }
    Ok "assets 校验通过"
}

$toolSums = Join-Path $ScriptDir 'bin\SHA256SUMS'
if (Test-Path $toolSums) {
    $bad = $false
    foreach ($line in Get-Content $toolSums) {
        if ($line -match '^([0-9a-fA-F]{64})\s+\*?(.+)$') {
            $want = $Matches[1].ToLower()
            $file = Join-Path (Join-Path $ScriptDir 'bin') $Matches[2].Trim()
            if ($Matches[2].Trim() -like '*linux*') { continue }
            if (-not (Test-Path $file)) { Err "缺少程序：$file"; $bad = $true; continue }
            $got = (Get-FileHash -Algorithm SHA256 -Path $file).Hash.ToLower()
            if ($got -ne $want) { Err "校验失败：$file"; $bad = $true }
        }
    }
    if ($bad) { Die "辅助工具校验失败，请重新下载整个 openwrt-flash 目录" }
    Ok "辅助工具校验通过"
}

$toolVersion = (& $Tool version) 2>$null
Info "工具版本：$toolVersion"

# ---------------------------------------------------------------- 网卡枚举

function Get-PhysicalEthernetAdapters {
    Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
        Where-Object {
            $_.InterfaceDescription -notmatch 'Wi-?Fi|Wireless|802\.11' -and
            $_.Status -ne 'Not Present'
        }
}

function Show-Adapter($index, $a) {
    $speed = '-'
    if ($a.LinkSpeed) { $speed = $a.LinkSpeed }
    $mac = ($a.MacAddress -replace '-', ':')
    $line = "  {0,2}) {1,-4} {2,-28} {3,-10} {4,-20} {5}" -f $index, $a.Status, $a.Name, $speed, $mac, $a.InterfaceDescription
    Write-Host $line
}

function Select-Adapter($purpose, $preset) {
    $adapters = @(Get-PhysicalEthernetAdapters)
    if ($adapters.Count -eq 0) { Die "没有找到有线网卡（请确认 USB 网卡已插好）" }

    if ($preset) {
        $hit = $adapters | Where-Object { $_.Name -eq $preset }
        if (-not $hit) { Die "网卡 $preset 不存在" }
        return $hit
    }

    $up = @($adapters | Where-Object { $_.Status -eq 'Up' })
    Write-Host ""
    Write-Host "可用的有线网卡（$purpose 用）：" -ForegroundColor White
    $i = 0
    foreach ($a in $adapters) { $i++; Show-Adapter $i $a }
    Write-Host ""

    $defaultIdx = 0
    if ($up.Count -eq 1) {
        $i = 0
        foreach ($a in $adapters) { $i++; if ($a.Name -eq $up[0].Name) { $defaultIdx = $i } }
        Info "只有一张网卡已连接（$($up[0].Name)），默认使用它"
    }

    if ($defaultIdx -gt 0) { $ans = Read-Choice "选择网卡序号 [回车=$defaultIdx]: " ; if (-not $ans) { $ans = "$defaultIdx" } }
    else { $ans = Read-Choice "选择网卡序号: " }

    if ($ans -notmatch '^\d+$') { Die "无效的序号：$ans" }
    $idx = [int]$ans
    if ($idx -lt 1 -or $idx -gt $adapters.Count) { Die "序号超出范围：$idx" }
    return $adapters[$idx - 1]
}

# ---------------------------------------------------------------- 固件选择

function Find-Firmwares {
    # 统一从 firmware\ 文件夹取：自己编译的和别人编译的 sysupgrade 固件都放这里
    $bases = @($ScriptDir, (Split-Path -Parent $ScriptDir), (Get-Location).Path)
    $seen = @{}
    $list = @()
    foreach ($b in $bases) {
        $dir = Join-Path $b $FirmwareDir
        if (-not (Test-Path $dir)) { continue }
        foreach ($f in Get-ChildItem -Path $dir -Filter '*.bin' -File -ErrorAction SilentlyContinue) {
            $key = $f.FullName.ToLower()
            if (-not $seen.ContainsKey($key)) {
                $seen[$key] = $true
                $list += $f
            }
        }
    }
    return $list
}

function Select-FirmwareFile($preset) {
    if ($preset) {
        if (-not (Test-Path $preset)) { Die "固件不存在：$preset" }
        return (Get-Item $preset)
    }

    $list = @(Find-Firmwares)
    if ($list.Count -eq 0) {
        Write-Host ""
        Err "没有找到固件。"
        Write-Host ""
        Write-Host "firmware 文件夹里没有任何 .bin 文件："
        Write-Host "  $(Join-Path $ScriptDir $FirmwareDir)"
        Write-Host ""
        Write-Host "请把 sysupgrade 固件（.bin）放进这个 firmware 文件夹再运行。"
        Write-Host "自己编译的、别人编译的固件都可以，文件名不限。"
        exit 2
    }

    Write-Host ""
    Write-Host "找到以下固件：" -ForegroundColor White
    $i = 0
    foreach ($f in $list) {
        $i++
        $h = (Get-FileHash -Algorithm SHA256 -Path $f.FullName).Hash.ToLower()
        Write-Host ("  {0,2}) {1}" -f $i, $f.FullName)
        Write-Host ("      大小 {0:N1} MiB  sha256 {1}…" -f ($f.Length / 1MB), $h.Substring(0, 16))
    }
    Write-Host ""

    if ($list.Count -eq 1) { $ans = Read-Choice "选择固件序号 [回车=1]: "; if (-not $ans) { $ans = "1" } }
    else { $ans = Read-Choice "选择固件序号: " }

    if ($ans -notmatch '^\d+$') { Die "无效的序号：$ans" }
    $idx = [int]$ans
    if ($idx -lt 1 -or $idx -gt $list.Count) { Die "序号超出范围：$idx" }
    return $list[$idx - 1]
}

# ---------------------------------------------------------------- 网络配置

$script:ChangedAdapters = @{}
$script:RestoreRoute    = $null
$script:FirewallRule    = $null

function Save-AdapterConfig($adapter) {
    $name = $adapter.Name
    if ($script:ChangedAdapters.ContainsKey($name)) { return }

    $iface = Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    $dhcp = $true
    if ($iface -and $iface.Dhcp -eq 'Disabled') { $dhcp = $false }

    $addrs = @(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.PrefixOrigin -ne 'WellKnown' } |
        ForEach-Object { @{ IP = $_.IPAddress; Prefix = $_.PrefixLength } })

    $gw = ''
    $route = Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($route) { $gw = $route.NextHop }

    $dns = @()
    $dnsCfg = Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if ($dnsCfg) { $dns = @($dnsCfg.ServerAddresses) }

    $script:ChangedAdapters[$name] = @{
        Dhcp   = $dhcp
        Addrs  = $addrs
        Gateway = $gw
        Dns    = $dns
    }
}

function Restore-AdapterConfigs {
    foreach ($name in @($script:ChangedAdapters.Keys)) {
        $c = $script:ChangedAdapters[$name]
        try {
            if ($c.Dhcp) {
                netsh interface ipv4 set address name="$name" dhcp | Out-Null
                netsh interface ipv4 set dns name="$name" dhcp | Out-Null
            } else {
                $first = $true
                foreach ($a in $c.Addrs) {
                    $mask = Convert-PrefixToMask $a.Prefix
                    if ($first -and $c.Gateway) {
                        netsh interface ipv4 set address name="$name" static $a.IP $mask $c.Gateway | Out-Null
                    } elseif ($first) {
                        netsh interface ipv4 set address name="$name" static $a.IP $mask | Out-Null
                    } else {
                        netsh interface ipv4 add address name="$name" $a.IP $mask | Out-Null
                    }
                    $first = $false
                }
                if ($c.Dns.Count -gt 0) {
                    netsh interface ipv4 set dns name="$name" static $c.Dns[0] | Out-Null
                    for ($j = 1; $j -lt $c.Dns.Count; $j++) {
                        netsh interface ipv4 add dns name="$name" $c.Dns[$j] index=$($j + 1) | Out-Null
                    }
                }
            }
            Info "已恢复网卡 $name 的原有配置"
        } catch {
            Warn "恢复网卡 $name 配置时出错：$($_.Exception.Message)"
        }
    }
    $script:ChangedAdapters = @{}
}

function Convert-PrefixToMask($prefix) {
    $mask = 0
    for ($b = 0; $b -lt $prefix; $b++) { $mask = $mask -bor (1 -shl (31 - $b)) }
    return ([IPAddress]$mask).ToString()
}

function Set-AdapterStatic($adapter, $ip, $mask) {
    Save-AdapterConfig $adapter
    if ($DryRun) {
        Info "[演练] netsh interface ipv4 set address name=`"$($adapter.Name)`" static $ip $mask"
        return
    }
    netsh interface ipv4 set address name="$($adapter.Name)" static $ip $mask | Out-Null
    if ($LASTEXITCODE -ne 0) { Die "给 $($adapter.Name) 配置 $ip 失败" }
}

function Remove-StaticAddress($adapter, $ip) {
    if ($DryRun) { return }
    try {
        Remove-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $ip -Confirm:$false -ErrorAction SilentlyContinue
    } catch { }
}

function Ensure-FirewallRule {
    if ($DryRun) { return }
    if ($script:FirewallRule) { return }
    $name = 'SBE1V1K Flash Tool (temporary)'
    try {
        Remove-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue
        New-NetFirewallRule -DisplayName $name -Direction Inbound -Program $Tool `
            -Protocol UDP -LocalPort 67,69 -Action Allow -Profile Any -ErrorAction Stop | Out-Null
        $script:FirewallRule = $name
    } catch {
        Warn "创建防火墙规则失败（$($_.Exception.Message)），如果设备收不到地址请手动放行 UDP 67/69"
    }
}

function Remove-FirewallRule {
    if ($script:FirewallRule) {
        Remove-NetFirewallRule -DisplayName $script:FirewallRule -ErrorAction SilentlyContinue
        $script:FirewallRule = $null
    }
}

function Ensure-SshRoute($adapter) {
    if ($DryRun) {
        Info "[演练] New-NetRoute 192.168.1.1/32 via $($adapter.Name)"
        return
    }
    Remove-NetRoute -DestinationPrefix "$DeviceIp/32" -Confirm:$false -ErrorAction SilentlyContinue
    New-NetRoute -DestinationPrefix "$DeviceIp/32" -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop | Out-Null
    $script:RestoreRoute = $true
}

function Remove-SshRoute {
    if ($script:RestoreRoute) {
        Remove-NetRoute -DestinationPrefix "$DeviceIp/32" -Confirm:$false -ErrorAction SilentlyContinue
        $script:RestoreRoute = $null
    }
}

function Invoke-Cleanup {
    try { Remove-SshRoute } catch { }
    try { Restore-AdapterConfigs } catch { }
    try { Remove-FirewallRule } catch { }
}

function Run-Tool([string[]]$toolArgs) {
    # 输出直接上屏（Out-Host），返回值只保留退出码，避免被输出内容污染
    & $Tool @toolArgs | Out-Host
    return $LASTEXITCODE
}

function Run-ToolCapture([string[]]$toolArgs) {
    # 需要解析输出时用：先上屏，再把输出与退出码一起返回
    $text = (& $Tool @toolArgs 2>&1 | Out-String)
    $code = $LASTEXITCODE
    Write-Host $text.TrimEnd()
    return @{ Code = $code; Text = $text }
}

function Get-RevFromText($text) {
    if ($text -match '(?m)^\s+REV=(\S+)\s*$') { return $Matches[1] }
    return ''
}

# ---------------------------------------------------------------- 主流程

function Show-Banner {
    Write-Host ""
    Write-Host "========================================================" -ForegroundColor White
    Write-Host "  SBE1V1K 恢复模式刷机工具（Windows）"
    Write-Host "  离线运行：只与本机直连的路由器通信"
    Write-Host "========================================================" -ForegroundColor White
    Write-Host ""
    Write-Host "将要做的事："
    Write-Host "  1. 本机临时地址 $RecoveryHostIp/$RecoveryPrefix，提供 DHCP + TFTP"
    Write-Host "  2. 引导路由器进入恢复模式（RAM 系统，不写 eMMC）"
    Write-Host "  3. 通过 SSH 上传你选的固件并核对 sha256"
    Write-Host "  4. 执行 sysupgrade -F -n（不保留旧配置）"
    Write-Host ""
    Write-Host "请先确认：" -ForegroundColor Yellow
    Write-Host "  - 路由器的 2.5G LAN1 口用网线直连本机所选网卡"
    Write-Host "  - 本机没有其他网卡占用 $RecoveryHostIp/$RecoveryPrefix 或 192.168.1.x 网段"
    Write-Host "  - 刷写期间不要断电"
    Write-Host "  - 如果本机有多个已连接网卡，建议先临时禁用其余网卡"
    Write-Host ""
    if ($DryRun) {
        Warn "演练模式：不会修改网络，也不会启动刷机工具"
    } elseif (-not (Confirm-Action "确认继续？")) {
        Info "已取消"
        exit 0
    }
}

function Check-FirmwareFile($file) {
    if ($file.Length -lt 8MB) {
        Warn ("固件只有 {0:N0} MiB，偏小，请确认选对了文件" -f ($file.Length / 1MB))
    }
    $fs = [System.IO.File]::OpenRead($file.FullName)
    try {
        $buf = New-Object byte[] 4
        $null = $fs.Read($buf, 0, 4)
    } finally { $fs.Close() }
    $magic = ($buf | ForEach-Object { $_.ToString('x2') }) -join ''
    if ($magic -ne 'd00dfeed') {
        Warn "固件头部不是 FIT 格式（实际：$magic），可能不是 SBE1V1K 的 sysupgrade 镜像"
        if (-not (Confirm-Action "仍要继续？")) { exit 0 }
    }
}

function Main {
    Show-Banner

    Step "选择刷机网卡（连路由器 2.5G LAN1 口的那张）"
    $adapter = Select-Adapter "刷机网卡" $Iface
    Ok "刷机网卡：$($adapter.Name)（$($adapter.MacAddress)）"
    if ($adapter.Status -ne 'Up') {
        Warn "这张网卡当前没有检测到连接（网线没插或对端没上电）"
        if (-not (Confirm-Action "仍然继续？")) { exit 0 }
    }

    $adapter2 = $null
    if ($SecondIface) {
        $adapter2 = Select-Adapter "刷写后继续" $SecondIface
        if ($adapter2.Name -eq $adapter.Name) { Die "-SecondIface 不能与 -Iface 相同" }
        Ok "刷写后继续使用的网卡：$($adapter2.Name)"
        Info "请把第二根网线连到路由器的 10G 口或 1G LAN 口，刷写后从这里继续"
    }

    Step "选择固件"
    $fw = Select-FirmwareFile $Firmware
    Ok "固件：$($fw.FullName)"
    $fwHash = (Get-FileHash -Algorithm SHA256 -Path $fw.FullName).Hash.ToLower()
    Write-Host "  sha256 $fwHash"
    Check-FirmwareFile $fw
    if (-not $DryRun -and -not (Confirm-Action "使用这个固件刷写？")) { Info "已取消"; exit 0 }

    # ---------------- 阶段 A
    Step "阶段 A：进入恢复模式"
    Ensure-FirewallRule
    Set-AdapterStatic $adapter $RecoveryHostIp $RecoveryMask

    if ($DryRun) {
        Info "[演练] & `"$Tool`" serve --iface `"$($adapter.Name)`" --ip $RecoveryHostIp --root `"$Assets`" --timeout 900s"
    } else {
        Write-Host ""
        Write-Host "──────────────── 请按下面操作 ────────────────" -ForegroundColor White
        Write-Host "  1. 把路由器断电（拔电源）"
        Write-Host "  2. 按住 Reset 键不放"
        Write-Host "  3. 插上电源，继续保持按住"
        Write-Host "  4. 大约 12 秒后松开 Reset"
        Write-Host "──────────────────────────────────────────────" -ForegroundColor White
        Write-Host ""

        $rc = Run-Tool @('serve', '--iface', "$($adapter.Name)", '--ip', $RecoveryHostIp,
                         '--root', $Assets, '--expect', 'initramfs.itb', '--timeout', '900s')
        switch ($rc) {
            0   { Ok "恢复系统已通过 TFTP 载入，正在启动" }
            4   { Die "15 分钟内没有等到路由器请求启动文件。请确认：网线插在 2.5G LAN1 口；Reset 按住够 12 秒；然后重新运行本脚本" }
            130 { Info "已取消"; Stop-Clean 0 }
            default { Die "DHCP/TFTP 服务异常退出（$rc）" }
        }
    }

    # ---------------- 阶段 B
    Step "阶段 B：登录恢复系统"
    $bAdapter = $adapter
    if ($adapter2) { $bAdapter = $adapter2 }

    if (-not $adapter2) {
        if (-not $DryRun) { Remove-StaticAddress $adapter $RecoveryHostIp }
    }
    Set-AdapterStatic $bAdapter $LanHostIp $LanMask
    Ensure-SshRoute $bAdapter

    Info "等待恢复系统 SSH 就绪（约 5–30 秒）…"
    $preRev = ''
    if ($DryRun) {
        Info "[演练] & `"$Tool`" wait --local $LanHostIp --timeout 300s"
    } else {
        $rc = Run-Tool @('wait', '--local', $LanHostIp, '--timeout', '300s')
        if ($rc -ne 0) { Die "恢复系统没有在预期时间内上线" }
        $r = Run-ToolCapture @('check', '--expect', 'ram')
        if ($r.Code -eq 3) { Die "设备指纹不符，为安全起见停止。请确认刷的是 SBE1V1K" }
        if ($r.Code -ne 0) { Die "读取设备信息失败" }
        $preRev = Get-RevFromText $r.Text
    }

    # ---------------- 上传与刷写
    Step "上传固件"
    if ($DryRun) {
        Info "[演练] & `"$Tool`" push --local $LanHostIp --src `"$($fw.FullName)`""
        Info "[演练] & `"$Tool`" sysupgrade --local $LanHostIp"
    } else {
        $rc = Run-Tool @('push', '--local', $LanHostIp, '--src', $fw.FullName)
        if ($rc -ne 0) { Die "上传或校验失败，未做任何写入" }

        Write-Host ""
        Warn "下一步将执行 sysupgrade，写入 eMMC 并重启路由器"
        Warn "使用 -n：设备上的旧配置会全部丢失（Wi-Fi、密码、插件设置）"
        if (-not (Confirm-Action "确认开始刷写？")) {
            Info "已取消（设备仍处于恢复模式，断电重启即可恢复原固件）"
            Stop-Clean 0
        }

        Step "刷写中"
        $rc = Run-Tool @('sysupgrade', '--local', $LanHostIp)
        if ($rc -ne 0) { Die "sysupgrade 启动失败（设备可能未重启）" }

        Step "等待新固件启动"
        if (-not $adapter2) {
            Write-Host ""
            Write-Host "════════════ 现在请换线 ════════════" -ForegroundColor White
            Write-Host "  路由器 2.5G 口刷机后变成 WAN 口，不再有 $DeviceIp。"
            Write-Host "  请把网线从 2.5G LAN1 移到路由器上的 10G 口或 1G LAN 口，"
            Write-Host "  保持插在本机网卡 $($adapter.Name) 上。"
            Write-Host "════════════════════════════════════" -ForegroundColor White
            Write-Host ""
            $null = Confirm-Action "已经换好线了吗？（确认后继续等待）"
        } else {
            Info "等待 10G/LAN 口（$($adapter2.Name)）上的新系统…"
        }

        while ($true) {
            $rc = Run-Tool @('wait', '--local', $LanHostIp, '--timeout', '420s')
            if ($rc -eq 0) { break }
            Warn "4 分钟内没有连上新系统"
            Info "如果还没换线，请换好线后按回车重试；输入 q 结束"
            $ans = Read-Choice "回车重试 / q 结束: "
            if ($ans -eq 'q') { Die "已放弃等待（固件可能已经刷写成功，可手动访问 $DeviceIp 检查）" }
        }

        $r = Run-ToolCapture @('check', '--expect', 'firmware')
        if ($r.Code -eq 3) {
            Err "设备能登录，但指纹显示不是从 eMMC 启动的新固件"
            Info "可能进入了原厂系统。请记录以上信息并回报"
            Stop-Clean 3
        }
        if ($r.Code -ne 0) { Die "核对新固件失败" }
        $postRev = Get-RevFromText $r.Text
        if ($preRev -and ($preRev -eq $postRev)) {
            Warn "版本指纹与刷写前的恢复系统完全相同（$postRev），可能没有真正写入新固件"
            Warn "历史上出现过 sysupgrade 静默不生效的情况，请核对版本后再使用"
        }
        Ok "刷写完成：新固件已从 eMMC 启动"
    }

    Step "收尾"
    if (-not $DryRun) {
        Remove-SshRoute
        Restore-AdapterConfigs
        Remove-FirewallRule
        Write-Host ""
        Ok "全部完成"
        Info "本机网络配置已恢复"
        Info "设备地址：http://$DeviceIp（root 无密码，未保留旧配置）"
        Info "如果设备改了 LAN 网段或密码，请按新配置访问"
    } else {
        Ok "演练结束：以上为将要执行的步骤"
    }
}

try {
    Main
} catch {
    if (-not $script:Died) { Err $_.Exception.Message }
    Invoke-Cleanup
    exit 2
}

if (-not $DryRun) { Invoke-Cleanup }
exit 0
