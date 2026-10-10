// 工作台的前端。
//
// 和原生侧只有一个约定：
//   发 → window.webkit.messageHandlers.bridge.postMessage({cmd, ...})
//   收 → window.Workbench.<cmd>Result(payload 对象)
//
// 没有框架、没有构建步骤。改完存盘刷新窗口就能看到效果，
// 不用重新编译 App —— 这是把它做成网页而不是 AppKit 视图的全部理由。

const send = (msg) => window.webkit?.messageHandlers?.bridge?.postMessage(msg);

// 这两个必须在页面脚本一开始就挂上：原生侧可能在 DOM 就绪之前就回数据，
// 挂晚了那次回复会直接丢掉（evaluateJavaScript 找不到函数就静默失败）。
window.Workbench = {};

const $ = (id) => document.getElementById(id);

const state = {
    sessions: [],
    totalFavorites: 0,
    // 正文区显示哪一屏。只有这两个值 —— 侧栏选中哪一项，它就跟着变。
    view: 'session',        // 'session' | 'favorites'
    currentID: null,
    entries: [],
    groups: [],             // 收藏视图的数据，按会话分组
    favoritesLoaded: false, // 收藏还没查回来之前，别急着说「还没有收藏」
    filter: '',
};

// ── 原生 → 网页 ─────────────────────────────────────────

window.Workbench.onSessions = ({ sessions, totalFavorites }) => {
    state.sessions = sessions;
    state.totalFavorites = totalFavorites ?? 0;
    renderSessions();

    // 收藏视图不依赖某个会话，刷新列表时**不要**把人从收藏视图里踢出去
    if (state.view === 'favorites') return;

    // 打开工作台多半就是想看最近那次——直接选上，别让人对着空页面再点一下。
    // 只在「还没选过」或「选中的会话已经没了」时自动选，不然会打断正在看的人。
    const stillThere = sessions.some((s) => s.id === state.currentID);
    if (!stillThere && sessions.length) {
        send({ cmd: 'load', id: sessions[0].id });
    } else if (!stillThere) {
        state.currentID = null;
        state.entries = [];
        renderDetail();
    }
};

window.Workbench.onSession = ({ id, entries }) => {
    state.view = 'session';
    state.currentID = id;
    state.entries = entries;
    // 这里**只改选中态、不重建侧栏**。
    //
    // 原因是双击改名：一次双击会先触发两次 click，每次 click 都发一次 load，
    // 回复正好落在这个函数里。如果这里 renderSessions()，输入框会被
    // replaceChildren 从 DOM 里直接抹掉 —— 表现就是「双击改名没反应」，
    // 而且不报错，最难查的那种。
    markSidebarSelection();
    renderDetail();
};

window.Workbench.onFavorites = ({ groups }) => {
    state.groups = groups;
    state.favoritesLoaded = true;
    renderDetail();
};

window.Workbench.onFavoriteToggled = ({ ok, id, index, favorited,
                                        count, totalFavorites, error }) => {
    if (!ok) return toast(`操作失败：${error || '未知错误'}`);

    state.totalFavorites = totalFavorites ?? state.totalFavorites;
    const session = state.sessions.find((s) => s.id === id);
    if (session) session.favoriteCount = count;

    if (state.view === 'favorites') {
        // 在收藏视图里取消收藏，那一条就该**立刻消失**
        if (!favorited) {
            state.groups = state.groups
                .map((g) => (g.id === id
                    ? { ...g, items: g.items.filter((it) => it.index !== index) }
                    : g))
                .filter((g) => g.items.length);
        }
        renderSessions();
        renderDetail();
        return;
    }

    // 会话视图：**只换这一行的星标**，不整表重绘 —— 整表重绘会把滚动位置打回顶部，
    // 而收藏往往是在读到一半时随手点的。
    const entry = state.entries.find((e) => e.index === index);
    if (entry) entry.favorited = favorited;
    const row = $('entries').querySelector(`li[data-index="${index}"]`);
    const oldStar = row?.querySelector('.star');
    if (oldStar) oldStar.replaceWith(starButton(id, index, favorited));
    row?.classList.toggle('starred', favorited);
    renderSessions();       // 只为了刷新侧栏的计数
};

