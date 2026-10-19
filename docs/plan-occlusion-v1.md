# 计划：遮挡字幕（黑块）v1

> 状态：**已实现（阶段 0–3），阶段 4 的「真机全链路」待用户手验**。
> 通用流程见全局 skill `tool-dev`，本项目约定见 [`dev-workflow.md`](dev-workflow.md)，本文不重复。
>
> 实现过程中撞出**两条计划里没有的实测事实**，见 §3.2 / §3.3；
> 另有**一条计划写错的判据**，见 §9 的更正。

---

## 1. Context

**问题**：片源的字幕是**烧在画面里**的硬字幕。播放器关不掉它——它已经是像素了。

**动因**：这个工具的用户场景是「边看边学」。而「学」这件事有一半靠**不看**：
练听力的时候要能一眼不看字幕，练英文的时候要能不瞟中文。软字幕一句话就能关，
硬字幕只能**拿东西盖上**。

**预期结果**：菜单点一下，屏幕上出现一块纯黑色块盖住字幕；再点一下取消。
盖着的时候，**这个工具自己照常工作**——抓屏、OCR、悬浮窗、落盘一条链路都不受影响。

### 为什么当初砍掉、现在又捡回来

`docs/requirements.md` 0.2 里，「遮挡视频里的中文字幕」是**被砍掉**的，理由两条：

| 当初的理由 | 现在是否成立 |
|---|---|
| 「非核心」 | 用户明确要，且它是「练听力」这个场景的唯一解法。**由用户判定** |
| 「与抓屏有自捕获冲突」 | **已被实测推翻**，见 §3。这条是当初砍掉它的真正技术理由 |

> ⚠️ 第二条的推翻是这份计划的地基。**它不是推理出来的，是跑出来的**——
> 四步对照实验，背景里 24 行真实文字，结论：**黑块只挡用户眼睛，挡不住自己的抓屏**。

---

## 2. 已定决策

用户已拍板，**不要重新讨论**。

| 决策 | 理由 |
|---|---|
| **遮挡时 OCR 继续工作**（黑块只挡眼睛） | 现有 `SCContentFilter(excludingApplications:)` 天然就是这个效果。练听力时字幕稿照常积累，事后能回看、能导出——这才是这个工具的价值。想停采集，用已有的「停止采集」 |
| **调整方式 = 拖动移动 + 四角缩放** | 换片源不用重画。平时鼠标穿透、不进调整模式就完全不影响操作播放器 |
| **持久化 = 记住区域 + 记住开关状态** | 和 `SavedSelection` 一个路子，写 UserDefaults。看同一部剧不用重设 |
| **一块就够**（v1 只支持单个遮挡块） | 同一个位置挡同一行，第二块没有真实用例 |
| **位置由用户拖出来，不给默认值** | 这是本项目 0.2 节定的原则：「判据交给用户，不写死规则」。给个"屏幕下方 15%"之类的常数，换个片源就崩 |
| **纯黑、不透明** | 用户原话「黑色色块」。半透明会漏出字幕笔画，等于没挡 |

---

## 3. 实测事实 —— 阶段 0 的结论

`Sources/EnglishApp/BlockSelfTest.swift`（`--selftest-block`），在这台机器上跑出来的：

```
① 无黑块 · 不排除自己 —— OCR 到 4 行，认出哨兵        ← 对照组成立
② 无黑块 · 排除自己   —— 抓到 24 行背景内容（基准）
③ 有黑块 · 不排除自己 —— 平均亮度 234.5 → 6.6（掉 97%），OCR 0 行   ← 黑块真的糊住了
④ 有黑块 · 排除自己   —— 24 行，与 ② 逐行一致          ← 结论
```

> ③ 第一次跑出来是 **6.6 而不是 0**。这不是黑块漏光——`BLOCK_DUMP` 存下来的图
> 一眼就看见，是**别的 App 的置顶浮标**压在我们的 `.floating` 黑块上。见 §3.3。
> 因此 ③ 的判据改成了「**相对 ① 掉八成以上**」，不再要求绝对 0。

**结论**：`SCContentFilter` 按**应用**排除，不透明窗口和透明悬浮窗待遇相同。
黑块被完整排掉，底下的字幕原样抓得到。

设计上的三个直接推论：

1. **采集层一行都不用改。** `ScreenCapturer`、`CaptureCoordinator`、OCR、成句、落盘
   全部不动。这个新功能纯粹长在 UI 层。
