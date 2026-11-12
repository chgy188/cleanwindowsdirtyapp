#Requires -Version 3.0

<#
.SYNOPSIS
    CleanWindowsDirtyApp - 清理 Windows「设置 → 应用 → 已安装的应用」列表中
    指向已不存在软件的残留条目（下称"幽灵条目"）。

.DESCRIPTION
    工作原理：只读扫描三个 Uninstall 注册表位置 → 按固定优先级取证分级
    （OK / SUSPECT / GHOST / PROTECTED）→ 经确认后删除注册表条目。
    删除前逐条导出 .reg 备份，支持一键恢复。不删除任何程序文件，
    不触碰 MSI 子组件与系统运行库。

.PARAMETER Mode
    Menu      默认。交互菜单，适合手动使用。
    Scan      只扫描并在控制台显示结果，不做任何修改。
    Clean     扫描后直接进入清理流程（交互确认）。
    Restore   从 backups 目录的 .reg 备份恢复注册表条目。

.PARAMETER IncludeSuspect
    清理时一并处理 SUSPECT 级别条目（只剩卸载器、MSI 无产品记录）。
    默认只处理 GHOST（安装目录与程序文件全部不存在）。

.PARAMETER IncludeHidden
    扫描时纳入 SystemComponent=1 的隐藏组件条目。默认跳过，
    因为这类条目绝大多数是 MSI 子组件（VC++/.NET/Python/VS 分包），
    删除会破坏 MSI 的修复与卸载逻辑。

.PARAMETER NonInteractive
    不询问确认。仅用于自动化场景。

.PARAMETER OutputRoot
    备份目录的上级目录，backups/ 会创建在该目录下。
    默认取脚本的上级目录（即项目根目录）。

.EXAMPLE
    .\CleanWindowsDirtyApp.ps1 -Mode Scan

.EXAMPLE
    .\CleanWindowsDirtyApp.ps1 -Mode Clean -IncludeSuspect

.EXAMPLE
    .\CleanWindowsDirtyApp.ps1 -Mode Restore

.NOTES
    版本 1.0.0
    兼容 Windows PowerShell 5.1 与 PowerShell 7+
    删除 HKLM 条目需要管理员权限；脚本会提示自动提权。
#>

[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Scan', 'Clean', 'Restore', 'UpdateCheck', 'UpdateRun')]
    [string]$Mode = 'Menu',

    [switch]$IncludeSuspect,
    [switch]$IncludeHidden,
    [switch]$NonInteractive,
    [switch]$DryRun,
    [string]$OutputRoot
)

$ScriptVersion = '1.1.2'

# ============================================================
#  目录（只保留删除前的 .reg 备份，不生成报告与运行日志）
# ============================================================

# 脚本可能从任意目录运行（本地 Run.bat、下载到用户目录、irm | iex），
# 没有 $PSScriptRoot 时退回当前目录，避免 Join-Path 拿到空路径报错。
$BaseDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($BaseDir)) { $BaseDir = (Get-Location).Path }

$RootDir = Split-Path -Parent $BaseDir
if ([string]::IsNullOrWhiteSpace($RootDir)) { $RootDir = $BaseDir }
if ($OutputRoot) { $RootDir = $OutputRoot }

$BackupDir = Join-Path $RootDir 'backups'
if (-not (Test-Path -LiteralPath $BackupDir)) {
    New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
}

function Write-Title {
    param([string]$Text)
    Write-Host ''
    Write-Host ('  ' + $Text) -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * [Math]::Min($Text.Length + 4, 78))) -ForegroundColor DarkCyan
}

# ============================================================
#  控制台：最大化窗口、按需清屏
# ============================================================

function Set-ConsoleMaximized {
    <#
      尽量把控制台窗口最大化，让表格能显示更多列。
      Windows Terminal / 输出重定向时取不到可用句柄，静默降级并返回当前宽度。
    #>
    try {
        if (-not ('Cwda.Console' -as [type])) {
            Add-Type -Namespace Cwda -Name Console -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
'@
        }
        $h = [Cwda.Console]::GetConsoleWindow()
        if ($h -ne [IntPtr]::Zero) { [void][Cwda.Console]::ShowWindow($h, 3) }  # 3 = SW_MAXIMIZE
    } catch {}

    try { return ([int]$Host.UI.RawUI.WindowSize.Width) } catch { return 0 }
}

function Clear-ScreenNow {
    <# 清屏；部分宿主不支持 Clear-Host 时静默跳过 #>
    try { Clear-Host } catch {}
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ============================================================
#  常量：扫描范围与保护名单
# ============================================================

$UninstallRoots = @(
    @{ Hive = 'HKLM-64'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall';        RegPrefix = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' },
    @{ Hive = 'HKLM-32'; Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; RegPrefix = 'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' },
    @{ Hive = 'HKCU';    Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall';       RegPrefix = 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' }
)

# 系统组件 / 运行库 / 驱动 / 更新 —— 一律不参与清理判定
$ProtectedNamePattern = @(
    'Visual C\+\+', 'Visual Studio', '\.NET', 'Runtime', 'Redistributable',
    'Driver', '驱动程序包', 'SDK', 'SDK AddOn', 'Targeting Pack', 'Target Pack',
    'Microsoft Update', 'Windows Update', 'Update Health', 'Microsoft Edge',
    'WebView2', 'Windows Subsystem', 'MSXML', 'Universal CRT', 'DirectX',
    'PhysX', 'HD Audio', 'Graphics Driver', '图形驱动程序', 'Audio Driver',
    'Vulkan', 'OpenAL', 'Prerequisites', 'Launcher Prerequisites',
    'Application Compatibility', 'Text-To-Speech', 'Windows Software Development',
    'Google Update', 'Java Auto Updater', 'vs_', 'Windows SDK'
) -join '|'

# 判定为"卸载器"而非主程序的文件名特征
$UninstallerFileNamePattern = '(?i)(unins|uninstall|卸载|setup|install|remove|免卸载|unwise)'

# 只接受这些扩展名作为"程序文件"证据（.ico 等图标不算）
$ProgramExtPattern = '(?i)\.(exe|bat|cmd|msi)$'

# ============================================================
#  取证：从注册表字符串里提取真实路径
# ============================================================

function Get-PathsFromString {
    <#
      从 InstallLocation / UninstallString / DisplayIcon 等字段中提取绝对路径。
      处理三种常见形态：
        1. 裸路径                 C:\Program Files\App
        2. 带引号路径             "C:\Program Files\App\unins000.exe" /SILENT
        3. 带图标索引的路径       C:\App\app.exe,0
      只返回带盘符的本地路径。
    #>
    param([string]$Value, [switch]$OnlyProgramFiles)

    $result = @()
    if ([string]::IsNullOrWhiteSpace($Value)) { return $result }

    # 去掉尾部 ",N" 图标索引（如 "C:\App\app.exe,0"）
    $raw = $Value.Trim() -replace ',\s*-?\d+\s*$', ''

    # 1) 引号包裹的路径：引号本身已界定边界，内部的空格不参与切分
    #    "C:\Program Files\App\unins000.exe" /SILENT  ->  C:\Program Files\App\unins000.exe
    foreach ($m in [regex]::Matches($raw, '"([^"]+)"')) {
        $p = $m.Groups[1].Value.Trim()
        if ($p -match '(?i)^[A-Za-z]:\\') { $result += $p }
    }

    # 2) 没有引号：抓「盘符开头 + 程序类扩展名结尾」的片段。
    #    用非贪婪 .*? 让含空格的路径完整保留，例如
    #    C:\Program Files\DAUM\PotPlayer\PotPlayerMini64.exe /SILENT
    if ($result.Count -eq 0) {
        foreach ($m in [regex]::Matches($raw, '(?i)[A-Za-z]:\\[^"]*?\.(?:exe|bat|cmd|msi|dll|ico)')) {
            $result += $m.Value
        }
    }

    if ($OnlyProgramFiles) {
        $result = $result | Where-Object { $_ -match $ProgramExtPattern }
    }

    return ($result | Select-Object -Unique)
}

function Test-IsDirectory {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $item) { return $false }
    return [bool]$item.PSIsContainer
}

$script:MsiInstaller = $null

function Get-MsiProductState {
    <#
      用 Windows Installer 官方 COM API 查询产品状态。
      比手算 packed GUID 去猜 Installer\Products 键名可靠得多
      （packed GUID 的分段倒序规则很容易写错，会把正常软件误判成失效）。
        3 / 4 / 5 = 已安装（local / source / default）
        1 / 2     = 未安装（advertised / absent）
        -1        = 未知（产品码不存在）
        -2        = COM 调用失败，需回退到注册表判定
    #>
    param([string]$Guid)

    if ([string]::IsNullOrWhiteSpace($Guid)) { return -1 }
    if ($Guid -notmatch '^\{') { $Guid = '{' + $Guid + '}' }

    try {
        if (-not $script:MsiInstaller) {
            $script:MsiInstaller = New-Object -ComObject WindowsInstaller.Installer
        }
        return [int]$script:MsiInstaller.ProductState($Guid)
    } catch {
        return -2
    }
}

function Test-MsiProductByRegistry {
    # COM 不可用时的兜底：按 ProductName 在 MSI 产品库里反查
    param([string]$DisplayName)

    if ([string]::IsNullOrWhiteSpace($DisplayName)) { return $false }

    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products',
        'HKLM:\SOFTWARE\Classes\Installer\Products'
    )
    foreach ($r in $roots) {
        if (-not (Test-Path -LiteralPath $r)) { continue }
        $keys = Get-ChildItem -LiteralPath $r -ErrorAction SilentlyContinue
        foreach ($k in $keys) {
            $props = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            $pn = [string]$props.ProductName
            if ($pn -and $pn.Trim() -eq $DisplayName.Trim()) { return $true }
        }
    }
    return $false
}

# ============================================================
#  判定：把一条注册表记录归类
# ============================================================

