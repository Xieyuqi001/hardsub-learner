#!/usr/bin/env node
// 工作台前端的离线回归器。
//
//   node Scripts/workbench-check.js
//
// 为什么需要它：工作台的逻辑是 500 行 JS，跑在 WKWebView 里，没有 GUI 就没法验。
// 而最容易错的地方恰恰是**桥接两侧的字段对不上**（Swift 发 onFavorites 带 groups，
// JS 若按别的名字取，就是静默失败——列表空着，不报错，最难查）。
//
// 所以这里手搓一个极简 DOM 桩，把 app.js 原样加载进来，喂它**和 Swift 侧一模一样
// 形状的 payload**，然后检查：① 画出来的 DOM 结构对不对 ② 发回去的消息对不对。
//
// 它不是浏览器，验不了布局、样式、真实点击。它验的是**逻辑和契约**。
// 布局和交互还得靠真机跑一遍（见 docs/plan-workbench-v1.1.md §7）。

const fs = require('fs');
const path = require('path');

const APP_JS = path.join(__dirname, '..', 'Resources', 'Workbench', 'app.js');

// ── 极简 DOM 桩 ─────────────────────────────────────────

class El {
    constructor(tag) {
        this.tagName = String(tag).toUpperCase();
        this.id = '';
        this.title = '';
        this.value = '';
        this.hidden = false;
        this.type = '';
        this.autocomplete = '';
        // 真 DOM 的 dataset 是 DOMStringMap：赋进去的数字会被转成字符串。
        // 这条要是不照做，`li.dataset.index = 2` 之后
        // `querySelector('li[data-index="2"]')` 就会假失败（选择器那侧永远是字符串）。
        this.dataset = new Proxy({}, {
            get: (t, k) => t[k],
            set: (t, k, v) => { t[k] = String(v); return true; },
        });
        this.style = {};
        this.attrs = {};
        this.children = [];
        this.parentNode = null;
        this._text = '';
        this._classes = new Set();
        this.handlers = {};
        this.classList = {
            add: (...c) => c.forEach((x) => this._classes.add(x)),
            remove: (...c) => c.forEach((x) => this._classes.delete(x)),
            contains: (c) => this._classes.has(c),
            toggle: (c, on) => (on ? this._classes.add(c) : this._classes.delete(c)),
        };
    }
    // 和真 DOM 一样：有子节点时 textContent 把后代文本拼起来
    get textContent() {
        return this._text + this.children.map((c) => c.textContent).join('');
    }
    set textContent(v) { this._text = String(v); this.children = []; }
    get className() { return [...this._classes].join(' '); }
    set className(v) {
        this._classes = new Set(String(v).split(/\s+/).filter(Boolean));
    }
    append(...nodes) {
        for (const n of nodes) { n.parentNode = this; this.children.push(n); }
    }
    replaceChildren(...nodes) { this.children = []; this._text = ''; this.append(...nodes); }
    replaceWith(node) {
        const p = this.parentNode;
        if (!p) return;
        const i = p.children.indexOf(this);
        if (i >= 0) p.children[i] = node;
        node.parentNode = p;
        this.parentNode = null;
    }
    setAttribute(k, v) { this.attrs[k] = v; }
    focus() {} select() {} addEventListener() {}
    contains(n) {
        if (n === this) return true;
        return this.children.some((c) => c.contains(n));
    }
    descendants(out = []) {
        for (const c of this.children) { out.push(c); c.descendants(out); }
        return out;
    }
    querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
    // 只认 app.js 真正用到的三种写法：`li` / `.name` / `li[data-index="7"]`。
    // 认不出来就**抛错**，不返回空数组 —— 静默返回空会让断言假装通过。
    querySelectorAll(sel) {
        const parse = (s) => {
            const m = /^([\w-]*)(?:\.([\w-]+))?(?:\[data-index="(.*)"\])?$/.exec(s);
            if (!m || (!m[1] && !m[2] && m[3] === undefined)) return null;
            return { tag: m[1] ? m[1].toUpperCase() : null, cls: m[2] || null, index: m[3] };
        };
        const q = parse(sel);
        if (!q) throw new Error(`DOM 桩不认识这个选择器：${sel}`);
        return this.descendants().filter((el) =>
            (q.tag === null || el.tagName === q.tag) &&
            (q.cls === null || el.classList.contains(q.cls)) &&
            (q.index === undefined || el.dataset.index === q.index));
    }
    getBoundingClientRect() { return { width: 168, height: 60 }; }
}