window.Workbench.onExported = (result) => {
    if (!result.ok) return toast(`导出失败：${result.error}`);
    toast(`已导出 ${result.sentenceCount} 句 → ${result.path.split('/').pop()}`);
};

window.Workbench.onRenamed = ({ ok, id, name, error }) => {
    if (!ok) {
        toast(`重命名失败：${error || '未知错误'}`);
    } else {
        const s = state.sessions.find((x) => x.id === id);
        if (s) s.name = name;
        // 只有正在看这一集时才动页头 —— 在收藏视图里改某个会话的名字，
        // 页头显示的是「★ 收藏」，不该被覆盖成会话名
        if (state.view === 'session' && state.currentID === id) {
            $('session-name').textContent = name;
        }
    }
    // 无论成败都按盘上的真实状态重画，不让前端自己维护一份可能过期的名字
    renderSessions();
};

// ── 侧栏 ────────────────────────────────────────────────

/**
 * 侧栏顶部那项常驻的收藏入口。
 * 它和会话并列，但**永远排第一**，而且不受"有没有会话"影响 ——
 * 一次都没采集过时，收藏视图照样打得开（空态）。
 */
function favoritesRow() {
    const li = document.createElement('li');
    li.className = 'pinned';
    if (state.view === 'favorites') li.classList.add('selected');

    const name = document.createElement('div');
    name.className = 'name';
    name.textContent = '★ 收藏';

    const sub = document.createElement('div');
    sub.className = 'sub';
    const fromSessions = state.sessions.filter((s) => s.favoriteCount).length;
    sub.textContent = state.totalFavorites
        ? `${state.totalFavorites} 句 · 来自 ${fromSessions} 集`
        : '还没有收藏';

    li.append(name, sub);
    li.onclick = openFavorites;
    return li;
}

function openFavorites() {
    state.view = 'favorites';
    hideMenu();
    markSidebarSelection();
    renderDetail();                       // 先用手上的旧数据画一版，别闪白
    send({ cmd: 'loadFavorites' });
}

/**
 * 只更新侧栏的选中态，**不重建 DOM**。
 * 重建 DOM 会顺手抹掉正在进行中的「就地改名」输入框（见 onSession 的注释）。
 */
function markSidebarSelection() {
    for (const li of $('session-list').children) {
        if (li.classList.contains('pinned')) {
            li.classList.toggle('selected', state.view === 'favorites');
        } else {
            li.classList.toggle('selected',
                state.view === 'session' && li.dataset.id === state.currentID);
        }
    }
}

function renderSessions() {
    const list = $('session-list');
    list.replaceChildren();

    list.append(favoritesRow());

    if (!state.sessions.length) {
        const li = document.createElement('li');
        li.className = 'sub empty';
        li.textContent = '还没有会话。回菜单栏点「开始采集」。';
        list.append(li);
        return;
    }

    for (const s of state.sessions) {
        const li = document.createElement('li');
        li.dataset.id = s.id;      // markSidebarSelection 靠它认出是哪一行
        if (state.view === 'session' && s.id === state.currentID) li.classList.add('selected');

        const name = document.createElement('div');
        name.className = 'name';
        name.textContent = s.name;

        const sub = document.createElement('div');
        sub.className = 'sub';
        const when = new Date(s.startedAt);
        const bits = [`${s.entryCount} 句`];
        if (s.favoriteCount) bits.push(`★ ${s.favoriteCount}`);
        bits.push(when.toLocaleString('zh-CN', {
            month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit',
        }));
        sub.textContent = bits.join(' · ');

        li.append(name, sub);
        li.onclick = () => send({ cmd: 'load', id: s.id });

        // 双击整行改名（照 Finder 的惯例：双击的对象是"这一项"，不只是名字那几个字）
        li.ondblclick = (ev) => {
            ev.preventDefault();
            const nameEl = li.querySelector('.name');
            if (nameEl) inlineEdit(nameEl, s.name, (v) => commitRename(s, v));
        };

        // 右键弹自绘菜单。必须 preventDefault，否则 WebKit 会弹它自己的
        // 「重新载入 / 检查元素」那个原生菜单，把我们的盖掉。
        li.oncontextmenu = (ev) => {
            ev.preventDefault();
            showMenu(ev.clientX, ev.clientY, [
                ['重命名', () => {
                    const nameEl = li.querySelector('.name');
                    if (nameEl) inlineEdit(nameEl, s.name, (v) => commitRename(s, v));
                }],
                ['在 Finder 中显示', () => send({ cmd: 'reveal', id: s.id, target: 'session' })],
            ]);
        };

        list.append(li);
    }
}

