# Debug arm64e RunScript 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 新增 `RuntimeViewer-Debug.xcworkspace`、`Debug-arm64e` build configuration、`RunScript.sh`，通过命令行 xcodebuild 编译并启动只在两个目标 target 带 arm64e 切片的 Debug 版本主 app，绕开 Xcode GUI 在 arm64e 模式下的编译 bug。

**Architecture:** 复制 `RuntimeViewer.xcworkspace` 的本地依赖工作区，叠加 `iOSPackagesShouldBuildARM64e=true`；在 `RuntimeViewerUsingAppKit.xcodeproj` 与 `RuntimeViewerServer.xcodeproj` 里增加 `Debug-arm64e` configuration（基于 Debug，仅给 `RuntimeViewerServer.framework` 和 `dev.mxiris.runtimeviewer.service` 两个 target 设 `EPA=YES`）；脚本骨架与工具函数模仿 `ArchiveScript.sh`，去除发版步骤，使用 `-configuration Debug-arm64e` 让需要 arm64e 切片的 target 自然拿到该切片；不传命令行 ARCHS override 以避免污染 SwiftMacro plugin 等 build-host 工具。

**Tech Stack:** bash, xcodebuild, xcbeautify（可选）

**参考文档:** `Documentations/Plans/2026-05-06-debug-arm64e-runscript-design.md`

---

## File Structure

| 类型 | 路径 | 责任 |
|------|------|------|
| 创建 | `RuntimeViewer-Debug.xcworkspace/contents.xcworkspacedata` | 工作区文件引用列表（与 `RuntimeViewer.xcworkspace` 一致，含本地兄弟仓库） |
| 创建 | `RuntimeViewer-Debug.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings` | `iOSPackagesShouldBuildARM64e=true` 等 workspace 级开关 |
| 修改 | `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit.xcodeproj/project.pbxproj` | 给所有 target + project 增加 `Debug-arm64e` build configuration（dev.mxiris.runtimeviewer.service 设 `EPA=YES`，其余沿用 Debug） |
| 修改 | `RuntimeViewerServer/RuntimeViewerServer.xcodeproj/project.pbxproj` | 给 RuntimeViewerServer/RuntimeViewerMobileServer + project 增加 `Debug-arm64e`（RuntimeViewerServer 设 `EPA=YES`） |
| 创建 | `RunScript.sh` | 命令行 `Debug-arm64e` 配置构建 / 启动入口 |

---

## Task 1: 新建 RuntimeViewer-Debug.xcworkspace

**Files:**
- Create: `RuntimeViewer-Debug.xcworkspace/contents.xcworkspacedata`
- Create: `RuntimeViewer-Debug.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings`

- [ ] **Step 1: 创建 `contents.xcworkspacedata`**

写入与 `RuntimeViewer.xcworkspace/contents.xcworkspacedata` **完全一致**的内容（保留所有 `container:..` 本地兄弟仓库引用）：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Workspace
   version = "1.0">
   <FileRef
      location = "container:../MachOKit">
   </FileRef>
   <FileRef
      location = "container:../MachOObjCSection">
   </FileRef>
   <FileRef
      location = "container:../MachOSwiftSection">
   </FileRef>
   <FileRef
      location = "container:../swift-demangling">
   </FileRef>
   <FileRef
      location = "container:../swift-semantic-string">
   </FileRef>
   <FileRef
      location = "group:RuntimeViewerCore">
   </FileRef>
   <FileRef
      location = "group:RuntimeViewerPackages">
   </FileRef>
   <FileRef
      location = "group:RuntimeViewerMCP">
   </FileRef>
   <FileRef
      location = "group:RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit.xcodeproj">
   </FileRef>
   <FileRef
      location = "group:RuntimeViewerUsingUIKit/RuntimeViewerUsingUIKit.xcodeproj">
   </FileRef>
   <FileRef
      location = "group:RuntimeViewerServer/RuntimeViewerServer.xcodeproj">
   </FileRef>
   <FileRef
      location = "group:RuntimeViewerPrecompiledLibraries/swift-syntax">
   </FileRef>
