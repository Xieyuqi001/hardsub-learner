# 工作台 v1.1 —— 重命名 + 收藏

> 承接 `~/.claude/plans/shimmying-petting-gray.md` 的「阶段 4：工作台」。
> 那一版把工作台做到了「会话列表 → 字幕稿 → 导出」，本次在**同一个工作台窗口内**加两件事。
> 流程按 `tool-dev` 走：需求已聊定（结构化选项 + 用户拍板），下面是筛完的 MVP、风险、分阶段实现。

---

## 1. Context

**问题**：工作台能看能导出，但**改不了**。

- 会话名是自动生成的「观看会话 10月5日 15:30」，一集一份，攒到十几份之后侧栏根本认不出哪份是哪集。
- 全量导出是一整集的流水账。真正想反复读的只有其中几句 —— 现在没有任何办法把它们挑出来。用户原话：**「导出成背诵材料」**，即收藏的落点是「攒出一篇能背的东西」，不是「整集重读」。

**预期结果**：能改名认得出会话；能在句子上打星；能在一个地方看到所有历史收藏并一键导出成一篇按来源分组的中英对照文档。

**这条需求推翻了 `requirements.md` 的一条旧判断**（必须同步回文档，见 §8）：

> 旧判断（v0.2）：「**砍掉节选收藏** —— 『识别到的全都沉淀』，收藏只是标记，导出的全量文本本身就够用。」
>
> 推翻的理由：全量文本够「读」，不够「背」。一集 300 句里真正要背的可能是 8 句，从 300 句里捞 8 句的成本比标记它们高得多。**「够用」是针对"通读"这个用途下的结论，换成"背诵"就不成立了。**

---

## 2. 已定决策

| # | 决策 | 理由 |
|---|---|---|
| D1 | 重命名只改 `meta.json` 的 `name`，**目录 id 不动** | id 是目录名兼排序键；改目录要迁移全部数据 + 改所有指向它的引用，收益为零 |
| D2 | 收藏存**每个会话一个 `favorites.json`**，工作台独写 | ① 不碰 `entries.jsonl`：它是「追加写 + 崩溃安全」的设计，工作台改写会破坏其前提；② 不给 `SubtitleEntry` 加可变的 UI 字段，避免 UI 状态漏进纯内核 |
| D3 | 收藏记录自带**文本快照** `{index, english, chinese, starredAt}` | 全局视图只需读 N 个小文件，不必解析 N 份 `entries.jsonl`；且句子若重排，快照仍在 |
| D4 | 收藏粒度**只到「句」**，不做整集收藏 | 用户原话就是「点句子上的星标」；整集收藏没有下游用途 |
| D5 | 星标入口 = 行右侧**悬停浮现的 ☆**，已收藏时**常亮 ★** | 不占正文视觉流；与既有「点行复制英文」共用一行，用 `stopPropagation` 隔开 |
| D6 | 全局收藏视图 = **侧栏顶部固定项「★ 收藏 · N」** | 复用既有「侧栏选中 → 正文渲染」模型，改动最小、最好发现 |
| D7 | 收藏视图**按来源会话分组**（会话按 `startedAt` 倒序，组内按原 index 升序） | 背诵材料要能按集读；组内保持原片顺序 |
| D8 | 右键菜单用**自绘 HTML 菜单**（重命名 / 在 Finder 中显示） | 免掉「网页坐标 → 窗口坐标」的换算与一次桥接往返；且改样式不用重新编译 —— 这正是工作台当初做成网页的全部理由 |
| D9 | 导出的目标：`~/Library/Application Support/English/favorites.md`（+`.txt`） | 它是跨会话的，放不进任何一个会话目录。文件名走 ASCII，和既有的 `export.md` 保持一致 |
| D10 | 导出里句子的编号**用它在原会话里的 index**，不重新编号 | 便于回原文档逐句对照；可追溯 > 连号好看 |
| D11 | 空名字 → **拒绝并还原** + toast；收藏项找不到原句 → **用快照渲染** | 判据交回用户，不做「自动补名」「自动清理」这类拍脑袋的规则 |

**拍脑袋常数自查**：本版**没有任何阈值、权重、自动判定**。改名改什么、哪句值得收藏、收藏视图长什么样，全部由用户动作决定。唯一的常数是「组内按 index 升序」，那是原始数据的固有顺序，不是判断规则。

---

## 3. 架构

