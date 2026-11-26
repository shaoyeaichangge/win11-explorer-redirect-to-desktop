# 排查时间线（每一步都有可判读的证据）

> 说明：文中路径中的用户名统一写作 `<user>`，机器名、邮箱等已移除。
> 所有"结果"列都是实测判读，不是推断。

## 阶段 0：把现象固定下来

先写一个探针，用 COM 枚举并对比窗口，判断"新窗口最终停在哪"：

```powershell
$sh = New-Object -ComObject Shell.Application
$before = @(); foreach ($w in @($sh.Windows())) { $before += [int64]$w.HWND }
Start-Process explorer.exe '"C:\Windows"'
Start-Sleep -Seconds 6
$new = @($sh.Windows() | Where-Object { $before -notcontains [int64]$_.HWND })
foreach ($w in $new) { $w.LocationURL }
```

判读：

- `BOUNCED_TO_DESKTOP` = `LocationURL` 以 `/Desktop` 结尾
- `OK` = 停在目标
- `NO_WINDOW` = 没抓到窗口（需要加长等待）

同时用 **100ms 轮询**确认了关键事实：**同一个 HWND 从 `C:/Windows` 变成 `C:/Desktop`** —— 是导航，不是崩溃重启（崩溃会换句柄）。

## 阶段 1：先排除"二进制/劫持"类

| # | 动作 | 结果 |
|---|---|---|
| 1 | `Get-AuthenticodeSignature` 校验 `explorer.exe` | 微软签名有效 |
| 2 | 查 IFEO、`AppInit_DLLs`、`AppCertDlls`、`Folder\shell\open\command`、`CLSID` 宿主 | 全部干净 |
| 3 | 查网络驱动器映射（`HKCU\Network`、`Get-SmbMapping`、`net use`） | 无映射 |

## 阶段 2：外壳扩展（走了两遍，两个层级）

第一遍用 `HKCU\...\Shell Extensions\Blocked`：网盘、Sync、PowerToys 的 DLL 确实从 explorer 卸载了；**WPS 的 `qingnse64.dll` / `kbaseconfigcenter64.dll` 仍然加载** —— 说明它通过别的注册路径进入，HKCU 屏蔽覆盖不到。

第二遍用 HKLM 层屏蔽 49 个 CLSID，重启后 explorer 内**只剩 1 个微软扩展（OneDrive）**：

```
third-party modules still inside Explorer:
  C:\Program Files\Microsoft OneDrive\<ver>\FileSyncShell64.dll
```

→ **照样跳**。外壳扩展这条线到此为止。

## 阶段 3：设备事件（微软官方答案）

用 360 搜索命中微软 Q&A 的同题报告：《Windows 资源管理器自动刷新并重定向到桌面文件夹》。
答案给出两条建议：① 关闭自动播放；② 在 `msconfig` 里禁用 "Shell 硬件检测"。

对这台机器：

| 动作 | 结果 |
|---|---|
| `HKCU\...\AutoplayHandlers\DisableAutoplay = 1` + 重启 explorer | ❌ 照样跳 |
| `sc config ShellHWDetection start= demand` + `sc stop` + 重启 explorer | ❌ 照样跳 |

> 结论：这类"重定向到桌面"的**机制**是真实存在的（设备/介质变化会让资源管理器把窗口刷到桌面），但**本机的触发源不是它**。官方答案只能当作候选，必须用本地证据交叉验证。

## 阶段 4：进程与服务（把"外部有人在操纵窗口"彻底否掉）

| 动作 | 结果 |
|---|---|
| 15 秒进程创建监视 | 只出现 1 个正常的 `explorer.exe /factory,{...} -Embedding` 宿主，**没有**外部进程去 `explorer.exe <路径>` |
| 该宿主进程的模块与线程 | 第三方仅 WPS/OneDrive；**0 个**启动地址落在所有模块之外的线程（排除手工映射注入） |
| 杀后台程序（办公套件后台、网盘、组网工具、远程控制、搜索索引、截图工具、桌面增强工具） | ❌ 照样跳 |
| 停掉**全部 27 个**第三方服务 | ❌ 照样跳 |
| 枚举运行中的第三方内核驱动 | 0 个（`UnionFS.sys`、`360Box64.sys` 等均为微软签名或已禁用） |

