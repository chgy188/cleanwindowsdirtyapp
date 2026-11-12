# CleanWindowsDirtyApp

> **一条命令运行（推荐）**：复制下面这一行，粘贴到 PowerShell 或 CMD 执行即可。会自动下载脚本、做 SHA256 校验、请求管理员权限并进入交互菜单，本机不用预先安装任何东西。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://cleanwindowsdirtyapp.pages.dev/bootstrap.ps1 | iex"
```

已经在 PowerShell 窗口里的话，直接 `irm https://cleanwindowsdirtyapp.pages.dev/bootstrap.ps1 | iex` 即可；托管与自建说明见下方「一条命令远程运行」。

清理 Windows「设置 → 应用 → 已安装的应用」列表里**指向已不存在软件**的残留条目（下称"幽灵条目"）。

典型场景：某个软件早就删了 / 目录被手动删了，但设置里那一行还在，点"卸载"报错或毫无反应。

---

## 快速开始

**双击 `Run.bat`** 即可。会自动请求管理员权限，然后给出交互菜单：

```
[1] 扫描及清理
[2] 从备份恢复
[3] 执行软件更新
[0] 退出
```

第一次跑选 `[1]`：它会先扫描、把清单列给你，答 `n` 就只看不删；确认清单无误后再答 `y`。

脚本不生成任何报告文件或运行日志，结果只在屏幕上显示；唯一落盘的是删除前的 `.reg` 备份。

启动时会尝试把控制台窗口**最大化**（取不到窗口句柄时静默降级，宽度不足会提示手动最大化）；返回菜单、进入功能、表格翻页、刷新清单、开始更新时都会**清屏**，屏幕上始终只留当前这一屏的内容。

---

## 一条命令远程运行（服务器托管）