// 页面里那些按 id 取的元素，先建好
const byId = {};
for (const id of ['session-list', 'entries', 'placeholder', 'detail', 'session-name',
                  'session-meta', 'no-match', 'filter', 'menu', 'toast',
                  'refresh', 'export-md', 'export-txt', 'reveal']) {
    byId[id] = new El(id === 'session-list' || id === 'entries' ? 'ul' : 'div');
    byId[id].id = id;
}
byId.detail.hidden = true;
byId.placeholder.hidden = false;
byId.menu.hidden = true;
byId.toast.hidden = true;
byId['no-match'].hidden = true;

const document = {
    getElementById: (id) => byId[id] || null,
    createElement: (tag) => new El(tag),
    addEventListener: () => {},
};

const sent = [];          // 网页发回原生的所有消息
const clipboard = [];     // 复制到剪贴板的内容

const window = {
    innerWidth: 900,
    innerHeight: 640,
    addEventListener: () => {},
    webkit: { messageHandlers: { bridge: { postMessage: (m) => sent.push(m) } } },
};

const navigator = { clipboard: { writeText: (t) => clipboard.push(t) } };

// ── 载入 app.js ─────────────────────────────────────────

const src = fs.readFileSync(APP_JS, 'utf8');
// 用 new Function 而不是 eval：app.js 的顶层 const/function 变成这里的局部变量，
// 只能通过 window.Workbench.* 这个真实契约来驱动它——不然容易测到"内部实现"上。
new Function('window', 'document', 'navigator', src)(window, document, navigator);

const WB = window.Workbench;

// ── 断言器 ──────────────────────────────────────────────

let passed = 0;
const failures = [];
let group = '';

function section(name) { group = name; console.log(`\n\x1b[1m── ${name} ──\x1b[0m`); }
function ok(cond, label) {
    if (cond) { passed++; console.log(`  \x1b[32m✓\x1b[0m ${label}`); }
    else { failures.push(`[${group}] ${label}`); console.log(`  \x1b[31m✗ ${label}\x1b[0m`); }
}
function eq(actual, expected, label) {
    const a = JSON.stringify(actual), e = JSON.stringify(expected);
    if (a === e) { passed++; console.log(`  \x1b[32m✓\x1b[0m ${label}`); }
    else {
        failures.push(`[${group}] ${label}\n      期望: ${e}\n      实际: ${a}`);
        console.log(`  \x1b[31m✗ ${label}\x1b[0m\n      期望: ${e}\n      实际: ${a}`);
    }
}
const last = () => sent[sent.length - 1];
const reset = () => { sent.length = 0; clipboard.length = 0; };

// 模拟一次真实点击：从目标往上冒泡，中途谁调了 stopPropagation 就停。
// 必须这么干——「点星不会顺带复制英文」这条靠的正是 stopPropagation，
// 要是直接调 star.onclick()，冒泡根本没发生，那个 bug 就测不出来了。
function click(target) {
    let stopped = false;
    const ev = {
        stopPropagation: () => { stopped = true; },
        preventDefault: () => {},
        clientX: 100, clientY: 200,
    };
    for (let n = target; n && !stopped; n = n.parentNode) {
        if (typeof n.onclick === 'function') n.onclick(ev);
    }
    return { stopped };
}

// ── 夹具：和 Swift 侧发出来的形状**逐字段对齐** ────────
// 这些形状来自 WorkbenchWindow.swift 的 reply(...)，改那边时这里也得跟着改。