```
        侧栏（★ 收藏 · N ／ 会话列表）          正文（收藏列表 ／ 会话详情）
                     │                                    │
                     └──────── Resources/Workbench/ ───────┘
                          index.html · app.js · style.css
                     │  {cmd} ↓            ↑ window.Workbench.<cmd>Result
                     ▼                                    ▲
        WorkbenchWindow.swift ── 桥接（本次新增 5 个 cmd，删 0）
            │              │                    │
            │              │                    └── Exporter.writeFavorites ──┐
            ▼              ▼                                                  ▼
   SessionStore.rename    SessionStore.favorites                ~/Library/Application Support/
            │              │                                        English/favorites.md|txt
            ▼              ▼
   sessions/<id>/meta.json   sessions/<id>/favorites.json   ← 新增：工作台独写
   sessions/<id>/entries.jsonl  ← 采集侧独写，工作台**永远只读**
            ▲
            │ 只追加（FileHandle 独占）
     CaptureCoordinator（采集侧）

  ★ 不变量：两个写入方写的是**互不相交**的文件，且不共用文件句柄。
    采集侧只写 entries.jsonl；工作台只写 meta.json 和 favorites.json。
```

---

## 4. 目录结构

```
English/
  Sources/
    EnglishCore/
      Favorites.swift          # 新增：Favorite 模型 + 文档编解码 + 切换/聚合/排序（纯逻辑，不读时钟）
    EnglishApp/
      SessionStore.swift       # 改：+ rename() · + favorites(of:) / setFavorites() · + listAllFavorites()
      Exporter.swift           # 改：+ writeFavorites()（跨会话汇总，独立于 write()）
      WorkbenchWindow.swift    # 改：+ rename/favorite/unfavorite/loadFavorites 四个 cmd；export 加 scope；
                               #     onSessions 增 favoriteCount、回 totalFavorites
    EnglishCoreCheck/
      main.swift               # 改：+「收藏」断言组（含反向对照）
  Resources/Workbench/
    index.html                 # 改：侧栏固定收藏项、自绘菜单容器、标题栏
    app.js                     # 改：选中态 (session|favorites)、行内编辑、右键菜单、星标、收藏视图渲染
    style.css                  # 改：星标、菜单、收藏项、编辑输入框、分组标题
  docs/
    requirements.md            # 改：§0 记本次推翻；§2 加 M8/M9；§3 移除「节选收藏」
    dev-workflow.md            # 改：决策表里「砍掉：…收藏」一行要更正
    plan-workbench-v1.1.md     # 本文
```

**框架图里的框 = 上面的文件 = §5 的任务，三处对齐。**

---

## 5. 分阶段实现

按**可独立验证性**排序：纯逻辑（离线可回归）→ 独立小功能 → 依赖落盘的功能 → 聚合视图 → 导出。

### 阶段 1：收藏内核 + 离线回归 ⭐

**先做这个** —— 它是唯一不需要 App、不需要屏幕就能反复回归的部分，也是最容易写错的部分（去重、排序、抗损坏）。

**做什么** —— `Sources/EnglishCore/Favorites.swift`：

```swift
public struct Favorite: Sendable, Equatable, Codable {
    public var index: Int        // 句在会话内的序号
    public var english: String   // 快照
    public var chinese: String   // 快照
    public var starredAt: Date   // 由调用方传入，Core 内不读时钟
}

public struct FavoritesDoc: Sendable, Equatable, Codable {
    public var favorites: [Favorite]
}
```

纯函数：`decode(_ data: Data?) -> FavoritesDoc`（坏数据 → 空）、`contains(index:)`、`adding(entry:at:)`、`removing(index:)`、`sorted()`、`deduped()`。

**关键约束**：`starredAt` **由调用方注入**，Core 里不出现 `Date()` —— 与 `Models.swift` 顶部「这一层不认识时间」的约束一致，也才能让回归可复现。

> ⚠️ **实现时推翻了计划里的两处设计**（2026-10-05，已按新方案落地）：
>
> **① 去掉了 `toggled(entry:at:)`，改成明确的 `adding` / `removing`。**
> 原计划让内核提供一个"翻一下"的 toggle，网页点星标时调它。实现时发现 toggle 在**状态错位时会翻错**：网页的渲染状态可能落后于盘上的真实状态，而 toggle 无法区分"我以为要取消"和"我要取消"。
> 改成网页发**明确意图**（这条要收藏 / 这条要取消）后，错位是**自愈**的——重复加幂等、重复取消也幂等，两种情况都收敛到正确结果。
>
> **② 跨会话聚合与排序没有放进 Core。**
> 原计划把它列为 Core 的纯函数。实现时发现**会话的排序是白送的**：`SessionStore.listSessions()` 本来就按 `startedAt` 倒序返回，聚合时顺着它的顺序走即可，再写一份排序逻辑纯属重复。所以 Core 只负责**单个会话内**的 codec + 增删 + 排序（那才是真正会写错的部分），聚合留在 `SessionStore` 的十几行循环里。

