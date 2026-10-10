# English 项目开发约定

> 这份文档是**给后续的 agent（或新对话窗口）看的**，不是给用户看的宣传文。
>
> **通用方法论已经独立成全局 skill `tool-dev`**（聊需求 → MVP 筛需求 → spike 先行 → 先计划再动手，
> 含七条铁律和协作方式）。本文**不复述方法论**，只讲这个项目独有的东西：
> 已经拍板的决策、开工要读什么、怎么验证、什么算做完。

---

## 一、本项目在通用流程里的位置

`tool-dev` 那四步，本项目**前四步都走完了**：

| 步骤 | 本项目的产物 |
|---|---|
| 聊需求 | 判据定为「用户框选 + 手动排除」，见 `requirements.md` 9.3 |
| MVP 筛需求 | 砍掉播放器控制等一批需求，见 `requirements.md` 第 0 节 |
| spike 先行 | `spike/` 跑完，产出三条改写设计的实测约束，见 `requirements.md` 9.5 |
| 先计划再动手 | 正式计划在 `~/.claude/plans/shimmying-petting-gray.md` |

**现在处于「按计划分阶段实现」阶段。** 你要做的是计划里的**某一个阶段**，不是整个项目。

---

## 二、已定决策：查锚点，别复述

这些都已拍板，**不要重新讨论**。要细节就去对应的锚点读，本文不复制一遍。

| 决策 | 理由 / 细节在哪 |
|---|---|
| 判据 = **用户框选 + 手动排除**，不用任何自动规则 | `requirements.md` 9.3 |
| 砍掉：播放器控制 / 单句循环 / 遮挡 / 字幕区域自动定位 | `requirements.md` 第 0.2 节（理由都是实测事实） |
| **收藏**：v0.2 砍掉 → **v0.3 以「导出成背诵材料」为由恢复**（M9），并新增 M8 会话重命名 | `requirements.md` 0.1；实现方案见 `docs/plan-workbench-v1.1.md`。**不要**再按"收藏已砍"去改代码 |
| **工作台可以写盘了**，但只写 `meta.json` + `favorites.json`；**永不写 `entries.jsonl`** | `plan-workbench-v1.1.md` D2 / §8。采集侧只写 `entries.jsonl`，两侧文件不相交，故可同时运行 |
| 抓屏 ScreenCaptureKit + OCR Vision `.accurate` + 翻译 Apple Translation + 悬浮窗 NSPanel | `requirements.md` 第 4 节 |
| 去重必须**模糊匹配**、confidence **不能当过滤阀**、配对用**行序不用绝对 y** | `requirements.md` 9.5（spike 实测，违反会重写核心算法） |
| 竞品只读思路、**不复用代码**（AGPL/GPL 与商业目标冲突） | `requirements.md` 10.3 |
| 构建走 **SwiftPM + 打包脚本**（本机无 Xcode，只有 CLT） | `requirements.md` 第 4 节末 |
| 字符级清洗交给 **LLM**，v1 **不在 App 里接模型**；工作台 API 只是把这步搬进去，不动内核 | `docs/llm-cleanup-prompt.md`（含提示词 + 每条限制的代价） |

---

## 三、开工：子任务认领须知

**1. 只读这些，不要读全部上下文**

- 计划文档（`~/.claude/plans/shimmying-petting-gray.md`）里**你负责的那一个「阶段 N」小节**；
- 计划文档「目录结构」小节里，**属于你这个阶段的那几个文件**；
- 该阶段引用的实测数据对应的 `requirements.md` 小节（例：阶段 1 读 9.5）。
- **不要**去读别的阶段、别的模块的细节——那才会导致上下文混乱，是本工作流要避免的事。

**2. 交付物就是目录结构里那几个文件**

- 目录结构已经写明了每个文件的职责（那行注释），照着实现，**不要新增计划里没有的模块或阶段**。
- 如果一个文件职责不清，**先改计划文档再动手**，而不是自己发明。

**3. 什么算做完**

- 该阶段「验证」小节通过，**且没有弄坏其它阶段**（回归跑过）。
- 汇报时给出**验证的规模和观察到的结果**，别说「应该好了」——按 `verify-fix` skill 的标尺来。
- 中途若推翻了计划里的某个假设，**主动说明被推翻的是什么**，并更新计划文档，别悄悄改代码。

---

## 四、验证命令（本项目最容易踩坑的地方）

