# 0019 - Helper 设置页的重装按钮

- **状态**: In Progress
- **创建日期**: 2026-09-05
- **最后更新**: 2026-09-05
- **所属愿景**: 无

## 摘要

设置窗口的 Helper Service 页面在服务已启用时只提供 Uninstall，想换掉一个新编译的 daemon
二进制必须先点 Uninstall、等状态刷新、再点 Install，两步之间还得自己确认第一步真的完成了。
但 `HelperServiceManager` 内部**早已有**一条完整、经过验证的重装序列——它藏在
`checkServiceVersionAndReinstallIfNeeded()` 里，只有启动时检测到版本不匹配才会走到，
设置页面碰不到。本提案把那条序列抽成可复用的方法，并在设置页面接出一个 Reinstall 按钮。

## 方案

### 1. `HelperServiceManager`（`RuntimeViewerPackages/Sources/RuntimeViewerHelperClient/`）

把 `checkServiceVersionAndReinstallIfNeeded()` 中间那段重装逻辑抽成 private
`performReinstall() async throws`，内容与现在逐行等价：

1. `invalidateConnection()` —— 丢弃指向旧 daemon 的 XPC 连接标记；
2. `installer.unregister()`，失败只记日志不中断（从 `.notRegistered` 出发 `register()` 仍可能成功）；
3. `Task.sleep(for: .seconds(1))`；
4. `installer.register()`，失败向上抛。

第 3 步是这次抽取的**主要动机**。现有注释写明：`SMAppService` 在磁盘上的记账会滞后于
`unregister()` 的 await 返回，缺了这个停顿，紧接着的 `register()` 会偶发以「已注册」失败。
这类只有踩过才知道的时序 workaround 不能在第二个调用点重写一遍，必须共用同一份代码。

`Action` 枚举加 `case reinstall`，`manageHelperService(action:)` 接上：调用
`performReinstall()`；成功后若状态变成 `.requiresApproval`，照现有 `.install` 分支的做法打开
系统设置的 Login Items；失败则走已有的 `occurredError` 通路，由 `updateStatusMessages` 转成
用户可读的文案。重装成功且状态为 `.enabled` 时，把 `message` 覆盖为明确的「已重新安装」，
而不是复用泛化的「registered and eligible to run」——用户需要能从状态行确认这次点击生效了。

`checkServiceVersionAndReinstallIfNeeded()` 改为调用 `performReinstall()`，
`.reinstalled` / `.reinstallFailed` 两种返回值和启动时的重启提示弹窗行为均不变。

### 2. `HelperServiceSettingsView`（`RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/Components/`）

`ServiceActionButtons` 的 `.enabled` 分支里，Uninstall 旁边加一个 Reinstall。其余状态
（`.requiresApproval` / `.notRegistered` / `.notFound`）不加——服务都没装起来时「重装」没有意义。
重装期间 `isLoading` 为 true，`HelperServiceStatusRow` 已有的逻辑会把整组按钮换成
`ProgressView`，正好覆盖那一秒多的等待，无需额外处理。

### 采取的假设

- **重装后不弹窗提示重启 App**（用户已确认）。启动时版本不匹配触发的自动重装会弹
  「Restart Now / Later」，手动重装不弹：`invalidateConnection()` 之后下一次 RPC 会自动重连到新
  daemon，功能上不需要重启。代价是已经注入到目标进程里的连接不会自动恢复。
- **不新增测试。** `HelperServiceManager` 直接操作真实的 `SMAppService.daemon(...)`，注册与注销
  需要 root 授权和系统 Login Items 交互，在测试进程里无法驱动，也无法在不污染开发机
  daemon 状态的前提下执行。`RuntimeViewerHelperClientTests` 现有三个套件全部是纯逻辑测试
  （平台判定、载荷平台、进程环境探测），本改动没有可落在同类缝上的新逻辑——它复用的正是
  一条无法被测试替身覆盖的系统调用序列。
- 不改项目 `AGENTS.md`：该文件未描述 Helper 设置页面的构成，本改动不产生需要写进去的约束。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-09-05 | 创建为 Draft | 用户提出「重装得点一遍卸载再点一次安装」，要求在设置 Helper 页面加一个重装按钮 |
| 2026-09-05 | 抽取共用的 `performReinstall()`，而非在设置页面另写一遍卸载+安装 | 那 1 秒 `Task.sleep` 是绕开 `SMAppService` 磁盘记账滞后的 workaround，复制一份必然漏掉 |
| 2026-09-05 | 按钮放在 Helper Service 状态行内、Uninstall 旁边，只在 `.enabled` 时出现 | 用户选定。语义上它是对该服务的一个操作，与 Install / Uninstall 同组；放进 Quick Actions 会与两个只读动作混在一起，且需要额外处理未安装时的禁用态 |
| 2026-09-05 | 重装完成后不弹重启提示，只更新状态行文字 | 用户选定。连接会自动重连，功能上不需要重启；已注入目标进程的连接不自动恢复是已知代价 |
| 2026-09-05 | 重装成功后显式覆盖 `message` 为「Service successfully reinstalled.」 | `updateStatusMessages` 只能描述 daemon 最终所处的状态，而重装成功后那个状态与点击前同样是 `.enabled`，状态行会一字不变，看起来像什么都没发生 |
| 2026-09-05 | 用户批准后实现，状态置为 In Progress | 两个 target 编译通过；实际的注册/注销行为未做运行时验证——它需要 root 授权对话框与系统 Login Items 交互，无法在无人值守下执行 |
| 2026-09-05 | 落地 `next` 时分配编号 `0019` | 按 evolution skill 的落地时编号规则，取所有远端共享分支上的全局最大号 `0018` + 1 |