function Get-EntryVerdict {
    <#
      优先级（严格分层，避免"图标还活着但软件没了"误判）：
        1. 命中保护名单                     → PROTECTED
        2. MSI 条目 + 产品数据库有记录       → OK
        3. MSI 条目 + 产品数据库无记录       → SUSPECT
        4. 安装目录真实存在（且是目录）      → OK
        5. 主程序文件存在                   → OK
        6. 只有卸载器存在                   → SUSPECT
        7. 以上全无                         → GHOST
    #>
    param($Props, [string]$KeyName)

    $name = [string]$Props.DisplayName

    if ($name -match $ProtectedNamePattern) {
        return @{
            Verdict = 'PROTECTED'
            Reason  = '系统组件/运行库/驱动，不在清理范围'
        }
    }

    $isMsi = ([string]$Props.WindowsInstaller -eq '1') -or
             ([string]$Props.UninstallString -match '(?i)msiexec')

    if ($isMsi) {
        # 产品码优先从 UninstallString（MsiExec.exe /X{GUID}）取，其次用键名
        $msiGuid = ''
        if ([string]$Props.UninstallString -match '(?i)\{[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\}') {
            $msiGuid = $Matches[0]
        }
        if (-not $msiGuid -and $KeyName -match '(?i)^\{[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\}') {
            $msiGuid = $KeyName
        }

        $state = -1
        if ($msiGuid) { $state = Get-MsiProductState $msiGuid }

        if ($state -eq -2) {
            # COM 不可用，退回注册表按产品名反查
            if (Test-MsiProductByRegistry $name) {
                return @{ Verdict = 'OK'; Reason = 'MSI 产品仍登记在安装数据库（注册表回退判定）' }
            }
            return @{ Verdict = 'SUSPECT'; Reason = 'MSI 条目，COM 与注册表均查不到产品记录' }
        }

        if ($state -eq 3 -or $state -eq 4 -or $state -eq 5) {
            return @{ Verdict = 'OK'; Reason = ('MSI 产品状态正常 (state=' + $state + ')') }
        }

        return @{ Verdict = 'SUSPECT'; Reason = ('MSI 产品未安装 (state=' + $state + ')') }
    }

    # 安装目录
    $locRaw = [string]$Props.InstallLocation
    $loc    = ''
    if (-not [string]::IsNullOrWhiteSpace($locRaw)) { $loc = $locRaw.Trim().Trim('"') }

    if ($loc -and (Test-IsDirectory $loc)) {
        return @{ Verdict = 'OK'; Reason = ('安装目录存在: ' + $loc) }
    }

    # 程序文件（只认 .exe/.bat/.cmd/.msi，忽略 .ico）
    $candidates = @()
    $candidates += Get-PathsFromString ([string]$Props.UninstallString)      -OnlyProgramFiles
    $candidates += Get-PathsFromString ([string]$Props.QuietUninstallString) -OnlyProgramFiles
    $candidates += Get-PathsFromString ([string]$Props.DisplayIcon)          -OnlyProgramFiles
    $candidates = $candidates | Select-Object -Unique

    $mainExe   = ''
    $uninstExe = ''
    foreach ($c in $candidates) {
        if (-not (Test-Path -LiteralPath $c)) { continue }
        $leaf = Split-Path -Leaf $c
        if ($leaf -match $UninstallerFileNamePattern) {
            if (-not $uninstExe) { $uninstExe = $c }
        } else {
            if (-not $mainExe) { $mainExe = $c }
        }
    }

    if ($mainExe) {
        return @{ Verdict = 'OK'; Reason = ('主程序存在: ' + $mainExe) }
    }
    if ($uninstExe) {
        # 卸载器还在时，再看它所在目录与上一级是否仍有其它程序文件（.exe/.dll）。
        # 有些绿色/插件类软件把本体和卸载器放在一起（如 Edirol 的 VST 目录、
        # Band-in-a-Box 把 unins096.exe 放在 D:\GY\bb\uninstall\），
        # 此时软件其实还在，不能判成"只剩卸载器"。
        $dir = Split-Path -Parent $uninstExe
        $probeDirs = @($dir, (Split-Path -Parent $dir))
        $siblings = @()
        foreach ($pd in $probeDirs) {
            if (-not $pd) { continue }
            if (-not (Test-Path -LiteralPath $pd)) { continue }
            $siblings += Get-ChildItem -LiteralPath $pd -Force -File -ErrorAction SilentlyContinue |
                         Where-Object {
                             $_.FullName -ne $uninstExe -and
                             $_.Extension -match '(?i)^\.(exe|dll)$' -and
                             $_.Name -notmatch $UninstallerFileNamePattern
                         }
        }
        if ($siblings.Count -gt 0) {
            return @{ Verdict = 'OK'; Reason = ('卸载器同目录仍有程序文件: ' + $uninstExe) }
        }
        return @{ Verdict = 'SUSPECT'; Reason = ('只剩卸载器，本体目录缺失: ' + $uninstExe) }
    }
    if ($loc) {
        return @{ Verdict = 'GHOST'; Reason = ('安装目录不存在: ' + $loc) }
    }
    return @{ Verdict = 'GHOST'; Reason = '安装目录与程序文件均不存在' }
}

# ============================================================
#  部署类型：区分「安装版」与「绿色/便携版」
# ============================================================

function Get-DeployInfo {
    <#
      判定依据（启发式，不是事实断言；清单表格里会显示判定理由）：
        MSI 产品                -> 安装版（绿色软件不会走 MSI）
        目录内有卸载组件         -> 安装版（Inno/NSIS 正常安装的标配）
        装在 Program Files 等     -> 安装版
        装在自定义目录 + 目录里没有任何卸载组件 -> 绿色/便携
        命中 !)xx.bat / 绿化 / portable 标记     -> 强证据
        位于其它软件的安装目录内  -> 反向排除（安装器的组件布局，如 MAGIX Content）
    #>
    param($Entry, $AllLocations)

    if ($Entry.Verdict -eq 'PROTECTED') {
        return @{ Type = '系统组件'; Why = '保护名单内，不参与部署类型判定' }
    }

    if ($Entry.Reason -match 'MSI') {
        return @{ Type = '安装版'; Why = 'MSI 产品注册' }
    }

    $loc = $Entry.InstallLocation.Trim().Trim('"').TrimEnd('\')
    $score = 0
    $why = @()

    # 是否装在系统约定的安装位置
    $isSystemDir = $false
    if ($loc -match '(?i)^[A-Za-z]:\\(Program Files|Windows)') { $isSystemDir = $true }
    if ($loc -match '(?i)\\AppData\\Local\\Programs')            { $isSystemDir = $true }
    # 注意：AppData\Local\Microsoft\WinGet\Packages 不算系统安装位——
    # winget 的 portable 包就是解压到这里，本质上仍是便携部署

    if ($loc -and -not $isSystemDir) {
        $score += 2
        $why += '装在自定义目录'
    }

    $hasUninstaller = $false
    if ($loc -and (Test-Path -LiteralPath $loc)) {
        foreach ($n in @('unins000.dat', 'unins001.dat', 'uninstall.exe', 'uninst.exe', '卸载.exe', 'Uninstall.exe')) {
            if (Test-Path -LiteralPath (Join-Path $loc $n)) { $hasUninstaller = $true; break }
        }

        if ($hasUninstaller) {
            $score -= 2
            $why += '目录内有卸载组件'
        } elseif ($isSystemDir) {
            # 程序装在 Program Files 却没卸载器数据，常见于驱动组件、
            # 由统一卸载器管理的产品 —— 弱信号，不足以判绿色
            $score += 1
            $why += '目录内无卸载组件(系统目录，弱信号)'
        } else {
            $score += 3
            $why += '目录内无卸载组件'
        }

        $items = @(Get-ChildItem -LiteralPath $loc -Force -ErrorAction SilentlyContinue)
        if (@($items | Where-Object { $_.Name -match '^!\)' }).Count -gt 0) {
            $score += 2
            $why += '存在 !) 中文脚本'
        }
        if (@($items | Where-Object { $_.Name -match '(?i)绿化|绿色|^portable|Portable\.ini' }).Count -gt 0) {
            $score += 2
            $why += '存在绿化/便携标记'
        }
    }

    # 反向：与其它条目的安装目录存在父子关系 -> 多半是安装器的组件目录，不是独立绿色软件
    # （两个方向都要查：当前是别人的子目录，或别人是当前的子目录）
    if ($loc) {
        foreach ($other in $AllLocations) {
            if (-not $other) { continue }
            if ($other -eq $loc) { continue }
            $isChild  = ($loc.Length   -gt $other.Length -and $loc.StartsWith($other, [StringComparison]::OrdinalIgnoreCase))
            $isParent = ($other.Length -gt $loc.Length   -and $other.StartsWith($loc, [StringComparison]::OrdinalIgnoreCase))
            if ($isChild -or $isParent) {
                $score -= 2
                $why += '与其它软件的安装目录重叠'
                break
            }
        }
    }

    if ($Entry.Hive -eq 'HKCU') {
        $score += 1
        $why += '用户级注册(HKCU)'
    }

    $type = '安装版'
    if ($score -ge 5) { $type = '绿色/便携' }
    elseif ($score -ge 3) { $type = '疑似绿色' }

    return @{ Type = $type; Why = ($why -join '、') }
}

# ============================================================
#  扫描：枚举 → 过滤 → 判定
# ============================================================