// ── 重命名 ──────────────────────────────────────────────

/**
 * 把一个元素**就地**换成输入框：Enter / 失焦提交，Esc 取消。
 *
 * 提交或取消时先把原元素放回原位、再回调 —— 这一步不能省：
 * 调用方（比如 renderDetail）后面还会按 id 去查那个元素，元素被 replaceWith
 * 换掉之后就查不到了，会直接在 null 上取属性。
 */
function inlineEdit(el, initial, onCommit) {
    const input = document.createElement('input');
    input.className = 'rename-input';
    if (el.id) input.id = el.id;   // 编辑期间 id 仍然查得到
    input.value = initial;
    input.autocomplete = 'off';
    el.replaceWith(input);
    input.focus();
    input.select();

    let done = false;
    const finish = (commit) => {
        if (done) return;          // blur 会紧跟着 Enter/Esc 再来一次，挡掉
        done = true;
        const value = input.value.trim();
        input.replaceWith(el);
        // 先乐观显示，让手一松就能看到结果；下面若判定不合法会按真实状态重画回来
        el.textContent = commit && value ? value : initial;
        onCommit(commit ? value : null);
    };

    input.onkeydown = (ev) => {
        if (ev.key === 'Enter') { ev.preventDefault(); finish(true); }
        else if (ev.key === 'Escape') { ev.preventDefault(); finish(false); }
    };
    input.onblur = () => finish(true);
}

function commitRename(session, value) {
    // null = 用户按了 Esc；空串 = 用户想清空名字。两者都不该发出去。
    if (value === null) return renderSessions();
    if (!value) { toast('名字不能为空'); return renderSessions(); }
    if (value === session.name) return renderSessions();
    send({ cmd: 'rename', id: session.id, name: value });
}

// ── 右键菜单 ────────────────────────────────────────────
//
// 自绘而不是调原生 NSMenu：省掉一次「网页坐标 → 窗口坐标」的换算和一次桥接往返，
// 而且改样式不用重新编译 App —— 这正是工作台当初做成网页的全部理由。

function showMenu(x, y, items) {
    const menu = $('menu');
    menu.replaceChildren(...items.map(([label, run]) => {
        const item = document.createElement('button');
        item.type = 'button';
        item.className = 'menu-item';
        item.textContent = label;
        item.onclick = () => { hideMenu(); run(); };
        return item;
    }));

    menu.hidden = false;
    // 贴着光标，但别越过窗口边界
    const box = menu.getBoundingClientRect();
    menu.style.left = `${Math.min(x, window.innerWidth - box.width - 6)}px`;
    menu.style.top = `${Math.min(y, window.innerHeight - box.height - 6)}px`;
}

function hideMenu() { $('menu').hidden = true; }

// mousedown 而不是 click：它在 click 之前发生，所以「按在别处的第一下」
// 只会关掉菜单，不会顺带触发下面那个元素。
document.addEventListener('mousedown', (ev) => {
    const menu = $('menu');
    if (!menu.hidden && !menu.contains(ev.target)) hideMenu();
});
document.addEventListener('keydown', (ev) => { if (ev.key === 'Escape') hideMenu(); });
window.addEventListener('blur', hideMenu);

