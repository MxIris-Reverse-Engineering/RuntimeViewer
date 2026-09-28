# 2026-09-28 App 图标里的头文件文字比原来暗淡：生成脚本选错了字重，深色填充也不是白色

**调查日期：** 2026-09-28
**修复落地：** 本日，见 `Resources/AppIconTools/GenerateCodeListingLayer.swift`（`SFMono-Regular` → `SFMono-Bold`）、`Resources/AppIcon.icon/icon.json` 与 `Resources/AppIconBeta.icon/icon.json`（代码层的 dark 填充改为纯白），两个 Xcode 26 变体随之重新生成
**所属分支：** `next`
**Severity：** Minor —— 不影响功能，但图标的主体内容明显变淡，浅色、深色外观都看得出来
**触发场景：** 用户对比记忆中的旧图标，指出「头文件文字太暗淡，之前很清楚」

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | 代码文字笔画细、偏灰。旧图标是粗体纯白 |
| **引入时间** | 2026-09-19 的 `74e665e4`：把单张 824 像素位图前景拆成矢量图层。不是 09-21 修描边那次，那次没有动代码层 |
| **根因 1：字重** | 生成脚本只按「首行文字的墨迹宽度」匹配旧位图，据此选了 SF Mono **Regular**。等宽字体各字重的字宽完全相同，这个判据选得出字号，选不出字重 |
| **根因 2：深色填充** | 代码层的 dark `fill-specializations` 写的是灰蓝色 `display-p3:0.80,0.86,0.93`，旧位图在深色外观下就是它自己的纯白 |
| **Status** | **Fixed** —— 改用 SF Mono **Bold**，dark 填充改为纯白。用 `ictool` 渲染修复前、修复后与旧位图文档三者对比，修复后与旧图基本一致 |

---

## 怎么定位的

先搭能看的回路：Icon Composer 自带的 `ictool` 可以按指定外观直接导出整张图标，不受系统外观影响，也能渲染任意历史版本（`git show 74e665e4^:…` 把旧 `.icon` 目录还原到 `/tmp` 再跑）：

```
"/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" \
    X.icon --export-image --output-file out.png --platform macOS --rendition Dark \
    --width 512 --height 512 --scale 1
```

浅色（`Default`）、深色（`Dark`）两种外观下，旧图的文字都明显更粗更亮。

**字重是量出来的，不是看出来的。** 在黑底上取旧位图首行 `@interface NSObject <NSObject> {` 所在的 600 × 44 区域，统计亮度总和（相当于「完全点亮的像素数」），再用各字重的 SF Mono 29 pt 在同样条件下排同一行：

| 来源 | 墨迹量 | 首行宽度 |
|---|---|---|
| 旧位图 | ≈ 4408 | 568 |
| SF Mono Regular（修复前） | ≈ 2757 | 572 |
| SF Mono Medium | ≈ 3157 | 572 |
| SF Mono Semibold | ≈ 3586 | 572 |
| SF Mono Bold | ≈ 4134 | 572 |
| SF Mono Heavy | ≈ 5060 | 573 |

宽度一列就是当初的判据：五个字重几乎一样宽，所以它什么也区分不了。墨迹量一列里旧位图落在 Bold 与 Heavy 之间。旧位图是 824 像素放大 1.3 倍的产物，放大时的抗锯齿会给笔画再加一圈灰边，所以略高于 Bold 是预期内的；逐字放大对比，字形也是 Bold 最接近。Regular 只有旧图墨迹量的 63%。

**深色填充有个反直觉的坑。** 第一次尝试直接删掉代码层的 dark 特化，想让它「保持 SVG 自己的白色」。结果深色外观下文字整体变成了**蓝色**：矢量层没有 dark 特化时，系统会按背景色调自动给它着色。旧位图不受影响，是因为位图层从不被重新着色。所以 dark 必须显式写成白色。

## 留下的约束

- **给等宽字体定字重，不能只看宽度。** 生成脚本头注释已写明：宽度只决定字体家族和字号，字重要看墨迹量。
- **矢量层要在深色外观下保持某个颜色，就必须写出这一条 dark 特化**，删掉不等于保持原色。已写入 `AGENTS.md` 的 App Icon 一节。