const SESSION_A = {
    id: '20261005-150000', name: '怪奇物语 S01E01',
    startedAt: '2026-10-05T15:00:00Z', entryCount: 3, hasChinese: true, favoriteCount: 1,
};
const SESSION_B = {
    id: '20261005-160000', name: '绝命毒师 S02E03',
    startedAt: '2026-10-05T16:00:00Z', entryCount: 2, hasChinese: true, favoriteCount: 2,
};
const ENTRIES_A = [
    { index: 1, start: 0, end: 1.4, chinese: '我不会骗你的。', english: "I'm not gonna lie to you.",
      frameCount: 3, isFlash: false, favorited: true },
    { index: 2, start: 1.4, end: 2.9, chinese: '你能来我真的很高兴。', english: "I'm really glad you came.",
      frameCount: 3, isFlash: false, favorited: false },
    { index: 3, start: 2.9, end: 3.2, chinese: '', english: 'Anyway.',
      frameCount: 1, isFlash: true, favorited: false },
];
const GROUPS = [
    {
        id: SESSION_B.id, name: SESSION_B.name, startedAt: SESSION_B.startedAt,
        items: [
            { index: 1, english: 'You got that right.', chinese: '说对了。', starredAt: '2026-10-05T16:10:00Z' },
            { index: 7, english: 'We need to go.', chinese: '我们得走了。', starredAt: '2026-10-05T16:11:00Z' },
        ],
    },
    {
        id: SESSION_A.id, name: SESSION_A.name, startedAt: SESSION_A.startedAt,
        items: [
            { index: 1, english: "I'm not gonna lie to you.", chinese: '我不会骗你的。', starredAt: '2026-10-05T15:10:00Z' },
        ],
    },
];

const rows = () => byId['session-list'].querySelectorAll('li');
const pinnedRow = () => rows().find((li) => li.classList.contains('pinned'));
const entryRows = () => byId.entries.children;
const groupHeads = () => entryRows().filter((li) => li.classList.contains('group'));

// ═══════════════════════════════════════════════════════
section('侧栏 · 会话列表与置顶的收藏入口');
// ═══════════════════════════════════════════════════════

reset();
WB.onSessions({ sessions: [SESSION_B, SESSION_A], totalFavorites: 3 });

ok(pinnedRow() !== undefined, '侧栏第一项是置顶的收藏入口');
ok(rows().length > 0 && rows()[0] === pinnedRow(),
   '收藏入口排在最前面（不是夹在会话中间）');
eq(rows().length, 3, '收藏项 + 两个会话 = 3 行');
eq(pinnedRow().children.length, 2, '收藏项是名字 + 副标题两行');
ok(pinnedRow().children[0].textContent === '★ 收藏', '收藏项名字是「★ 收藏」');
ok(pinnedRow().children[1].textContent === '3 句 · 来自 2 集',
   '收藏项的副标题显示总数和来源集数');

const subs = rows().slice(1).map((li) => li.children[1].textContent);
ok(subs[0].includes('★ 2'), '会话行显示自己的收藏数（绝命毒师 2 句）');
ok(subs[1].includes('3 句'), '会话行仍然显示总句数');

// 打开工作台自动选最近那一集
eq(last(), { cmd: 'load', id: SESSION_B.id }, '首次列表面板 → 自动加载最近那一集');

// ═══════════════════════════════════════════════════════
section('正文 · 会话视图与星标');
// ═══════════════════════════════════════════════════════

reset();
WB.onSession({ id: SESSION_B.id, favoriteCount: 2, entries: ENTRIES_A });

eq(byId['session-name'].textContent, SESSION_B.name, '页头显示会话名');
ok(byId.detail.hidden === false && byId.placeholder.hidden === true, '从占位切到详情');
eq(entryRows().length, 3, '三句都渲染出来');

const starA = entryRows()[0].querySelector('.star');
ok(starA !== null, '每行右侧有一颗星');
ok(starA.textContent === '★' && starA.classList.contains('on'), '已收藏的那句显示实心星');
ok(entryRows()[0].classList.contains('starred'), '已收藏的那行带 starred 标记');
ok(entryRows()[1].querySelector('.star').textContent === '☆', '没收藏的显示空心星');

// 点星：要发明确意图，而且**不能**顺带复制英文
reset();
click(entryRows()[1].querySelector('.star'));
eq(last(), { cmd: 'favorite', id: SESSION_B.id, index: 2 }, '点空心星 → 发「收藏这条」的明确意图');
eq(clipboard.length, 0, '★ 点星不会顺带触发整行的「复制英文」（冒泡被拦住了）');

reset();
click(entryRows()[0].querySelector('.star'));
eq(last(), { cmd: 'unfavorite', id: SESSION_B.id, index: 1 }, '点实心星 → 发「取消这条」的明确意图');

