#!/usr/bin/env node
// 前端检查器的**反向对照**。
//
//   node Scripts/workbench-check-mutants.js
//
// 一份永远全绿的检查是最没用的东西。它会让人以为改动是安全的，
// 而实际上它对代码里发生的事一无所知 —— 那种"绿"是负资产。
//
// 所以这个脚本把每个我**真修过的 bug** 的逆操作重新打到 app.js 上，
// 然后看 workbench-check.js 会不会变红。**漏掉任何一条，就说明检查对那类
// 问题是瞎的**，那条断言等于没写。
//
// 只在需要动 app.js 时跑（改动前端逻辑 / 增删断言时）。
// 跑完一定还原文件；中途被打断也不会留下被改坏的 app.js（见 finally）。

const fs = require('fs');
const cp = require('child_process');
const path = require('path');

const APP = path.join(__dirname, '..', 'Resources', 'Workbench', 'app.js');
const CHECK = path.join(__dirname, 'workbench-check.js');
const original = fs.readFileSync(APP, 'utf8');

// 每条 = 一个真实的 bug 的逆操作。期望：检查必须变红，且**红在该红的那条上**。
const MUTATIONS = [
    ['onSession 改回整表重绘 —— 双击改名的那个原 bug',
     '    markSidebarSelection();\n    renderDetail();',
     '    renderSessions();\n    renderDetail();'],

    ['onRenamed 去掉「只在会话视图才改页头」的守卫',
     "if (state.view === 'session' && state.currentID === id) {",
     'if (state.currentID === id) {'],

    ['onSessions 去掉「在收藏视图就别踢人」的早返回',
     "    if (state.view === 'favorites') return;",
     '    if (false) return;'],

    ['starButton 去掉 stopPropagation —— 点星会顺带复制一次英文',
     '        ev.stopPropagation();\n        send({ cmd: favorited',
     '        send({ cmd: favorited'],

    ['onFavoriteToggled 在会话视图改回整表重绘 —— 滚动位置会被打回顶部',
     "    const row = $('entries').querySelector(`li[data-index=\"${index}\"]`);",
     "    const row = null && $('entries').querySelector(`li[data-index=\"${index}\"]`);"],

    ['renderEntries 不写 dataset.index —— 单行更新静默失效',
     '        li.dataset.index = e.index;          // 收藏后要按它找到这一行，做单行更新',
     '        // (mutation)'],

    ['renderFavorites 去掉「数据没回来别下结论」的守卫 —— 会闪一下「还没有收藏」',
     '        if (!state.favoritesLoaded) return;',
     '        if (false) return;'],

    ['收藏项副标题不再显示来源集数',
     '`${state.totalFavorites} 句 · 来自 ${fromSessions} 集`',
     '`${state.totalFavorites} 句`'],
];

const strip = (s) => s.replace(/\x1b\[[0-9;]*m/g, '');

let missed = 0;
let skipped = 0;

try {
    console.log('── 变异测试：把每个修过的 bug 的逆操作打回去，看检查会不会咬 ──\n');

    for (const [name, from, to] of MUTATIONS) {
        if (!original.includes(from)) {
            // 锚点没找到 = app.js 被改过，这条变异验证不了。**不能当成通过。**
            skipped++;
            console.log(`  \x1b[33m?  \x1b[0m ${name}`);
            console.log(`      \x1b[33m锚点没找到 —— app.js 变了，这条变异得跟着更新\x1b[0m`);
            continue;
        }

        fs.writeFileSync(APP, original.replace(from, to));
        const r = cp.spawnSync('node', [CHECK], { encoding: 'utf8' });
        const out = strip(r.stdout || '');
        const caught = r.status !== 0;

        if (!caught) {
            missed++;
            console.log(`  \x1b[31m✗ 漏了\x1b[0m  ${name}`);
            console.log(`      \x1b[31m这个 bug 从检查里溜过去了 —— 检查对它是瞎的\x1b[0m`);
            continue;
        }

        const count = (out.match(/✗/g) || []).length;
        const first = (out.split('\n').find((l) => l.includes('✗')) || '').trim();
        console.log(`  \x1b[32m✓ 咬住了\x1b[0m  ${name}`);
        console.log(`      红了 ${count} 条，第一条：${first}`);
    }
} finally {
    fs.writeFileSync(APP, original);   // 无论上面发生什么，app.js 都要还原
}

console.log('');
if (missed === 0 && skipped === 0) {
    console.log(`\x1b[32m${MUTATIONS.length} 个变异全部被咬住 —— 检查不是假绿\x1b[0m`);
    process.exit(0);
}
if (missed) console.log(`\x1b[31m${missed} 个变异漏网：检查对这些改动是瞎的\x1b[0m`);
if (skipped) console.log(`\x1b[33m${skipped} 个变异跳过：锚点没找到（多半是 app.js 改了）\x1b[0m`);
process.exit(1);
