# 2026-09-16 Xcode 27 下编辑器静默退回 NSTextView：变的是安装名，不是 API

**调查日期：** 2026-09-16
**修复落地：** 本日，见 `RuntimeViewerSourceEditorBridge` 的 `OTHER_LDFLAGS` / `OTHER_SWIFT_FLAGS`，以及 `SourceEditorBridgeLinkageTests`、`Stubs/VerifyAcrossXcodes.sh`
**所属分支：** `next`
**Severity：** Major —— 装 Xcode 27 的机器上整个 Xcode 编辑器路径不可用，且不报错、不提示，看上去像"这个功能没做"
**触发场景：** 把 Xcode 27.0 设为 LaunchServices 解析到的那一份（或用新加的 Settings › Editor › Xcode 指定它），开启 Settings › Editor 的 "Use Xcode's Source Editor"，然后在侧栏点任意对象

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | 内容面板仍是内置 `NSTextView`：没有折叠、没有 sticky header、没有 minimap。Xcode 26.x 下一切正常 |
| **影响范围** | 只影响 bridge bundle 的加载。框架本身 `dlopen` 成功，符号也都在，落地点在其后一步 |
| **根因** | Xcode 27 把这几个框架的 `LC_ID_DYLIB` 从 `@rpath/SourceEditor.framework/Versions/A/SourceEditor` 改成了 `@rpath/SharedFrameworks/SourceEditor.framework/Versions/A/SourceEditor`。bridge bundle 的 `LC_LOAD_DYLIB` 记的是旧那串（来自 stub 的 `.tbd`），dyld 按字符串匹配已加载镜像时对不上，于是转去文件系统找 `@rpath/SourceEditor.framework/…`，rpath 里没有、默认路径里也没有，报 `Library not loaded` |
| **为什么静默** | `SourceEditorLoader` 把任何失败都归成 `Unavailability` 并回落到 `NSTextView` —— 这是它在没装 Xcode 的机器上的正常行为，所以"回落"本身不构成异常信号，只有 `#log(.info, …)` 一行 |
| **Status** | **Fixed** —— bridge 改用 `-undefined dynamic_lookup` 并抑制 Swift autolink，产物里不再记录对这些框架的任何依赖，符号在 `RTLD_GLOBAL` 建立的扁平命名空间里解析 |

---

## 为什么先怀疑错了方向

同一天早些时候刚修过一个真正的 Xcode 27 API 变动：`SourceModelNodeTypeAdjuster.adjustNodeType(for:)`
改成返回 `Bool`，旧 descriptor 不再导出（见 0009 决策日志 2026-09-16 那条）。于是"27 下不工作"
很自然会被当成同一类问题的残余。

**它不是。** 那条修的是 conformance 绑定，发生在 bundle 已经加载之后；而这一条根本走不到那一步。
两者唯一的共同点是都由 27 引入，机制毫无关系。

## 定位过程

### 1. 先确认框架真的在

27.0 的 `Contents/SharedFrameworks` 里 `SourceEditor` / `SourceModel` / `SourceModelSupport` /
`_CodeCompletionFoundation` 四个都在，所以不是 `XcodeSourceEditorLocator` 找不到目录。

### 2. 用探针复现，拿到确切报错

按 `SourceEditorLoader` 的同一套顺序（绝对路径、`RTLD_LAZY | RTLD_GLOBAL`、定点循环）加载四个框架，
再 `Bundle.loadAndReturnError()`：

| Xcode | 结果 |
|---|---|
| 26.6 | 框架加载成功 → bundle 加载成功 → 实例化成功 → `editorView` 是 `SourceEditorView` |
| 27.0 | **框架加载成功** → bundle 加载失败：`Library not loaded: @rpath/SourceEditor.framework/Versions/A/SourceEditor` |

**"框架加载成功、bundle 失败"这一行就把范围缩到了两者之间的那一步。** 报错里 dyld 列出的尝试路径
（`/System/Library/Frameworks/…`、`/usr/lib/swift/…`）说明它走的是"找文件"分支，也就是说它压根没把
已经加载进来的那份算数。

### 3. 对照安装名

```
$ otool -l <Xcode>/Contents/SharedFrameworks/SourceEditor.framework/Versions/A/SourceEditor \
    | grep -A3 LC_ID_DYLIB | grep ' name '

26.5 / 26.6:  name @rpath/SourceEditor.framework/Versions/A/SourceEditor
27.0:         name @rpath/SharedFrameworks/SourceEditor.framework/Versions/A/SourceEditor
```

四个框架一致地多了 `SharedFrameworks/` 一段。

**这也解释了为什么框架自己加载得好好的**：它们互相引用时用的正是各自的新安装名，而按绝对路径
`dlopen` 进来的镜像就是以自己的 `LC_ID_DYLIB` 登记的，所以框架之间对得上；只有 bridge 这个外来者
记的是旧串。

### 4. 反向验证

把已构建的 bundle 复制一份，`install_name_tool -change` 三处再 ad-hoc 重签，27.0 下加载成功，
并跑通了整个 `SourceEditorBridging` 面（七个显示开关全开、换主题、objc 与 swift 各一次 `setSource`、
布局与绘制）。**改这一个字符串就够** —— 说明 27 没有其它破坏性变更卡在这条路上。

### 5. 排除"是别的符号没了"