</Workspace>
```

- [ ] **Step 2: 创建 `WorkspaceSettings.xcsettings`**

写入与 `RuntimeViewer-Distribution.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings` **完全一致**的内容：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>IDEWorkspaceSharedSettings_AutocreateContextsIfNeeded</key>
	<false/>
	<key>iOSPackagesShouldBuildARM64e</key>
	<true/>
</dict>
</plist>
```

注意 plist 内部缩进使用 tab（与 Distribution 原文一致），不要替换成空格。

- [ ] **Step 3: 验证 workspace 文件 xcodebuild 可识别**

运行：

```bash
xcodebuild -workspace RuntimeViewer-Debug.xcworkspace -list 2>&1 | head -40
```

预期：列出 schemes（含 `RuntimeViewer macOS`、`RuntimeViewerCatalystHelper`），无 `xcodebuild: error` 行。

- [ ] **Step 4: Commit**

```bash
git add RuntimeViewer-Debug.xcworkspace/contents.xcworkspacedata \
        RuntimeViewer-Debug.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings
git commit -m "$(cat <<'EOF'
feat(debug-arm64e-runscript): add RuntimeViewer-Debug workspace with arm64e flag

Mirrors RuntimeViewer.xcworkspace (with local sibling repo references for
MachOKit/MachOObjCSection/MachOSwiftSection/swift-demangling/swift-semantic-string)
and adds iOSPackagesShouldBuildARM64e=true so xcodebuild produces arm64e
SPM slices. The Xcode GUI compile bug under this flag is bypassed by the
upcoming RunScript.sh, which drives xcodebuild from the command line.
EOF
)"
```

---

## Task 2: RunScript.sh 骨架（头部、默认参数、工具函数、参数解析）

**Files:**
- Create: `RunScript.sh`

- [ ] **Step 1: 写脚本头与默认参数**

新建 `RunScript.sh`，写入：

```bash
#!/usr/bin/env bash
# RunScript.sh — Build and launch a Debug + arm64e RuntimeViewer using
# xcodebuild from the command line. The Xcode GUI fails to compile under
# iOSPackagesShouldBuildARM64e=true; this script bypasses that bug.
#
# Usage:
#   ./RunScript.sh                          # build + launch
#   ./RunScript.sh --no-launch              # build only
#   ./RunScript.sh --update-packages        # refresh SPM pins first
#   ./RunScript.sh --dry-run                # print commands without running
#   ./RunScript.sh --help
#
# All distribution-related flags (notarize, appcast, GitHub upload, commit)
# are intentionally absent — see ArchiveScript.sh for those.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

# Defaults
WORKSPACE="RuntimeViewer-Debug.xcworkspace"
SCHEME="RuntimeViewer macOS"
CATALYST_SCHEME="RuntimeViewerCatalystHelper"
CONFIGURATION="Debug-arm64e"
BUILD_NUMBER="$(date +"%Y%m%d.%H.%M")"
DERIVED_DATA="$PROJECT_DIR/DerivedData/Debug-arm64e"

UPDATE_PACKAGES=false
LAUNCH=true
DRY_RUN=false
```

- [ ] **Step 2: 写工具函数（fail / log / pretty / run / run_piped）**

继续追加：

