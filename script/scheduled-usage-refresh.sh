#!/bin/bash
set -euo pipefail
umask 077

bundle_id="ai.shenliyuan.switchgpt-sly"
label="$bundle_id.scheduled-usage-refresh"
domain="gui/$(/usr/bin/id -u)"
service="$domain/$label"
agent_dir="$HOME/Library/LaunchAgents"
agent_plist="$agent_dir/$label.plist"
cli="$HOME/Applications/switchgpt-sly.app/Contents/Helpers/switchgpt"

fail() {
  echo "$*" >&2
  exit 1
}

if [[ $# -ne 1 || ! "$1" =~ ^(install|status|uninstall)$ ]]; then
  echo "Usage: $0 {install|status|uninstall}" >&2
  exit 2
fi

/bin/launchctl print "$domain" >/dev/null 2>&1 || fail "No macOS GUI login session is available for this user."
job="$(/bin/launchctl print "$service" 2>/dev/null || true)"
if [[ -n "$job" ]]; then
  loaded_plist="$(/usr/bin/awk '/^\tpath = / { sub(/^\tpath = /, ""); print; exit }' <<< "$job")"
  loaded_program="$(/usr/bin/awk '/^\tprogram = / { sub(/^\tprogram = /, ""); print; exit }' <<< "$job")"
  [[ "$loaded_plist" == "$agent_plist" && "$loaded_program" == "$cli" ]] \
    || fail "A different service uses $label. It was left untouched."
fi

if [[ "$1" == status ]]; then
  if [[ -n "$job" ]]; then
    echo "Registered: $service"
    /usr/bin/awk '/^\t(state|runs|last exit code|last terminating signal) = /' <<< "$job"
  elif [[ -e "$agent_plist" || -L "$agent_plist" ]]; then
    echo "The plist exists but the service is not loaded: $agent_plist"
  else
    echo "Scheduled usage refresh is not installed."
  fi
  exit 0
fi

if [[ "$1" == install ]]; then
  [[ -x "$cli" ]] || fail "Install the current local SwitchGPT build first."
  cli_help="$("$cli" --help)" || fail "Could not read the installed SwitchGPT command's help."
  [[ "$cli_help" == *'<quota|usage|refresh>'* ]] || fail "The installed SwitchGPT build does not support scheduled refresh."
  /bin/mkdir -p "$agent_dir"
elif [[ ! -e "$agent_plist" && ! -L "$agent_plist" ]]; then
  [[ -z "$job" ]] || fail "The service is registered without its plist. It was left untouched."
  echo "Scheduled usage refresh is not installed."
  exit 0
fi

[[ ! -L "$agent_dir" ]] || fail "The LaunchAgents directory is a symbolic link. It was left untouched."
work_dir="$(/usr/bin/mktemp -d "$agent_dir/.switchgpt-refresh.XXXXXX")"
candidate="$work_dir/daily.plist"
legacy="$work_dir/twice-daily.plist"
previous="$work_dir/previous.plist"
cleanup() {
  /bin/rm -f "$candidate" "$legacy" "$previous"
  /bin/rmdir "$work_dir"
}
trap cleanup EXIT

/bin/cat > "$candidate" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>
  <key>AssociatedBundleIdentifiers</key>
  <array><string>$bundle_id</string></array>
  <key>Program</key>
  <string></string>
  <key>ProgramArguments</key>
  <array>
    <string>refresh</string>
  </array>
  <key>StartCalendarInterval</key>
  <array>
    <dict><key>Hour</key><integer>9</integer><key>Minute</key><integer>0</integer></dict>
  </array>
  <key>StandardOutPath</key>
  <string>/dev/null</string>
  <key>StandardErrorPath</key>
  <string>/dev/null</string>
</dict>
</plist>
PLIST
/usr/bin/plutil -replace Program -string "$cli" "$candidate"
/usr/bin/plutil -insert ProgramArguments.0 -string "$cli" "$candidate"
/usr/bin/plutil -lint -s "$candidate"

old_schedule=false
if [[ -e "$agent_plist" || -L "$agent_plist" ]]; then
  [[ -f "$agent_plist" && ! -L "$agent_plist" ]] \
    || fail "An unexpected file exists at $agent_plist. It was left untouched."
  if ! /usr/bin/cmp -s "$candidate" "$agent_plist"; then
    /bin/cp "$candidate" "$legacy"
    /usr/bin/plutil -insert StartCalendarInterval.1 -json '{"Hour":21,"Minute":0}' "$legacy"
    if ! /usr/bin/cmp -s "$legacy" "$agent_plist"; then
      # Some plutil versions inserted the executable ahead of the old placeholder.
      /usr/bin/plutil -insert ProgramArguments.1 -string '' "$legacy"
      /usr/bin/cmp -s "$legacy" "$agent_plist" \
        || fail "An unexpected file exists at $agent_plist. It was left untouched."
    fi
    old_schedule=true
  fi
fi

stop_idle_job() {
  if [[ -n "$job" ]]; then
    local current_job
    current_job="$(/bin/launchctl print "$service")" \
      || fail "The registered service changed. Retry after checking its status."
    if /usr/bin/awk '/^\tpid = / { running = 1 } END { exit !running }' <<< "$current_job"; then
      fail "A refresh is running. Wait for it to finish before changing its schedule."
    fi
    /bin/launchctl bootout "$service" || fail "macOS could not unload scheduled usage refresh."
  fi
}

if [[ "$1" == uninstall ]]; then
  stop_idle_job
  /bin/rm "$agent_plist"
  echo "Removed scheduled usage refresh."
  exit 0
fi

if [[ -n "$job" && "$old_schedule" == false ]]; then
  [[ -f "$agent_plist" ]] || fail "The service is registered without its plist. It was left untouched."
  echo "Scheduled usage refresh is already installed."
  exit 0
fi

if [[ "$old_schedule" == true ]]; then
  /bin/ln "$agent_plist" "$previous"
  stop_idle_job
  if ! /bin/mv -f "$candidate" "$agent_plist"; then
    if [[ -n "$job" ]]; then
      /bin/launchctl bootstrap "$domain" "$agent_plist" || true
    fi
    fail "Could not update $agent_plist."
  fi
elif [[ ! -f "$agent_plist" ]]; then
  /bin/link "$candidate" "$agent_plist" || fail "Could not create $agent_plist without replacing an existing file."
fi
if ! /bin/launchctl bootstrap "$domain" "$agent_plist"; then
  if ! /bin/launchctl print "$service" >/dev/null 2>&1; then
    if [[ "$old_schedule" == true ]]; then
      if ! /bin/mv -f "$previous" "$agent_plist"; then
        trap - EXIT
        fail "Could not restore the previous plist. Its backup is at $previous."
      fi
      if [[ -n "$job" ]]; then
        /bin/launchctl bootstrap "$domain" "$agent_plist" \
          || fail "Restored the previous plist, but macOS could not reload it."
      fi
      fail "macOS did not register the daily schedule. Restored the previous schedule."
    elif [[ "$candidate" -ef "$agent_plist" ]]; then
      /bin/rm "$agent_plist"
    fi
  fi
  fail "macOS did not register scheduled usage refresh."
fi
echo "Installed scheduled usage refresh daily at 09:00 local time."
