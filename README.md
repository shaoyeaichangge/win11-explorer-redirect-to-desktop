# Windows 11: 新建的资源管理器窗口自动跳回桌面

> **English** — Every newly created File Explorer window on Windows 11 24H2 jumped back to
> the Desktop folder within ~0.5 s (same HWND, so it was a *navigation*, not a crash).
> Shell extensions, background services, kernel drivers, malware, device events and OS
> corruption were all ruled out by experiment. The real cause was a **stale value inside one
> per-user registry key** — `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer`.
> Wiping that key (keeping the folder mappings) fixes it in about 30 seconds. No reinstall,
> no new user profile, no data loss.

---

## 1. 症状

| 项目 | 现象 |
|---|---|
| 触发 | **任何**方式新建一个文件夹窗口：双击文件夹、`explorer.exe <路径>`、Win+E、`ShellExecute`、`Shell.Application.Open/Explore`、`.lnk` 快捷方式、从第三方程序里"打开所在文件夹" |
| 表现 | 窗口先正确显示目标目录（例如 `C:\Windows`，116 项），**0.4 ~ 3.6 秒后**自动导航到 `file:///C:/Users/<user>/Desktop`（桌面，99 项） |
| 关键特征 | **同一个窗口句柄**（HWND）位置发生变化 → 是导航，不是崩溃/重启 |
| 反例 1 | 在**已打开的**窗口地址栏里粘贴路径回车 → 稳定，不跳 |
| 反例 2 | 通过 `Navigate2()` 让一个**已落定**的窗口跳转 → 稳定，不跳 |
| 反例 3 | `shell:Downloads` / `shell:MyComputerFolder` / `shell:UsersFilesFolder` → 有时稳定（时机性，不稳定复现） |

环境：Windows 11 24H2 `26100.4351`（专业版），本地管理员账户，机器曾插过多个"量产成光驱"的 U 盘。

---

## 2. 一分钟修复

```powershell
# 管理员 PowerShell（脚本会自己提权，也可以直接双击 fix-step7-*.bat）
powershell -ExecutionPolicy Bypass -File .\scripts\Fix-ExplorerState.ps1
```

脚本做三件事：

1. 把 `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer` 导出成 `.reg` 备份；
2. 杀掉 `explorer.exe`，**逐个删除**该键下的过期子键，只保留
   `User Shell Folders` / `Shell Folders`（文件夹位置映射）；
   `Advanced` / `FileExts` / `SessionInfo` 被系统锁着，删不动也不需要动；
3. 重启资源管理器，然后自动开 2 个文件夹验证结果。