```bash
fail() { echo "error: $*" >&2; exit 1; }
log()  { echo "[RunScript] $*"; }

# Pipe xcodebuild output through xcbeautify when it is installed; otherwise
# fall back to cat so that runs do not depend on the tool.
pretty() {
    if command -v xcbeautify >/dev/null 2>&1; then
        xcbeautify
    else
        cat
    fi
}

run() {
    if $DRY_RUN; then
        printf '+ '; printf '%q ' "$@"; echo
    else
        "$@"
    fi
}

# Run a command with its stdout+stderr piped through pretty(). The raw
# output is also tee'd to $LOG_DIR so devs can recover the full xcodebuild
# log when xcbeautify drops error lines. `set -o pipefail` ensures a
# failure in the leading command still propagates.
run_piped() {
    if $DRY_RUN; then
        printf '+ '; printf '%q ' "$@"; printf '| tee <log> | pretty\n'
        return 0
    fi
    mkdir -p "$LOG_DIR"
    XCODEBUILD_LOG_INDEX=$((XCODEBUILD_LOG_INDEX + 1))
    local slug="${XCODEBUILD_LOG_NAME:-step}"
    local log_path
    log_path="$LOG_DIR/$(printf '%02d' "$XCODEBUILD_LOG_INDEX")-${slug}.log"
    log "Raw xcodebuild log: $log_path"
    "$@" 2>&1 | tee "$log_path" | pretty
}
```

- [ ] **Step 3: 写参数解析**

继续追加：

```bash
while [[ $# -gt 0 ]]; do
    case "$1" in
        --workspace) WORKSPACE="$2"; shift 2;;
        --scheme) SCHEME="$2"; shift 2;;
        --catalyst-helper-scheme) CATALYST_SCHEME="$2"; shift 2;;
        --configuration) CONFIGURATION="$2"; shift 2;;
        --build-number) BUILD_NUMBER="$2"; shift 2;;
        --derived-data) DERIVED_DATA="$2"; shift 2;;
        --update-packages) UPDATE_PACKAGES=true; shift;;
        --no-launch) LAUNCH=false; shift;;
        --dry-run) DRY_RUN=true; shift;;
        -h|--help) sed -n '2,15p' "$0" | sed 's/^# *//'; exit 0;;
        *) fail "unknown argument: $1";;
    esac
done

[[ -d "$WORKSPACE" ]] || fail "workspace not found: $WORKSPACE"

log "workspace=$WORKSPACE scheme=$SCHEME configuration=$CONFIGURATION build=$BUILD_NUMBER"
log "derived_data=$DERIVED_DATA update_packages=$UPDATE_PACKAGES launch=$LAUNCH"
```

- [ ] **Step 4: 写 LOG_DIR 与计数器**

继续追加：

```bash
LOG_DIR="${LOG_DIR:-$PROJECT_DIR/Products/Logs}"
XCODEBUILD_LOG_INDEX=0

mkdir -p "$LOG_DIR"
log "xcodebuild logs: $LOG_DIR"
```

- [ ] **Step 5: 加可执行权限**

```bash
chmod +x RunScript.sh
```

- [ ] **Step 6: 验证 `--help` 与未知参数**

运行：

```bash
./RunScript.sh --help
```

预期：打印 `RunScript.sh — Build and launch ...` 等 usage 行（来自头部注释 line 2–15）。

运行：

```bash
./RunScript.sh --bogus 2>&1 || true
```

预期：stderr 输出 `error: unknown argument: --bogus`，退出码非 0。

- [ ] **Step 7: 验证 bash 语法**

```bash
bash -n RunScript.sh
```

预期：无输出（语法 OK）。

- [ ] **Step 8: Commit**

```bash
git add RunScript.sh
git commit -m "$(cat <<'EOF'
feat(debug-arm64e-runscript): scaffold RunScript.sh with arg parsing

Adds the bash skeleton: shebang, defaults (Debug + arm64e workspace,
DerivedData/Debug-arm64e), helper functions (fail/log/pretty/run/run_piped)
modeled after ArchiveScript.sh, argument parsing, and workspace existence
check. Build and launch logic land in the next commit.
EOF
)"
```

---

## Task 3: RunScript.sh 编译流程与 launch

**Files:**
- Modify: `RunScript.sh`（在参数解析与 LOG_DIR 之后追加）

- [ ] **Step 1: 写 `update_packages` 函数**

在 `LOG_DIR=...; mkdir -p "$LOG_DIR"; log "xcodebuild logs: ..."` 后追加：

