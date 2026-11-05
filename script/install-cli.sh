#!/usr/bin/env bash
set -euo pipefail

# Install a stable command pointing into an already installed app bundle.
app_bundle="${1:-$HOME/Applications/switchgpt-sly.app}"
command_directory="${2:-$HOME/.local/bin}"
cli="$app_bundle/Contents/Helpers/switchgpt"
link="$command_directory/switchgpt"
if [[ ! -x "$cli" ]]; then
  echo "CLI not found in installed app: $app_bundle" >&2
  exit 1
fi
mkdir -p "$command_directory"
if [[ -e "$link" || -L "$link" ]]; then
  if [[ -L "$link" && "$(readlink "$link")" == "$cli" ]]; then
    echo "CLI already installed: $link"
    exit 0
  fi
  echo "Existing command left untouched: $link" >&2
  exit 1
fi
ln -s "$cli" "$link"
echo "Installed: $link"
echo "Ensure $command_directory is in PATH, then run: switchgpt --help"
