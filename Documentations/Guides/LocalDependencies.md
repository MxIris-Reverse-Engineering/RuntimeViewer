# 使用指南：本地依赖 workspace

- **面向**: 同时改本仓库和 MachO 那几个上游库、要在 App 里直接编进未推送改动的人
- **对应提案**: [0078](../Evolutions/0078-local-dependencies-workspace.md)
- **最后更新**: 2026-11-08

`RuntimeViewer-Local.xcworkspace` 的内容与 `RuntimeViewer-Debug.xcworkspace` 相同，另外多了六个上游库的本地检出：
MachOKit、MachOKitExtensions、MachOObjCSection、MachOSwiftSection、swift-demangling、swift-semantic-string。
workspace 里的本地包会顶替依赖图里所有同名的包，不论哪个清单、用哪个 URL 引用它。所以在这个 workspace 里，
这六个库用本地检出编进 App，其余依赖照锁文件里的版本。

## 什么时候开哪个

- 改了这六个库、要在 App 里马上看到效果：开 `RuntimeViewer-Local.xcworkspace`。
- 要按 RV 钉住的版本编（推送前核对、对照 CI 与发版）：开 `RuntimeViewer-Debug.xcworkspace`。
- 同一个工程不能同时开在两个 workspace 里，先关掉一个再开另一个。两个 workspace 各用各的 DerivedData，
  来回切换都是增量编译。
- `RunScript.sh` 默认用 Debug workspace 和一个固定的构建目录。用本地 workspace 时两样都换掉，否则两个 workspace
  共用一个构建目录，每次切换都要重编大半个 App：

  ```bash
  ./RunScript.sh --workspace RuntimeViewer-Local.xcworkspace --derived-data /Volumes/DerivedData/RuntimeViewer/Debug-arm64e-Local
  ```

  这个 workspace 已经用本地检出，不要再加 `--local-deps`。

## 它从哪找这六个库

workspace 里这六条的路径写成 `../MachOKit` 这样，相对 workspace 所在的检出，落在检出旁边的 `.worktrees/` 目录里，
也就是本仓库 `.worktrees/` 下的六个符号链接。`RuntimeViewerCore/Package.swift` 的本地候选（`../../MachOKit` 等）
用的也是这组链接。

| 链接 | 指向（都在 `MxIris-Reverse-Engineering/` 下） |
|---|---|
| `MachOKit` | `MachOKit/.worktrees/MachOKit` |
| `MachOKitExtensions` | `MachOKitExtensions`（仓库根，它没有常驻 worktree） |
| `MachOObjCSection` | `MachOObjCSection/.worktrees/MachOObjCSection` |
| `MachOSwiftSection` | `MachOSwiftSection/.worktrees/MachOSwiftSection` |
| `swift-demangling` | `swift-demangling/.worktrees/swift-demangling` |
| `swift-semantic-string` | `swift-semantic-string/.worktrees/swift-semantic-string` |

- `.worktrees/` 不进仓库，链接每台机器各建一次。两台 Mac Studio 在 2026-11-08 都已建好。新机器上照表在仓库根执行
  `ln -s <指向的绝对路径> .worktrees/<链接名>`。
- 本仓库的任何 worktree（`.worktrees/RuntimeViewer-<用途>`）都经同一组链接找到这六个库，同一个 workspace 文件不用改。
- **包按目录名认**：Xcode 拿路径最后一段的小写当包的身份。要改用某个库的功能 worktree，把对应的链接改指过去
  （链接是本仓库所有检出共用的，改完记得指回来）。直接把 workspace 里的路径改成功能 worktree 的路径（目录名是 `MachOSwiftSection-<用途>` 这种）会解析失败：
  `unable to override package 'MachOSwiftSection' because its identity … doesn't match override's identity (directory name)`。

## 锁文件

本地 workspace 的 `xcshareddata/swiftpm/Package.resolved` 不进仓库（见 `.gitignore`）：它随本机这六个检出的清单变化，
提交了就会频繁改动，两台 Mac 还会互相覆盖。第一次使用、或 RV 的 pin 有了变化之后，从 Debug workspace 拷一份：

```bash
cp RuntimeViewer-Debug.xcworkspace/xcshareddata/swiftpm/Package.resolved RuntimeViewer-Local.xcworkspace/xcshareddata/swiftpm/
```

Xcode 解析时去掉这六个库的条目（它们用的是本地检出），再加上本地检出自己要的测试依赖（如 MachOSwiftSection 的
swift-snapshot-testing），其余 pin 不变。不拷也能用，只是 Xcode 会把其余依赖解析到清单允许的最新版本，与 RV 钉的
版本不一定相同。`UpdatePackagesScript.sh` 不处理这个 workspace。

## 不要用各个 Package.swift 里的开关代替它

每个 `Package.swift` 都自己决定一个依赖用本地路径还是 URL。只打开 `RuntimeViewerCore` 的本地候选时，MachOSwiftSection、
MachOObjCSection 等库的清单仍然按 URL 引用 MachOKit、MachOObjCSection 这些包，同一个包经路径和 URL 各进一次，
SwiftPM 拒绝解析。`USING_LOCAL_DEPENDENCIES=1` 能让所有清单一致，但它打开每个清单的全部本地候选：UIFoundation、
RxSwiftPlus、RxAppKit、MachInjector、swift-helper-service、swift-injection-peer 等也跟着换成本地。它留给包级别的
`swift build` / `swift test` 和 `RunScript.sh --local-deps`。

## 再加一个库

在 `contents.xcworkspacedata` 里照现有条目加一条 `group:../<库名>`，在 `.worktrees/` 下建同名链接，再在上面的表里补一行。
链接名要与包名相同，理由见上一节的「包按目录名认」。