function Get-AppEntries {
    param([switch]$WithHidden)

    $entries = @()

    foreach ($root in $UninstallRoots) {
        if (-not (Test-Path -LiteralPath $root.Path)) { continue }

        $keys = Get-ChildItem -LiteralPath $root.Path -ErrorAction SilentlyContinue
        foreach ($key in $keys) {
            $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            if (-not $props) { continue }

            $displayName = [string]$props.DisplayName
            if ([string]::IsNullOrWhiteSpace($displayName)) { continue }

            # 过滤：MSI 子组件、补丁、嵌套条目
            $isHidden = ($props.SystemComponent -eq 1)
            if ($isHidden -and -not $WithHidden) { continue }
            if (-not [string]::IsNullOrWhiteSpace([string]$props.ParentKeyName)) { continue }
            if ([string]$props.ReleaseType -match '(?i)Update|Hotfix|Security Update') { continue }

            $keyName = $key.PSChildName
            $verdict = Get-EntryVerdict -Props $props -KeyName $keyName

            $sizeKb = 0
            if ($props.EstimatedSize) {
                try { $sizeKb = [int]$props.EstimatedSize } catch { $sizeKb = 0 }
            }

            # 隐藏组件里，只保留"明确有安装目录且目录已消失"的作为可疑项，
            # 其余（InstallLocation 为空）是正常的 MSI 分包，一律标 PROTECTED
            if ($isHidden -and $verdict.Verdict -ne 'OK') {
                $locRaw = [string]$props.InstallLocation
                if ([string]::IsNullOrWhiteSpace($locRaw)) {
                    $verdict = @{ Verdict = 'PROTECTED'; Reason = 'MSI 隐藏子组件（无独立安装路径），不处理' }
                }
            }

            $entries += [PSCustomObject]@{
                Hive           = $root.Hive
                RegPath        = ($root.RegPrefix + '\' + $keyName)
                PsPath         = $key.PSPath
                KeyName        = $keyName
                DisplayName    = $displayName
                DisplayVersion = [string]$props.DisplayVersion
                Publisher      = [string]$props.Publisher
                Verdict        = $verdict.Verdict
                Reason         = $verdict.Reason
                InstallLocation= [string]$props.InstallLocation
                UninstallString= [string]$props.UninstallString
                DisplayIcon    = [string]$props.DisplayIcon
                EstimatedSizeKB= $sizeKb
                IsHidden       = $isHidden
                DeployType     = ''
                DeployWhy      = ''
            }
        }
    }

    # 第二遍：判定部署类型。需要全量 InstallLocation，才能识别"位于其它软件目录内"的组件
    $allLocations = @($entries | ForEach-Object {
        $l = $_.InstallLocation.Trim().Trim('"').TrimEnd('\')
        if ($l) { $l }
    })

    foreach ($e in $entries) {
        $info = Get-DeployInfo -Entry $e -AllLocations $allLocations
        $e.DeployType = $info.Type
        $e.DeployWhy  = $info.Why
    }

    return $entries
}

# ============================================================
#  展示（所有清单统一用表格 + 滑动窗口）
# ============================================================

function Show-ScanResult {
    param($Entries)

    $ghost     = @($Entries | Where-Object { $_.Verdict -eq 'GHOST' })
    $suspect   = @($Entries | Where-Object { $_.Verdict -eq 'SUSPECT' })
    $ok        = @($Entries | Where-Object { $_.Verdict -eq 'OK' })
    $protected = @($Entries | Where-Object { $_.Verdict -eq 'PROTECTED' })

    Write-Host ''
    Write-Host ("  共扫描 {0} 条" -f $Entries.Count) -ForegroundColor White

    $sumRows   = New-Object System.Collections.Generic.List[object]
    $sumColors = New-Object System.Collections.Generic.List[string]
    foreach ($g in @(
        @{ Name = '确定失效'; Count = $ghost.Count;     Color = 'Red';      Why = '安装目录和程序文件都不存在，默认清理目标' },
        @{ Name = '可疑';     Count = $suspect.Count;   Color = 'Yellow';   Why = '只剩卸载器或 MSI 查无记录，默认不动' },
        @{ Name = '正常';     Count = $ok.Count;        Color = 'Green';    Why = '软件仍在' },
        @{ Name = '受保护';   Count = $protected.Count; Color = 'DarkGray'; Why = '系统组件/运行库，永不触碰' }
    )) {
        $sumRows.Add([string[]]@($g.Name, [string]$g.Count, $g.Why))
        $sumColors.Add($g.Color)
    }
    Show-Table -Headers @('分级', '条数', '说明') -Rows $sumRows `
               -MinWidths @(12, 8, 40) -FlexColumn 2 -RowColors $sumColors

    # 明细只列需要关注的条目；正常与受保护项只给汇总数字，避免清单过长
    $rows   = New-Object System.Collections.Generic.List[object]
    $colors = New-Object System.Collections.Generic.List[string]
    foreach ($e in $Entries) {
        $cat   = ''
        $color = ''
        $why   = ''
        if ($e.Verdict -eq 'GHOST') {
            $cat = '失效'; $color = 'Red'; $why = [string]$e.Reason
        } elseif ($e.Verdict -eq 'SUSPECT') {
            $cat = '可疑'; $color = 'Yellow'; $why = [string]$e.Reason
        } elseif ($e.DeployType -eq '绿色/便携') {
            $cat = '绿色'; $color = 'Magenta'; $why = [string]$e.DeployWhy
        } elseif ($e.DeployType -eq '疑似绿色') {
            $cat = '疑似绿色'; $color = 'DarkMagenta'; $why = [string]$e.DeployWhy
        } else {
            continue
        }

        $ver = [string]$e.DisplayVersion
        if ([string]::IsNullOrWhiteSpace($ver)) { $ver = '-' }
        $rows.Add([string[]]@($cat, [string]$e.DisplayName, $ver, [string]$e.Hive, $why))
        $colors.Add($color)
    }

    if ($rows.Count -gt 0) {
        Write-Host ''
        Write-Host '  需关注的条目：' -ForegroundColor White
        Show-Table -Headers @('分类', '名称', '版本', '位置', '依据') `
                   -Rows $rows -MinWidths @(10, 24, 10, 8, 28) `
                   -FlexColumn 1 -RowColors $colors -Caption '需关注的条目'
    } else {
        Write-Host ''
        Write-Host '  没有需要关注的条目。' -ForegroundColor Green
    }

    if ($suspect.Count -gt 0) {
        Write-Host ''
        Write-Host '  提示：可疑条目多数是「软件装在别处、注册表路径字段过时」，默认不动；' -ForegroundColor DarkYellow
        Write-Host '        需要连带清理时加 -IncludeSuspect。' -ForegroundColor DarkYellow
    }
}

# ============================================================
#  清理
# ============================================================

function Get-SafeFileName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return 'entry' }
    $invalid = [IO.Path]::GetInvalidFileNameChars()
    foreach ($ch in $invalid) {
        $Name = $Name.Replace([string]$ch, '_')
    }
    $Name = $Name.Trim()
    if ($Name.Length -gt 60) { $Name = $Name.Substring(0, 60) }
    if ([string]::IsNullOrWhiteSpace($Name)) { return 'entry' }
    return $Name
}

function Invoke-CleanEntries {
    param($Entries)

    if ($Entries.Count -eq 0) {
        Write-Host ''
        Write-Host '  没有需要清理的条目。' -ForegroundColor Green
        return 0
    }

    # 只有涉及 HKLM 的条目才需要提权；HKCU 条目普通权限即可删除
    $needAdmin = @($Entries | Where-Object { $_.Hive -like 'HKLM*' }).Count -gt 0
    if ($needAdmin -and -not (Test-IsAdmin)) {
        Write-Host ''
        Write-Host '  待清理条目含 HKLM 项，删除需要管理员权限。' -ForegroundColor Yellow
        Write-Host '  请通过 Run.bat 启动，或用管理员身份重新运行本脚本。' -ForegroundColor Yellow
        return -1
    }

    $sessionDir = Join-Path $BackupDir ('backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
    Write-Host ("  备份目录: {0}" -f $sessionDir) -ForegroundColor Gray

    $okCount = 0
    $failCount = 0

    foreach ($e in $Entries) {
        $fileName = (Get-SafeFileName $e.DisplayName) + '.reg'
        $backupFile = Join-Path $sessionDir $fileName
        $i = 1
        while (Test-Path -LiteralPath $backupFile) {
            $i++
            $backupFile = Join-Path $sessionDir ((Get-SafeFileName $e.DisplayName) + "-$i.reg")
        }

        # 1) 导出备份
        $exportOutput = & reg.exe export $e.RegPath $backupFile /y 2>&1
        if (-not (Test-Path -LiteralPath $backupFile)) {
            Write-Host ("    [跳过] {0} —— 备份失败: {1}" -f $e.DisplayName, ($exportOutput -join ' ')) -ForegroundColor Red
            $failCount++
            continue
        }

        # 2) 删除注册表条目
        try {
            Remove-Item -LiteralPath $e.PsPath -Recurse -Force -ErrorAction Stop
            Write-Host ("    [已删除] {0}" -f $e.DisplayName) -ForegroundColor Green
            $okCount++
        } catch {
            Write-Host ("    [失败] {0} —— {1}" -f $e.DisplayName, $_.Exception.Message) -ForegroundColor Red
            $failCount++
        }
    }

    Write-Host ''
    Write-Host ("  清理完成：成功 {0} 条，失败 {1} 条。备份保存在:" -f $okCount, $failCount) -ForegroundColor White
    Write-Host ("    {0}" -f $sessionDir) -ForegroundColor Gray

    return $okCount
}

# ============================================================
#  恢复
# ============================================================

function Get-BackupSessions {
    if (-not (Test-Path -LiteralPath $BackupDir)) { return @() }
    $sessions = Get-ChildItem -LiteralPath $BackupDir -Directory -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending
    return @($sessions)
}

function Invoke-Restore {
    $sessions = Get-BackupSessions
    if ($sessions.Count -eq 0) {
        Write-Host ''
        Write-Host '  没有找到任何备份（backups 目录为空）。' -ForegroundColor Yellow
        return
    }

    if (-not (Test-IsAdmin)) {
        Write-Host ''
        Write-Host '  当前不是管理员会话，无法读取备份内容判断是否需要提权。' -ForegroundColor Yellow
        Write-Host '  请用 Run.bat 启动后再恢复。' -ForegroundColor Yellow
        return
    }

    Write-Title '选择要恢复的备份批次'
    $rows = New-Object System.Collections.Generic.List[object]
    $i = 1
    foreach ($s in $sessions) {
        $files = @(Get-ChildItem -LiteralPath $s.FullName -Filter '*.reg' -ErrorAction SilentlyContinue)
        $rows.Add([string[]]@([string]$i, $s.Name, [string]$files.Count, $s.LastWriteTime.ToString('yyyy-MM-dd HH:mm')))
        $i++
    }
    Show-Table -Headers @('编号', '备份批次', '条目数', '备份时间') -Rows $rows `
               -MinWidths @(5, 26, 8, 18) -FlexColumn 1 -Caption '选择要恢复的备份批次'
    Write-Host '  [0] 返回' -ForegroundColor DarkGray

    $choice = Read-Host "`n  请输入编号"
    if ($choice -eq '0' -or [string]::IsNullOrWhiteSpace($choice)) { return }
    $index = 0
    if (-not [int]::TryParse($choice, [ref]$index)) { Write-Host '  输入无效。' -ForegroundColor Red; return }
    if ($index -lt 1 -or $index -gt $sessions.Count) { Write-Host '  编号超出范围。' -ForegroundColor Red; return }

    $session = $sessions[$index - 1]
    $files = @(Get-ChildItem -LiteralPath $session.FullName -Filter '*.reg' -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) { Write-Host '  该批次没有备份文件。' -ForegroundColor Yellow; return }

    Write-Host ''
    $fileRows = New-Object System.Collections.Generic.List[object]
    $fi = 0
    foreach ($f in $files) {
        $fi++
        $fileRows.Add([string[]]@([string]$fi, $f.Name))
    }
    Show-Table -Headers @('序号', '备份文件') -Rows $fileRows -MinWidths @(5, 40) -FlexColumn 1

    $confirm = Read-Host "`n  确认把以上 $($files.Count) 个条目恢复到注册表？(y/N)"
    if ($confirm -ne 'y') { Write-Host '  已取消。' -ForegroundColor Yellow; return }

    $ok = 0
    $fail = 0
    foreach ($f in $files) {
        $out = & reg.exe import $f.FullName 2>&1
        $code = $LASTEXITCODE
        if ($code -eq 0) {
            Write-Host ("    [恢复] {0}" -f $f.Name) -ForegroundColor Green
            $ok++
        } else {
            Write-Host ("    [失败] {0} —— {1}" -f $f.Name, ($out -join ' ')) -ForegroundColor Red
            $fail++
        }
    }

    Write-Host ''
    Write-Host ("  恢复完成：成功 {0} 个，失败 {1} 个。" -f $ok, $fail) -ForegroundColor White
}

# ============================================================
#  软件更新（数据源：winget）
# ============================================================

$script:WingetExe = $null
# 下载包大小缓存：key = "Id|Available"，value = 字节数（0 = 探测不到）
$script:SizeCache   = @{}
$script:SizeRetried = @{}

function Get-WingetExe {
    if ($script:WingetExe) { return $script:WingetExe }
    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $cmd) { return $null }
    $script:WingetExe = $cmd.Source
    return $script:WingetExe
}

function Get-VersionPart {
    <#
      取版本号里的第 N 段数字；解析不了返回 -1。
      例：Get-VersionPart '8.0.4310.10' 1  -> 0
    #>
    param([string]$Version, [int]$Index)
    if ($Version -match '^[0-9]+(\.[0-9]+)?(\.[0-9]+)?') {
        # 注意：-split 的操作数是正则，'.' 必须转义，否则会把每个字符都拆开
        $parts = @($Matches[0] -split '\.')
        if ($Index -lt $parts.Count) { return [int]$parts[$Index] }
        return 0
    }
    return -1
}

function Get-WingetUpgrades {
    <#
      只读：调用 winget 列出可升级软件。
      winget 的表格用两个以上空格分列，从右往左依次是
      源 / 可用版本 / 当前版本 / 包 ID，剩下的部分是名称。
      按这个顺序取比按列宽切分可靠——长名称被截断也不影响。
      winget 不可用或查询失败时返回 $null。
    #>
    $exe = Get-WingetExe
    if (-not $exe) { return $null }

    $tmp     = [IO.Path]::GetTempFileName()
    $errFile = $tmp + '.err'

    $p = Start-Process -FilePath $exe `
         -ArgumentList @('upgrade', '--include-unknown', '--disable-interactivity') `
         -NoNewWindow -PassThru `
         -RedirectStandardOutput $tmp -RedirectStandardError $errFile

    $finished = $true
    try { Wait-Process -Id $p.Id -Timeout 180 -ErrorAction Stop } catch { $finished = $false }
    if (-not $finished) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch {}
        Remove-Item -LiteralPath $tmp, $errFile -Force -ErrorAction SilentlyContinue
        return $null
    }

    $lines = @(Get-Content -LiteralPath $tmp -Encoding UTF8 -ErrorAction SilentlyContinue)
    Remove-Item -LiteralPath $tmp, $errFile -Force -ErrorAction SilentlyContinue

    $items = New-Object System.Collections.Generic.List[object]
    $truncated = 0

    foreach ($line in $lines) {
        $t = $line.TrimEnd()
        if (-not $t) { continue }
        if ($t -match '^\s*[-=]{3,}\s*$') { continue }

        # 列宽不足时 winget 会用单个空格把各列挤在一起，
        # 所以按单个空格切分，再从右往左取：源 / 可用版本 / 当前版本 / 包 ID。
        # 版本号和 ID 都不含空格，这样取不会碰到名称里的空格。
        $tokens = @($t -split ' ' | Where-Object { $_ })
        if ($tokens.Count -lt 5) { continue }

        $source = $tokens[-1]
        if ($source -ne 'winget' -and $source -ne 'msstore') { continue }

        $avail = $tokens[-2]
        $cur   = $tokens[-3]
        $id    = $tokens[-4]

        # ID 被列宽截断（末尾 ...）时无法据此升级，跳过并计数
        if ($id -match '\.\.\.' -or $id -notmatch '^[A-Za-z0-9._+-]+$') { $truncated++; continue }

        $name = ($tokens[0..($tokens.Count - 5)] -join ' ').Trim()
        if (-not $name) { $name = $id }

        # 风险档按「软件性质」划分，而不是按版本号跨度：
        # 各厂商版本号含义完全不同（OneDrive 的 26.145 → 26.183 只是日常更新，
        # 而 Python 的 3.13 → 3.15 是真跳版本），用数字跨度判定必然大量误报。
        $level = '常规'
        $note  = ''

        $cm  = Get-VersionPart $cur   0
        $nm  = Get-VersionPart $avail 0
        $cm2 = Get-VersionPart $cur   1
        $nm2 = Get-VersionPart $avail 1

        # 版本跨度只作为参考信息写进备注，不改变档位
        if ($cm -ge 0 -and $nm -gt $cm) {
            $note = "主版本 $cm → $nm"
        } elseif ($cm -ge 0 -and $cm -eq $nm -and $cm2 -ge 0 -and $nm2 -ge ($cm2 + 10)) {
            $note = "版本号跨度较大：$cm2 → $nm2"
        }

        if ($cur -eq 'Unknown' -or $avail -eq 'Unknown') {
            $level = '待确认'
            $note  = '版本信息不完整，可能是误报'
        } elseif ($id -match '(?i)(ASIO|Steinberg|Yamaha|AudioDriver|\.Driver$)') {
            $level = '驱动'
            $note  = '驱动类，升级可能影响音频或硬件设备'
        } elseif ($id -match '(?i)Microsoft\.WSL') {
            $level = '注意'
            $note  = '子系统大版本更新，可能影响已安装的 Linux 发行版'
        } elseif ($id -match '(?i)(Tencent\.|Baidu\.|ByteDance\.|Telegram\.|Tonec\.|Microsoft\.OneDrive|Microsoft\.Outlook)') {
            $level = '注意'
            $note  = '客户端类，更新后界面可能变化，或需要重新登录'
        }

        $items.Add([pscustomobject]@{
            Name      = $name
            Id        = $id
            Version   = $cur
            Available = $avail
            Source    = $source
            Level     = $level
            Note      = $note
        })
    }

    if ($truncated -gt 0) {
        Write-Host ("  winget 清单里有 {0} 行 ID 被列宽截断，已跳过。" -f $truncated) -ForegroundColor DarkYellow
    }

    return $items
}

function Format-FileSize {
    param([long]$Bytes)
    if ($Bytes -le 0) { return '-' }
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ("$Bytes B")
}

function Convert-SizeToBytes {
    param([string]$Number, [string]$Unit)
    try {
        $v = [double]::Parse($Number.Replace(',', '.'), [Globalization.CultureInfo]::InvariantCulture)
    } catch { return 0 }
    switch ($Unit.ToUpper()) {
        'GB' { return [long]($v * 1GB) }
        'MB' { return [long]($v * 1MB) }
        'KB' { return [long]($v * 1KB) }
        default { return [long]$v }
    }
    return 0
}

function Find-InstallerUrl {
    <#
      winget show 的输出可能是 GBK 或 UTF-8，还夹着 \r 进度符，中文关键词不可靠。
      所以把整段输出拼起来扫所有 URL，再按「安装包特征」挑选，不依赖行结构。
    #>
    param([object]$Lines)

    $all = (@($Lines) -join "`n") -replace '\x1B\[[0-9;?]*[A-Za-z]', ''
    $all = $all -replace '[\x00-\x1F\x7F]', ' '

    $weak = $null
    foreach ($m in [regex]::Matches($all, 'https?://[^\s]+')) {
        $u = $m.Value.TrimEnd(')', ',', ';', '"')
        if ($u -match '(?i)\.(msi|msix|exe|zip|7z|appx)(\?|$)|/releases/download/|/download/') { return $u }
        if (-not $weak -and $u -match '(?i)installer|setup|install') { $weak = $u }
    }
    return $weak
}

function Get-RemoteFileSize {
    <#
      HEAD 取 Content-Length；部分 CDN 不响应 HEAD，就退回 GET + Range(0-0)，
      从 Content-Range 里读总大小，只取 1 字节、不下载整个安装包。
      两种都失败返回 0，不拖累主流程。
    #>
    param([string]$Url, [int]$TimeoutMs = 1500)
    try {
        $req = [Net.HttpWebRequest]::Create($Url)
        $req.Method = 'HEAD'
        $req.Timeout = $TimeoutMs
        $req.ReadWriteTimeout = $TimeoutMs
        $req.AllowAutoRedirect = $true
        $req.UserAgent = 'Mozilla/5.0'
        $resp = $req.GetResponse()
        $len = [long]$resp.ContentLength
        $resp.Close()
        if ($len -gt 0) { return $len }
    } catch {}

    try {
        $req = [Net.HttpWebRequest]::Create($Url)
        $req.Method = 'GET'
        $req.Timeout = $TimeoutMs
        $req.ReadWriteTimeout = $TimeoutMs
        $req.AllowAutoRedirect = $true
        $req.UserAgent = 'Mozilla/5.0'
        $req.AddRange(0, 0)
        $resp = $req.GetResponse()
        $cr  = [string]$resp.Headers['Content-Range']
        $len = [long]$resp.ContentLength
        $resp.Close()
        if ($cr -and $cr -match '/(\d+)\s*$') { return [long]$Matches[1] }
        if ($len -gt 0) { return $len }
    } catch {}
    return 0
}

function Get-UpgradeSizes {
    <#
      winget 的升级清单不带包大小。这里分批并发跑 winget show 拿安装程序 URL，
      再用 HEAD 取 Content-Length，结果写进 $script:SizeCache。
      带总预算，探测不到就显示 -，绝不阻塞升级流程。
    #>
    param([array]$Items, [int]$BudgetSec = 30, [int]$BatchSize = 6)

    if ($null -eq $script:SizeCache)   { $script:SizeCache = @{} }
    if ($null -eq $script:SizeRetried) { $script:SizeRetried = @{} }

    $exe = Get-WingetExe
    if (-not $exe) { return }

    $todo = New-Object System.Collections.Generic.List[object]
    foreach ($it in $Items) {
        $key = [string]$it.Id + '|' + [string]$it.Available
        $known = $script:SizeCache.ContainsKey($key)
        $failedBefore = $known -and ($script:SizeCache[$key] -eq 0)
        # 没探测过的直接查；上次失败的在刷新时重试一次，之后不再重复拖慢流程
        if (-not $known -or ($failedBefore -and -not $script:SizeRetried.ContainsKey($key))) {
            $todo.Add([pscustomobject]@{ Id = [string]$it.Id; Key = $key })
            $script:SizeRetried[$key] = $true
        }
    }
    if ($todo.Count -eq 0) { return }

    $sw   = [Diagnostics.Stopwatch]::StartNew()
    $urls = @{}
    $done = 0
    while ($done -lt $todo.Count -and $sw.Elapsed.TotalSeconds -lt $BudgetSec) {
        $end   = [Math]::Min($done + $BatchSize - 1, $todo.Count - 1)
        $slice = New-Object System.Collections.Generic.List[object]
        for ($k = $done; $k -le $end; $k++) { $slice.Add($todo[$k]) }

        $jobs = New-Object System.Collections.Generic.List[object]
        foreach ($e in $slice) {
            $tmp = [IO.Path]::GetTempFileName()
            $err = $tmp + '.err'
            try {
                $p = Start-Process -FilePath $exe `
                     -ArgumentList @('show', '--id', $e.Id, '--exact', '--disable-interactivity', '--accept-source-agreements') `
                     -NoNewWindow -PassThru -RedirectStandardOutput $tmp -RedirectStandardError $err
                $jobs.Add([pscustomobject]@{ Key = $e.Key; Tmp = $tmp; Err = $err; Proc = $p })
            } catch {
                Remove-Item -LiteralPath $tmp, $err -Force -ErrorAction SilentlyContinue
                $script:SizeCache[$e.Key] = 0
            }
        }

        foreach ($j in $jobs) {
            try { [void]$j.Proc.WaitForExit(9000) } catch {}
            if (-not $j.Proc.HasExited) { try { $j.Proc.Kill() } catch {} }
            $lines = @(Get-Content -LiteralPath $j.Tmp -Encoding UTF8 -ErrorAction SilentlyContinue)
            Remove-Item -LiteralPath $j.Tmp, $j.Err -Force -ErrorAction SilentlyContinue
            $u = Find-InstallerUrl -Lines $lines
            if ($u) { $urls[$j.Key] = $u } else { $script:SizeCache[$j.Key] = 0 }
        }
        $done = $end + 1
    }

    # HEAD 阶段单独限 8 秒：网络慢时宁可留几个 -，也不让清单迟迟不出现
    $headStart = [double]$sw.Elapsed.TotalSeconds
    foreach ($key in @($urls.Keys)) {
        if (($sw.Elapsed.TotalSeconds - $headStart) -ge 8) {
            $script:SizeCache[$key] = 0
            continue
        }
        $script:SizeCache[$key] = (Get-RemoteFileSize -Url $urls[$key] -TimeoutMs 1500)
    }
    $sw.Stop()
}

function Get-ConsoleSize {
    <# 取当前控制台宽高；非交互或取不到时回退 100x30 #>
    $w = 0
    $h = 0
    try {
        $sz = $Host.UI.RawUI.WindowSize
        $w = [int]$sz.Width
        $h = [int]$sz.Height
    } catch {}
    if ($w -le 0)  { $w = 100 }
    if ($h -le 0)  { $h = 30 }
    return [pscustomobject]@{ W = $w; H = $h }
}

function Get-CharCellWidth {
    <# 控制台单元格宽度：中文/全角算 2 列，控制字符算 0 列 #>
    param([char]$Char)

    $n = [int]$Char
    if ($n -lt 32 -or $n -eq 127) { return 0 }
    if (($n -ge 0x1100 -and $n -le 0x115F) -or
        ($n -ge 0x2E80 -and $n -le 0xA4CF) -or
        ($n -ge 0xAC00 -and $n -le 0xD7A3) -or
        ($n -ge 0xF900 -and $n -le 0xFAFF) -or
        ($n -ge 0xFE10 -and $n -le 0xFE6F) -or
        ($n -ge 0xFF00 -and $n -le 0xFF60) -or
        ($n -ge 0xFFE0 -and $n -le 0xFFE6)) { return 2 }
    return 1
}

function Get-ConsoleCellWidth {
    param([string]$Text)
    $w = 0
    foreach ($c in $Text.ToCharArray()) { $w += (Get-CharCellWidth -Char $c) }
    return $w
}

function Limit-ConsoleWidth {
    <#
      按控制台单元格宽度截断成一行：去掉 ANSI 转义/控制字符（winget 的进度输出会带），
      并按显示宽度裁剪，避免整行被控制台自动折成两行、把光标位置弄乱。
    #>
    param([string]$Text, [int]$MaxCells)

    $clean = ($Text -replace '\x1B\[[0-9;?]*[A-Za-z]', '') -replace '[\x00-\x1F\x7F]', ''
    $sb = New-Object System.Text.StringBuilder
    $w  = 0
    foreach ($c in $clean.ToCharArray()) {
        $cw = Get-CharCellWidth -Char $c
        if ($cw -eq 0) { continue }
        if ($w + $cw -gt $MaxCells) { break }
        [void]$sb.Append($c)
        $w += $cw
    }
    return $sb.ToString()
}

function Fit-CellText {
    <# 表格单元格：按显示宽度裁剪（放不下时尾部加 …），再补空格对齐到列宽 #>
    param([string]$Text, [int]$Cells)

    $clean = ($Text -replace '\x1B\[[0-9;?]*[A-Za-z]', '') -replace '[\x00-\x1F\x7F]', ''
    $full  = Limit-ConsoleWidth -Text $clean -MaxCells $Cells
    if ((Get-ConsoleCellWidth -Text $full) -lt (Get-ConsoleCellWidth -Text $clean)) {
        $text = (Limit-ConsoleWidth -Text $clean -MaxCells ([Math]::Max(1, $Cells - 1))) + '…'
    } else {
        $text = $full
    }
    return ($text + (' ' * [Math]::Max(0, $Cells - (Get-ConsoleCellWidth -Text $text))))
}

function Format-TableLines {
    <#
      紧凑表格：表头 + 分隔线 + 数据行，不画外框以省行数。
      列宽按 MinWidths 的比例分配整个可用宽度，不会让某一列独吞剩余空间。
      Rows 的每一行是 string[]；RowColors 是每行对应的颜色名。
    #>
    param(
        [string[]]$Headers,
        [object]$Rows,
        [int[]]$MinWidths,
        [int]$FlexColumn = 1,
        [object]$RowColors = $null,
        [int]$Width = 0
    )

    if ($Width -le 0) { $Width = (Get-ConsoleSize).W }
    $n = $Headers.Count
    if ($n -eq 0) { return @() }

    # 前缀 2 列 + 末尾 1 列余量；列间用 " | "（3 列）
    $usable = [Math]::Max(20, $Width - 3) - 3 * ($n - 1)
    $weights = @($MinWidths | ForEach-Object { [int]$_ })
    while ($weights.Count -lt $n) { $weights += 12 }
    $totalWeight = 0
    foreach ($w in $weights) { $totalWeight += $w }

    $widths = @()
    for ($k = 0; $k -lt $n; $k++) {
        $widths += [Math]::Max(4, [int][Math]::Floor($usable * $weights[$k] / [double]$totalWeight))
    }

    # 舍入产生的偏差：超出可用宽度就从最宽列逐列扣，富余则给弹性列
    $sum = 0
    foreach ($w in $widths) { $sum += $w }
    if ($sum -gt $usable) {
        $guard = 0
        while ($sum -gt $usable -and $guard -lt 500) {
            $ix = 0
            for ($k = 1; $k -lt $n; $k++) { if ($widths[$k] -gt $widths[$ix]) { $ix = $k } }
            if ($widths[$ix] -le 4) { break }
            $widths[$ix]--
            $sum--
            $guard++
        }
    } elseif ($FlexColumn -ge 0 -and $FlexColumn -lt $n) {
        $widths[$FlexColumn] += $usable - $sum
    }

    $lines = New-Object System.Collections.Generic.List[object]

    $headCells = @()
    $sepCells  = @()
    for ($k = 0; $k -lt $n; $k++) {
        $headCells += (Fit-CellText -Text $Headers[$k] -Cells $widths[$k])
        $sepCells  += ('-' * $widths[$k])
    }
    $lines.Add([pscustomobject]@{ Text = ('  ' + ($headCells -join ' | ')); Color = 'Cyan' })
    $lines.Add([pscustomobject]@{ Text = ('  ' + ($sepCells -join '-+-'));  Color = 'DarkCyan' })

    $i = 0
    foreach ($r in $Rows) {
        $cells = @()
        for ($k = 0; $k -lt $n; $k++) {
            $v = ''
            if ($null -ne $r -and $k -lt $r.Count) { $v = [string]$r[$k] }
            $cells += (Fit-CellText -Text $v -Cells $widths[$k])
        }
        $color = 'White'
        if ($null -ne $RowColors -and $i -lt $RowColors.Count -and $RowColors[$i]) { $color = $RowColors[$i] }
        $lines.Add([pscustomobject]@{ Text = ('  ' + ($cells -join ' | ')); Color = $color })
        $i++
    }

    return $lines
}

function Write-TableLine {
    param($Line)
    if ($Line.Color) { Write-Host $Line.Text -ForegroundColor $Line.Color }
    else             { Write-Host $Line.Text }
}

function Show-Table {
    <#
      表格 + 滑动窗口：每页重复表头，回车/n 下翻、p 上翻、q 结束。
      非交互或一屏放得下时直接整表输出。
    #>
    param(
        [string[]]$Headers,
        [object]$Rows,
        [int[]]$MinWidths,
        [int]$FlexColumn = 1,
        [object]$RowColors = $null,
        [string]$Hint = '',
        [string]$Caption = ''
    )

    $size  = Get-ConsoleSize
    $lines = @(Format-TableLines -Headers $Headers -Rows $Rows -MinWidths $MinWidths `
                                 -FlexColumn $FlexColumn -RowColors $RowColors -Width $size.W)
    if ($lines.Count -lt 2) { return }

    $data = @()
    if ($lines.Count -gt 2) { $data = @($lines[2..($lines.Count - 1)]) }
    $perPage = [Math]::Max(6, $size.H - 7)

    if ($NonInteractive -or $data.Count -le $perPage) {
        if ($Hint) { Write-Host ('  ' + $Hint) -ForegroundColor DarkGray }
        foreach ($l in $lines) { Write-TableLine -Line $l }
        return
    }

    $head  = @($lines[0], $lines[1])
    $pages = [int][Math]::Ceiling($data.Count / [double]$perPage)
    $start = 0
    while ($true) {
        $end  = [Math]::Min($start + $perPage - 1, $data.Count - 1)
        $page = [int][Math]::Floor($start / [double]$perPage) + 1

        # 每翻一页都清屏，旧页不会堆在屏幕上；表头与标题重新打印
        Clear-ScreenNow
        if ($Caption) { Write-Host ('  ' + $Caption) -ForegroundColor White }
        if ($Hint)    { Write-Host ('  ' + $Hint) -ForegroundColor DarkGray }
        Write-Host ''

        foreach ($l in $head) { Write-TableLine -Line $l }
        for ($k = $start; $k -le $end; $k++) { Write-TableLine -Line $data[$k] }
        Write-Host ("  —— 第 {0}/{1} 页 · 第 {2}-{3}/{4} 行 ——" -f `
            $page, $pages, ($start + 1), ($end + 1), $data.Count) -ForegroundColor DarkGray

        $ans = Read-Host '  回车/n 下翻 · p 上翻 · q 结束'
        if ($ans -match '^[qQ]') { return }
        if ($ans -match '^[pPuUbB]') {
            $start = [Math]::Max(0, $start - $perPage)
            continue
        }
        if ($end -ge $data.Count - 1) { return }
        $start = $end + 1
    }
}

