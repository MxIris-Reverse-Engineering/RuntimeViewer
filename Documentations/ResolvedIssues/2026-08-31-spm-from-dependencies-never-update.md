# 2026-08-31 `--update-packages` 从来没更新过 `from:` 依赖

**调查日期：** 2026-08-31
**修复落地：** 本日，见 `RunScript.sh` / `ArchiveScript.sh` 的 `update_packages()`
**Severity：** Minor —— 不崩溃、不报错，但 `--update-packages` 没有兑现它的名字，依赖悄悄停滞数月
**触发场景：** 反复执行 `./RunScript.sh --update-packages`，`from:` 约束下的依赖版本纹丝不动；删 `Package.resolved`、单独跑 `swift package update` 均无效

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | `--update-packages` 跑完，`swift-dependencies` 仍是 `1.14.1`，尽管本地仓库缓存里 `1.17.1` 早已就位 |
| **影响范围** | 全部 `from:` 声明的直接与传递依赖；实测 20 个落后，其中 17 个是同 major、本应自动升级 |
| **根因** | `update_packages()` 删了 workspace 的 `Package.resolved`，却复用同一个 `$DERIVED_DATA`，`SourcePackages/workspace-state.json` 把旧版本原样喂回给 SPM |
| **Status** | **Fixed** —— 补删 `workspace-state.json` |

---

## 现象

```
swift-dependencies      1.14.1 -> 1.17.1      swiftmcp          1.9.0 -> 1.10.4
xctest-dynamic-overlay  1.11.0 -> 1.13.1      swift-custom-dump 1.6.1 -> 1.7.3
swift-system             1.7.5 -> 1.8.1       swift-asn1        1.6.0 -> 1.7.1
frameworktoolbox         0.9.0 -> 0.10.0      sparkle           2.9.4 -> 2.9.6
… 同 major 共 17 个
```

右侧版本**全部已 fetch 到 `~/Library/Caches/org.swift.swiftpm/repositories` 的本地镜像**，
即 SPM 看得见新 tag，只是不选。所以这不是"缓存没刷新"，而是"解析结果被旧状态钉住"。

## 根因

SwiftPM 在 Xcode workspace 下有**三层独立的版本状态**：

| 层 | 位置 | 谁写 |
|---|---|---|
| 1 | `<workspace>/xcshareddata/swiftpm/Package.resolved` | 提交进仓库的 pin |
| 2 | `<DerivedData>/SourcePackages/workspace-state.json` | SPM 自己的解析状态 |
| 3 | `~/Library/Caches/org.swift.swiftpm/repositories/` | 全局裸仓库镜像 |

修复前的 `update_packages()` 只清了第 1 层：

```sh
run rm -f "$workspace_package_resolved"                                       # 第 1 层
xcodebuild -resolvePackageDependencies -derivedDataPath "$DERIVED_DATA" ...   # 第 2 层原封不动
```

`$DERIVED_DATA` 是跨次构建复用的固定目录（`/Volumes/DerivedData/RuntimeViewer/Debug-arm64e`），
其 `SourcePackages/workspace-state.json` 记录着上一次解析出的每个版本。
第 1 层被删后，SPM 直接从第 2 层读回旧版本，`-resolvePackageDependencies`
本身的语义又只是"满足现有约束"、从不主动升级，于是解析结果原地踏步。

这个坑 `BuildRuntimeViewerServerXCFramework.sh:169-186` 早已记录过——那个脚本
每次都 `rm -rf "$DERIVED_DATA_DIR"` 做 clean build，顺带清掉了第 2 层，所以从未暴露。
`RunScript.sh` / `ArchiveScript.sh` 复用 DerivedData，就踩了个正着。

### 为什么不能靠 `swift package update` 补救

```sh
swift package update --package-path "$PROJECT_DIR/RuntimeViewerCore"
swift package update --package-path "$PROJECT_DIR/RuntimeViewerPackages"
```

这两行曾经存在于 `update_packages()` 中（已移除，勿加回）。它们写的是**各 package 自己的**
`Package.resolved`，Xcode workspace 从不读那两个文件，因此对 workspace 的解析结果毫无影响。
而且按 `BuildRuntimeViewerServerXCFramework.sh` 的注释，独立解析还会挑到不兼容的上游约束
（SwiftMCP 要 swift-syntax 602.x，RxSwiftPlus 要 601.x，workspace 靠本地 checkout 统一了它们）。

## 验证

三组对照，起点均为同一份原始 `Package.resolved`，在 APFS clone 出的隔离
DerivedData 上进行，不触碰真实构建目录。

| 组 | 操作 | 结果 |
|---|---|---|
| 0 基线 | 只删 `Package.resolved` | **复现**：83 个 pin 仅 8 个变化，`swift-dependencies` 仍 `1.14.1` |
| A 最小 | 再删 `workspace-state.json`，保留 `checkouts/` `repositories/` | **修复**：27 个变化，17 个同 major 依赖全部升级 |
| B 保守 | 整个删 `SourcePackages` | 未执行——A 已达成目标，B 需重下 2.4G artifacts |

组 A 保留了 276M `checkouts/` 与 772M `repositories/`，SPM 复用已有 clone 直接切 tag，
耗时与组 0 相当（约 80 秒），因此选 A 而非整目录删除。

## 修复

`RunScript.sh` 与 `ArchiveScript.sh` 的 `update_packages()`：

```sh
    run rm -f "$workspace_package_resolved"
    run rm -f "$DERIVED_DATA/SourcePackages/workspace-state.json"   # ← 新增
```

## 相关

- `BuildRuntimeViewerServerXCFramework.sh:169-186` —— 同一根因的早期记录，走的是 clean build 路径
- 跨 major 的依赖（`keyboardshortcuts` 2→3、`swift-subprocess` 0.5→1.0）不在本次修复范围，
  需要改 `Package.swift` 的 `from:` 并处理 API 破坏
- 传递依赖 `swift-crypto` 会被 `swift-certificates` 拉高到 `4.3.1`（跨 major），
  首次执行修复后的 `--update-packages` 时需留意 API 破坏
