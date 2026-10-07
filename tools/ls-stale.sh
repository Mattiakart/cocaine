#!/bin/zsh
# Lists Launch Services entries for Cocaine bundles (bundle id local.cocaine.*) other than the installed copy: build
# folders, test copies in temporary folders, copies already deleted. A stale entry can be what `open -b local.cocaine.toggle`
# (Homebrew's reopen after an upgrade) or "Open with" picks.
#   tools/ls-stale.sh            list them (read-only)
#   tools/ls-stale.sh --apply    forget those whose folder no longer exists, or that are under a temporary folder
#                                (never /Applications/Cocaine.app or ~/Applications/Cocaine.app)
set -uo pipefail
LSR=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
APPLY=0; [ "${1:-}" = --apply ] && APPLY=1
n=0
"$LSR" -dump 2>/dev/null | awk '/^path:/{p=$0; sub(/^path: */,"",p); sub(/ \(0x[0-9a-f]+\)$/,"",p)} /^identifier: *local\.cocaine\./{print p}' | sort -u |
while IFS= read -r p; do
  case "$p" in /Applications/Cocaine.app|"$HOME/Applications/Cocaine.app") continue ;; esac
  stale=0
  [ -e "$p" ] || stale=1
  case "$p" in /private/var/folders/*|/var/folders/*|/private/tmp/*|/tmp/*) stale=1 ;; esac
  n=$((n+1))
  if [ "$APPLY" = 1 ] && [ "$stale" = 1 ]; then "$LSR" -u "$p" 2>/dev/null; print -r -- "forgot  $p"
  else print -r -- "$([ "$stale" = 1 ] && echo stale || echo kept)   $p"; fi
done