```bash
update_packages() {
    log "Updating Swift package dependencies"
    run swift package update --package-path "$PROJECT_DIR/RuntimeViewerCore"
    run swift package update --package-path "$PROJECT_DIR/RuntimeViewerPackages"

    local workspace_path="$WORKSPACE"
    if [[ "$workspace_path" != /* ]]; then
        workspace_path="$PROJECT_DIR/$workspace_path"
    fi

    local workspace_package_resolved="$workspace_path/xcshareddata/swiftpm/Package.resolved"
    log "Refreshing workspace package pins"
    run rm -f "$workspace_package_resolved"

    XCODEBUILD_LOG_NAME="resolve-catalyst-helper-packages" run_piped xcodebuild -resolvePackageDependencies \
        -workspace "$WORKSPACE" \
        -scheme "$CATALYST_SCHEME" \
        -skipPackagePluginValidation -skipMacroValidation

    XCODEBUILD_LOG_NAME="resolve-main-packages" run_piped xcodebuild -resolvePackageDependencies \
        -workspace "$WORKSPACE" \
        -scheme "$SCHEME" \
        -skipPackagePluginValidation -skipMacroValidation
}

if $UPDATE_PACKAGES; then
    update_packages
fi
```

- [ ] **Step 2: 写 build Catalyst helper 步骤**

继续追加：

```bash
log "Building Catalyst helper"
XCODEBUILD_LOG_NAME="build-catalyst-helper" run_piped xcodebuild build \
    -workspace "$WORKSPACE" \
    -scheme "$CATALYST_SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination 'generic/platform=macOS,variant=Mac Catalyst' \
    -derivedDataPath "$DERIVED_DATA" \
    -skipPackagePluginValidation -skipMacroValidation \
    "CURRENT_PROJECT_VERSION=$BUILD_NUMBER"
```

- [ ] **Step 3: 写 build 主 app + 定位 .app**

继续追加：

```bash
log "Building main app"
XCODEBUILD_LOG_NAME="build-main" run_piped xcodebuild build \
    -workspace "$WORKSPACE" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    -skipPackagePluginValidation -skipMacroValidation \
    "CURRENT_PROJECT_VERSION=$BUILD_NUMBER"

PRODUCTS_DIR="$DERIVED_DATA/Build/Products/$CONFIGURATION"
APP_PATH=""
if [[ -d "$PRODUCTS_DIR" ]]; then
    APP_PATH=$(find "$PRODUCTS_DIR" -maxdepth 1 -type d -name 'RuntimeViewer*.app' \
        -not -name 'RuntimeViewerCatalystHelper.app' | head -1)
fi
if $DRY_RUN; then
    APP_PATH="${APP_PATH:-<app-path>}"
else
    [[ -n "$APP_PATH" && -d "$APP_PATH" ]] || fail "expected built *.app under $PRODUCTS_DIR"
fi
```

注：`$DRY_RUN` 时 `find` 命中不到（脚本只 echo 了 xcodebuild 命令、并未真编译），所以单独处理；让 dry-run 也能跑到末尾的 launch / log 段。

- [ ] **Step 4: 写 launch + 末尾 log 输出**

继续追加：

```bash
if $LAUNCH; then
    log "Launching $APP_PATH"
    run open "$APP_PATH"
else
    log "Launch skipped (--no-launch)"
fi

log "Done. Outputs:"
log "  app:                 $APP_PATH"
log "  derived_data:        $DERIVED_DATA"
```

- [ ] **Step 5: bash 语法检查**

```bash
bash -n RunScript.sh
```

预期：无输出。

- [ ] **Step 6: 干跑验证命令拼接**

```bash
./RunScript.sh --dry-run 2>&1 | tee /tmp/runscript-dryrun.log
```

预期 `/tmp/runscript-dryrun.log` 中能看到（顺序、参数应一致）：