// ── 正文 ────────────────────────────────────────────────

function renderDetail() {
    $('placeholder').hidden = true;
    $('detail').hidden = false;
    if (state.view === 'favorites') renderFavoritesDetail();
    else renderSessionDetail();
}

function renderSessionDetail() {
    const session = state.sessions.find((s) => s.id === state.currentID);
    $('session-name').textContent = session?.name ?? '会话';
    $('session-meta').textContent = `${state.entries.length} 句`;
    renderEntries();
}

function renderFavoritesDetail() {
    const total = state.groups.reduce((n, g) => n + g.items.length, 0);
    $('session-name').textContent = '★ 收藏';
    $('session-meta').textContent = !state.favoritesLoaded
        ? '载入中…'
        : (total ? `共 ${total} 句 · 来自 ${state.groups.length} 集` : '还没有收藏');
    renderFavorites();
}

// 会话视图和收藏视图共用同一套文本匹配（两边都是 {english, chinese}）
function matches(entry) {
    if (!state.filter) return true;
    const q = state.filter.toLowerCase();
    return entry.english.toLowerCase().includes(q)
        || entry.chinese.toLowerCase().includes(q);
}

/** 行右侧那颗星。两个视图共用。 */
function starButton(sessionID, index, favorited) {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = favorited ? 'star on' : 'star';
    b.textContent = favorited ? '★' : '☆';
    b.title = favorited ? '取消收藏' : '收藏这句';
    b.setAttribute('aria-pressed', favorited ? 'true' : 'false');
    b.onclick = (ev) => {
        // 必须拦住：整行的 onclick 是「复制英文」，不拦会顺手复制一次
        ev.stopPropagation();
        send({ cmd: favorited ? 'unfavorite' : 'favorite', id: sessionID, index });
    };
    return b;
}

function copyEnglish(text) {
    if (!text) return;
    navigator.clipboard?.writeText(text);
    toast('已复制英文');
}

function renderEntries() {
    const ol = $('entries');
    ol.replaceChildren();

    const shown = state.entries.filter(matches);
    $('no-match').hidden = shown.length > 0 || !state.entries.length;

    for (const e of shown) {
        const li = document.createElement('li');
        li.dataset.index = e.index;          // 收藏后要按它找到这一行，做单行更新
        if (e.favorited) li.classList.add('starred');

        const n = document.createElement('span');
        n.className = 'n';
        n.textContent = e.index;

        const en = document.createElement('div');
        en.className = 'en';
        if (e.english) {
            en.textContent = e.english;
            if (e.isFlash) en.classList.add('flash');
        } else {
            en.textContent = '（没识别到英文）';
            en.classList.add('missing');
        }

        li.append(n, en);

        // 中文可以缺（不是所有片源都有中字），缺了就不占行
        if (e.chinese) {
            const zh = document.createElement('div');
            zh.className = 'zh';
            zh.textContent = e.chinese;
            li.append(zh);
        }

        li.append(starButton(state.currentID, e.index, !!e.favorited));

        // 点一行就把英文抄到剪贴板——做生词卡时最常用的一步
        li.onclick = () => copyEnglish(e.english);

        ol.append(li);
    }
}

// ── 收藏视图 ────────────────────────────────────────────

