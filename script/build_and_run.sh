#!/usr/bin/env bash

set -euo pipefail

mode="${1:-run}"
app_name="switchgpt-sly"
bundle_id="ai.shenliyuan.switchgpt-sly"
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dev_bundle_directory="$repository_root/.build/dev-app"
app_bundle="$dev_bundle_directory/$app_name.app"
app_contents="$app_bundle/Contents"
app_macos="$app_contents/MacOS"
app_binary="$app_macos/$app_name"
app_resources="$app_contents/Resources"
app_icon="$app_resources/AppIcon.icns"
helper_directory="$app_contents/Helpers"
recovery_helper="$helper_directory/SwitchGPTRecoverySupervisor"
info_plist="$app_contents/Info.plist"

cd "$repository_root"

# Keep generated development bundles out of Spotlight application results.
# Public release artifacts continue to use dist/release via the release scripts.
mkdir -p "$dev_bundle_directory"
touch "$dev_bundle_directory/.metadata_never_index"

swift build -c debug --product SwitchGPTApp
swift build -c debug --product SwitchGPTRecoverySupervisor
build_bin_dir="$(swift build -c debug --show-bin-path)"
build_binary="$build_bin_dir/SwitchGPTApp"
build_recovery_helper="$build_bin_dir/SwitchGPTRecoverySupervisor"

# Stop only this app for run/debug modes, after compilation has succeeded.
# Reinstall waits until the replacement bundle is ready before stopping it.
case "$mode" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify)
    pkill -x "$app_name" >/dev/null 2>&1 || true
    ;;
esac

rm -rf "$app_bundle"
mkdir -p "$app_macos"
mkdir -p "$app_resources"
mkdir -p "$helper_directory"
cp "$build_binary" "$app_binary"
cp "$build_recovery_helper" "$recovery_helper"
cp "$repository_root/App/Info.plist" "$info_plist"
cp "$repository_root/App/Assets/AppIcon.icns" "$app_icon"
cp -R "$repository_root/App/Resources/en.lproj" "$app_resources/"
cp -R "$repository_root/App/Resources/zh-Hans.lproj" "$app_resources/"
/usr/bin/plutil -insert SwitchGPTSourceRevision -string "$(git rev-parse --short=12 HEAD)" "$info_plist"
chmod 755 "$app_binary"
chmod 755 "$recovery_helper"

signing_identity="$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Apple Development:/{print $2; exit}')"
if [[ -n "$signing_identity" ]]; then
  codesign --force --sign "$signing_identity" --timestamp=none --options runtime "$recovery_helper" >/dev/null
  signing_team="$(codesign -dvv "$recovery_helper" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
  if [[ -z "$signing_team" ]]; then
    echo "Signed recovery helper has no TeamIdentifier" >&2
    exit 1
  fi
  /usr/bin/plutil -replace SwitchGPTHostTeamIdentifier -string "$signing_team" "$info_plist"
  codesign --force --sign "$signing_identity" --timestamp=none --options runtime "$app_binary" >/dev/null
  codesign --force --sign "$signing_identity" --timestamp=none --options runtime "$app_bundle" >/dev/null
  echo "Signed with Apple Development identity"
else
  /usr/bin/plutil -replace SwitchGPTHostTeamIdentifier -string "" "$info_plist"
  codesign --force --sign - --timestamp=none "$recovery_helper" >/dev/null
  codesign --force --sign - --timestamp=none "$app_binary" >/dev/null
  codesign --force --sign - --timestamp=none "$app_bundle" >/dev/null
  echo "Apple Development identity unavailable; using ad hoc signing for local launch"
fi

codesign --verify --deep --strict "$app_bundle"

open_app() {
  /usr/bin/open -n "$app_bundle"
}

verify_process() {
  for _ in {1..30}; do
    if pgrep -x "$app_name" >/dev/null 2>&1; then
      echo "Running: $app_name"
      return 0
    fi
    sleep 0.2
  done

  echo "App process did not stay alive: $app_name" >&2
  return 1
}

reinstall_app() {
  local user_app_directory="$HOME/Applications"
  local installed_app="$user_app_directory/$app_name.app"
  local staged_app="$user_app_directory/.$app_name.install-$(uuidgen).app"
  local backup_app="$user_app_directory/.$app_name.backup-$(uuidgen).app"
  local installed_identifier

  if [[ ! -d "$installed_app" || -L "$installed_app" ]]; then
    echo "Expected installed app is missing or unsafe: $installed_app" >&2
    return 1
  fi
  installed_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$installed_app/Contents/Info.plist" 2>/dev/null) || return 1
  if [[ "$installed_identifier" != "$bundle_id" ]]; then
    echo "Installed app has a different bundle identifier; leaving it untouched" >&2
    return 1
  fi

  if ! /usr/bin/ditto "$app_bundle" "$staged_app"; then
    rm -rf "$staged_app"
    echo "Could not stage the new app; installed bundle is unchanged" >&2
    return 1
  fi
  if ! codesign --verify --deep --strict "$staged_app"; then
    rm -rf "$staged_app"
    echo "Staged app failed signature verification" >&2
    return 1
  fi

  # Only stop this exact app process. ChatGPT is never part of this operation.
  pkill -x "$app_name" >/dev/null 2>&1 || true
  for _ in {1..30}; do
    if ! pgrep -x "$app_name" >/dev/null 2>&1; then break; fi
    sleep 0.1
  done
  if pgrep -x "$app_name" >/dev/null 2>&1; then
    rm -rf "$staged_app"
    echo "App is still running; leaving installed bundle untouched" >&2
    return 1
  fi

  if ! mv "$installed_app" "$backup_app"; then
    rm -rf "$staged_app"
    return 1
  fi
  if ! mv "$staged_app" "$installed_app"; then
    mv "$backup_app" "$installed_app"
    rm -rf "$staged_app"
    return 1
  fi

  if ! codesign --verify --deep --strict "$installed_app" \
    || ! /usr/bin/open -n "$installed_app" \
    || ! verify_process; then
    pkill -x "$app_name" >/dev/null 2>&1 || true
    mv "$installed_app" "$staged_app"
    mv "$backup_app" "$installed_app"
    /usr/bin/open -n "$installed_app" || true
    rm -rf "$staged_app"
    echo "New app failed verification; restored previous installation" >&2
    return 1
  fi

  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$installed_app" || echo "LaunchServices registration will retry on next launch" >&2
  local trash_backup="$HOME/.Trash/$app_name-before-$(date +%Y%m%d-%H%M%S)-$(uuidgen).app"
  if ! mv "$backup_app" "$trash_backup"; then
    echo "Previous bundle retained at: $backup_app" >&2
  fi
  echo "Reinstalled: $installed_app"
  echo "Source revision: $(/usr/libexec/PlistBuddy -c 'Print :SwitchGPTSourceRevision' \
    "$installed_app/Contents/Info.plist")"
}

case "$mode" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$app_binary"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$app_name\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$bundle_id\""
    ;;
  --verify|verify)
    open_app
    verify_process
    ;;
  --install|install)
    user_app_directory="$HOME/Applications"
    mkdir -p "$user_app_directory"
    installed_app="$user_app_directory/$app_name.app"
    if [[ -e "$installed_app" ]]; then
      echo "Existing app left untouched: $installed_app" >&2
      exit 1
    fi
    /usr/bin/ditto "$app_bundle" "$installed_app"
    echo "Installed: $installed_app"
    ;;
  --reinstall|reinstall)
    reinstall_app
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--install|--reinstall]" >&2
    exit 2
    ;;
esac
