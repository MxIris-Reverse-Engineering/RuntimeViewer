# Debug arm64e RunScript 设计

## 背景与动机

`RuntimeViewer-Distribution.xcworkspace` 通过
`xcshareddata/WorkspaceSettings.xcsettings` 中的
`iOSPackagesShouldBuildARM64e=true` 强制所有 SPM 包构建 arm64e
切片，这是发版时必备的配置。

但日常开发用的 `RuntimeViewer.xcworkspace` 不能照搬这一设置，原因有二：

1. 该 workspace 引用了本地兄弟仓库（`../MachOKit`、`../MachOObjCSection`、
   `../MachOSwiftSection`、`../swift-demangling`、`../swift-semantic-string`），
   它们只随主仓库 SPM 走，没有为 arm64e 单独配置。
2. 开启 arm64e 后用 Xcode GUI 编译会触发 Xcode 自身的 bug 直接失败，
   但 `xcodebuild` 命令行可以正常通过。

因此需要一份"带本地依赖、能产出 arm64e 调试包"的入口，并通过命令行
脚本绕开 GUI 编译失败的问题。

## 目标

- 提供 `RuntimeViewer-Debug.xcworkspace`：内容等于
  `RuntimeViewer.xcworkspace`（保留本地兄弟仓库引用）+
  `iOSPackagesShouldBuildARM64e=true`。
- 提供 `RunScript.sh`：用 `xcodebuild` 命令行构建并启动 Debug + arm64e
  版本的主 app，避开 GUI bug。
- 不引入 archive / export / notarize / appcast / upload / commit 等发版步骤
  （这些归 `ArchiveScript.sh` 管）。

## 非目标

- 不替换 `ArchiveScript.sh`。
- 不修改 `RuntimeViewer.xcworkspace` 或 `RuntimeViewer-Distribution.xcworkspace`。
- 不为 iOS / Catalyst / 模拟器产物提供发布入口（`BuildSimulatorScript.sh`、
  `ArchiveScript.sh` 已覆盖）。
- 不附加 lldb attach、断点恢复等调试器集成 — 启动后用户自己用 Xcode
  Debug → Attach to Process 即可。

## 方案

### 1. 新增 `RuntimeViewer-Debug.xcworkspace`

目录结构：

```
RuntimeViewer-Debug.xcworkspace/
├── contents.xcworkspacedata        # 复制自 RuntimeViewer.xcworkspace
└── xcshareddata/
    └── WorkspaceSettings.xcsettings  # 复制自 Distribution（含 arm64e 开关）
```

`contents.xcworkspacedata` 的引用列表与 `RuntimeViewer.xcworkspace`
完全一致（含 `container:../MachOKit` 等本地兄弟仓库），不做任何裁剪。

`WorkspaceSettings.xcsettings` 内容：

```xml
<plist version="1.0">
<dict>
    <key>IDEWorkspaceSharedSettings_AutocreateContextsIfNeeded</key>
    <false/>
    <key>iOSPackagesShouldBuildARM64e</key>
    <true/>
</dict>
</plist>
```

不创建 `xcuserdata` 目录（按需自动生成）。

### 2. 新增 `RunScript.sh`

模仿 `ArchiveScript.sh` 的骨架，复用其工具函数和参数解析风格。

#### 默认参数

| 参数 | 默认值 |
|------|--------|
| `WORKSPACE` | `RuntimeViewer-Debug.xcworkspace` |
| `SCHEME` | `RuntimeViewer macOS` |
| `CATALYST_SCHEME` | `RuntimeViewerCatalystHelper` |
| `CONFIGURATION` | `Debug` |
| `BUILD_NUMBER` | `$(date +"%Y%m%d.%H.%M")` |
| `DERIVED` | `$PROJECT_DIR/DerivedData/Debug-arm64e` |
| `LAUNCH` | `true` |

`DerivedData/Debug-arm64e` 单独成路径，避免与 Xcode GUI 的默认
DerivedData 互相污染（GUI 那份编译失败的产物不会被命令行复用，反之亦然）。

#### 命令行选项

| 选项 | 行为 |
|------|------|
| `--workspace <path>` | 覆盖 workspace |
| `--scheme <name>` | 覆盖主 app scheme |
| `--catalyst-helper-scheme <name>` | 覆盖 Catalyst helper scheme |
| `--configuration <name>` | 覆盖 configuration（默认 Debug） |
| `--build-number <n>` | 覆盖 `CURRENT_PROJECT_VERSION` |
| `--derived-data <path>` | 覆盖 DerivedData |
| `--update-packages` | 编译前刷新 SPM pin（同 ArchiveScript） |
| `--no-launch` | 编译完不自动启动 .app |
| `--keep-derived` | 保留 DerivedData（默认就保留，仅占位以保持参数对称） |
| `--dry-run` | 仅打印命令，不执行 |
| `-h, --help` | 显示帮助 |

