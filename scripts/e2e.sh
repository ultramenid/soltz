#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
# End-to-end run of build/test.noindex/SoltzTest.app (the app with its test harness built in) against a throwaway sshd: this Mac's /usr/sbin/sshd, run as the current user
# on 127.0.0.1 only, public key only, with everything it uses (host keys, client keys, authorized_keys, config,
# pid file, log, its sessions' ZDOTDIR and SCREENDIR) in one mktemp -d directory. Builds the bundle if
# it is missing or older than a source, runs `Soltz --e2e`, and always stops the server, ends what it started and
# deletes the directory, then checks that nothing is left and ~/.ssh/known_hosts was not touched.
#
# The app calls back into this script while it runs (`e2e.sh ctl <command>`, with SOLTZ_E2E_TMP set):
#   drop      kill the server side of every open connection (the listener stays)
#   stop      drop, then stop the server (the port then refuses connections)
#   start     start it again on the same port with the host key it last had
#   rekey     stop, then start it on the same port with the second host key
#   children  how many processes run under the listener
#   screens   how many GNU screen sessions the server's sessions left in SCREENDIR
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
script="$root/scripts/e2e.sh"

# Every process under `pid`, deepest last.
descendants() {
  for child in $(pgrep -P "$1" 2>/dev/null); do
    echo "$child"
    descendants "$child"
  done
}

listener() { cat "$tmp/sshd.pid" 2>/dev/null || true; }

# SIGKILL the sshd-session processes under the listener: every connection drops as if the network went away.
drop() {
  pid="$(listener)"
  [ -n "$pid" ] || return 0
  for p in $(descendants "$pid"); do
    case "$(ps -o comm= -p "$p" 2>/dev/null)" in *sshd*) kill -KILL "$p" 2>/dev/null || true ;; esac
  done
}

# Start sshd with host key $1 on the port in $tmp/port and wait until it answers.
start_server() {
  port="$(cat "$tmp/port")"
  cat >"$tmp/sshd_config" <<EOF
ListenAddress 127.0.0.1
Port $port
HostKey $1
PidFile $tmp/sshd.pid
AuthorizedKeysFile $tmp/authorized_keys
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
PermitUserRC no
PermitUserEnvironment no
PrintMotd no
PrintLastLog no
AllowTcpForwarding no
GatewayPorts no
AllowAgentForwarding no
AllowStreamLocalForwarding no
X11Forwarding no
PermitTunnel no
SetEnv ZDOTDIR=$tmp/zdot SCREENDIR=$tmp/screens
Subsystem sftp internal-sftp -d $tmp/work
EOF
  rm -f "$tmp/sshd.pid"
  echo "$1" >"$tmp/host_key_in_use"
  /usr/sbin/sshd -f "$tmp/sshd_config" -E "$tmp/sshd.log"
  i=0
  until [ -s "$tmp/sshd.pid" ] && nc -z 127.0.0.1 "$port" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -le 50 ] || { echo "sshd did not start:" >&2; cat "$tmp/sshd.log" >&2; return 1; }
    sleep 0.1
  done
}

stop_server() {
  pid="$(listener)"
  [ -n "$pid" ] || return 0
  drop
  kill "$pid" 2>/dev/null || true
  i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 50 ]; do i=$((i + 1)); sleep 0.1; done
  kill -KILL "$pid" 2>/dev/null || true
  rm -f "$tmp/sshd.pid"
}

screens() { SCREENDIR="$tmp/screens" screen -ls 2>/dev/null | awk '/\.soltz_/ {print $1}'; }

if [ "${1-}" = ctl ]; then
  tmp="${SOLTZ_E2E_TMP:?}"
  case "${2-}" in
    drop) drop ;;
    stop) stop_server ;;
    start) start_server "$(cat "$tmp/host_key_in_use")" ;;
    rekey) stop_server && start_server "$tmp/host_key2" ;;
    children) pid="$(listener)"; [ -n "$pid" ] && descendants "$pid" | wc -l | tr -d ' ' || echo 0 ;;
    screens) screens | wc -l | tr -d ' ' ;;
    *) echo "unknown ctl command: ${2-}" >&2; exit 2 ;;
  esac
  exit 0
fi

# Build the bundle when it is missing or a source changed since.
app="$root/build/test.noindex/SoltzTest.app/Contents/MacOS/Soltz"
if [ ! -x "$app" ] || [ -n "$(find "$root/App/Sources" "$root/App/Package.swift" "$root/Packages" \
  \( -name '*.swift' -o -name '*.a' \) -newer "$app" -not -path '*/.build/*' 2>/dev/null | head -1)" ]; then
  SOLTZ_HARNESS=1 sh "$root/scripts/bundle-app.sh"
fi

known="$HOME/.ssh/known_hosts"
known_before="$(stat -f '%m %z' "$known" 2>/dev/null || echo absent)"
# This user's temp dir: macOS mktemp always uses it (TMPDIR has no say), so the files the core's host-side wrappers
# make with mktemp and leave on purpose (zsh ZDOTDIR trampolines, screen/tmux rc files) land there.
user_tmp="$(getconf DARWIN_USER_TEMP_DIR)"
tmp="$(mktemp -d)"
touch "$tmp/.start"
port=""
status=1
app_pid=""