> 修复后实测：`C:\Windows`（连测 3 次）、`Documents`、`Downloads`、`D:\`、`E:\` 全部稳定。

---

## 3. 根因

`HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer` 是资源管理器的**用户级状态库**（几百个值：窗口位置、视图、地址栏历史、上次访问的目录、Home/QuickAccess 状态……）。

其中某个值被写坏之后，shell 在**创建新窗口**时会把这个窗口解析到 shell 命名空间的**根**——也就是桌面。因此：

- 现象指向"桌面"而不是某个具体目录 → 因为桌面就是 shell 的根；
- 只在"新建窗口"时发生、在"已存在窗口导航"时不发生 → 因为坏状态只在窗口初始化路径上被读取；
- 换个新用户账户就正常 → 因为新账户的这份状态是干净的。

**具体是哪个值没能最终锁定**（50 多个子键里逐一二分还要 6 轮），但整组清掉后 Windows 会按默认值重建，症状消失且不复发。若要继续深挖，参见 `docs/diagnosis.md` 末尾的二分方法。

### 时间线推测（未证实）

该机器上 `explorer.exe` 在 30 天内崩过 4 次（`c0000374` 堆损坏，最近一次 11/24 18:51），而某网盘客户端的外壳扩展恰好是 **11/24 17:51** 安装的。崩溃/安装过程中把这份状态写坏，是合理推测；但没有直接证据，且**不能**据此判定该软件有罪。

---

## 4. 为什么难查：所有"常规嫌疑"都被实验否掉了

| 假设 | 验证方式 | 结果 |
|---|---|---|
| 某个后台程序在操纵窗口 | 杀掉 PowerToys 全套、UiPath、WPS 后台、网盘、组网工具、远程控制、Everything、Snipaste、Codex、WorkBuddy | ❌ 照样跳 |
| 第三方外壳扩展 | HKLM 层屏蔽 49 个扩展（WPS / Adobe / 百度 / Sync / PowerToys），使 explorer 内只剩 1 个微软扩展 | ❌ 照样跳 |
| 插拔 U 盘触发的设备事件（微软 Q&A 官方答案） | 关闭自动播放 + 禁用 `ShellHWDetection` 服务 | ❌ 照样跳 |
| 第三方后台服务 | **27 个第三方服务全部停止**（脚本自动二分） | ❌ 照样跳 |
| 内核驱动 / 文件系统过滤驱动 | 枚举运行中的第三方驱动 | ❌ 0 个（`UnionFS.sys` 等均为微软签名） |
| 桌面被持续写入（每次写入触发刷新） | `FileSystemWatcher` 监控桌面 20 秒 | ❌ 0 个文件事件 |
| COM 组件劫持 | 扫 `HKCR\CLSID` 中指向 `AppData` / `ProgramData` / `Temp` 的 InprocServer32 | ❌ 12 个全是 Defender / Visual Studio / MathWorks 等正常组件 |
| 路径解析层坏了 | P/Invoke `SHParseDisplayName` + `Shell.NameSpace` | ✅ 完全正常（HRESULT=0，PIDL 回读正确，116 项） |
| 窗口视图缓存 / 桌面命名空间 / 特定标志位 | 逐个清 `Bags`(121) + `BagMRU`、桌面 `NameSpace` 项、"桌面整理"外壳扩展、`ShellViewReentered` 标志 | ❌ 全不是 |
| **整机 Windows 坏了** | 新建临时账户登录测试 | ✅ **新账户完全正常 → 锁定为"用户配置"问题** |

最后一行是全局转折点：它一次性排除了"系统损坏 / 需要重装"，把搜索空间从"整台机器"缩到"一个用户配置"。

---

## 5. 决定性的一步

```
一次整键删除（HKCU\...\Explorer）  → 被系统拒绝（部分子键有保护）
改为逐个删除子键（跳过保留项/锁定项） → 删掉 50 个 → 重启 explorer → 症状消失
```

对比之前十几轮"猜某个值"的尝试，说明这类问题**不应该靠猜**：状态库太大，必须整组重置或做二分。

---

## 6. 代价（都不是数据损失）

| 回到默认 | 完好无损 |
|---|---|
| 任务栏固定项、快速访问固定项 | 所有文件（桌面/文档/下载/各数据盘） |
| 文件夹视图（排序、列宽、图标大小） | 文件夹位置映射（Desktop/Personal/Downloads） |
| 记住的窗口大小与位置、地址栏历史 | 系统文件、驱动、已安装软件 |
| 桌面图标排列 | 第三方程序的一切功能 |

备份文件会在脚本同目录生成，`reg import <备份>.reg` 可回滚。

---

## 7. 仓库内容

```
README.md                        本文
docs/diagnosis.md                完整排查时间线（含每步命令与判读）
docs/playbook.md                 可复用的方法论：窗口/外壳类异常的排查顺序
docs/evidence.md                 关键证据输出（已脱敏）
scripts/Fix-ExplorerState.ps1    ★ 一键修复（整组重置 Explorer 状态）
scripts/Remove-PhantomCdrom.ps1  清理"幽灵" USB 光驱设备记录（非本 bug 元凶，见附录）
scripts/Test-ExplorerRedirect.ps1 复现/验证：新窗口是否会被重定向到桌面
scripts/Test-ServiceBisect.ps1    无需重启地二分定位"哪个服务在捣鬼"
scripts/Test-ProfileIsolation.ps1 一分钟定界：是用户配置还是整机（建临时账户）
scripts/Repair-SystemFiles.ps1    DISM + SFC，并可修复被指向死 WSUS 的 Windows Update
```

所有脚本都是 PowerShell，无第三方依赖；除 `Fix-ExplorerState.ps1` / `Repair-SystemFiles.ps1` 外均**不需要管理员**。

---

## 8. 复现与验证

```powershell
# 复现：返回 BOUNCED_TO_DESKTOP / OK / NO_WINDOW
powershell -ExecutionPolicy Bypass -File .\scripts\Test-ExplorerRedirect.ps1 -Target 'C:\Windows'

# 定界：新建临时管理员账户，切换登录后观察文件夹是否还跳
powershell -ExecutionPolicy Bypass -File .\scripts\Test-ProfileIsolation.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\Test-ProfileIsolation.ps1 -Remove
```

---

## 9. 附录：顺带发现但**不是**本次元凶的问题

1. **Windows Update 被指向不存在的 WSUS**：`HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate`
   的 `WUServer = http://127.0.0.1:8530`，本机无服务监听 → 更新中心报 `0x80240438`，机器长期未打补丁。
   `scripts/Repair-SystemFiles.ps1` 会在询问后备份并清除这几项策略。
2. **14 个"幽灵"光驱设备记录**（NON-present）：量产 U 盘 ×1、"Linux File-CD Gadget" ×2、
   Realtek 驱动光盘 ×3、挂载 ISO 留下的"Microsoft 虚拟 DVD-ROM" ×8。
   它们会拖慢设备枚举，可用 `scripts/Remove-PhantomCdrom.ps1` 清理（只删非在位设备）。
3. **explorer.exe 堆损坏崩溃**（`c0000374`，30 天 4 次）：与本次故障时间相关，建议保持系统更新。

---

## 许可

MIT，见 `LICENSE`。脚本按"现状"提供；涉及注册表/设备删除的操作都有备份，请先读脚本再运行。