`UsedSymbols.txt` 的 135 个符号（SourceEditor 123 + SourceModel 1 + SourceModelSupport 11）
逐个对 27.0 的二进制核对，只有 Xcode 26 专属的那个 `adjustNodeType` descriptor 缺席，而它已经由
`@_weakLinked` 覆盖。框架资源里 `Default (Dark).xccolortheme` 等也都在原处
（27 只是把 `SourceEditorTextFindPanel.nib` 拆成了两个 nib，bridge 不碰 nib）。

---

## 修法：不是改成新安装名，而是不再记录安装名

改成 27 的安装名会把 26 反过来弄坏；为两种安装名各出一个 bundle 变体则要多一个签名产物，而且
Xcode 每改一次布局就要再加一个变体。

采用的做法是让 bridge 根本不链接这些框架：

```
OTHER_LDFLAGS   = -undefined dynamic_lookup
OTHER_SWIFT_FLAGS = -Xfrontend -disable-autolink-framework -Xfrontend SourceEditor   (三个框架各一组)
```

`-disable-autolink-framework` 是必需的：Swift 会为 `import SourceEditor` 写入 autolink 指令，
不抑制的话链接器又把 `-framework` 加回来，`OTHER_LDFLAGS` 改了也白改。

产物里于是没有任何指向这三个框架的 `LC_LOAD_DYLIB`，符号全部落到 `dynamically looked up`，在
loader 用 `RTLD_GLOBAL` 建立起来的扁平命名空间里解析 —— 安装名叫什么都不再相干。

### 丢掉的和没丢掉的

- **丢掉的是链接期符号校验。** `Stubs/*.tbd` 从此只服务 `RuntimeViewerSourceEditorBridgeTests`
  （它仍然 `-weak_framework` 链接，靠 rpath 去找文件）。`Stubs/README.md` 已相应更新。
- **没丢掉"符号缺了会被发现"。** 实测在框架未加载的情况下 `dlopen` 该 bundle 仍然硬失败并点名符号：
  `symbol not found in flat namespace '_$s12SourceEditor0aB4ViewCMn'`。报错点从链接期挪到了加载期，
  而加载期失败正是 `SourceEditorLoader` 已经在记日志的那条路径。
- **`@_weakLinked` 照常成立。** 两个 `adjustNodeType` descriptor 在产物里仍是
  `weak external (dynamically looked up)`，每个 Xcode 各绑上自己的那一个。

---

## 验证

| 项目 | 结果 |
|---|---|
| Debug-arm64e 构建 | 成功，产物无 SourceEditor 系 `LC_LOAD_DYLIB` |
| Release 构建 | 成功，`x86_64 arm64` 双架构，无 `dynamic_lookup` 相关警告 |
| Xcode 26.5 / 26.6 / 27.0 | **同一个 bundle** 三版全部跑通完整 `SourceEditorBridging` 面 |
| `RuntimeViewerSourceEditorBridgeTests` | 6 个测试全过（26.6）。把 rpath 改指向 27 并用 27 的 `xctest` 跑，同样 6 个全过 —— 测试 target 仍 `-weak_framework` 链接 stub，但它靠 rpath 找**文件**而不是靠"已加载"匹配，所以不受安装名变更影响，不需要改 |
| 链接测试的红绿 | 用 `OTHER_LDFLAGS="-framework …" OTHER_SWIFT_FLAGS=""` 覆盖重建后，`SourceEditorBridgeLinkage` 失败并点名三条依赖，退出码 1；恢复后退出码 0 |

### 同类排查

这个模式是"按绝对路径 `dlopen` 一个框架，同时又在链接期记录它的安装名"。全仓库排查结果：

- 引用 `Stubs` 的只有 6 个 configuration —— bridge 的三个（已修）与测试 target 的三个。
- 测试 target 是 `-weak_framework` + `LD_RUNPATH_SEARCH_PATHS`，靠 rpath 找**文件**，不走"已加载"
  匹配，因此不受影响（已实测，见上表）。
- 其余 `dlopen` 调用点（`DyldUtilities.swift` 把 image 载进本地运行时引擎）没有对应的链接期依赖。

没有第三处实例。

### 回归测试（永久保留）

- `RuntimeViewerSourceEditorBridgeTests/SourceEditorBridgeLinkageTests.swift` —— 自己解析产物的
  Mach-O 加载命令，断言没有任何一条指向这四个框架，逐 slice 检查所以 Release 的 x86_64 也覆盖到。
  把 `-framework` 改回去即失败。不需要装 Xcode，也不需要框架在场。
- `Stubs/VerifyAcrossXcodes.sh` —— 对本机每个已安装 Xcode 起一个独立进程，按 loader 的顺序加载框架
  与 bundle，再跑完整功能面。**单元测试做不到这一层**：框架 `dlopen` 一次就不卸载，一个进程只能验一版。

---

## 给下次的三条

1. **"27 下不工作"不等于"27 改了 API"。** 先看它停在哪一步：框架加载、bundle 加载、conformance 绑定
   是三段完全不同的机制，报错文本一眼能分开。
2. **回落路径天生静默。** `SourceEditorLoader` 的设计前提就是"没有 Xcode 也要能用"，所以任何加载失败
   都长得和"这台机器没装 Xcode"一样。排查这类问题要直接看 `#log` 里那一行 `SourceEditor unavailable`，
   而不是等 UI 报错。
3. **别人的安装名不是稳定接口。** 私有框架的 `LC_ID_DYLIB` 随版本改动没有任何兼容承诺；凡是靠
   `dlopen` 拿到的东西，就不要同时在链接期记录它的名字。
