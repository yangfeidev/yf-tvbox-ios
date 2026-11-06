#!/usr/bin/env bash
#
# 出可安装包（development 签名的 ipa）。
#
# 用法：
#   ./scripts/build-ipa.sh                # 用默认团队，产出 build/YFTVBox-<ver>-<build>.ipa
#   DEVELOPMENT_TEAM=XXXXXXXXXX ./scripts/build-ipa.sh
#   ./scripts/build-ipa.sh --install      # 出包后直接装到已连接设备
#
# 前置：
#   - Xcode 已登录 Apple 开发者账号，且该账号属于 DEVELOPMENT_TEAM
#   - 目标 iPhone 的 UDID 已在描述文件里（第一次插线跑一次 Xcode 即可自动注册）
#
# 为什么必须带 -disable-sandbox：
#   这台机器的命令行进程本身在沙箱里，Swift 编译器再调 sandbox-exec 启动宏插件宿主会失败，
#   报错伪装成 "external macro implementation type 'ObservationMacros.ObservableMacro' could not be found"。
#   Xcode 图形界面构建没有这个问题。

set -euo pipefail

cd "$(dirname "$0")/.."

TEAM="${DEVELOPMENT_TEAM:-X3T54D57W9}"
SCHEME="YFTVBox"
PROJECT="YFTVBox.xcodeproj"
ARCHIVE="build/YFTVBox.xcarchive"
STAGE="build/ipastage"
INSTALL_AFTER=0

for arg in "$@"; do
  case "$arg" in
    --install) INSTALL_AFTER=1 ;;
    *) echo "未知参数：$arg"; exit 1 ;;
  esac
done

echo "==> 1/5 生成工程"
xcodegen generate >/dev/null

echo "==> 2/5 归档（Release, team=${TEAM}）"
rm -rf "$ARCHIVE" "$STAGE"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  DEVELOPMENT_TEAM="$TEAM" \
  CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates \
  OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox' \
  | grep -E "error:|warning: .*provisioning|ARCHIVE" || true

APP="$ARCHIVE/Products/Applications/$SCHEME.app"
if [ ! -d "$APP" ]; then
  echo "归档失败：$APP 不存在"
  exit 1
fi

echo "==> 3/5 校验签名与描述文件"
codesign -dv "$APP" 2>&1 | grep -E "TeamIdentifier|Authority" | head -3
PROFILE=$(mktemp)
security cms -D -i "$APP/embedded.mobileprovision" > "$PROFILE"
python3 - "$PROFILE" <<'PY'
import plistlib, sys
d = plistlib.load(open(sys.argv[1], 'rb'))
devices = d.get('ProvisionedDevices', [])
print(f"  描述文件：{d.get('Name')}")
print(f"  设备数：{len(devices)}（development 包只能装这些设备）")
print(f"  get-task-allow：{d.get('Entitlements', {}).get('get-task-allow')}")
PY
rm -f "$PROFILE"

echo "==> 4/5 打包 ipa"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Info.plist")
IPA="build/${SCHEME}-${VERSION}-${BUILD}.ipa"
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
(cd "$STAGE" && zip -qry "../$(basename "$IPA")" Payload)
rm -rf "$STAGE"
echo "  产出：$IPA ($(du -h "$IPA" | cut -f1))"

echo "==> 5/5 完成"
if [ "$INSTALL_AFTER" -eq 1 ]; then
  DEVICE=$(xcrun devicectl list devices 2>/dev/null | awk '/physical/ && /available/ {print $3; exit}')
  if [ -z "${DEVICE:-}" ]; then
    echo "  没找到可用设备。插线后重试，或用 Apple Configurator / Sideloadly 拖入 ipa。"
    exit 0
  fi
  echo "  安装到 $DEVICE"
  xcrun devicectl device install app --device "$DEVICE" "$APP"
else
  cat <<EOF

安装方式（任选其一）：
  1) 插线后用 Xcode：Window → Devices，把 $IPA 拖到设备上
  2) 插线后命令行：xcrun devicectl device install app --device <UDID> "$APP"
  3) 用 Apple Configurator / Sideloadly / iMazing 拖入 ipa
  4) 本脚本加 --install 自动装到已连接设备

注意：development 签名有效期约一年，到期需重新出包；
      包里的描述文件只认列表内的设备 UDID，换机要重新注册并出包。
EOF
fi