// 行点击仍然复制英文（既有行为不能被破坏）
reset();
click(entryRows()[1]);
eq(clipboard, ["I'm really glad you came."], '点整行仍然复制英文（既有行为没被破坏）');

// ═══════════════════════════════════════════════════════
section('星标回执 · 只改一行，不整表重绘');
// ═══════════════════════════════════════════════════════

const untouchedBefore = entryRows()[2];

reset();
WB.onFavoriteToggled({ ok: true, id: SESSION_B.id, index: 2, favorited: true,
                       count: 3, totalFavorites: 4 });

eq(entryRows()[1].querySelector('.star').textContent, '★', '回执到了 → 那颗星变实心');
ok(entryRows()[1].classList.contains('starred'), '那一行也标成已收藏');
// 这一条是「点收藏不会把滚动位置打回顶部」的机器可验版本：
// 其它行的 DOM 节点身份没变，就说明没有整表重建。
ok(entryRows()[2] === untouchedBefore,
   '★ 其它行的 DOM 节点没被替换（证明确实是单行更新，不是整表重绘）');
eq(pinnedRow().children[1].textContent, '4 句 · 来自 2 集', '侧栏收藏总数跟着更新');

// ═══════════════════════════════════════════════════════
section('收藏视图 · 跨会话聚合');
// ═══════════════════════════════════════════════════════

reset();
pinnedRow().onclick();
eq(last(), { cmd: 'loadFavorites' }, '点收藏入口 → 去要收藏数据');
ok(pinnedRow().classList.contains('selected'), '收藏入口进入选中态');
eq(byId['session-name'].textContent, '★ 收藏', '页头切到「★ 收藏」');
eq(byId['session-meta'].textContent, '载入中…', '数据还没回来时说「载入中」，不谎报「还没有收藏」');
eq(byId.entries.children.length, 0,
   '数据没回来之前正文区是空的（不闪一下「还没有收藏」再消失）');

reset();
WB.onFavorites({ groups: GROUPS });

eq(groupHeads().length, 2, '按会话分成两组');
ok(groupHeads()[0].textContent.includes(SESSION_B.name), '组标题是会话名（最新那集在前）');
eq(entryRows().length, 5, '两个组标题 + 3 条收藏 = 5 行');
eq(byId['session-meta'].textContent, '共 3 句 · 来自 2 集', '页头统计正确');

const favRow = entryRows().find((li) => li.dataset.index === '7');
ok(favRow !== undefined, '编号 7 那条收藏在列表里');
ok(favRow.children[1].textContent === 'We need to go.', '收藏视图显示英文');
ok(favRow.children[2].textContent === '我们得走了。', '收藏视图显示中文');
eq(favRow.querySelector('.star').textContent, '★', '收藏视图里的星是实心的');
eq(favRow.children[0].textContent, '7', '★ 编号用原会话里的 index（第 7 句还是 7）');

// 点组标题回那一集
reset();
groupHeads()[0].onclick();
eq(last(), { cmd: 'load', id: SESSION_B.id }, '点组标题 → 回到那一集');

// 回收藏视图，验「取消收藏后那条立刻消失」
reset();
pinnedRow().onclick();
WB.onFavorites({ groups: GROUPS });
reset();
entryRows().find((li) => li.dataset.index === '7').querySelector('.star')
    .onclick({ stopPropagation: () => {} });
eq(last(), { cmd: 'unfavorite', id: SESSION_B.id, index: 7 }, '在收藏视图里点实心星 → 发取消');

WB.onFavoriteToggled({ ok: true, id: SESSION_B.id, index: 7, favorited: false,
                       count: 1, totalFavorites: 2 });
ok(entryRows().find((li) => li.dataset.index === '7') === undefined,
   '取消后那条立刻从收藏视图消失');
eq(byId['session-meta'].textContent, '共 2 句 · 来自 2 集', '页头统计跟着减');

// ═══════════════════════════════════════════════════════
section('导出 / Finder 跟着当前视图走');
// ═══════════════════════════════════════════════════════

reset();
byId['export-md'].onclick();
eq(last(), { cmd: 'export', format: 'md', scope: 'favorites' },
   '在收藏视图点导出 → 导的是收藏（带 scope，没有 id）');
reset();
byId.reveal.onclick();
eq(last(), { cmd: 'reveal', target: 'favorites' }, '在收藏视图点 Finder → 显示收藏导出文件');