function Get-LevelColor {
    param([string]$Level)
    switch ($Level) {
        '常规'  { return 'Green' }
        '注意'  { return 'Yellow' }
        '驱动'  { return 'Magenta' }
        default { return 'DarkYellow' }
    }
}

function Show-UpgradeList {
    <# 可更新清单表格；编号按传入顺序，和手动挑选时的编号一致 #>
    param([array]$Items)

    # 反复出现的分组话术不逐条重复，只保留有个性的备注
    $noteFreq = @{}
    foreach ($it in $Items) {
        if ($it.Note) {
            $key = [string]$it.Note
            if ($noteFreq.ContainsKey($key)) { $noteFreq[$key]++ } else { $noteFreq[$key] = 1 }
        }
    }

    $rows   = New-Object System.Collections.Generic.List[object]
    $colors = New-Object System.Collections.Generic.List[string]
    $idx = 0
    foreach ($it in $Items) {
        $idx++
        $note = [string]$it.Note
        if ($note -and $noteFreq[$note] -ge 3) { $note = '' }

        $size = '-'
        $key  = [string]$it.Id + '|' + [string]$it.Available
        if ($script:SizeCache -and $script:SizeCache.ContainsKey($key)) {
            $bytes = 0
            try { $bytes = [long]$script:SizeCache[$key] } catch {}
            if ($bytes -gt 0) { $size = Format-FileSize -Bytes $bytes }
        }

        $rows.Add([string[]]@(
            [string]$idx,
            [string]$it.Level,
            [string]$it.Name,
            ('{0} → {1}' -f $it.Version, $it.Available),
            [string]$it.Id,
            $size,
            $note
        ))
        $colors.Add((Get-LevelColor -Level $it.Level))
    }

    Show-Table -Headers @('编号', '分档', '名称', '版本跨度', '包 ID', '大小', '备注') `
               -Rows $rows -MinWidths @(5, 8, 24, 18, 18, 9, 14) `
               -FlexColumn 2 -RowColors $colors `
               -Caption '可更新软件清单' `
               -Hint '分档：常规=工具/运行库，注意=客户端类，驱动=建议单独确认；大小探测不到时显示 -'
}