1. `[RunScript] workspace=RuntimeViewer-Debug.xcworkspace scheme=RuntimeViewer macOS configuration=Debug build=...`
2. `[RunScript] Building Catalyst helper (arm64e)`
3. `+ xcodebuild build -workspace RuntimeViewer-Debug.xcworkspace -scheme RuntimeViewerCatalystHelper -configuration Debug -destination generic/platform=macOS,variant=Mac\ Catalyst -derivedDataPath .../DerivedData/Debug-arm64e -skipPackagePluginValidation -skipMacroValidation ARCHS=arm64e ONLY_ACTIVE_ARCH=NO CURRENT_PROJECT_VERSION=...`
4. `[RunScript] Building main app (arm64e)`
5. `+ xcodebuild build -workspace RuntimeViewer-Debug.xcworkspace -scheme RuntimeViewer\ macOS -configuration Debug -destination generic/platform=macOS -derivedDataPath .../DerivedData/Debug-arm64e -skipPackagePluginValidation -skipMacroValidation ARCHS=arm64e ONLY_ACTIVE_ARCH=NO CURRENT_PROJECT_VERSION=...`
6. `[RunScript] Launching <app-path>`
7. `+ open <app-path>`
8. `[RunScript] Done. Outputs:`

确认每条 xcodebuild 命令都包含 `ARCHS=arm64e ONLY_ACTIVE_ARCH=NO`，主 app destination 是 `generic/platform=macOS`，Catalyst helper 是 `generic/platform=macOS,variant=Mac Catalyst`。

- [ ] **Step 7: 干跑 `--no-launch`**

```bash
./RunScript.sh --no-launch --dry-run 2>&1 | grep -E '(Launching|Launch skipped)'
```

预期：输出 `[RunScript] Launch skipped (--no-launch)`，不出现 `Launching`。

- [ ] **Step 8: Commit**

```bash
git add RunScript.sh
git commit -m "$(cat <<'EOF'
feat(debug-arm64e-runscript): build Catalyst helper, main app, launch

Implements the build pipeline: optional update_packages, the Catalyst
helper build (Mac Catalyst destination), the main macOS app build
(generic/platform=macOS), .app discovery, and default launch via open.
Both xcodebuild invocations pass ARCHS=arm64e ONLY_ACTIVE_ARCH=NO so the
binary is forced to a pure arm64e slice. --no-launch and --dry-run are
honored.
EOF
)"
```

---

## Task 4: 端到端真实编译与 arm64e 验证（manual，不产生 commit）

**Files:** 无需修改（仅验证 Task 1–3 的产物是否真能跑通）

- [ ] **Step 1: 真实编译，不启动**

```bash
./RunScript.sh --no-launch
```

预期：

- 终端打印 `Building Catalyst helper (arm64e)` → `Building main app (arm64e)` → `Launch skipped`
- `Products/Logs/01-build-catalyst-helper.log` 与 `Products/Logs/02-build-main.log` 存在
- 退出码 0

如果失败，先看 `Products/Logs/<NN>-*.log` 的尾部错误。最常见的失败：

- `iOSPackagesShouldBuildARM64e` 未生效（确认 Task 1 Step 2 的 plist 写对了）
- 本地兄弟仓库不存在（确认 `../MachOKit` 等仓库都在）

- [ ] **Step 2: 用 lipo 验证关键二进制的切片**

```bash
APP_PATH=$(find DerivedData/Debug-arm64e/Build/Products/Debug-arm64e \
    -maxdepth 1 -type d -name 'RuntimeViewer*.app' \
    -not -name 'RuntimeViewerCatalystHelper.app' | head -1)

# 主 app（EPA=NO，预期 arm64-only，不含 arm64e）
lipo -info "$APP_PATH/Contents/MacOS/RuntimeViewer-Debug"

# RuntimeViewerServer.framework（EPA=YES，预期含 arm64e）
lipo -info "$APP_PATH/Contents/Resources/RuntimeViewerServer.framework/RuntimeViewerServer"

# dev.mxiris.runtimeviewer.service（EPA=YES，预期含 arm64e）
lipo -info "$APP_PATH/Contents/Library/LaunchServices/dev.mxiris.runtimeviewer.service"
```

预期输出：

