#!/bin/bash
#
# SwiftPM 产物 → 可双击的 .app
#
# 为什么不用 xcodebuild：这台机器只有 CommandLineTools，没有完整 Xcode，
# xcodebuild 根本不可用。所以手动组装 bundle 目录结构。
#
# 用法：
#   Scripts/package_app.sh              # release 构建
#   CONFIG=debug Scripts/package_app.sh # debug 构建（快，但 OCR 慢）
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# 「每台机器不一样」的东西（证书名、bundle id）从 Scripts/local.env 读。
# 该文件被 .gitignore 挡着，不会进公开仓库；模板见 Scripts/local.env.example。
# 必须放在下面那批 "${VAR:-默认值}" **之前** —— 否则默认值会先把变量占住，
# 后面再 source 也盖不过去。
if [ -f "$ROOT/Scripts/local.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$ROOT/Scripts/local.env"
    set +a
fi

CONFIG="${CONFIG:-release}"
APP_NAME="English"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"

# 自签名证书名。跑过 Scripts/setup_signing.sh 之后才有。
CERT_NAME="${CERT_NAME:-English Local Dev}"

# bundle id。**这不能写死在仓库里**：它是 TCC（屏幕录制权限）锚点的一部分，
# 而且公开仓库里带着作者自己的 id 既没意义也漏信息。默认给个中性的，
# 你自己的机器（已经给老 id 授过权）用 Scripts/local.env 覆盖回来即可。
BUNDLE_ID="${BUNDLE_ID:-dev.hardsub.english}"

# ⚠️ 变量后面紧跟全角字符时必须写成 ${VAR}：bash 会把全角括号
# 当成变量名的一部分，报 "CONFIG）: unbound variable"
echo "▸ 构建（${CONFIG}）…"
swift build -c "$CONFIG" --product EnglishApp
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

echo "▸ 组装 bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/EnglishApp" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Scripts/Info.plist" "$APP/Contents/Info.plist"
# Info.plist 里那份是中性的占位值，真正的 id 在这里落进去。
# （PlistBuddy 是 macOS 自带的，不需要装东西。）
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# SwiftPM 把 target 的资源打包成 *.bundle 放在 bin 目录旁边，
# Bundle.module 运行时按这个位置找。必须一起搬进 Contents/Resources。
shopt -s nullglob
for b in "$BIN_DIR"/*.bundle; do
    echo "   资源包 $(basename "$b")"
    cp -R "$b" "$APP/Contents/Resources/"
done
shopt -u nullglob

# 工作台的网页资源。它是普通文件而不是 SwiftPM resource，因为 SwiftPM 只认
# target 目录**内部**的资源，而这些文件按计划是放在仓库根的 Resources/。
# 走 Bundle.main 找 Contents/Resources 反而更直接（见 WorkbenchWindow）。
if [ -d "$ROOT/Resources/Workbench" ]; then
    echo "   工作台资源 Resources/Workbench"
    cp -R "$ROOT/Resources/Workbench" "$APP/Contents/Resources/"
fi

# ── 签名 ────────────────────────────────────────────────────────────────────
# 这一步不是走过场。TCC（屏幕录制权限）锚定在 **bundle id + 代码签名的指定要求**上：
#   · ad-hoc 签名（-s -）的指定要求里含 cdhash，**每次重新构建 cdhash 都变**，
#     系统会认为这是另一个程序 → 权限失效，每次重编译都要重新授权
#   · 自签名证书签出来的指定要求是稳定的 → 权限一次授权长期有效
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "▸ 用证书签名：${CERT_NAME}（bundle id: ${BUNDLE_ID}）"
    codesign --force --deep --options runtime \
        --sign "$CERT_NAME" --identifier "$BUNDLE_ID" "$APP"
else
    echo "▸ ⚠️  没找到证书「${CERT_NAME}」，退回 ad-hoc 签名"
    echo "   后果：每次重新打包，屏幕录制权限都会失效，要重新授权。"
    echo "   想一劳永逸就先把证书建好（需要你确认后再跑）："
    echo "       Scripts/setup_signing.sh"
    codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP"
fi

echo ""
echo "▸ 完成：$APP"
codesign -dv "$APP" 2>&1 | sed 's/^/   /'
echo ""

# 关键提醒：这个 App 是常驻的（菜单栏），`open` 在它已经运行时**不会重启它**，
# 只是把旧窗口切到前台 —— 于是你看到的永远是重新打包之前的界面。
# 已经不止一次因此以为"改的东西没生效"，所以这里主动查一下并说清楚。
if pgrep -f "$APP/Contents/MacOS/English" >/dev/null 2>&1; then
    echo "   ⚠️  English.app 现在正在运行（PID $(pgrep -f "$APP/Contents/MacOS/English" | tr '\n' ' '))"
    echo "       上面的新代码**不会**进到那个进程里。要看到新版："
    echo "         1) 先停止采集（菜单栏 ⌘S），别丢正在录的这一集"
    echo "         2) 菜单栏 → 退出（⌘Q）"
    echo "         3) 再 open \"$APP\""
    echo "       直接 open 只会把旧窗口切到前台，界面还是老样子。"
else
    echo "   双击打开，或：open \"$APP\""
fi
echo "   权限没了就重置一次：tccutil reset ScreenCapture $BUNDLE_ID"