不复用 ArchiveScript 的 `--update-appcast` / `--upload-to-github` /
`--commit-push` / `--skip-notarization` / `--include-ios-simulator` 等
发版相关选项 — 用不到。

#### 复用的工具函数

直接搬运 ArchiveScript.sh 中的：

- `fail`、`log`：错误退出与统一前缀日志
- `pretty`：xcbeautify 自动检测，无则透传 `cat`
- `run`：`--dry-run` 时只 echo，不执行
- `run_piped`：通过 `pretty` 美化输出，同时把原始 log 落到
  `Products/Logs/<NN>-<slug>.log`，便于排查
- `update_packages`（仅当 `--update-packages` 时调用）

`LOG_DIR` 默认 `$PROJECT_DIR/Products/Logs`（与 ArchiveScript 共用）。
不抓取 `xcdistributionlogs`（不走 exportArchive）。

#### 编译流程

1. 解析参数，校验 `RuntimeViewer-Debug.xcworkspace` 存在。
2. （可选）`update_packages`。
3. **Build Catalyst helper**（CLAUDE.md 强制要求，不提供跳过开关）：

   ```bash
   xcodebuild build \
       -workspace "$WORKSPACE" \
       -scheme "$CATALYST_SCHEME" \
       -configuration "$CONFIGURATION" \
       -destination 'generic/platform=macOS,variant=Mac Catalyst' \
       -derivedDataPath "$DERIVED" \
       -skipPackagePluginValidation -skipMacroValidation \
       ARCHS=arm64e ONLY_ACTIVE_ARCH=NO \
       "CURRENT_PROJECT_VERSION=$BUILD_NUMBER"
   ```

4. **Build 主 app**：

   ```bash
   xcodebuild build \
       -workspace "$WORKSPACE" \
       -scheme "$SCHEME" \
       -configuration "$CONFIGURATION" \
       -destination 'generic/platform=macOS' \
       -derivedDataPath "$DERIVED" \
       -skipPackagePluginValidation -skipMacroValidation \
       ARCHS=arm64e ONLY_ACTIVE_ARCH=NO \
       "CURRENT_PROJECT_VERSION=$BUILD_NUMBER"
   ```

5. 在 `$DERIVED/Build/Products/Debug/` 下定位 `*.app`，记录路径。
6. 默认 `open "$APP_PATH"`（`--no-launch` 跳过）。
7. log 输出主 app 路径。

#### 强制 arm64e 的两层保险

- workspace 层：`iOSPackagesShouldBuildARM64e=true` 让 SPM 包构建 arm64e
- 命令行层：`ARCHS=arm64e ONLY_ACTIVE_ARCH=NO` 强制主 app target
  只产 arm64e 切片（覆盖工程 default ARCHS）

两层一起保证产物纯 arm64e，方便挂调试器时不会因架构不匹配出错。

## 验证与回退

### 手动验证步骤

1. 运行 `./RunScript.sh`（无参数）。
2. 确认 `Products/Logs/01-build-catalyst-helper.log` 与
   `Products/Logs/02-build-main.log` 都存在且无错误。
3. `.app` 自动启动，菜单 → "About RuntimeViewer" 看到 build number。
4. 终端运行 `lipo -info "<app_path>/Contents/MacOS/<binary>"`，
   预期输出包含 `arm64e`，**不**包含 `arm64`。
5. 重跑 `./RunScript.sh --no-launch`，验证不会自动启动。
6. 重跑 `./RunScript.sh --dry-run`，验证只打印命令。

### 回退方案

- 若发现 workspace 写法或脚本有问题，可直接删除
  `RuntimeViewer-Debug.xcworkspace` 与 `RunScript.sh`，不影响其他流程。
- 任何 commit 都拆成可单独 revert 的小 commit（workspace 一个，脚本一个）。

## 风险

- **Xcode GUI bug 依旧存在**：用户若直接在 Xcode 里 ⌘B 这个 Debug
  workspace 仍会失败。脚本只解决命令行编译，不解决 GUI 编译。
  在脚本头部 / README 注释里需要说明这一点。
- **DerivedData 体积**：`Debug-arm64e` 与 GUI DerivedData 并存可能多
  占几 GB 磁盘。可接受，必要时手动删除。
- **arm64e 调试器**：arm64e 在非 Apple 内部环境下需要启动
  `boot-args` 加 `-arm64e_preview_abi`。这是已有约束，本设计不解决。