```
... RuntimeViewer-Debug are: x86_64 arm64
... RuntimeViewerServer are: x86_64 arm64 arm64e
... dev.mxiris.runtimeviewer.service are: x86_64 arm64 arm64e
```

主 app **不应**含 `arm64e`（因为它在 Debug-arm64e 下保持 EPA=NO）。
后两者**必须**含 `arm64e`，否则说明 Debug-arm64e configuration 在该
target 上的 `ENABLE_POINTER_AUTHENTICATION=YES` 设置丢失，回到工程
build settings 检查。

- [ ] **Step 3: 真实启动**

```bash
./RunScript.sh
```

预期：编译完成后 `RuntimeViewer.app` 启动。如果系统启动失败，提示用户检查 `csrutil` / `boot-args` 是否启用 arm64e preview ABI（这是 arm64e 调试的已知前置条件，与本任务无关）。

- [ ] **Step 4: 干净状态确认**

```bash
git status
```

预期：tracking tree 干净（Task 1 / 2 / 3 的产物均已 commit）；可能有未 track 的 `DerivedData/` 与 `Products/Logs/`，这两者都已经在 `.gitignore`（验证：`git check-ignore DerivedData/Debug-arm64e Products/Logs` 应输出两条匹配）。

如果 `git check-ignore` 没有匹配 `Products/Logs`（说明仓库的 `.gitignore` 不覆盖该路径，因为 ArchiveScript.sh 也写到这个路径，所以理论上应该已经忽略了——若没有，提示用户在后续单独 PR 处理 `.gitignore`，本计划不引入该改动）。

---

## Self-Review

**Spec coverage：**
- ✅ 新 workspace 复制本地依赖 + arm64e flag → Task 1
- ✅ RunScript.sh 默认参数（workspace / scheme / configuration / DERIVED / LAUNCH 等）→ Task 2 Step 1
- ✅ fail/log/pretty/run/run_piped 工具函数 → Task 2 Step 2
- ✅ 命令行选项 `--update-packages` / `--no-launch` / `--dry-run` / `--help` 等 → Task 2 Step 3
- ✅ Catalyst helper 不可跳过 → Task 3 Step 2（无 `--skip-catalyst-helper` 开关）
- ✅ 主 app build → Task 3 Step 3
- ✅ 编译完默认 `open .app` → Task 3 Step 4
- ✅ arm64e 切片只落到目标 target（RuntimeViewerServer.framework、dev.mxiris.runtimeviewer.service）→ 由 `Debug-arm64e` configuration 的 `ENABLE_POINTER_AUTHENTICATION=YES` 提供（前置 Setup，已 commit），脚本不传任何 ARCHS override
- ✅ Workspace 层 arm64e（`iOSPackagesShouldBuildARM64e=true`）→ Task 1 Step 2
- ✅ DerivedData 独立路径 → Task 2 Step 1
- ✅ lipo 验证 arm64e → Task 4 Step 2
- ✅ 不引入 archive / export / notarize / appcast / upload / commit-push → 三个 Task 中均无相关代码

**Placeholder scan:** 全部代码块均为完整可粘贴内容；无 TBD/TODO；测试 / 验证步骤都给了实际命令与期望输出。

**Type / 命名一致性:** 变量名 `WORKSPACE` / `SCHEME` / `CATALYST_SCHEME` / `CONFIGURATION` / `BUILD_NUMBER` / `DERIVED_DATA` / `UPDATE_PACKAGES` / `LAUNCH` / `DRY_RUN` / `LOG_DIR` / `XCODEBUILD_LOG_INDEX` / `XCODEBUILD_LOG_NAME` 在 Task 2 / Task 3 之间引用一致；函数名 `fail` / `log` / `pretty` / `run` / `run_piped` / `update_packages` 一致。

**Commit 边界:** workspace、Debug-arm64e configuration、脚本骨架、编译流程各自独立 commit，可单独 revert，互不依赖对方未 commit 的代码。

无需修改，进入 handoff。