脚本已托管在 Cloudflare Pages，用户不用下载压缩包、不用记参数，只执行一条命令：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://cleanwindowsdirtyapp.pages.dev/bootstrap.ps1 | iex"
```

如果已经在 PowerShell 窗口里，更短的形式也可以：

```powershell
irm https://cleanwindowsdirtyapp.pages.dev/bootstrap.ps1 | iex
```

`$Sources` 按「Pages → GitHub raw → 四个 GitHub raw 前缀镜像」依次回退，`$Sha256` 已填发布版本主脚本的哈希。

**自建托管时要做的三件事**

1. 把 `bootstrap.ps1` 和 `src/CleanWindowsDirtyApp.ps1` 上传到 HTTPS 主机，主脚本文件名必须保持 `CleanWindowsDirtyApp.ps1`；`$Sources` 填的是**主脚本所在目录**（本项目为 `/src`），bootstrap 放在任意可访问路径都行。
2. 编辑 `bootstrap.ps1` 顶部的 `$Sources`。可填多个源，第一个失败会自动依次尝试后面的；GitHub raw 可配合 `gh-proxy.org` / `gh-proxy.com` / `github.tbap.top` / `ghfile-geekertao.top` 这类 **URL 前缀型镜像**兜底（只用于下载脚本自身，不会改变 winget 的升级源）。用 Cloudflare Pages 时建议同时发布 `_headers`，给两个 `.ps1` 指定 `Content-Type: text/plain; charset=utf-8`，否则部分客户端会把响应当二进制。
3. 可选但强烈建议：把主脚本的 SHA256 填进 `$Sha256`（**每次更新主脚本都要同步更新并重新部署，否则用户下载会被校验拦下**）：

   ```powershell
   (Get-FileHash .\src\CleanWindowsDirtyApp.ps1 -Algorithm SHA256).Hash
   ```

   留空时只做基本校验（文件大于 1 KB、内容含 `CleanWindowsDirtyApp`、排除 HTML 错误页），不校验完整性。

**用户那边会发生什么**

`bootstrap.ps1` 是纯 ASCII 的短脚本，专门为了让 `irm | iex` 可靠：它把主脚本下载到 `%USERPROFILE%\CleanWindowsDirtyApp\CleanWindowsDirtyApp.ps1`，校验通过后自动请求管理员权限，再以 `-File` 方式启动主脚本并传入 `-OutputRoot`，所以 `.reg` 备份会落在同一目录下的 `backups/`。下载源全部失败时直接报错退出，**不会执行任何东西**，也不会用失败残留覆盖已有的可用脚本。

不直接 `irm 主脚本 | iex` 的原因：主脚本是 UTF-8 BOM 且依赖 `$PSScriptRoot`，从字符串执行时取值不可靠；提权和备份目录也需要一个确定的本地路径。

**发布流程**：改完脚本 → `git push` 到 GitHub → 重新计算主脚本 SHA256 并更新 `bootstrap.ps1` 的 `$Sha256` → 用 `wrangler pages deploy <发布目录> --project-name cleanwindowsdirtyapp --branch main` 重新部署。发布目录只放 `bootstrap.ps1`、`src/CleanWindowsDirtyApp.ps1` 和 `_headers`，不要把本机扫描结果传上去。当前 Pages 项目是 Wrangler 的 **Direct Upload** 类型，不会自动跟随 GitHub 提交。

> **安全提示**：`irm | iex` 等于把服务器返回的内容直接当代码执行，只填自己控制的 HTTPS 源，并填写 SHA256。
>
> **不做 winget 自动安装**：Win11 自带 `winget`，`[3] 执行软件更新` 直接可用；极少数没有 winget 的机器上只有该项不可用，扫描与清理不受影响。

---

## 它到底做了什么

1. 枚举三处注册表位置（64 位 / 32 位 / 当前用户）
2. 逐条按**固定优先级**取证，判成四类
3. 只对确认失效的条目动手，**删除前逐条导出 `.reg` 备份**
4. 所有清单以表格 + 滑动窗口的方式显示在控制台
5. 更新时逐包显示下载 / 安装动态进度条

**它不删除任何程序文件、不卸载任何软件、不触碰 MSI 子组件与系统运行库。**

---

## 判定规则（分级）

| 级别 | 含义 | 默认处理 |
|---|---|---|
| `PROTECTED` | 系统组件、运行库、驱动、更新、MSI 隐藏分包 | 永不触碰 |
| `OK` | 安装目录存在 / 主程序存在 / MSI 产品仍登记 | 不动 |
| `SUSPECT` | 只剩卸载器、或 MSI 条目在安装数据库里查无记录 | 默认不动，加 `-IncludeSuspect` 才处理 |
| `GHOST` | 安装目录和程序文件全部不存在 | **默认清理目标** |

取证顺序（严格分层，专门避免误判）：

1. MSI 条目 → 调 Windows Installer 官方 COM API 的 `ProductState` 查产品状态
   （不靠手算 packed GUID 去猜注册表键名——那个分段倒序规则极易写错，
   会把 Cubase、GitHub CLI、PuTTY 这类正常软件整批判成失效）
2. `InstallLocation` 是否为**真实存在的目录**
3. `UninstallString` / `QuietUninstallString` / `DisplayIcon` 里的 **`.exe`** 是否存在
4. 文件名像卸载器（`unins*`、`uninstall*`、`setup*`、`卸载*`）→ 只算"卸载器"，不算"软件还在"；
   但若卸载器所在目录或上一级仍有其它 `.exe/.dll`（绿色软件、VST 插件常见），仍判为 `OK`
5. `DisplayIcon` 里的 `.ico` 一律忽略 —— 破解/绿色包的图标常指向第三方共享图标（如 `D:\InnoFE\GFX\Air.ico`），图标活着不代表软件还在

---

## 区分绿色软件（便携版）

扫描结果里每条记录多一个 `DeployType` 字段，取值：

| 类型 | 含义 |
|---|---|
| `安装版` | 走正规安装器（MSI 产品、或目录内有卸载组件、或装在 Program Files） |
| `绿色/便携` | 没有正式卸载流程，删掉程序目录就算干净，但注册表条目会留下 |
| `疑似绿色` | 有部分绿色特征，证据不足以下结论 |
| `系统组件` | 保护名单内，不参与部署类型判定 |

判定是加权打分，每条记录都附带 `DeployWhy` 说明得了哪些分：

| 信号 | 权重 |
|---|---|
| 装在自定义目录（不在 Program Files / Windows / AppData\Local\Programs） | +2 |
| 安装目录内**没有任何**卸载组件（`unins000.dat` / `uninstall.exe` / `卸载.exe`） | +3（系统目录下只 +1，弱信号） |
| 目录内有 `!)xxx.bat`、或"绿化/绿色/portable"标记 | +2 |
| 注册在 `HKCU`（绿色软件通常不提权写 HKLM） | +1 |
| 目录内有卸载组件 | −2 |
| 与其它软件的安装目录重叠（安装器的组件布局，如 MAGIX Content） | −2 |
| MSI 产品 | 直接判安装版 |

≥5 分判 `绿色/便携`，3–4 分判 `疑似绿色`。

**为什么是启发式而不是断言**：绿色包装完常把 `!)绿化.bat` 删掉，特征文件就没了；有些绿色版仍带打包器生成的卸载器；正常安装也允许改到 D 盘。所以每条都写清依据，供你人工复核，而不是给一个绝对结论。

本机实测：9 条判为绿色（5 个 VST 插件、RaiDrive、以及 winget 便携安装的 Deno / FFmpeg / yt-dlp），2 条疑似（MAGIX，因目录与内容包重叠被降级），NVIDIA 驱动组件、Copilot、Update Notifier 等均正确排除。

---

## 软件更新（可选）

`[3] 执行更新`，数据源只有一个：**winget**（Windows 自带的应用商店命令行）。不自己爬各家官网。

进入 `[3]` 后先联网检查、列出可更新清单，再问你更新范围——**在确认之前不会改动任何软件**，只想看清单的话看完选 `[0]` 返回即可。

每完成一轮更新会自动重新联网刷新可更新清单，并回到「选择更新范围」，可以直接接着挑下一批（清单与编号都已更新）；选 `[0]` 或已全部为最新才返回主菜单。取消确认、空范围、无效输入也都留在这一页重选，不会退回主菜单。

执行时每个包显示一条**动态进度条**，区分「下载」和「安装」两个阶段，例如：

```
        [下载] [██████████░░░░░░░]  62%  12.3 MB / 45.6 MB  ·  12s