function Invoke-UpgradeCheck {
    <# -Refresh 只影响标题与提示文案，表示一轮升级结束后的复查 #>
    param([switch]$Refresh)

    # 区分「查到 0 条」和「查询失败」：后者不应让调用方误以为已全部升完
    $script:UpgradeCheckFailed = $false

    if ($Refresh) { Write-Title '刷新可更新清单（winget）' }
    else          { Write-Title '检查软件更新（winget）' }

    $exe = Get-WingetExe
    if (-not $exe) {
        Write-Host '  未找到 winget，无法检查更新。' -ForegroundColor Red
        Write-Host '  Win11 自带「应用安装程序」，可在 Microsoft Store 里修复它。' -ForegroundColor Yellow
        $script:UpgradeCheckFailed = $true
        return @()
    }

    Write-Host ("  winget: {0}" -f $exe) -ForegroundColor Gray
    if ($Refresh) { Write-Host '  正在重新检查可用更新...' -ForegroundColor Gray }
    else          { Write-Host '  正在联网查询可用更新（首次可能需要 30–90 秒）...' -ForegroundColor Gray }

    $items = Get-WingetUpgrades
    if ($null -eq $items) {
        Write-Host '  查询失败：winget 没有返回结果（网络或软件源问题）。' -ForegroundColor Red
        $script:UpgradeCheckFailed = $true
        return @()
    }
    if ($items.Count -eq 0) {
        Write-Host '  当前没有可升级的软件。' -ForegroundColor Green
        return @()
    }

    Write-Host ''
    Write-Host '  正在探测更新包大小（约十几秒，探测不到的显示 -）...' -ForegroundColor Gray
    if ($NonInteractive) { Get-UpgradeSizes -Items $items -BudgetSec 8 }
    else                 { Get-UpgradeSizes -Items $items }

    Write-Host ("  共 {0} 条可升级" -f $items.Count) -ForegroundColor White
    Show-UpgradeList -Items $items

    $totalBytes = [long]0
    $known = 0
    foreach ($it in $items) {
        $key = [string]$it.Id + '|' + [string]$it.Available
        if ($script:SizeCache -and $script:SizeCache.ContainsKey($key)) {
            $b = 0
            try { $b = [long]$script:SizeCache[$key] } catch {}
            if ($b -gt 0) { $totalBytes += $b; $known++ }
        }
    }
    if ($known -gt 0) {
        Write-Host ("  已探测 {0}/{1} 个包，合计约 {2}" -f $known, $items.Count, (Format-FileSize -Bytes $totalBytes)) -ForegroundColor DarkGray
    }
    if (-not $Refresh) {
        Write-Host '  winget 只覆盖有源数据的软件；绿色版、破解版、银行控件不在其中。' -ForegroundColor DarkYellow
    }
    return $items
}