```bash
# 纯逻辑回归 —— 阶段 1 及以后每次改动都跑
swift run core-check

# 落盘自检 —— 改名 / 收藏 / 导出。全程在临时目录里跑，不碰真实数据
# 关键断言：这些操作跑完，entries.jsonl 一个字节都没变
swift run EnglishApp --selftest-store

# 工作台前端回归 —— 改 Resources/Workbench/ 底下任何东西都要跑
node Scripts/workbench-check.js

# 上面那个检查器的反向对照 —— 增删断言、改前端逻辑之后跑
node Scripts/workbench-check-mutants.js

# 采集链体检（需要屏幕录制权限）
swift run capture-check [x y 宽 高 秒数] [--dump 目录]

# 自排除对照实验（验证悬浮窗不会被自己 OCR 进去）
build/English.app/Contents/MacOS/English --selftest-capture

# 打包签名（setup_signing.sh 只需跑一次）
Scripts/setup_signing.sh && Scripts/package_app.sh

# 全链路：手动走一遍
open build/English.app

# 落盘检查
cat ~/Library/Application\ Support/English/sessions/<id>/entries.jsonl
```

**打包之后要确认新资源真的进去了**，`package_app.sh` 抄的是 `Resources/Workbench/`：

```bash
diff -q Resources/Workbench/app.js build/English.app/Contents/Resources/Workbench/app.js
```

> ⚠️ **写落盘自检时，临时目录要套两层。**
> 收藏导出落在 `store.root.deletingLastPathComponent()`，和线上
> `Application Support/English/sessions` 同构。要是把 `store.root` 直接设在
> `NSTemporaryDirectory()` 上，导出的 `favorites.md` 会掉进**所有进程共用的 `$TMPDIR`**，
> `defer` 只删得掉会话目录、删不掉它——**第一遍全绿，第二遍开始有一条必红**。
> 一条只在首跑成立的断言等于没验。（2026-10-05 实际踩到，已修。）

> ⚠️ **不要用 `swift test`。**
> 这台机器只有 CommandLineTools，没有完整 Xcode。这种工具链下 `swift test` 会
> **编译通过、退出码 0、但一条测试都不执行**——把测试改成故意失败，依然退出 0、零输出。
> 这是"看起来绿了其实没跑"的典型陷阱。
>
> 所以回归测试不用任何测试框架，而是一个普通可执行目标 `EnglishCoreCheck`：
> 读真实剧集夹具、跑断言、打印可读报告，失败时退出码非 0。
> 详见 `Package.swift` 顶部的长注释。

> ⚠️ **黄金夹具不是全覆盖，别把"92 项全绿"当成"没改坏"。**
> 实测（2026-10-05）夹具那 27 帧**一次都没进入** `SubtitleAssembler` 的 pending 分支——
> 改那条路径时，夹具改前改后都是全绿，那个绿对改动**零信息量**。
>
> 拿真实数据生成的夹具，覆盖的是它自己那段数据里出现过的情况。**改了它没走过的分支，
> 必须自己补用例**（`main.swift` 的「成句边界」那组就是这么来的，每个正例都配反向对照——
> 只验"别切开"的话，把逻辑改成"永不切句"也能全绿）。
>
> 想知道夹具到底走没走到某条路径，别推理，**插探针数一遍**。

---

## 五、认领示例（阶段 1：EnglishCore）

- **读什么**：计划文档的「阶段 1」小节 + 「目录结构」里 `Sources/EnglishCore/` 那几个文件
  + `requirements.md` 9.5（实测约束的来源）。
- **不读什么**：阶段 2 的采集细节、阶段 3 的悬浮窗、`spike/` 的全部历史。它们与你的任务无关。
- **交付物**：`Models.swift` / `TextNormalizer.swift` / `Similarity.swift` / `FramePairer.swift` /
  `SubtitleAssembler.swift`，以及 `Sources/EnglishCoreCheck/` 下的断言器与夹具。
- **验证**：`swift run core-check` 全绿；夹具 `episode_ep01.json` 的断言
  （句数、每句文本、`开启画9` 不出现、跨 y 漂移仍是同一句）通过。
- **边界**：不碰屏幕、不碰 UI、不引入计划外的依赖；
  `WordValidator` 用协议注入，生产包 `NSSpellChecker`、测试用桩。

---

## 六、和本项目历史相关的两条注记

- **`spike/` 是一次性的，会被归档。** 正式版另起目录，**不往 `spike/` 里加功能**。
  里面的代码可以搬（`realPixelWidth`、`recognize`、`SCContentFilter` 自排除……），
  但**脚手架不带过去**——CLI 主循环和框选子进程 hack 是命令行工具特有的坑，正式版是正常 `.app`。
- **`spike/` 踩的坑要判断清楚哪些会跟着走。** 比如「跑过 AppKit 事件循环后进程静默 `exit(0)`」
  这个坑就是命令行工具特有的（裸 `NSApplication` + `async main` 无法共存），正式版不会遇到。
  而「验证的规模必须 ≥ 故障发作的规模」（2 帧 vs 30 帧）是通用的，已沉淀成 `verify-fix` skill。