```

百分比与「已下载 / 总量」取自 winget 输出，整行原地刷新、按窗口宽度截断，不换行不刷屏；安装器没给百分比时（很常见）改用脉冲条，不伪造数字。单个包超过 10 分钟会自动终止并记为「超时」，不影响后面的包继续。

**所有清单统一用表格显示**：扫描结果、可更新软件、备份批次、清理确认、更新结果都是对齐的列（编号 / 名称 / 版本跨度 / 分档 / 包 ID / 大小 / 备注等）。列宽按窗口自适应，中文按两列宽对齐，超长内容以 `…` 省略，一行就是一条、不会折行。

可更新清单多一列**「大小」**：winget 的升级清单本身不带包大小，脚本会分批并发跑 `winget show` 拿到安装程序 URL，再用 HEAD 请求读 `Content-Length`，并在清单下方给出已探测包的合计下载量。探测有耗时上限（清单查询 30 秒 / 非交互 8 秒，大小请求另限 8 秒），拿不到的显示 `-`，不会阻塞升级；下载时解析到的真实大小会回填，且下一轮刷新清单会自动重试上次没探测到的包（每个只重试一次）。

超过窗口高度时启用**滑动窗口**：每页清屏、重复标题和表头，回车或 `n` 下翻、`p` 上翻、`q` 结束，页脚显示当前页码与行号范围。编号与「手动挑选」里的编号一致，可以直接拿来指定要更新的条目。

按**软件性质**分三档：

| 档位 | 含义 | 典型软件 |
|---|---|---|
| `常规` | 工具、运行库、系统组件 | 7-Zip、Git、CMake、PuTTY、Python、VC++ Redist、.NET |
| `注意` | 客户端类，更新后界面可能变化或需重新登录 | 微信、百度网盘、剪映、豆包、Telegram、IDM、OneDrive、Outlook、WSL |
| `驱动` | 音频/硬件驱动，建议单独确认 | ASIO4ALL、Yamaha Steinberg USB Driver |

可选「只更新常规 / 常规+注意 / 全部 / 手动挑选」。选「手动挑选」时会列出全部可更新软件（带编号和包 ID），输入编号即可，例如 `1,5,9`；粘贴包 ID 也能识别，两者可以混用。

**为什么按软件性质分档，而不是按版本号跨度**

各厂商版本号含义差别很大：OneDrive 的 `26.145 → 26.183` 只是日常更新，Python 的 `3.13 → 3.15` 才是真跳版本。按数字跨度判定会大量误报（实测把 28 条全判成"低风险"），按软件性质分才稳定。版本跨度仍会作为备注显示，供参考。

**三个必须知道的限制**

1. **覆盖有限**：winget 只能看到"有源数据"的软件。本机 148 条里它能管 30 条（约 20%）。绿色版 VST 插件、Cubase、银行控件、Band-in-a-Box 都不在源里，只能各自官网更新。
2. **升级是重新安装，不是打补丁**：winget 会覆盖安装，破解/绿色版可能被换成官方版。
3. **没有回滚**：注册表条目能 `reg export` 备份，软件更新没有等价手段，升级后一般回不到旧版本。

**逐条执行，互不中断**：每条单独调 `winget upgrade --id`，单条超时 600 秒（大体积客户端下载慢会自动终止并记为"超时"），一条失败不影响后面的。失败时会在该条下面直接用一句中文说明原因（例如「软件正在运行，关闭后重试」「下载被服务器拒绝 403，稍后重试或手动安装」），结果表格的「详情」列再汇总一次，退出码放在表格下方的「技术信息」里供排查；winget 返回 0 但部署实际失败的情况（如 `0x80073D02`）也会判为失败，不会误报成功。

**失败原因不会一闪而过**：一轮结束后清单会自动刷新，失败原因会写进刷新后清单的「备注」列（形如 `失败：下载被服务器拒绝 403，稍后重试或手动安装`），并在清单下方按编号完整列出，直到该包升级成功才消失；有失败记录时「备注」列会自动加宽，选「手动挑选」时同样可见。

---

## 命令行用法

```powershell
# 只扫描，显示清单，不改任何东西
.\src\CleanWindowsDirtyApp.ps1 -Mode Scan