2. **③ 那一步不能省。** 少了它，④ 的「内容一致」完全可能只是黑块压根没画上——
   那是一个假通过。四步对照缺一不可。
3. **② 需要有内容的背景。** 背景若一个字都没有，④ 就退化成空对空。探针里对这个
   情况有显式警告，不许它悄悄通过。

### 3.2 实现时撞到的坑：负宽矩形的 `.width` 是绝对值

计划里写的是「拖过对边不许翻转」。实现后在 `core-check` 里做反向对照时，一条断言红了：
一个宽度为 −400 的 `CGRect`，`isUsable` 居然判定它可用。

实测（2026-10-19）CoreGraphics 的行为：

```swift
let r = CGRect(x: 0, y: 0, width: -400, height: 60)
r.width       // 400   ← 绝对值
r.size.width  // -400  ← 只有这里看得到负号
r.minX        // -400
r.maxX        // 0
```

**结论**：所有尺寸判据必须用 **`.size.width` / `.size.height`**，不能用 `.width`。
`isUsable` 和 `fit` 都按这条改了，并在 `core-check` 里钉了三条断言——
不然下一个读代码的人会把负号当成笔误「修正」掉。

### 3.3 实现时撞到的限制：`.floating` 压不住层级更高的窗口

③ 那步的亮度 6.6 不是我们的 bug。用 `BLOCK_DUMP` 把图存下来，看到亮区集中在
右上角一块（归一化 x 0.58–1.00、y 0.12–0.20，面积 2–3%），形状是一个药丸——
**另一个 App 的「拖拽至此上传」置顶浮标**，它的窗口层级高于 `.floating`。

- 挡视频画面够用（视频窗口在正常层级）。
- 别的 App 的「永远置顶」浮窗会压在黑块上面。**这不是本功能要解决的问题**，
  已写进 README 的「已知的不足」。
- 自检因此不能用绝对亮度阈值，改成相对 ① 的下降比例。

---

## 4. 架构

```
                    AppDelegate（菜单栏）
                      │  「遮挡字幕」⌘B  /  「调整遮挡范围…」
                      ↓
               OcclusionPanel                    ← 新增：黑块窗口本体
                      │   · 纯黑不透明 NSPanel，属性照抄 OverlayPanel 那套
                      │   · 平时 ignoresMouseEvents = true（鼠标穿透）
                      │   · 调整模式：拖动移动 + 四角把手缩放 + 描边
                      │
                      ├─→ UserDefaults：OcclusionRect / OcclusionOn
                      └─→ OcclusionGeometry               ← 新增（EnglishCore）
                               移动 / 缩放 / clamp 到屏幕 / 最小尺寸
                               ↑ 纯函数，core-check 离线回归


   采集侧（**一行都不改**）：

   ScreenCapturer ── SCContentFilter(excludingApplications: 本 App)
                          ↑
                    悬浮窗和黑块都在这条排除规则里
                    ⇒ 用户看得见黑块，抓屏看不见
                       （§3 实测）
```

**关键边界**：

- **几何计算与窗口渲染分开**。`OcclusionGeometry` 只做 `CGRect` 算术（移动、缩放的
  符号处理、越界 clamp、最小尺寸），不 import AppKit；`OcclusionPanel` 只管把它
  接到窗口上。理由和 `EnglishCore` 存在的理由一样：**最容易写错的那部分要能离线回归**。
  拖动缩放写成 UI 里的一坨，就只能靠手点验，而手点验不了「拖过头翻成负尺寸」这种边界。
- **这个功能不碰采集链路任何一个文件。** 见 §3 推论 1。

---

## 5. 目录结构

| 文件 | 职责 |
|---|---|
| `Sources/EnglishCore/OcclusionGeometry.swift`（新增） | 纯几何：`move` / `resize(handle:)` / `clamp(to:)` / 最小尺寸。只认 `CGRect` |
| `Sources/EnglishCoreCheck/main.swift`（改） | 补 §7 阶段 1 那组断言，每正例配反向对照 |
| `Sources/EnglishApp/OcclusionPanel.swift`（新增） | 黑块窗口本体：显示/隐藏、调整模式、四角把手、描边 |
| `Sources/EnglishApp/BlockSelfTest.swift`（已建，改） | `--selftest-block`。从「裸窗口探针」改成**驱动真实的 `OcclusionPanel`**，变成永久回归 |
| `Sources/EnglishApp/AppDelegate.swift`（改） | 菜单两项 + 持久化 + 状态文案 |
| `Sources/EnglishCapture/RegionPicker.swift`（改） | 只加了一个参数：`begin(hint:)`，让提示语能说「拖拽画出要遮挡的字幕范围」。**绘制逻辑一行没动**，直接复用 |
| `docs/requirements.md`（改） | 变更记录：恢复「遮挡」，写明原砍掉理由已被实测推翻 |
| `docs/dev-workflow.md`（改） | 验证命令表加 `--selftest-block` |