// 切回会话视图，同一组按钮应该导这一集
reset();
WB.onSession({ id: SESSION_A.id, favoriteCount: 1, entries: ENTRIES_A });
reset();
byId['export-txt'].onclick();
eq(last(), { cmd: 'export', format: 'txt', id: SESSION_A.id },
   '在会话视图点导出 → 导的是这一集');
reset();
byId.reveal.onclick();
eq(last(), { cmd: 'reveal', id: SESSION_A.id }, '在会话视图点 Finder → 显示这一集的导出文件');
ok(!('scope' in last()), '会话视图不带 scope —— 原生侧的向后兼容分支走得通');

// ═══════════════════════════════════════════════════════
section('重命名 · 双击进入编辑，且不被回执打断');
// ═══════════════════════════════════════════════════════

WB.onSessions({ sessions: [SESSION_B, SESSION_A], totalFavorites: 2 });
reset();

const rowA = rows().find((li) => li.dataset.id === SESSION_A.id);
rowA.ondblclick({ preventDefault: () => {} });

const input = byId['session-list'].querySelector('.rename-input');
ok(input !== null, '双击会话行 → 名字就地变成输入框');
eq(input.value, SESSION_A.name, '输入框预填当前名字');

// ★ 这一条是回归测试。一次双击会先触发两次 click，各发一次 load，
//    它们的回复正好落在 onSession 里。onSession 若重建侧栏，输入框就被抹掉了，
//    表现是「双击改名完全没反应」——不报错，所以只有机器测得到。
WB.onSession({ id: SESSION_A.id, favoriteCount: 1, entries: ENTRIES_A });
ok(byId['session-list'].querySelector('.rename-input') !== null,
   '★ load 的回执到了之后，输入框**还在**（双击改名不会被自己发的 load 打断）');
ok(rows().find((li) => li.dataset.id === SESSION_A.id).classList.contains('selected'),
   '回执同时把选中态挪到了这一行');

// 改完按回车
reset();
input.value = '  怪奇物语 S01E01 改  ';
input.onkeydown({ key: 'Enter', preventDefault: () => {} });
eq(last(), { cmd: 'rename', id: SESSION_A.id, name: '怪奇物语 S01E01 改' },
   '回车提交，名字送去首尾空白（trim 是前端做一次、后端再做一次）');
ok(byId['session-list'].querySelector('.rename-input') === null, '提交后输入框还原成文字');

// 回执把名字落到界面上
WB.onRenamed({ ok: true, id: SESSION_A.id, name: '怪奇物语 S01E01 改' });
eq(byId['session-name'].textContent, '怪奇物语 S01E01 改', '回执后页头标题也跟着更新');
eq(rows().find((li) => li.dataset.id === SESSION_A.id).children[0].textContent,
   '怪奇物语 S01E01 改', '侧栏那一行的名字也跟着更新');

// 空名字要被拦下，且一个字都不发出去
reset();
rows().find((li) => li.dataset.id === SESSION_A.id).ondblclick({ preventDefault: () => {} });
byId['session-list'].querySelector('.rename-input').value = '    ';
byId['session-list'].querySelector('.rename-input').onkeydown({ key: 'Enter', preventDefault: () => {} });
eq(sent.length, 0, '空名字 / 全空格 → 一个消息都不发');
ok(byId.toast.hidden === false, '空名字给出提示（toast 弹出来了）');

// Esc 取消
reset();
rows().find((li) => li.dataset.id === SESSION_A.id).ondblclick({ preventDefault: () => {} });
const escInput = byId['session-list'].querySelector('.rename-input');
escInput.value = '不要这个名字';
escInput.onkeydown({ key: 'Escape', preventDefault: () => {} });
eq(sent.length, 0, 'Esc 取消 → 不发消息');
ok(byId['session-list'].querySelector('.rename-input') === null, 'Esc 之后输入框收起');
ok(rows().find((li) => li.dataset.id === SESSION_A.id).children[0].textContent === '怪奇物语 S01E01 改',
   'Esc 之后名字还原成原来的（不是被打了一半的输入）');