teardown() {
  set +e
  [ -n "$app_pid" ] && kill "$app_pid" 2>/dev/null && wait "$app_pid" 2>/dev/null
  # Persistent sessions' screens first (their window shells are not under the listener), then the server.
  for s in $(screens); do SCREENDIR="$tmp/screens" screen -S "$s" -X quit >/dev/null 2>&1; done
  stop_server
  sleep 0.3
  pkill -f "$tmp" 2>/dev/null
  sleep 0.2
  [ "$status" -eq 0 ] || { echo "--- sshd log ---"; tail -n 40 "$tmp/sshd.log" 2>/dev/null; }
  # What is still running with the temp dir in its arguments or environment (ps -E), read before the rm.
  snapshot="$(ps -axwwE -o pid=,command= 2>/dev/null)"
  left="$(printf '%s\n' "$snapshot" | grep -F -- "$tmp")"
  # mktemp entries made in this user's temp dir since the run began: the wrappers' files go, anything else is reported.
  wrappers=0
  strays=""
  for f in $(find "$user_tmp" -maxdepth 1 -name 'tmp.*' -newer "$tmp/.start" 2>/dev/null); do
    [ "${f##*/}" = "${tmp##*/}" ] && continue
    # Only what names Soltz as its maker (the wrappers' files say so on a line of their own): a temp entry of any
    # other program, whatever it holds, is left alone and reported.
    if grep -rqsx -e '# soltz' "$f"; then
      rm -rf "$f" && wrappers=$((wrappers + 1))
    else
      strays="$strays $f"
    fi
  done
  rm -rf "$tmp"
  fail=0
  if [ -n "$left" ]; then echo "[FAIL] cleanup: processes still running from the run:"; echo "$left"; fail=1
  else echo "[PASS] cleanup: no process left with the run's temp dir in its arguments or environment"; fi
  if [ -n "$port" ] && nc -z 127.0.0.1 "$port" 2>/dev/null; then echo "[FAIL] cleanup: port $port still answers"; fail=1
  elif [ -n "$port" ]; then echo "[PASS] cleanup: sshd stopped, port $port closed"; fi
  if [ -e "$tmp" ]; then echo "[FAIL] cleanup: $tmp still exists"; fail=1
  else echo "[PASS] cleanup: temp dir deleted"; fi
  echo "[INFO] cleanup: removed $wrappers mktemp files the core's host-side wrappers left in $user_tmp (it leaves them on purpose)"
  if [ -n "$strays" ]; then echo "[FAIL] cleanup: other new mktemp entries in $user_tmp, left alone:$strays"; fail=1
  else echo "[PASS] cleanup: no other new mktemp entry in this user's temp dir"; fi
  known_after="$(stat -f '%m %z' "$known" 2>/dev/null || echo absent)"
  if [ "$known_before" = "$known_after" ]; then echo "[PASS] cleanup: ~/.ssh/known_hosts unchanged (mtime size: $known_after)"
  else echo "[FAIL] cleanup: ~/.ssh/known_hosts changed: $known_before -> $known_after"; fail=1; fi
  [ "$fail" -eq 0 ] || status=1
  exit "$status"
}
trap teardown EXIT
# The app runs in the background so these interrupt the `wait` for it; teardown then ends it.
trap 'exit 130' INT TERM HUP

mkdir -p "$tmp/work" "$tmp/local"
# ZDOTDIR (sshd SetEnv): every zsh the server starts reads this empty folder instead of the user's rc files and keeps
# its history here (macOS /etc/zshrc: ${ZDOTDIR}/.zsh_history). SCREENDIR: screen sessions' sockets.
mkdir -m 700 "$tmp/screens" "$tmp/zdot"
ssh-keygen -q -t ed25519 -N '' -C soltz-e2e-host -f "$tmp/host_key"
ssh-keygen -q -t ed25519 -N '' -C soltz-e2e-host2 -f "$tmp/host_key2"
ssh-keygen -q -t ed25519 -N '' -C soltz-e2e-client -f "$tmp/client_key"
ssh-keygen -q -t ed25519 -N '' -C soltz-e2e-wrong -f "$tmp/wrong_key"
cp "$tmp/client_key.pub" "$tmp/authorized_keys"
# A free loopback port, picked by the kernel.
/usr/bin/python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])' >"$tmp/port"
port="$(cat "$tmp/port")"
start_server "$tmp/host_key"
echo "[INFO] sshd $(/usr/sbin/sshd -V 2>&1 | head -1) as $(id -un) on 127.0.0.1:$port (pid $(listener)), temp dir $tmp"

set +e
env -u SSH_AUTH_SOCK \
  SOLTZ_E2E_TMP="$tmp" SOLTZ_E2E_CTL="$script" SOLTZ_E2E_PORT="$port" SOLTZ_E2E_USER="$(id -un)" \
  SOLTZ_E2E_KEY="$tmp/client_key" SOLTZ_E2E_WRONG_KEY="$tmp/wrong_key" \
  SOLTZ_E2E_WORK="$tmp/work" SOLTZ_E2E_LOCAL="$tmp/local" \
  SOLTZ_E2E_HOST_FP="$(ssh-keygen -lf "$tmp/host_key.pub" | awk '{print $2}')" \
  SOLTZ_E2E_HOST2_FP="$(ssh-keygen -lf "$tmp/host_key2.pub" | awk '{print $2}')" \
  "$app" --e2e &
app_pid=$!
wait "$app_pid"
status=$?
app_pid=""
set -e
