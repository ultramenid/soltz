#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
# Runs `swift test` in every package. The plugin path works around Swift Testing's
# macro plugin not being found with Command Line Tools only (no Xcode).
cd "$(dirname "$0")/../Packages" || exit 1
status=0
for pkg in */; do
  [ -d "$pkg/Tests" ] || continue
  printf '%s: ' "${pkg%/}"
  line="$(cd "$pkg" && swift test -Xswiftc -plugin-path \
    -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing 2>&1 \
    | grep -E "Test run with|error:" | tail -1)"
  echo "${line:-FAILED}"
  # The run's own verdict: the pipeline's status is grep's, which is 0 for a failed run too.
  case "$line" in *" passed "*) ;; *) status=1 ;; esac
done
exit $status