**不新增 target、不新增依赖。** `OcclusionGeometry` 是 `EnglishCore` 里的一个文件。

---

## 6. 交互设计

### 菜单

```
遮挡字幕                    ⌘B     ← 勾选态
调整遮挡范围…                      ← 没有块时置灰
```

### 「遮挡字幕」的三态

| 当前状态 | 点击后 |
|---|---|
| 没有块 | 进**绘制**：全屏压暗遮罩，拖出一块（与「框选字幕区域」**完全同一套体验**，用户已经会了）。松手即生效、记录、打勾 |
| 有块、关着 | 显示 |
| 有块、开着 | 隐藏 |

### 「调整遮挡范围…」

进入调整模式，这一模式下：

- `ignoresMouseEvents = false`（平时是 `true`）
- 黑块四周浮出**描边 + 四角把手**，一眼能看出「现在能拖」
- 拖块体 → 移动；拖四角 → 缩放（最小 40×20 点，clamp 在当前显示器内）
- 菜单项变成「完成调整」，再点一次退出；**Esc 也能退出**
- 退出即恢复鼠标穿透 + 隐藏描边把手

> ⚠️ **调整模式是唯一会吃掉鼠标事件的状态。** 忘了退出去，用户点播放器会没反应，
> 而屏幕上看不出原因——所以描边必须显眼，且**开始采集 / 停止采集时强制退出调整模式**。

---

## 7. 分阶段实现

**顺序按「可独立验证性」排，不按依赖顺序。**

### 阶段 0：撞掉唯一的未知 ✅ 已完成

**做了什么**：`--selftest-block` 四步对照实验。
**结果**：见 §3，全部通过。

**遗留**：现在这个探针自己内联了一个裸 `NSWindow`。阶段 2 里把它改成驱动真实的
`OcclusionPanel`——**探针和正式实现必须是同一个东西**，否则探针验的是探针。

### 阶段 1：纯几何 + 离线断言 ✅ 已完成

**结果**：`swift run core-check` **180 项全绿**（本阶段新增 51 项）。踩到并钉死了
§3.2 的负宽坑。每条正例都配了反向对照，包括「把不翻转逻辑改成允许翻转，断言必须变红」。

**做什么**：`Sources/EnglishCore/OcclusionGeometry.swift`

```swift
/// 四角把手的标识。拖哪个角，哪两条边跟着动。
public enum ResizeHandle: Sendable { case topLeft, topRight, bottomLeft, bottomRight }

public enum OcclusionGeometry {
    public static let minSize = CGSize(width: 40, height: 20)

    /// 整体平移，结果 clamp 在 bounds 内
    public static func move(_ rect: CGRect, by delta: CGSize, within bounds: CGRect) -> CGRect
    /// 拖某个角缩放。**拖过对边时不许翻转**，到最小尺寸就停
    public static func resize(_ rect: CGRect, handle: ResizeHandle,
                              to point: CGPoint, within bounds: CGRect) -> CGRect
}
```

**为什么是纯函数**：这一段是典型的手滑重灾区——拖左边界时 `origin.x` 变而
`width` 反向变、拖过对边会翻成负宽、clamp 顺序不对会跳一下。放进 UI 里只能手点验，
而这些边界手点**验不出来**。

**怎么验证**：

```bash
swift run core-check
```

**必须写的断言**（每条都配**反向对照**——只验「能做到」等于没验）：

- 四个角各自只动该动的两条边，另两条**纹丝不动**
- 拖左边界越过右边界 → **不翻转**，停在最小宽度
- 拖到屏幕外 → clamp 回屏幕内，且**尺寸不被 clamp 改变**
- 已经是 40×20 时再往里拖 → 尺寸不变（幂等）
- 同一操作跑两遍结果相同
- **反向对照**：把「不翻转」的逻辑改成允许翻转，上面那条必须变红

### 阶段 2：黑块窗口 + 菜单接线 + 持久化 ✅ 已完成