**怎么验证** —— `swift run core-check`，新增「收藏」断言组：

| 断言 | 反向对照（没有它就会假绿） |
|---|---|
| 编解码往返后逐字段相等 | 字段大小写/顺序不同**不**相等 |
| 同一 index 收藏两次 → 只有一条 | 两个不同 index → **必须**两条 |
| 取消后 → 空文档 | 取消不存在的 index → 不崩、不变 |
| 坏 JSON / 空 Data / nil → 空文档 | 正常数据 → 非空（证明解码真的在干活） |
| 聚合排序：会话按时间倒序、组内按 index 升序 | 打乱输入顺序 → 输出仍相同（确定性） |
| index 与当前 entries 失配时，快照仍能渲染 | —— |

> 反向对照不是凑数：夹具「27 帧一次都没进 pending 分支」的教训（见 `dev-workflow.md` 四）说明**只验正例会给出零信息量的绿**。比如「不重复」若不配「不同 index 必须两条」，把 `toggled` 写成永远返回单条也能全绿。

**验证规模**：≥ 6 组断言，每组至少 1 正 1 反；跑完原有 92 项不得回归。

### 阶段 2：重命名

**做什么**
- `SessionStore.rename(id:to:) throws -> SessionMeta`：trim → 空则抛错 → 原子写 `meta.json`（**只写这一个文件**）。
- 桥接新增 `rename` cmd → 回 `onRenamed {ok, id, name}`（失败回 `{ok:false, error}`）。
- 前端：侧栏 `li` 绑 `dblclick` → 把 `.name` 换成 `<input>`（自动全选）；`Enter`/失焦提交，`Esc` 取消；`contextmenu` → preventDefault → 自绘菜单（重命名 / 在 Finder 中显示，后者复用既有 `reveal` cmd）；正文的 `#session-name` 支持同一条路径双击改名。
- 提交成功后本地改 `state.sessions` 并重绘侧栏 + 正文标题；失败则还原 + toast。

**怎么验证**（真机清单，交给用户跑）

1. 双击侧栏项 → 改名 → 侧栏与正文标题**同时**变；
2. `cat …/sessions/<id>/meta.json` 看到新名字，**且目录名没变**；
3. **退出 App 重开**，名字还在（证明是落盘不是内存态）；
4. 点「导出 Markdown」→ 文件首行是新名字（证明导出跟着走）；
5. 空名字 / 全空格 → 被拒、名称还原、toast；
6. 右键 → 菜单弹出 → 「在 Finder 中显示」打开该会话目录；
7. **采集进行中**改名 → 采集不中断，停止后 `entries.jsonl` 完整。

**规模**：至少改 5 个会话，其中 1 个**正在采集**；不是试 1 个就收工。

### 阶段 3：句子星标

**做什么**
- `SessionStore.favorites(of:)` / `setFavorites(_:for:)`（原子写 `favorites.json`）。
- 桥接新增 `favorite` / `unfavorite` cmd。**服务端按 index 从 `entries.jsonl` 取真实文本做快照**，不信任前端传来的文本 —— 单一事实来源。
- `onSession` 的每条 entry 增 `favorited: Bool`。
- 前端：每行右侧星标按钮，`stopPropagation` 隔开「点行复制」；切换后**只更新该行与本地计数，不整表重绘**（保住滚动位置）。

**怎么验证**

1. 点 5 句 → `cat …/favorites.json`：5 条、中英快照正确、`starredAt` 有值；
2. 再点一次取消 → 文件里少一条；
3. 重开工作台，星的还亮着（落盘生效）；
4. 点星标**不会**弹出「已复制英文」（隔离有效）；
5. 星标一行后**滚动位置不变**（不是整表重绘）；
6. 采集进行中星标 → 采集不中断，`favorites.json` 与 `entries.jsonl` 都完好。

### 阶段 4：全局收藏视图