function Format-UpgradeProgress {
    <#
      一行进度条：阶段 / 百分比 / 下载大小 / 已用时间。
      winget 没给百分比时（安装阶段常见）画脉冲条，仍然动态反馈，不伪造数字。
    #>
    param(
        [string]$Phase,
        [int]$Percent,
        [string]$SizeText,
        [int]$Seconds,
        [int]$MaxCells
    )

    $barCells = [Math]::Max(8, [Math]::Min(24, $MaxCells - 58))

    if ($Percent -ge 0) {
        $filled = [int][Math]::Round($barCells * $Percent / 100.0)
        if ($filled -gt $barCells) { $filled = $barCells }
        $bar = ('█' * $filled) + ('░' * ($barCells - $filled))
        $pct = ('{0,3}%' -f $Percent)
    } else {
        $pos = $Seconds % ($barCells + 4)
        $sb = New-Object System.Text.StringBuilder
        for ($k = 0; $k -lt $barCells; $k++) {
            if ([Math]::Abs($k - $pos) -le 1) { [void]$sb.Append('█') } else { [void]$sb.Append('░') }
        }
        $bar = $sb.ToString()
        $pct = '  - '
    }

    $line = ('        [{0}] [{1}] {2}' -f $Phase, $bar, $pct)
    if ($SizeText) { $line = $line + ('  ' + $SizeText) }
    $line = $line + ('  ·  {0}s' -f $Seconds)
    return (Limit-ConsoleWidth -Text $line -MaxCells $MaxCells)
}