**结果**：`--selftest-store` / `--selftest-capture` 回归全过；`--selftest-block` 退出码 0
（③ 亮度 234.5 → 6.6，④ 与 ② 逐行一致）。持久化和渲染另做了无头验证：写
`OcclusionRect` / `OcclusionOn` 到 UserDefaults 后启动 App、截全屏、用像素检查器量
目标区域——开 0.0/255，关 224.3/255，黑块落在预期像素上（误差 ≤ 2pt）。

**做什么**：

- `Sources/EnglishApp/OcclusionPanel.swift`：窗口属性照抄 `OverlayPanel` 里那套注释
  写明的组合（`.nonactivatingPanel` + `level` + `[.canJoinAllSpaces, .fullScreenAuxiliary]`），
  **少一个就会「看起来没生效」**。外加 `isOpaque = true`、纯黑、`ignoresMouseEvents = true`
- 绘制交互：复用 `RegionPicker` 那套全屏遮罩拖拽。**直接复用，不抄一遍**
  （它是 `public`，在 `EnglishCapture` 里，把回调换成"返回一个普通矩形"即可）
- `AppDelegate`：菜单两项 + UserDefaults 读写（`OcclusionRect` / `OcclusionOn`）
- `BlockSelfTest`：改为驱动真实的 `OcclusionPanel`

**怎么验证**：

```bash
swift run EnglishApp --selftest-store            # 回归：老断言一条不红
./build/English.app/Contents/MacOS/English --selftest-block   # 现在验的是真东西了
swift run EnglishApp --selftest-capture          # 回归：自排除没被破坏
```

**真机手动**：点「遮挡字幕」→ 拖一块 → 屏幕上有黑块；再点 → 消失；再点 → 回来。
`⌘Q` 退出重开 → 位置和开关状态都还在。

### 阶段 3：调整模式 ✅ 已完成

**结果**：几何部分由阶段 1 的 51 项断言覆盖；接线部分构建通过，`startCapture` /
`stopCapture` 都会强制 `setAdjusting(false)`。**鼠标行为本身只能真机验**，见 §9。

**做什么**：`OcclusionPanel` 加调整模式——描边 + 四角把手 + 拖动 + `canBecomeKey`
（为了 Esc）+ `AppDelegate` 里「调整」菜单项的状态文案。

**怎么验证**：几何部分阶段 1 已离线钉死，这里验的是**接线接对没有**：

- 拖四角，黑块四角真的跟着鼠标；拖块体只平移
- 调整模式里鼠标能拖，退出后**点播放器正常**（穿透恢复了）
- 开始 / 停止采集时**强制退出调整模式**

### 阶段 4：真机全链路 + 文档收尾 🔄 文档已收尾，真机全链路待用户手验

**已完成**：`requirements.md`（0.0 变更记录 + 0.2 表 + §2/§3）、`dev-workflow.md`
（验证命令 + 一条新踩的坑）、`README.md`（菜单表 / 验证 / 已知不足 / 代码结构）。

**待用户手验**：下面 §9 那张清单——它无头跑不了，替用户猜没有意义。

- **全链路手动走一遍**（§8）
- 更新 `docs/requirements.md`：把 0.2 表和第 3 节里那两处**「计划恢复中」的临时指针**，
  换成正式的 0.4 变更记录（照 `节选收藏` 那条的写法：strikethrough + 指向新小节 + 写清恢复了什么）
- 更新 `docs/dev-workflow.md` 的验证命令表

---

## 8. 已知风险与对策

| 风险 | 严重度 | 对策 |
|---|---|---|
| 黑块漏进抓屏 → OCR 读到一片黑 | **已排除** | §3 四步对照实测；`--selftest-block` 是永久回归 |
| 全屏播放视频时黑块被视频盖住 | **中** | 窗口属性复用 `OverlayPanel` 那套（已是实测过的组合）；**只能真机验**，见 §9 |
| 别的 App 的「永远置顶」窗口压在黑块上 | **已确认存在，不修** | 实测见 §3.3。`.floating` 层的上限，写进 README「已知的不足」；用户碰上就关掉那个浮标 |
| 调整模式忘了退出 → 点播放器没反应 | 中 | 描边显眼 + 菜单打勾 + Esc + 采集状态变化时强制退出 |
| 拖动缩放把块翻成负尺寸 / 跳一下 | 中 | 纯函数 + core-check 离线断言（含反向对照） |
| 外接屏拔了，块落在不存在的屏上 | 中 | 启动时校验 rect 是否还在某个 `NSScreen` 内，不在就清掉并给一句明确文案 |
| 用户以为「遮挡 = 停止采集」 | 中 | 菜单文案和状态字符串写清楚；`requirements.md` 里记一笔 |
| 屏幕共享 / 录屏时黑块会被对方看到 | 低 | 这是遮挡的必然含义，不做处理，写进文档即可 |
| 调整模式和悬浮窗的「点击穿透」互相干扰 | 低 | 两个独立窗口、各自独立的 `ignoresMouseEvents`，互不影响 |