**做什么**
- `SessionStore.listAllFavorites() -> [(meta: SessionMeta, favorites: [Favorite])]`，**读不了的会话跳过**，不整体失败。
- 桥接新增 `loadFavorites` → `onFavorites`（每条带 sessionID / sessionName / sessionStartedAt / index / english / chinese / starredAt）；`onSessions` 每个会话增 `favoriteCount`，另回 `totalFavorites`。
- 前端：侧栏顶部固定项「★ 收藏 · N」；`state.view = 'session' | 'favorites'`，正文按 view 分派渲染；收藏视图按会话分组（组标题 = 会话名 + 日期），每条 = 英文加粗 + 中文次要 + 星标（取消）+ 点行复制；组标题可点 → **切回那个会话**（只切视图，不做滚动定位，见 §8）；header 的筛选框复用，作用于收藏视图。
- 空态文案：「还没有收藏。在某个会话里点句子右边的 ☆。」

**怎么验证**

1. 在 3 个会话各收藏 2 句 → 侧栏显示 6 → 点开看到 3 组、共 6 条、组序按会话时间倒序；
2. 在收藏视图取消一条 → 该条消失、计数变 5、`favorites.json` 同步少一条（**跨视图一致**）；
3. 在会话视图收藏一条 → 切到收藏视图**立刻**能看到（无需手动刷新）；
4. 一条收藏都没有时：计数显示 0，点开是空态文案而不是空白页；
5. 手工往某个 `favorites.json` 塞一行坏 JSON → 全局视图**跳过那一集**、其余照常显示，工作台不报错不白屏。

### 阶段 5：导出收藏

**做什么**
- `Exporter.writeFavorites(format:store:)`：聚合 → 按会话分组 → 写 `…/English/favorites.md|txt`，**与 `write()` 各自独立**（不共用一个函数，避免会话导出被拖进来）。
- md 结构：
  ```
  # 收藏 · 背诵材料

  > 共 6 句 · 来自 3 集 · 导出于 2026-10-05 21:40

  ---

  ## 观看会话 10月5日 15:30（10月5日）

  12. **I'm not gonna lie to you.**
     我不会骗你的。

  ## …
  ```
- 桥接 `export` cmd 加 `scope: 'session' | 'favorites'`（默认 `session`，**向后兼容**既有前端调用）。
- 前端收藏视图 header 加「导出 Markdown / 纯文本 / Finder」。

**怎么验证**

1. 收藏 6 句 → 导出 → `cat …/English/favorites.md`：3 个 `##` 分组、6 条、编号 = 原 index、英文加粗中文缩进；
2. 文件里没有 UI 噪音串、没有空条目、没有重复；
3. 取消 1 条再导出 → 5 条（**不残留旧内容**，证明是重写不是追加）；
4. 零收藏时点导出 → 明确报错「还没有收藏」，**不生成空文件**；
5. 「Finder」按钮打开的是收藏导出文件，不是某个会话的。

---

## 6. 已知风险与对策

| # | 风险 | 严重度 | 对策 |
|---|---|---|---|
| R1 | **工作台首次出现写操作**，可能与采集侧抢文件 | 🟠 中高 | 两者写**互不相交**的文件：采集侧只写 `entries.jsonl`（`meta.json` 仅创建时写一次，之后再不写），工作台只写 `meta.json` + `favorites.json`。已从 `CaptureCoordinator.swift:37-69` 确认 `meta.name` 创建后再没被读。**不变量：工作台永不写 `entries.jsonl`** |
| R2 | `favorites.json` 的 index 与 `entries.jsonl` 对不上 | 🟢 低 | D3 的快照兜底 → 全局视图照常渲染；会话视图找不到对应行就不渲染星标，不报错 |
| R3 | `favorites.json` 损坏 / 半截 | 🟡 中 | 解码失败当空收藏、跳过这一集 —— 同 `entries.jsonl`「坏一行只坏一行」的哲学 |
| R4 | WKWebView 的原生右键菜单抢 `contextmenu` | 🟢 低 | `preventDefault` + 自绘菜单；退路：改由原生 `NSMenu` 弹出（多一次桥接往返 + 坐标换算） |
| R5 | 侧栏选中态从「只有会话」扩成「会话 or 收藏」，自动选中的逻辑打架 | 🟡 中 | 收敛成一个 `resolveSelection()`：只在**当前选中项确实不存在**时才接管，且永不动一个仍然存在的收藏选中项 |
| R6 | 重命名时正在采集，采集侧内存里的旧名字 | 🟢 低 | **实测无用**：`meta.name` 创建后再没被读（唯一读者是导出，走的是读盘）。将来若采集侧要显示名字，改为读盘即可 |
| R7 | 列表刷新要读每个会话的 `entries.jsonl` 数句数，加 `favoriteCount` 后变成 2N 次读 | 🟢 低 | 会话量级是「集」，暂不是问题；记在这里备查，真慢了再做索引 |
| R8 | 会话 id 精度是**秒**，同一秒建两个会话会撞 id 并静默覆盖数据 | 🟠 中高 | **不在本次范围**，是自检时顺带发现的（§7.6 ①）。当前 UI 路径难触发，但必须单独修 |

