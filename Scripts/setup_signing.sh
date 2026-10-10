#!/bin/bash
#
# 建一张自签名代码签名证书，让屏幕录制权限能跨重新构建保持有效。
#
# ⚠️ 这个脚本会改动你 **登录钥匙串的信任设置**（把这张证书标记为受信任的
#    代码签名证书）。这是它必须做的事，也是它需要你亲自确认后再跑的原因。
#    它不会碰系统钥匙串（不加 -d，不需要 sudo），只影响你自己的账户。
#
# 为什么非要这样：
#   TCC（屏幕录制权限）锚定在 bundle id + 代码签名的"指定要求"上。
#   ad-hoc 签名（codesign -s -）的指定要求里含 cdhash，每次重新构建都会变，
#   系统就当成另一个程序，权限失效、要重新授权。自签名证书的指定要求是稳定的。
#
set -euo pipefail

CERT_NAME="${CERT_NAME:-English Local Dev}"
KEYCHAIN="${KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
P12_PASS="english"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── 判据必须用 find-identity，不能用 find-certificate ──────────────────────────
#
# 这两者**不等价**，而它们的差集正是本脚本最容易静默失效的地方：
#
#   find-certificate  → 钥匙串里有没有这张证书
#   find-identity -p codesigning → 有没有一个**能用来签名**的身份（= 证书 + 配对私钥 + 已被信任）
#
# 证书导入成功、但 `add-trusted-cert` 那步没跑（或被打断）时，会出现
# **证书在、身份不在**的状态：find-certificate 找得到，find-identity 找不到。
# 用 find-certificate 判"已建好"就会报 ✓ 然后什么都不做，而
# package_app.sh 那边照样退回 ad-hoc —— 权限每重新构建就失效，还找不到原因。
if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "✓ 签名身份已就绪：$CERT_NAME"
    echo "  重新打包直接跑 Scripts/package_app.sh 就行。"
    exit 0
fi

# ── 半成品状态：证书在，但还不是可用的签名身份 ─────────────────────────────────
# 多半是信任标记没设上。私钥通常还在（它在 add-trusted-cert 之前就导入了），
# 所以只需要补信任这一步，不用推倒重来。
if security find-certificate -c "$CERT_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "▸ 证书「${CERT_NAME}」在钥匙串里，但还不是可用的签名身份。"
    echo "  多半是导入后没标受信任 —— 补这一步，不重建。"
    echo
    echo "  ⚠️ 接下来会弹密码框：改钥匙串信任设置需要你授权。"
    echo
    security find-certificate -c "$CERT_NAME" -p "$KEYCHAIN" > "$TMP/cert.pem"
    security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

    if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$CERT_NAME"; then
        echo ""
        echo "✓ 修好了。现在可以："
        echo "     Scripts/package_app.sh"
        exit 0
    fi
    echo ""
    echo "✗ 补了信任标记，但身份还是不可用 —— 说明私钥丢了（只有证书没有配对私钥）。"
    echo "  先删干净再来一次："
    echo "     security delete-identity -c \"${CERT_NAME}\" \"${KEYCHAIN}\""
    echo "     security delete-certificate -c \"${CERT_NAME}\" \"${KEYCHAIN}\""
    exit 1
fi

cat > "$TMP/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions    = ext
prompt             = no

[dn]
CN = $CERT_NAME

[ext]
basicConstraints     = critical,CA:false
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
EOF

echo "▸ 生成自签名证书（10 年有效）…"
openssl req -x509 -newkey rsa:2048 -nodes -sha256 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -config "$TMP/openssl.cnf" 2>/dev/null

# -legacy：否则新版 openssl 默认用 AES-256-CBC + PBKDF2，
# macOS 的 security import 读不了，会报 "MAC verification failed"
openssl pkcs12 -export -legacy \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/identity.p12" -passout "pass:$P12_PASS" 2>/dev/null

echo "▸ 导入登录钥匙串（可能需要你输入钥匙串密码）…"
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$P12_PASS" \
    -T /usr/bin/codesign -T /usr/bin/security

echo "▸ 标记为受信任的代码签名证书…"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

# ── 收尾校验：不信自己前面几步都成功了，直接问钥匙串 ───────────────────────────
# 前面每个子命令都返回 0 不等于最终状态对（证书导入成功但信任没设就是这么来的）。
# 这里必须用和 package_app.sh **同一个判据**再问一遍。
if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$CERT_NAME"; then
    echo ""
    echo "✓ 完成，签名身份已就绪。现在可以："
    echo "     Scripts/package_app.sh"
    echo ""
    echo "  想删掉这张证书："
    echo "     security delete-identity -c \"$CERT_NAME\" \"$KEYCHAIN\""
    exit 0
fi

echo ""
echo "✗ 跑完了，但「${CERT_NAME}」仍不是可用的签名身份。"
echo "  签名不会生效，package_app.sh 会退回 ad-hoc。当前状态："
security find-identity -v "$KEYCHAIN" 2>&1 | sed 's/^/    /'
exit 1