---

## 9. 端到端验证

```bash
# ── 每次改动都跑（不需要屏幕）──
swift run core-check                             # 阶段 1 新增的几何断言
swift run EnglishApp --selftest-store            # 回归

# ── 改 UI / 窗口就跑（需要屏幕录制权限）──
./build/English.app/Contents/MacOS/English --selftest-block     # 本功能的核心性质
./build/English.app/Contents/MacOS/English --selftest-capture   # 回归：自排除

# ── 改工作台前端才跑 ──
node Scripts/workbench-check.js

# ── 打包 + 真机全链路 ──
Scripts/package_app.sh
open build/English.app
```

**真机全链路（必须做，无头跑不了的那部分）**：

1. 打开一个全屏播放的视频（或先拿 TextEdit 凑合）
2. 点「遮挡字幕」→ 拖出一块盖住字幕行
3. 框选字幕区域（**故意让框选区域和黑块重叠**）→ 开始采集
4. 看三件事：黑块**看得见**、悬浮窗**照常滚字幕**、黑块**盖在视频上面**
5. `⌘Q` 退出重开 → 黑块位置和开关都在

**成功判据（一句可判断的话）**：

> 开着遮挡块采集屏幕上的一段文字，**黑块全程看得见**，而 `entries.jsonl` 里
> **句子的中英文本序列**和不开遮挡时完全一样。

⚠️ **这句原来写错了，这里是更正。** 原判据写的是「两次 `entries.jsonl` 逐字节相同」。
实现时发现 `SubtitleEntry` 带 `start` / `end` / `frameCount`，两次跑的采样时刻
不可能完全一致——**逐字节相同永远做不到**，这条判据会把一个正确的实现判成失败。
能判断的只有**文本序列**：同样一段画面，开着和关着黑块采出来的句子应该一条不差。

判断时也别只看状态栏文案，**看 `entries.jsonl`**（同 `dev-workflow.md` 里「停止采集」
那条教训）。

---

## 10. 这个版本不做

- **多个遮挡块** —— 一块够用
- **颜色 / 透明度 / 圆角可调** —— 纯黑不透明，别长出设置面板
- **「只挡中文行」这类自动判断** —— 判据交给用户，他自己决定画在哪一行
- **遮挡时自动隐藏悬浮窗** —— 两个开关各自独立，用户自己组合（挡原字幕 + 看悬浮窗是合法用法）
- **吸附到视频边缘 / 对齐辅助线 / 旋转**
- **跨多显示器的一块** —— 块锚定在单块屏幕上，和 `ScreenSelection` 一致
- **遮挡块上写字 / 做标记 / 当白板**
- **快捷键自定义**

---

## 11. 开工前该读的

| 文件 | 读它干什么 |
|---|---|
| `Sources/EnglishApp/BlockSelfTest.swift` | **阶段 0 的结论就在这个文件的输出里**，注释写明了四步为什么缺一不可 |
| `Sources/EnglishApp/OverlayPanel.swift` | 窗口属性那套「少一个就看不到」的组合，照抄 |
| `Sources/EnglishCapture/RegionPicker.swift` | 绘制交互照抄；坐标系换算（左下 → 左上）在这 |
| `Sources/EnglishCapture/ScreenCapturer.swift` | `SCContentFilter` 自排除那几行——**整个功能的地基** |
| `Sources/EnglishApp/AppDelegate.swift` | 菜单怎么搭、`SavedSelection` 怎么持久化 |
| `Sources/EnglishCoreCheck/main.swift` | 断言怎么写（每正例配反向对照） |

**不要读**：`spike/`、工作台相关（`WorkbenchWindow.swift` / `Resources/Workbench/`）、
`Exporter.swift`、`SessionStore.swift`。这个功能一个字节都不碰它们。