> 另有 R5 的表述与实现不符，以及一条计划里完全没预见的 DOM 重建坑 —— 照实记在 §7.5。

---

## 7. 端到端验证 + 成功判据

### 7.1 自动断言（本文写完后实际跑过）

```bash
swift run core-check                            # 129 项通过
swift run EnglishApp --selftest-store           # 38 项通过（连跑 3 遍都通过，见下）
node Scripts/workbench-check.js                 # 76 项通过
node Scripts/workbench-check-mutants.js         # 8 个变异全部被咬住
node --check Resources/Workbench/app.js         # 语法 OK
Scripts/package_app.sh                          # 签名 + 打包成功
diff -q Resources/Workbench/app.js build/English.app/Contents/Resources/Workbench/app.js
```

前端那两项是这次新增的。**为什么需要**：工作台有 500 行前端逻辑跑在 WKWebView 里，
没有 GUI 就没法验；而最容易错的地方是**桥接两侧字段对不上**——Swift 发
`onFavorites{groups}`，JS 按别的名字取就是静默失败（列表空着、不报错）。
所以手搓一个极简 DOM 桩把 `app.js` 原样加载进来，喂它**和 Swift 侧逐字段对齐的
payload**，检查画出来的 DOM **和发回去的消息**。

`workbench-check-mutants.js` 是它的**反向对照**：把 8 个修过的 bug 的逆操作打回
`app.js`，看检查会不会红、红在该红的那条上。**一份永远全绿的检查比没有检查更坏。**

**这套检查的盲区**（别把它当成"界面对了"）：验不了布局、样式、真实事件、
WKWebView 本身。断言写对了 ≠ 长对了。

### 7.2 只能靠人跑的（交用户）

```bash
Scripts/package_app.sh && open build/English.app
```

1. **改名**：双击侧栏某一行 → 名字就地变输入框 → 改成「怪奇物语 S01E01」→ 回车。
   再右键那一行 → 菜单里应只有「重命名 / 在 Finder 中显示」。
2. **改名持久**：退出 App 重开工作台 → 新名字还在，导出文档的标题也是新名字。
3. **空名字**：改名时清空再回车 → 应弹提示且**不改**；按 Esc → 名字还原。
4. **星标**：随便打开一集，鼠标移到句子右侧 → 出现空心 ☆；点一下 → 变实心 ★。
   注意**点星时不该弹出「已复制英文」**（那是点整行才有的行为）。
5. **不跳滚动**：滚到列表中段，点一句的 ☆ → **视野不该被打回顶部**，只有那一行变。
6. **全局收藏**：侧栏顶部「★ 收藏」显示总句数 → 点进去 → 按集分组、最新的在上。
   点组标题「回这一集 →」应跳回那一集。
7. **收藏里取消**：在收藏视图点实心 ★ → 那一条**立刻消失**，页头统计跟着减。
8. **导出**：在收藏视图点导出 → 生成 `~/Library/Application Support/English/favorites.md`；
   点 Finder 应选中这个文件。回会话视图再点导出 → 导的是这一集。
9. **空态**：一次都没采集过时打开工作台 → 侧栏仍有「★ 收藏」，副标题写「还没有收藏」。

### 7.3 落盘检查

```bash
cat ~/Library/Application\ Support/English/sessions/<id>/meta.json
cat ~/Library/Application\ Support/English/sessions/<id>/favorites.json
cat ~/Library/Application\ Support/English/favorites.md
```

### 7.4 成功判据（一句）

> 改名后**重开 App 名字还在、导出标题跟着变**；收藏的句子在收藏视图里**跨集聚合、能取消、能导出成一篇带来源分组的中英对照文档**；全程**不影响正在进行的采集**（`entries.jsonl` 只增不改）。

---

## 7.5 实现中实际推翻了什么（照实记）