## 阶段 5：文件系统与路径解析

| 动作 | 结果 |
|---|---|
| `FileSystemWatcher` 监控桌面 20 秒 | **0 个**文件事件（排除"桌面被持续写入触发刷新"） |
| P/Invoke `SHParseDisplayName`（在全新进程里） | `C:\Windows`、`C:\`、`D:\`、`E:\` 全部 `HRESULT=0`，PIDL 回读路径正确 |
| `Shell.NameSpace('C:\Windows').Items().Count` | 116，正确 |
| 路径写法对比（`\\?\`、`/`、`file:///`、`shell:`） | 结果**不稳定**（`shell:ProgramFiles` 跳、`shell:Downloads` 不跳）→ 说明不是"路径规则"问题，而是**时机/状态**问题 |

## 阶段 6：决定性定界 —— 换账户

用管理员脚本建临时账户 → 切换登录 → Win+E 打开文件夹：

> **新账户完全正常。**

这一步排除了：系统文件损坏、驱动、服务、任何全局安装的软件。
搜索空间从"整台机器"缩到"**一个用户配置（HKCU）**"。

## 阶段 7：在 HKCU 内做定向排除（全部失败，但缩小了范围）

| 候选 | 动作 | 结果 |
|---|---|---|
| 窗口视图缓存（旧位置 `HKCU\Software\Microsoft\Windows\Shell`） | 删除 `Bags`/`BagMRU` | ❌ |
| 窗口视图缓存（**真实**位置 `HKCU\Software\Classes\Local Settings\...\Shell`，121 个 bag） | 备份后清除并重建 | ❌ |
| 桌面命名空间里的两个第三方扩展（某办公套件"云盘"项） | 备份后删除两项 | ❌ |
| "桌面整理"外壳扩展 + 某网盘外壳扩展（每用户 CLSID） | 备份后删除 3 个 CLSID | ❌ |
| `Explorer\Advanced\ShellViewReentered`（崩溃后的降级标志） | 清除该值 | ❌ |
| Explorer 内单个猜测值（`LaunchTo`、`SeparateProcess`、`User Shell Folders` 等） | 逐个试 | ❌ |

## 阶段 8：整组重置（成功）

```
整键删除 HKCU\...\Explorer            → 系统拒绝（ERROR: Error accessing the registry）
改成逐个删除子键（跳过保留项）        → 删除 50 个成功，3 个被锁（Advanced/FileExts/SessionInfo）
保留：User Shell Folders、Shell Folders
重启 explorer + 探测                   → C:\Windows / Documents / Downloads 全部 OK
跨盘复测                               → D:\、E:\ 也 OK；C:\Windows 连测 3 次全 OK
```

被删除的 50 个子键（供后续研究者参考）：

```
Accent, AppContract, AutoInstalledPWAs, AutoplayHandlers, BannerStore, BitBucket,
CabinetState, CD Burning, CIDOpen, CIDSave, CLSID, ComDlg32, Desktop, DetailsPane,
Discardable, DontShowMeThisDialogAgain, ExtractionWizard, FeatureUsage, Gallery,
HideDesktopIcons, LogonStats, LowRegistry, Map Network Drive MRU, MenuOrder,
MMStuckRects3, Modules, MountPoints2, Mru, MyComputer, OperationStatusManager,
Package Installation, RecentDocs, RunMRU, SearchPlatform, Shutdown, StartPage,
StartupApproved, StorageProvider, StreamMRU, Streams, StuckRects3, Substrate,
TabletMode, Taskband, TWinUI, TypedPaths, UserAssist, VirtualDesktops, VisualEffects,
Wallpapers
```

> 注意：`CLSID`、`Desktop`、`Modules`、`Substrate`、`StartPage`、`TypedPaths` 这些名字看着无关，但都在同一个状态库里——**这正是"靠猜"不可行的原因**。

## 如果要把根因精确到单个值（未做完的二分）

1. 恢复备份；
2. 先恢复一半子键 → 重启 explorer → 探测；
3. 若复现，坏值在恢复的那一半里，否则在另一半；
4. 重复 3，约 `log2(50) ≈ 6` 轮即可定位到单个值。

代价：每轮约 40 秒（含 explorer 重启与 2 次探测）。实用价值有限——清空后 Windows 会以默认值重建，且实测不复发。