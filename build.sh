#!/usr/bin/env bash
# 编译 macs。产物落在本目录 bin/macs。
# 只需要 Xcode Command Line Tools 里的 swiftc,无第三方依赖。
#
#   ./build.sh              只编译
#   ./build.sh --install    编译并装到固定位置(~/.local/bin + ~/.dsh/skills)
#                           技能里引用的是 ~/.local/bin/macs,重编译后要再跑一次
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$DIR/bin"
swiftc -O "$DIR/src/macs.swift" -o "$DIR/bin/macs"
echo "built: $DIR/bin/macs"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/.local/bin"
  cp "$DIR/bin/macs" "$HOME/.local/bin/macs"
  mkdir -p "$HOME/.dsh/skills/mac-screen"
  cp "$DIR/SKILL.md" "$HOME/.dsh/skills/mac-screen/SKILL.md"
  echo "installed:"
  echo "  $HOME/.local/bin/macs"
  echo "  $HOME/.dsh/skills/mac-screen/SKILL.md"
fi