| 计划里写的 | 实际做成 | 为什么 |
|---|---|---|
| R5：把选中态收敛成一个 `resolveSelection()` | `markSidebarSelection()`（**只切 class、不重建 DOM**）+ `onSessions` 里一句早返回 | R5 只说"逻辑别打架"，没看出真正的坑在**谁重建了 DOM**。见下面那条 |
| （没有预见）| `onSession` 里**绝不能** `renderSessions()` | 双击会先触发两次 `click`（各发一次 `load`），回复落在 `onSession` 里。它一重建侧栏，正在编辑的输入框就被 `replaceChildren` 抹掉——**表现是"双击改名没反应"，且不报错**。这是本次最难查的一个 bug，已固化成变异测试第 1 条 |
| （没有预见）| `renderFavorites` 需要 `favoritesLoaded` 守卫 | 否则点开收藏会先闪一句"还没有收藏"再被数据覆盖 |

---

## 7.6 顺带发现的两个问题（**不在本次范围内**）

**① 会话 id 的精度是秒，同一秒内建两个会话会撞 id 并损坏数据。** 🟠

`SessionStore.sessionID(for:)` 用的是 `yyyyMMdd-HHmmss`。`--selftest-store` 连建两个会话时
暴露了这点，当时的处理是**在测试里 `Thread.sleep(1.1)` 绕开**——那只是掩盖，没有修。
当前 UI 路径下很难触发（要连点两次「开始采集」），但它是**静默的数据覆盖**：
两个会话共用 `meta.json` / `entries.jsonl`。

建议改法：id 后面拼一小段随机后缀（`20261005-150000-7f3a`），或退一步在
`createSession` 里检测目录已存在就自增。**改动会影响目录名**，得单独评估。

**② `--selftest-store` 曾经只在第一遍成立。** ✅ 已修

它把 `store.root` 直接设在 `NSTemporaryDirectory()` 上，而收藏导出落在
`root.deletingLastPathComponent()` → 于是 `favorites.md` 掉进**所有进程共用的 `$TMPDIR`**，
`defer` 只删得掉会话目录。结果：**第一遍全绿，第二遍开始「零收藏时不生成空文件」必红**。
已改成套两层目录（和线上 `English/sessions` 同构），并连跑 3 遍确认幂等、`$TMPDIR` 无残留。

---

## 8. 明确不做（v1.1 边界）

**用户明确没选**（本次结构化提问的结果，不是我的取舍）：

- ❌ 点收藏项**跳回原会话并滚到那一句** —— 只做「点组标题切回那个会话」，不做滚动定位与高亮。
  *理由*：跨视图滚动定位要做「目标句在不在当前渲染窗口内 / 筛选是否把它藏了 / 加载后何时滚」三件容易出错的事，而它换来的只是省一次手动点击。想验证它值得做，得先有真实使用数据。
- ❌ 会话正文里的「只看收藏」筛选开关。
  *理由*：全局收藏视图已经能回答「我收藏了什么」，在单集里再加一个同义开关是重复入口。

**本版主动砍掉**：

- ❌ 整集收藏 / 收藏分组 / 自定义标签
- ❌ **删除会话**（右键菜单只放两项）—— 破坏性操作，且需要二次确认 UI，本版不引入
- ❌ 拖拽排序、多选、批量收藏
- ❌ 收藏内容的编辑（只标记，不修改原句）
- ❌ 重命名后自动重导出（已导出的文件不会追溯更新）
- ❌ 收藏的云同步 / 多设备 / 账号

**永久不变量（不是"这版不做"）**：

- 🚫 **工作台永不写 `entries.jsonl`**。它是采集侧的追加写文件，「崩溃安全」正是靠"只追加、不改写"换来的。

---

## 9. 文档同步（改代码前先做，或与阶段 1 同批）

`dev-workflow.md` 说「不要悄悄改代码 / 先改计划」。本次推翻了一条已定决策，必须回写：

1. `requirements.md` §0 —— 记下「**恢复节选收藏**」及其理由（全量文本够"通读"不够"背诵"），与原砍掉的理由并列。
2. `requirements.md` §2 功能需求 —— 加 **M8 会话重命名**、**M9 句子收藏 + 收藏导出**。
3. `requirements.md` §3 明确不做 —— 移除「❌ 节选收藏、收藏夹」，保留「❌ 逐词查词、生词本、Anki 卡片」（这次仍然没做）。
4. `dev-workflow.md` 二、已定决策表 —— 「砍掉：…收藏」一行更正为「v0.2 砍掉，v1.1 以『背诵材料导出』为由恢复」，并指向本文。