// ★ 在收藏视图里改某个会话的名字，**不能**把页头从「★ 收藏」覆盖成会话名。
//    页头显示的是"你正在看的东西"，改别人的名字不该动它。
WB.onSessions({ sessions: [SESSION_B, SESSION_A], totalFavorites: 2 });
pinnedRow().onclick();
WB.onFavorites({ groups: GROUPS });
WB.onRenamed({ ok: true, id: SESSION_A.id, name: '被误改的标题' });
eq(byId['session-name'].textContent, '★ 收藏',
   '★ 在收藏视图里改某集名字 → 页头仍是「★ 收藏」，没被覆盖成会话名');

// ★ 刷新侧栏（onSessions）不该把人从收藏视图里踢回会话视图。
//    这里必须让 currentID 指向一个**已经不在列表里**的会话才测得到：
//    否则 onSessions 本来就不会发 load，守卫在不在都看不出区别。
WB.onSession({ id: '20260101-000000', entries: [] });   // 一集"已经不在列表里"的
pinnedRow().onclick();
WB.onFavorites({ groups: GROUPS });
reset();
WB.onSessions({ sessions: [SESSION_B, SESSION_A], totalFavorites: 2 });
eq(sent.filter((m) => m.cmd === 'load').length, 0,
   '★ 在收藏视图里刷新侧栏 → 不发 load（发了就会被拽回会话视图）');
eq(byId['session-name'].textContent, '★ 收藏',
   '★ 刷新侧栏 → 仍然停在收藏视图（刷新不踢人）');

// ═══════════════════════════════════════════════════════
section('右键菜单');
// ═══════════════════════════════════════════════════════

reset();
const ctxRow = rows().find((li) => li.dataset.id === SESSION_B.id);
let prevented = false;
ctxRow.oncontextmenu({ preventDefault: () => { prevented = true; }, clientX: 100, clientY: 200 });
ok(prevented, '右键必须拦掉默认行为（否则会被 WebKit 的原生菜单盖住）');
ok(byId.menu.hidden === false, '自绘菜单弹出来');
eq(byId.menu.children.map((b) => b.textContent), ['重命名', '在 Finder 中显示'],
   '菜单里是「重命名」和「在 Finder 中显示」两项');

reset();
byId.menu.children[1].onclick();
eq(last(), { cmd: 'reveal', id: SESSION_B.id, target: 'session' },
   '菜单的「在 Finder 中显示」打开的是会话**目录**，不是导出文件');
ok(byId.menu.hidden === true, '点了菜单项之后菜单收起');

// 菜单里选「重命名」也要能进编辑
byId.menu.children[0].onclick.disabled;   // 只是确认属性存在
reset();
ctxRow.oncontextmenu({ preventDefault: () => {}, clientX: 10, clientY: 10 });
byId.menu.children[0].onclick();
ok(byId['session-list'].querySelector('.rename-input') !== null, '从右键菜单也能进改名');

// ═══════════════════════════════════════════════════════
section('空态 · 一次都没采集过');
// ═══════════════════════════════════════════════════════

reset();
WB.onSessions({ sessions: [], totalFavorites: 0 });
ok(pinnedRow() !== undefined, '没有会话时，收藏入口仍然在（它不依赖任何会话）');
ok(pinnedRow().children[1].textContent === '还没有收藏', '没有收藏时副标题说得明白');
ok(rows().some((li) => li.textContent.includes('回菜单栏点「开始采集」')),
   '没有会话时给出下一步该干什么');
eq(sent.length, 0, '没有会话就不发 load（别对着空 id 乱问）');

reset();
pinnedRow().onclick();
WB.onFavorites({ groups: [] });
ok(entryRows()[0].classList.contains('empty-hint'), '零收藏时给空态文案而不是留白');
ok(entryRows()[0].textContent.includes('点句子右边的 ☆'), '空态文案说清**怎么**收藏');
eq(byId['no-match'].hidden, true, '零收藏是空态，不是「没有匹配的句子」');

// ── 总结 ────────────────────────────────────────────────

console.log('\n' + '─'.repeat(60));
if (failures.length === 0) {
    console.log(`\x1b[32m全部通过：${passed} 项检查\x1b[0m`);
    process.exit(0);
}
console.log(`\x1b[31m失败 ${failures.length} 项 / 共 ${passed + failures.length} 项：\x1b[0m`);
for (const f of failures) console.log(`  · ${f}`);
process.exit(1);