function Read-WingetProgress {
    <# 从 winget 的一行输出里提取阶段、百分比、下载大小，并回填大小缓存 #>
    param(
        [string]$Text,
        [string]$Phase,
        [int]$Percent,
        [string]$SizeText,
        [string]$CacheKey
    )

    $newPhase   = $Phase
    $newPercent = $Percent
    $newSize    = $SizeText

    if ($Text -match '(?i)install|安装|校验|验证|hash') {
        if ($newPhase -ne '安装') { $newPhase = '安装'; $newPercent = -1; $newSize = '' }
    } elseif ($Text -match '(?i)download|下载|正在获取') {
        $newPhase = '下载'
    }
    if ($Text -match '已成功安装|Successfully installed') { $newPhase = '安装'; $newPercent = 100 }

    # 优先数字百分比，其次用 winget 自带方块进度条的填充比例
    $ms = [regex]::Matches($Text, '(\d{1,3})\s*%')
    if ($ms.Count -gt 0) {
        $p = [int]$ms[$ms.Count - 1].Groups[1].Value
        if ($p -ge 0 -and $p -le 100 -and $p -ge [Math]::Max(0, $newPercent)) { $newPercent = $p }
    } else {
        $filled = ([regex]::Matches($Text, '█')).Count
        $empty  = ([regex]::Matches($Text, '░')).Count
        if (($filled + $empty) -ge 5) {
            $p = [int][Math]::Round(100 * $filled / ($filled + $empty))
            if ($p -ge [Math]::Max(0, $newPercent)) { $newPercent = $p }
        }
    }

    $sm = [regex]::Match($Text, '(\d+(?:[.,]\d+)?)\s*(KB|MB|GB)\s*/\s*(\d+(?:[.,]\d+)?)\s*(KB|MB|GB)', 'IgnoreCase')
    if ($sm.Success) {
        $newSize = ('{0} {1} / {2} {3}' -f `
            $sm.Groups[1].Value, $sm.Groups[2].Value.ToUpper(), $sm.Groups[3].Value, $sm.Groups[4].Value.ToUpper())
        if ($CacheKey -and $script:SizeCache) {
            $bytes = Convert-SizeToBytes -Number $sm.Groups[3].Value -Unit $sm.Groups[4].Value
            if ($bytes -gt 0) { $script:SizeCache[$CacheKey] = $bytes }
        }
    }

    return [pscustomobject]@{ Phase = $newPhase; Percent = $newPercent; SizeText = $newSize }
}

function Get-UpgradeFailureReason {
    <#
      把 winget 的原始输出翻成一句中文短原因。
      结果表格的「详情」列很窄，这里只给结论，技术细节另放。
    #>
    param([int]$Code, [string]$Text)

    $t = [string]$Text

    # winget 有时退出码是 0，但 MSIX 部署其实失败了，所以这些特征要优先判
    if ($t -match '0x80073D02|需要关闭以下应用|close the following app|无法安装，因为需要关闭') {
        return '软件正在运行，关闭后重试'
    }
    if ($t -match '0x80190193|已禁止\s*[（(]?\s*403|返回状态[:：]?\s*403|Returned status:\s*403|HTTP\s+403|403\s+Forbidden|Download request failed[^\r\n]{0,80}403') {
        return '下载被服务器拒绝 403，稍后重试或手动安装'
    }
    if ($t -match '0x80072EFD|0x80072EE7|0x80072F8F|无法连接到|无法连接|could not connect|connection.*timed out|连接超时|网络错误') {
        return '网络连接失败，检查网络后重试'
    }
    if ($t -match '哈希不匹配|hash does not match|hash mismatch|校验失败|Installer hash') {
        return '安装包校验失败，清理缓存后重试'
    }
    if ($t -match '0x80070005|拒绝访问|Access is denied|需要管理员|权限不足') {
        return '权限不足，需以管理员运行'
    }
    if ($t -match '磁盘空间|not enough space|insufficient disk') {
        return '磁盘空间不足'
    }
    if ($t -match '0x80070666|0x80070667|已安装了另一个版本|another version is already installed') {
        return '版本冲突，需先卸载旧版本'
    }
    if ($t -match 'Installer failed|安装器失败|安装失败|安装程序返回|安装程序失败') {
        return '安装器执行失败，可能需要交互确认'
    }
    if ($t -match '找不到|not found|没有找到匹配|no package found') {
        return '源里找不到该包或版本不匹配'
    }

    if ($Code -eq 0) { return '' }
    return '升级未完成（winget 返回非零退出码）'
}

function Resolve-UpgradeOutcome {
    <#
      统一判定升级结果。Status 是状态，Detail 是给用户看的一句中文，
      Tech 是退出码等技术信息（只在失败时用到）。
    #>
    param([int]$Code, [string]$StdOut, [string]$StdErr)

    $all    = ([string]$StdOut + "`n" + [string]$StdErr)
    $reason = Get-UpgradeFailureReason -Code $Code -Text $all
    $tech   = ("exit {0}" -f $Code)

    # 明确的失败特征优先于退出码：winget 对「MSIX 部署失败」可能仍返回 0
    $hardFail = '0x80073D02|需要关闭以下应用|0x80190193|已禁止\s*[（(]?\s*403|Returned status:\s*403|Installer failed|安装失败'
    if ($all -match $hardFail) {
        if ([string]::IsNullOrWhiteSpace($reason)) { $reason = '升级未完成，请重试' }
        return [pscustomobject]@{ Status = '失败'; Detail = $reason; Tech = $tech }
    }

    if ($Code -eq 0 -or $all -match '已成功安装|Successfully installed|成功安装') {
        $note = ''
        if ($Code -ne 0) { $note = '已完成安装（安装器可能要求重启）' }
        return [pscustomobject]@{ Status = '成功'; Detail = $note; Tech = '' }
    }

    if ($Code -eq -1978335189 -or $all -match '找不到可用的升级|No available upgrade|没有可用的较新') {
        return [pscustomobject]@{ Status = '跳过'; Detail = '已是最新版本，无需更新'; Tech = '' }
    }

    if ([string]::IsNullOrWhiteSpace($reason)) { $reason = '升级未完成，请重试' }
    return [pscustomobject]@{ Status = '失败'; Detail = $reason; Tech = $tech }
}

function Invoke-WingetUpgradeOne {
    <#
      升级单个包。带超时：大体积软件可能下载很久，超时后终止并记为「超时」。
      用 System.Diagnostics.Process 而不是 Start-Process -PassThru 启动：
      本机 PowerShell 5.1 下后者的 ExitCode 读出来是 $null（进程确已退出，
      HasExited 为 True、Refresh() 也无效），会把每次升级都误判成失败。
    #>
    param([string]$Id, [string]$CacheKey = '', [int]$TimeoutSec = 600)

    $exe = Get-WingetExe

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $exe
    $psi.Arguments              = ('upgrade --id "{0}" --silent --accept-package-agreements --accept-source-agreements --disable-interactivity' -f $Id)
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    try {
        $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
        $psi.StandardErrorEncoding  = [Text.Encoding]::UTF8
    } catch {}

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    try {
        [void]$proc.Start()
    } catch {
        return [pscustomobject]@{ Id = $Id; Status = '失败'; Detail = "无法启动 winget: $($_.Exception.Message)" }
    }

    # 逐行读 winget 输出，解析成下载/安装进度条，单行原地刷新、不滚屏不折行。
    $outSb      = New-Object System.Text.StringBuilder
    $errTask    = $proc.StandardError.ReadToEndAsync()
    $lineTask   = $proc.StandardOutput.ReadLineAsync()
    $sw         = [System.Diagnostics.Stopwatch]::StartNew()
    $phase      = '准备'
    $percent    = -1
    $sizeText   = ''
    $lastText   = ''
    $lastSec    = -1
    $lastCells  = 0
    $timedOut   = $false

    while ($true) {
        if ($sw.Elapsed.TotalSeconds -ge $TimeoutSec) { $timedOut = $true; break }

        $changed = $false
        if ($lineTask.IsCompleted) {
            $line = $null
            try { $line = $lineTask.Result } catch {}
            if ($null -eq $line) { break }   # 输出流结束

            # winget 用 \r 原地刷新进度，同一次读取里可能混着多段。
            # 全部留作诊断依据（错误可能出现在被覆盖的前一段里），
            # 只用最后一段渲染进度条。
            $parts = @($line -split "`r" | Where-Object { $_.Trim() })
            if ($parts.Count -gt 0) {
                foreach ($seg in $parts) {
                    $s = $seg.Trim()
                    if ($s) { [void]$outSb.AppendLine($s) }
                }
                $text = $parts[$parts.Count - 1].Trim()
                if ($text) {
                    $p = Read-WingetProgress -Text $text -Phase $phase -Percent $percent `
                                             -SizeText $sizeText -CacheKey $CacheKey
                    $phase = $p.Phase; $percent = $p.Percent; $sizeText = $p.SizeText
                    $changed = $true
                }
            }
            $lineTask = $proc.StandardOutput.ReadLineAsync()
        }

        $sec = [int]$sw.Elapsed.TotalSeconds
        if ($sec -ne $lastSec) { $lastSec = $sec; $changed = $true }

        if ($changed) {
            # 留 1 列余量：刚好撑满窗口宽度时控制台仍会自动换行
            $maxCells = [Math]::Max(24, (Get-ConsoleSize).W - 1)
            $shown = Format-UpgradeProgress -Phase $phase -Percent $percent -SizeText $sizeText `
                                            -Seconds $sec -MaxCells $maxCells
            $cells = Get-ConsoleCellWidth -Text $shown
            $pad   = [Math]::Max(0, $lastCells - $cells)
            $color = 'DarkCyan'
            if ($phase -eq '安装') { $color = 'Cyan' }
            Write-Host -NoNewline ("`r" + $shown + (' ' * $pad)) -ForegroundColor $color
            $lastCells = $cells
        }

        if (-not $lineTask.IsCompleted) { Start-Sleep -Milliseconds 150 }
    }
    $sw.Stop()

    # 进度行定稿，之后的 OK / 失败从新行开始
    if ($lastCells -gt 0) {
        $maxCells   = [Math]::Max(24, (Get-ConsoleSize).W - 1)
        $finalPhase = '完成'
        $finalPct   = 100
        if ($timedOut) { $finalPhase = '超时'; $finalPct = 0 }
        $final = Format-UpgradeProgress -Phase $finalPhase -Percent $finalPct -SizeText $sizeText `
                                        -Seconds ([int]$sw.Elapsed.TotalSeconds) -MaxCells $maxCells
        $pad   = [Math]::Max(0, $lastCells - (Get-ConsoleCellWidth -Text $final))
        Write-Host -NoNewline ("`r" + $final + (' ' * $pad)) -ForegroundColor DarkGray
        Write-Host ''
    }

    if ($timedOut) {
        try { $proc.Kill() } catch {}
        return [pscustomobject]@{ Id = $Id; Status = '超时'; Detail = "超过 $TimeoutSec 秒未完成，已终止" }
    }

    try { [void]$proc.WaitForExit(3000) } catch {}
    $errText = ''
    try { $errText = [string]$errTask.Result } catch { $errText = '' }

    $out = $outSb.ToString()

    $code = $null
    try { $code = [int]$proc.ExitCode } catch { $code = $null }
    if ($null -eq $code) { $code = -1 }

    # stderr 也要一起判定：winget 的下载/部署错误常常只写在那边。
    return (Resolve-UpgradeOutcome -Code $code -StdOut $out -StdErr $errText)
}

function Select-UpgradeTargets {
    <#
      范围选择循环：取消、无效输入、空范围都留在这一页重选；
      返回 Cancel=$true 表示选 [0] 退出升级流程、回主菜单。
    #>
    param([array]$Items)

    $low    = @($Items | Where-Object { $_.Level -eq '常规' })
    $mid    = @($Items | Where-Object { $_.Level -eq '注意' })
    $driver = @($Items | Where-Object { $_.Level -eq '驱动' })

    while ($true) {
        Write-Title '选择更新范围'
        Write-Host ("   [1] 只更新常规软件（{0} 条，推荐）" -f $low.Count) -ForegroundColor Green
        Write-Host ("   [2] 常规 + 注意（{0} 条）" -f ($low.Count + $mid.Count)) -ForegroundColor Yellow
        Write-Host ("   [3] 全部（{0} 条，含驱动 {1} 条）" -f $Items.Count, $driver.Count) -ForegroundColor Red
        Write-Host '   [4] 手动输入要更新的包 ID' -ForegroundColor White
        Write-Host '   [0] 返回主菜单' -ForegroundColor DarkGray
        Write-Host ''

        $choice = '1'
        if (-not $NonInteractive) { $choice = Read-Host '  请选择' }

        if ($choice -eq '0') { return [pscustomobject]@{ Cancel = $true;  Targets = @() } }
        if ($choice -eq '1') { return [pscustomobject]@{ Cancel = $false; Targets = @($low) } }
        if ($choice -eq '2') { return [pscustomobject]@{ Cancel = $false; Targets = @($low + $mid) } }
        if ($choice -eq '3') { return [pscustomobject]@{ Cancel = $false; Targets = @($Items) } }

        if ($choice -eq '4') {
            Write-Host ''
            Write-Host '  下面是全部可更新的包，输入前面的编号即可（也可直接粘贴 ID）:' -ForegroundColor White
            Show-UpgradeList -Items $Items

            Write-Host ''
            # 注意：不能用 $input，它是 PowerShell 的自动变量（管道输入枚举器）
            $answerText = Read-Host '  输入编号或包 ID（多个用逗号分隔，例如 1,5,9；输入 0 重选范围）'
            if (-not $answerText) {
                Write-Host '  没有输入，请重新选择。' -ForegroundColor Yellow
                continue
            }
            if ($answerText.Trim() -eq '0') { continue }

            $tokens = @($answerText -split '[,;，；\s]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $picked = New-Object System.Collections.Generic.List[object]

            foreach ($tk in $tokens) {
                if ($tk -match '^\d+$') {
                    $n = [int]$tk
                    if ($n -ge 1 -and $n -le $Items.Count) {
                        $picked.Add($Items[$n - 1])
                    } else {
                        Write-Host ("    编号 {0} 超出范围（1-{1}），已跳过。" -f $n, $Items.Count) -ForegroundColor Yellow
                    }
                } else {
                    $hit = @($Items | Where-Object { $_.Id -eq $tk })
                    if ($hit.Count -gt 0) { $picked.Add($hit[0]) }
                    else { Write-Host ("    未找到包 ID: {0}，已跳过。" -f $tk) -ForegroundColor Yellow }
                }
            }

            if ($picked.Count -eq 0) {
                Write-Host '  没有匹配的可升级条目，请重新选择。' -ForegroundColor Yellow
                continue
            }

            # 同一包可能被编号和 ID 各指一次，去重
            return [pscustomobject]@{ Cancel = $false; Targets = @($picked | Sort-Object Id -Unique) }
        }

        Write-Host '  无效的选项，请输入 0-4。' -ForegroundColor Red
    }
}

function Invoke-UpgradeRun {
    <#
      交互模式下每完成一轮升级就自动重新联网刷新可更新清单，并回到
      「选择更新范围」，可以接着挑下一批；选 [0] 或已全部为最新才回主菜单。
      非交互 / 演练仍只跑一轮，避免自动化任务里循环。
    #>
    $needRefresh = $true
    $firstCheck  = $true
    $items       = @()
    $maxCols     = [Math]::Max(40, (Get-ConsoleSize).W - 1)

    while ($true) {
        if ($needRefresh) {
            if (-not $firstCheck) { Clear-ScreenNow }   # 新一轮刷新，清掉上一轮的结果
            $oldItems = @($items)
            if ($firstCheck) { $items = @(Invoke-UpgradeCheck) }
            else             { $items = @(Invoke-UpgradeCheck -Refresh) }
            $firstCheck = $false

            # 查询失败不等于「已全部升完」：有旧清单就留在范围选择继续用旧清单
            if ($script:UpgradeCheckFailed) {
                Write-Host '  清单刷新失败，未改动任何软件。' -ForegroundColor Red
                if ($oldItems.Count -eq 0 -or $NonInteractive) { break }
                Write-Host '  继续使用上一份清单。' -ForegroundColor DarkGray
                $items       = $oldItems
                $needRefresh = $false
                continue
            }
            if ($items.Count -eq 0) {
                Write-Host '  当前已没有可更新的软件，返回主菜单。' -ForegroundColor Green
                break
            }
        }

        $sel = Select-UpgradeTargets -Items $items
        if ($sel.Cancel) { break }
        $targets = @($sel.Targets)

        if ($targets.Count -eq 0) {
            if ($NonInteractive) { break }
            Write-Host '  该范围内没有可更新的条目，请重新选择。' -ForegroundColor Yellow
            $needRefresh = $false      # 同一份清单重选即可，不必再联网
            continue
        }

        Write-Host ''
        Write-Host ("  即将更新 {0} 条：" -f $targets.Count) -ForegroundColor White
        $pendingRows   = New-Object System.Collections.Generic.List[object]
        $pendingColors = New-Object System.Collections.Generic.List[string]
        foreach ($t in $targets) {
            $pendingRows.Add([string[]]@(
                [string]$t.Name,
                ('{0} → {1}' -f $t.Version, $t.Available),
                [string]$t.Level,
                [string]$t.Id
            ))
            $pendingColors.Add((Get-LevelColor -Level $t.Level))
        }
        Show-Table -Headers @('名称', '版本跨度', '分档', '包 ID') -Rows $pendingRows `
                   -MinWidths @(24, 18, 8, 20) -FlexColumn 0 -RowColors $pendingColors -Caption '本轮待更新'
        Write-Host ''
        Write-Host '  注意：winget 的升级是重新安装，不是打补丁；升级后一般无法回滚到旧版本。' -ForegroundColor Yellow
        Write-Host '        升级过程中请勿关闭窗口，也不要同时使用这些软件。' -ForegroundColor Yellow

        if (-not $NonInteractive) {
            $confirm = Read-Host "`n  确认开始更新？(y/N)"
            if ($confirm -ne 'y') {
                Write-Host '  已取消，未做任何修改。' -ForegroundColor Yellow
                $needRefresh = $false
                continue
            }
        }

        Clear-ScreenNow
        Write-Title '开始更新'
        $results = New-Object System.Collections.Generic.List[object]
        $i = 0

        foreach ($t in $targets) {
            $i++
            $head = ("  [{0}/{1}] {2}   {3} -> {4}" -f $i, $targets.Count, $t.Name, $t.Version, $t.Available)
            Write-Host (Limit-ConsoleWidth -Text $head -MaxCells $maxCols) -ForegroundColor White

            if ($DryRun) {
                Write-Host '        —— 演练模式，跳过' -ForegroundColor DarkGray
                $results.Add([pscustomobject]@{ Name = $t.Name; Id = $t.Id; Status = '演练跳过'; Detail = '' })
                continue
            }

            $cacheKey = [string]$t.Id + '|' + [string]$t.Available
            $r = Invoke-WingetUpgradeOne -Id $t.Id -CacheKey $cacheKey
            $results.Add([pscustomobject]@{ Name = $t.Name; Id = $t.Id; Status = $r.Status; Detail = $r.Detail; Tech = $r.Tech })

            if ($r.Status -eq '成功') {
                Write-Host '        OK' -ForegroundColor Green
            } elseif ($r.Status -eq '跳过') {
                Write-Host '        已是最新' -ForegroundColor Yellow
            } else {
                Write-Host ("        {0}" -f $r.Status) -ForegroundColor Red
                if ($r.Detail) {
                    $why = Limit-ConsoleWidth -Text ("  原因：" + [string]$r.Detail) -MaxCells ([Math]::Max(20, $maxCols - 8))
                    Write-Host ('        ' + $why) -ForegroundColor DarkYellow
                }
            }
        }

        # 汇总
        $ok      = @($results | Where-Object { $_.Status -eq '成功' })
        $skipped = @($results | Where-Object { $_.Status -eq '跳过' })
        $failed  = @($results | Where-Object { $_.Status -ne '成功' -and $_.Status -ne '跳过' })

        Write-Title '更新结果'

        if ($DryRun) {
            Write-Host ("  演练模式：已识别 {0} 条待更新，未执行任何实际升级。" -f $targets.Count) -ForegroundColor DarkCyan
            Write-Host '  去掉 -DryRun 参数后才会真正执行。' -ForegroundColor DarkGray
        } else {
            $summary = "  成功 {0} 条" -f $ok.Count
            if ($skipped.Count -gt 0) { $summary = $summary + ("，已是最新 {0} 条" -f $skipped.Count) }
            if ($failed.Count -gt 0)  { $summary = $summary + ("，失败 {0} 条" -f $failed.Count) }
            Write-Host $summary -ForegroundColor White

            if ($failed.Count -gt 0) {
                Write-Host ''
                Write-Host '  失败的条目：' -ForegroundColor Yellow
                $failRows   = New-Object System.Collections.Generic.List[object]
                $failColors = New-Object System.Collections.Generic.List[string]
                foreach ($f in $failed) {
                    $failRows.Add([string[]]@([string]$f.Name, [string]$f.Status, [string]$f.Detail))
                    $failColors.Add('Red')
                }
                Show-Table -Headers @('名称', '状态', '详情') -Rows $failRows `
                           -MinWidths @(24, 10, 36) -FlexColumn 2 -RowColors $failColors
                Write-Host ''
                $techLines = @($failed | Where-Object { $_.Tech })
                if ($techLines.Count -gt 0) {
                    Write-Host '  技术信息（供排查）：' -ForegroundColor DarkGray
                    foreach ($f in $techLines) {
                        Write-Host ("    {0}  {1}" -f $f.Name, $f.Tech) -ForegroundColor DarkGray
                    }
                    Write-Host ''
                }
                Write-Host '  提示：403 多为厂商源站/镜像问题，稍后重试或手动安装；软件正在运行请先关闭。' -ForegroundColor DarkYellow
                Write-Host '  可直接在下面刷新后的清单里选「手动挑选」重试（编号以新清单为准）。' -ForegroundColor DarkYellow
            }
        }

        if ($NonInteractive -or $DryRun) { break }

        Write-Host ''
        Write-Host '  本轮完成，正在刷新可更新清单...' -ForegroundColor Cyan
        $needRefresh = $true
    }
}

# ============================================================
#  主流程
# ============================================================

function Invoke-ScanOnly {
    Write-Title '扫描已安装应用列表'
    Write-Host ("  管理员权限: {0}" -f (Test-IsAdmin)) -ForegroundColor Gray
    Write-Host '  正在读取注册表...' -ForegroundColor Gray

    $entries = Get-AppEntries -WithHidden:$IncludeHidden
    Show-ScanResult -Entries $entries

    return $entries
}

function Invoke-CleanFlow {
    $entries = Invoke-ScanOnly

    $targets = @($entries | Where-Object { $_.Verdict -eq 'GHOST' })
    if ($IncludeSuspect) {
        $targets += @($entries | Where-Object { $_.Verdict -eq 'SUSPECT' })
    }
    $targets = @($targets)

    Write-Title '清理确认'
    if ($targets.Count -eq 0) {
        Write-Host '  没有符合条件的待清理条目。' -ForegroundColor Green
        return
    }

    Write-Host ("  将删除以下 {0} 条注册表记录（只删条目，不删任何文件）:" -f $targets.Count) -ForegroundColor White
    $cleanRows   = New-Object System.Collections.Generic.List[object]
    $cleanColors = New-Object System.Collections.Generic.List[string]
    $ci = 0
    foreach ($t in $targets) {
        $ci++
        $cleanRows.Add([string[]]@([string]$ci, [string]$t.DisplayName, [string]$t.Verdict, [string]$t.RegPath))
        if ($t.Verdict -eq 'GHOST') { $cleanColors.Add('Red') } else { $cleanColors.Add('Yellow') }
    }
    Show-Table -Headers @('编号', '名称', '判定', '注册表路径') -Rows $cleanRows `
               -MinWidths @(5, 24, 10, 30) -FlexColumn 1 -RowColors $cleanColors -Caption '待清理条目'

    if (-not $NonInteractive) {
        $confirm = Read-Host ("`n  确认清理这 {0} 条？删除前会逐条导出备份；输入 n 则只看不删。(y/N)" -f $targets.Count)
        if ($confirm -ne 'y') { Write-Host '  已取消，注册表未做任何修改。' -ForegroundColor Yellow; return }
    }

    Write-Host ''
    Invoke-CleanEntries -Entries $targets | Out-Null

    Write-Host ''
    Write-Host '  提示：重新打开「设置 → 应用 → 已安装的应用」即可看到列表已更新。' -ForegroundColor Cyan
}

function Show-Menu {
    Write-Host ''
    Write-Host '  ============================================================' -ForegroundColor Cyan
    Write-Host ("   CleanWindowsDirtyApp  v{0}" -f $ScriptVersion) -ForegroundColor Cyan
    Write-Host '   清理「设置 → 应用」中指向已不存在软件的残留条目' -ForegroundColor Cyan
    Write-Host '   并按 winget 批量更新有可用新版本的软件' -ForegroundColor Cyan
    Write-Host '  ============================================================' -ForegroundColor Cyan
    Write-Host ("   管理员权限: {0}" -f (Test-IsAdmin)) -ForegroundColor Gray
    Write-Host ''
    Write-Host '   [1] 扫描及清理' -ForegroundColor White
    Write-Host '   [2] 从备份恢复' -ForegroundColor White
    Write-Host '   [3] 执行软件更新（先列出可更新清单，确认前不改任何东西）' -ForegroundColor White
    Write-Host '   [0] 退出' -ForegroundColor DarkGray
    Write-Host ''
}

function Invoke-Menu {
    while ($true) {
        Clear-ScreenNow
        Show-Menu
        $choice = Read-Host '  请选择'

        switch ($choice) {
            '1' {
                Clear-ScreenNow
                Invoke-CleanFlow
                Read-Host "`n  按回车返回菜单" | Out-Null
            }
            '2' {
                Clear-ScreenNow
                Invoke-Restore
                Read-Host "`n  按回车返回菜单" | Out-Null
            }
            '3' {
                Clear-ScreenNow
                Invoke-UpgradeRun
                Read-Host "`n  按回车返回菜单" | Out-Null
            }
            '0' {
                Write-Host '  已退出。' -ForegroundColor Gray
                return
            }
            default {
                Write-Host '  无效的选项，请输入 0-3。' -ForegroundColor Red
            }
        }
    }
}

# ============================================================
#  入口
# ============================================================

if (-not $NonInteractive) {
    $winWidth = Set-ConsoleMaximized
    if ($winWidth -gt 0 -and $winWidth -lt 110) {
        Write-Host '  建议最大化窗口（Alt+空格 → X），表格列会更完整。' -ForegroundColor DarkYellow
    }
}

Write-Host ''
Write-Host ("  CleanWindowsDirtyApp v{0}  |  {1}" -f $ScriptVersion, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -ForegroundColor DarkGray

switch ($Mode) {
    'Scan'        { Invoke-ScanOnly | Out-Null }
    'Clean'       { Invoke-CleanFlow }
    'Restore'     { Invoke-Restore }
    'UpdateCheck' { Invoke-UpgradeCheck | Out-Null }
    'UpdateRun'   { Invoke-UpgradeRun }
    'Menu'        { Invoke-Menu }
}

Write-Host ''
