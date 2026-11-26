# 关键证据（已脱敏）

> 用户名统一写作 `<user>`，主机名/邮箱/个人目录已移除。
> 每条都标注了"这条证据排除了什么"，便于复核。

---

## 1. 窗口是被"导航"走的，不是崩溃重建

100 ms 轮询同一个窗口：

```
t=0.00s  hwnd=0x000C0A1E  url=file:///C:/Windows           title=Windows
t=0.42s  hwnd=0x000C0A1E  url=file:///C:/Windows           title=Windows
t=0.83s  hwnd=0x000C0A1E  url=file:///C:/Users/<user>/Desktop  title=Desktop
t=1.26s  hwnd=0x000C0A1E  url=file:///C:/Users/<user>/Desktop  title=Desktop
```

**排除**：explorer 崩溃重启（崩溃会换 HWND，且标题会短暂消失）。

---

## 2. 路径解析层是健康的

在全新进程里直接调用 shell API：

```
SHParseDisplayName("C:\Windows")   HRESULT=0x00000000
SHGetPathFromIDList                -> C:\Windows
SHParseDisplayName("C:\")          HRESULT=0x00000000
SHParseDisplayName("D:\")          HRESULT=0x00000000
SHParseDisplayName("E:\")          HRESULT=0x00000000
Shell.NameSpace("C:\Windows").Items().Count  -> 116
```

**排除**：shell 命名空间损坏、路径映射错误、注册表 `Shell Folders` 指向错误。
**指向**：坏状态在 explorer 进程内部（新建窗口时被读取）。

---

## 3. 外壳扩展全部屏蔽后仍然复现

在 HKLM 层屏蔽 49 个第三方 CLSID 并重启 explorer 后，进程内仅剩 1 个微软扩展：

```
third-party modules inside explorer.exe
  C:\Program Files\Microsoft OneDrive\<ver>\FileSyncShell64.dll
第三方线程（启动地址不在任何已加载模块内）: 0
```

探测结果：

```
C:\Windows                     -> BOUNCED_TO_DESKTOP
C:\Users\<user>\Downloads      -> BOUNCED_TO_DESKTOP
```

**排除**：第三方外壳扩展 / 手工映射注入 / 线程注入。

---

## 4. 全部第三方服务停止后仍然复现

```
=== Service bisect: 27 candidate service(s) ===
Phase 1: stop everything
RESULT: STILL BROKEN with every third-party service stopped.
```

**排除**：所有后台服务（含网盘、办公套件后台、组网工具、远程控制、驱动更新器）。

---

## 5. 桌面没有被持续写入

对 `%USERPROFILE%\Desktop` 与 `%TEMP%` 分别挂 `FileSystemWatcher`，观察 20 秒（期间反复打开文件夹）：

```
watcher events: 0
```

**排除**："某个程序不停往桌面写文件 → 触发刷新 → 窗口被拉回桌面"。

---

## 6. 没有第三方内核驱动在跑

```
=== running kernel drivers (file path outside %SystemRoot%) ===
count: 0
  (UnionFS.sys 等为微软签名驱动；360Box64.sys Start=4 已禁用)
```

**排除**：文件系统过滤驱动 / 第三方内核组件导致的 shell 异常。

---

## 7. 决定性证据：换账户即正常

```
=== profile isolation test ===
created local administrator 'dshprobe'
-> switch user, log in, open any folder
   result: 文件夹停住，不跳桌面
```

**结论**：系统级组件全部正常，故障属于**单个用户配置**。
**排除**：系统文件损坏、覆盖安装/重装的必要性、全局安装的软件。

---

## 8. 修复过程与结果

```
=== Fix Explorer state ===
  subkeys present: 53   to remove: 50
  backup: explorer-state-backup-20261126-091045.reg (4711 KB)
  removed 50 stale subkeys
  locked, left alone: Advanced, FileExts, SessionInfo

  verifying ...
    C:\Windows                     OK
    C:\Users\<user>\Downloads      OK

RESULT: FIXED
```

跨盘复测（修复后每次都是新窗口、每次等 6 秒）：

```
C:\Windows                     OK    file:///C:/Windows
C:\Users\<user>\Documents      OK    file:///C:/Users/<user>/Documents
C:\Users\<user>\Downloads      OK    file:///C:/Users/<user>/Downloads
D:\                            OK    file:///D:/
E:\                            OK    file:///E:/
C:\Windows (repeat 2)          OK
C:\Windows (repeat 3)          OK
```

文件夹映射完好：

```
User Shell Folders\Desktop    = C:\Users\<user>\Desktop
User Shell Folders\Personal   = C:\Users\<user>\Documents
User Shell Folders\{374DE290-...} = C:\Users\<user>\Downloads
```

---

## 9. 无效尝试的原始判读（避免重复走）

| 尝试 | 输出判读 |
|---|---|
| 关闭自动播放（`DisableAutoplay=1`） | 仍 `BOUNCED_TO_DESKTOP` |
| 禁用 `ShellHWDetection` 服务 | 仍 `BOUNCED_TO_DESKTOP`（服务已恢复 Automatic） |
| 清理旧位置 `HKCU\Software\Microsoft\Windows\Shell\Bags`（1 个） | 仍 `BOUNCED_TO_DESKTOP` |
| 清理真实位置 `HKCU\Software\Classes\Local Settings\...\Shell\Bags`（121 个） | 仍 `BOUNCED_TO_DESKTOP` |
| 删除桌面命名空间中 2 个第三方项 | 仍 `BOUNCED_TO_DESKTOP` |
| 删除 3 个每用户 CLSID（桌面整理 + 网盘扩展） | 仍 `BOUNCED_TO_DESKTOP` |
| 清除 `Explorer\Advanced\ShellViewReentered` | 仍 `BOUNCED_TO_DESKTOP` |
| 整键删除 `HKCU\...\Explorer` | `ERROR: Error accessing the registry`（被保护子键挡住） |
| **逐子键删除** | **FIXED** |