# 扫描及清理（交互确认）
.\src\CleanWindowsDirtyApp.ps1 -Mode Clean

# 连"只剩卸载器"的可疑项一起清理
.\src\CleanWindowsDirtyApp.ps1 -Mode Clean -IncludeSuspect

# 恢复备份
.\src\CleanWindowsDirtyApp.ps1 -Mode Restore

# 纳入隐藏的 SystemComponent 条目一起扫描（默认跳过）
.\src\CleanWindowsDirtyApp.ps1 -Mode Scan -IncludeHidden

# 非交互（自动化用，会直接删 GHOST 条目，请先看清单）
.\src\CleanWindowsDirtyApp.ps1 -Mode Clean -NonInteractive

# 只检查、不更新（命令行专用；菜单里这项已并入 [3]）
.\src\CleanWindowsDirtyApp.ps1 -Mode UpdateCheck

# 执行更新（默认只更新"常规"档，逐条确认）
.\src\CleanWindowsDirtyApp.ps1 -Mode UpdateRun

# 演练：只走流程，不实际升级任何软件
.\src\CleanWindowsDirtyApp.ps1 -Mode UpdateRun -NonInteractive -DryRun
```

参数一览：

| 参数 | 说明 |
|---|---|
| `-Mode` | `Menu`（默认）/ `Scan` / `Clean` / `Restore` / `UpdateCheck` / `UpdateRun` |
| `-IncludeSuspect` | 清理时连带处理 SUSPECT |
| `-IncludeHidden` | 扫描时纳入 `SystemComponent=1` 隐藏条目 |
| `-NonInteractive` | 不询问确认；表格一次性完整输出，不进入滑动窗口 |
| `-DryRun` | 更新时只演练，不实际执行 |
| `-OutputRoot` | 指定备份目录的上级目录（默认项目根目录） |

远程运行时 `bootstrap.ps1` 会自动带上 `-OutputRoot "%USERPROFILE%\CleanWindowsDirtyApp"`，备份目录随之落在主脚本旁边；本地双击 `Run.bat` 时不用管这个参数。

---

## 目录结构

```
cleanwindowsdirtyapp/
├─ Run.bat                        本地一键启动（自动提权）
├─ bootstrap.ps1                  远程自举脚本（纯 ASCII，托管时与下方主脚本放同一 HTTP 目录）
├─ README.md                      本文件
├─ src/
│  └─ CleanWindowsDirtyApp.ps1    主脚本（UTF-8 BOM）
└─ backups/                       唯一会写入的目录：删除前的注册表备份（按批次分目录）
   └─ backup-20261112-093000/
      ├─ 某软件.reg
      └─ ...