function renderFavorites() {
    const ol = $('entries');
    ol.replaceChildren();

    const total = state.groups.reduce((n, g) => n + g.items.length, 0);
    const groups = state.groups
        .map((g) => ({ ...g, items: g.items.filter(matches) }))
        .filter((g) => g.items.length);

    $('no-match').hidden = groups.length > 0 || !total;

    if (!total) {
        // 还没查回来就先不下结论 —— 否则点开收藏会先闪一句"还没有收藏"
        if (!state.favoritesLoaded) return;
        // 一条收藏都没有：给一句话说明**怎么收藏**，而不是留一片空白
        const li = document.createElement('li');
        li.className = 'empty-hint';
        li.textContent = '还没有收藏。在某个会话里点句子右边的 ☆。';
        ol.append(li);
        return;
    }

    for (const g of groups) {
        const head = document.createElement('li');
        head.className = 'group';

        const label = document.createElement('span');
        label.textContent = `${g.name}（${dayLabel(g.startedAt)}）`;

        const jump = document.createElement('span');
        jump.className = 'jump';
        jump.textContent = '回这一集 →';

        head.append(label, jump);
        head.title = '回到这一集';
        // 只切视图，不做滚动定位到具体那一句 —— 见计划文档 §8 的取舍
        head.onclick = () => { state.view = 'session'; send({ cmd: 'load', id: g.id }); };
        ol.append(head);

        for (const item of g.items) ol.append(favoriteRow(g, item));
    }
}

function favoriteRow(group, item) {
    const li = document.createElement('li');
    li.dataset.index = item.index;

    const n = document.createElement('span');
    n.className = 'n';
    // 显示的是它在**原会话里**的序号，和导出文档里的编号对得上，方便回原文对照
    n.textContent = item.index;

    const en = document.createElement('div');
    en.className = 'en';
    if (item.english) {
        en.textContent = item.english;
    } else {
        en.textContent = '（没识别到英文）';
        en.classList.add('missing');
    }

    li.append(n, en);

    if (item.chinese) {
        const zh = document.createElement('div');
        zh.className = 'zh';
        zh.textContent = item.chinese;
        li.append(zh);
    }

    li.append(starButton(group.id, item.index, true));
    li.onclick = () => copyEnglish(item.english);
    return li;
}

function dayLabel(iso) {
    return new Date(iso).toLocaleDateString('zh-CN', { month: 'long', day: 'numeric' });
}

// ── 交互 ────────────────────────────────────────────────

$('refresh').onclick = () => send({ cmd: 'list' });

// 导出和 Finder 都跟着当前视图走：在收藏视图里导的是收藏，在会话视图里导的是这一集。
// 同一组按钮干两件事，比再加一组按钮更不容易按错。
function exportTarget() {
    if (state.view === 'favorites') return { scope: 'favorites' };
    return state.currentID ? { id: state.currentID } : null;
}

$('export-md').onclick = () => {
    const t = exportTarget();
    if (t) send({ cmd: 'export', format: 'md', ...t });
};
$('export-txt').onclick = () => {
    const t = exportTarget();
    if (t) send({ cmd: 'export', format: 'txt', ...t });
};
$('reveal').onclick = () => {
    if (state.view === 'favorites') return send({ cmd: 'reveal', target: 'favorites' });
    if (state.currentID) send({ cmd: 'reveal', id: state.currentID });
};

// 页头的大标题也双击可改 —— 看着这一集想改个名，不用再回侧栏找它。
// 收藏视图的标题是固定的「★ 收藏」，没有名字可改。
$('session-name').ondblclick = () => {
    if (state.view !== 'session') return;
    const session = state.sessions.find((s) => s.id === state.currentID);
    if (session) {
        inlineEdit($('session-name'), session.name, (v) => commitRename(session, v));
    }
};

$('filter').oninput = (ev) => {
    state.filter = ev.target.value.trim();
    renderDetail();          // 按当前视图分派，筛选框在两个视图里都生效
};

let toastTimer;
function toast(text) {
    const el = $('toast');
    el.textContent = text;
    el.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { el.hidden = true; }, 2600);
}

// 在普通浏览器里打开时给个明确的说明，别让人对着空列表猜
if (!window.webkit?.messageHandlers?.bridge) {
    $('placeholder').innerHTML =
        '<p>这个界面要在 App 里打开才能拿到数据。</p>'
        + '<p class="hint">浏览器里只能调样式；数据要靠原生侧的桥接。</p>';
} else {
    send({ cmd: 'list' });
}