```

---

## 恢复

`[2] 从备份恢复` 或 `-Mode Restore`，会列出所有备份批次，选一个批次即可把里面的 `.reg` 全部导入回去。

也可以手动：

```cmd
reg import "backups\backup-20261112-093000\某软件.reg"
```

---

## 技术选型说明

**为什么是 PowerShell 5.1 兼容的脚本，而不是 Python / C# / Node**

| 方案 | 优点 | 缺点 | 结论 |
|---|---|---|---|
| **PowerShell** | Windows 自带，零安装；原生读写注册表、调用 `reg export/import`、`Test-Path`；原生 UAC 提权 | 语法对 5.1 有约束 | **采用** |
| Python | 生态好 | 要装解释器；注册表操作依赖第三方库；给非技术用户用不友好 | 不用 |
| C# / Go | 可编译成单文件 exe | 用户改不了、审计不了；杀软容易误报 | 不用 |
| 批处理 .bat | 原生 | 处理注册表和有条件判断太笨重、易出错 | 只做启动器 |

**几个刻意的工程决定**

- **单文件主脚本**：不拆模块，方便用户自己打开看、改、审计。脚本以 UTF-8 BOM 保存，中文在记事本里不乱码。
- **`.bat` 只做启动器**：Windows 的 PATH / ExecutionPolicy 是新手最容易卡住的地方，双击一个 bat 自动提权最省事。bat 用英文输出，规避 cmd 编码问题。
- **远程用自举脚本，不直接 `iex` 主脚本**：主脚本带 UTF-8 BOM、依赖 `$PSScriptRoot`，`irm 主脚本 | iex` 在 5.1 下编码和路径都不可靠；`bootstrap.ps1` 只负责下载到本地文件、校验、提权，再以 `-File` 启动，主脚本仍是同一份、不需要为远程场景改逻辑。
- **默认只读**：`[1]` 会先把清单列给你，答 `n` 就只看不删、不改任何东西，第一次跑很安全。
- **不落盘冗余文件**：扫描/更新结果只在控制台显示，不写 CSV/JSON 报告和运行日志；唯一保留的是可用来恢复的 `.reg` 备份。
- **备份优先于删除**：每个条目是先 `reg export` 成功才执行删除，备份失败就跳过该条，绝不"先删了再说"。
- **不用三元运算符、不用 `??`、不用 `-AsHashtable`**：这些在 PowerShell 5.1 下不可用（Windows 自带的就是 5.1，很多人的机器上升不到 7）。

---

## 常见问题

**Q：为什么有些条目被标成 `SUSPECT` 而不是直接删？**
A：多半是"软件装在别处、注册表路径字段过时"。比如 Band-in-a-Box 条目里写的是 `C:\bb`，实际装在 `D:\GY\bb`，软件好好的。如果直接把 `SUSPECT` 也删了，可能误伤。所以默认不动。

**Q：删掉的条目会影响软件本身吗？**
A：对 `GHOST` 来说不会——软件本来就不在了。这条目只是"设置里的一行字"。

**Q：为什么提示需要管理员权限？**
A：`HKLM` 下的条目普通用户改不了。`Run.bat` 会自动弹 UAC；点"是"即可。`HKCU` 下的条目不需要提权。

**Q：清理完设置里没变化？**
A：关闭设置窗口重新打开，或按 `Win + I` 重进一次。列表是打开时读取注册表渲染的。

**Q：会不会误删 MSI 组件导致软件修不了？**
A：不会。`SystemComponent=1` 的条目默认全部跳过，脚本里还额外做了一层保护：只有"明确写了安装目录、且该目录确实消失"的极少数隐藏条目才会被标出来，而且只放在 `SUSPECT` 里等你决定。

**Q：`[3]` 执行更新会不会把我装的破解软件冲掉？**
A：winget 只能更新"源里有的软件"，破解/绿色版通常不在源里，不会被碰。但它确实是覆盖安装——如果你把某个正版软件换成了精简版，更新后会变回官方版。

**Q：更新显示"失败"，但软件版本其实已经变了？**

A：这是 1.1.0 的误判——脚本读不到 winget 的退出码（`Start-Process -PassThru` 在本机返回的是空值），于是把每一次升级都记成失败。1.1.1 已修复：改用 `System.Diagnostics.Process` 启动，退出码能正确读到；另外补了两条判定，「已经是最新」显示为 `已是最新` 而不是失败，安装器要求重启但已完成安装的也记为成功。结果表格的「详情」列现在显示中文原因，真实退出码列在下方「技术信息」里。

**Q：更新失败了怎么办？**
A：先看该条下面那句中文原因：软件正在运行就关掉它再试；403 / 网络失败通常是厂商源站或镜像临时问题，稍后重试或手动下载安装；版本冲突需要先卸载旧版。一轮结束后清单会自动刷新，直接在「选择更新范围」里选「手动挑选」，只对失败的那几条重试即可（编号以刷新后的清单为准）。

**Q：清单里「大小」为什么有的是 `-`？**
A：winget 清单本身没有包大小，需要额外查安装程序 URL 再发 HEAD 请求，部分源不返回 `Content-Length`、或超出探测预算就会显示 `-`。不影响升级本身；下载进度条里的「已下载 / 总量」是 winget 给的真实值。

---

## 已验证的行为

在 Windows 11（Build 26100，Windows PowerShell 5.1）上实测跑通：

| 验证项 | 结果 |
|---|---|
| 全量扫描 | 148 条 → 失效 0 / 可疑 7 / 正常 96 / 受保护 45 |
| 误判回归 | PotPlayer、WPS、IDM、Cubase、GitHub CLI、PuTTY、CMake、Python 全部正确判为正常 |
| 造一条假条目（不存在的安装目录） | 正确识别为 `GHOST`，且只命中这一条 |
| 清理该条目 | `reg export` 备份成功（484 B）→ 删除成功 → 注册表键确实消失 |
| 导入备份 | `reg import` 退出码 0，条目与字段完整恢复 |
| HKCU 条目清理 | 非管理员会话下可直接执行，不要求提权 |
| 绿色软件识别 | 9 条判为绿色/便携、2 条疑似；NVIDIA 驱动、Copilot、Update Notifier 等误报已修正排除 |
| 更新检查 | winget 列出 30 条可升级，全部正确解析（含名称中间带空格的 OneDrive、VC++ x64/x86、.NET Desktop Runtime，这四条在早期版本里会被漏掉） |
| 更新执行（演练） | 19 条"常规"档全部走通，结果表格正确显示，未实际升级任何软件 |
