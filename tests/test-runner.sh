#!/usr/bin/bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

runner="$work/runner"
cc -std=c17 -O2 -Wall -Wextra -Werror \
  -DRUNNER_TESTING -DREQUIRED_UID="$(id -u)" -DKILL_GRACE_MS=100 \
  -o "$runner" "$repo_root/native/ai-usage-pills-runner.c"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

run_expect() {
  local expected=$1
  local label=$2
  shift 2
  set +e
  "$@" >"$work/$label.out" 2>"$work/$label.err"
  local actual=$?
  set -e
  [[ $actual -eq $expected ]] || {
    cat "$work/$label.err" >&2
    fail "$label returned $actual, expected $expected"
  }
}
assert_process_gone() {
  local pid=$1
  local context=$2
  for _ in {1..20}; do
    if [[ ! -r /proc/$pid/stat ]] || [[ $(<"/proc/$pid/stat") == *") Z "* ]]; then
      return
    fi
    sleep 0.05
  done
  fail "$context left descendant $pid running"
}


missing="$work/missing"
run_expect 2 production-arguments "$repo_root/bin/ai-usage-pills-runner" invalid 65536


cat >"$work/good" <<'SCRIPT'
#!/usr/bin/bash
printf 'fallback'
SCRIPT
chmod 0755 "$work/good"

cat >"$work/non-executable" <<'SCRIPT'
#!/usr/bin/bash
printf 'wrong'
SCRIPT
chmod 0644 "$work/non-executable"

run_expect 0 fallback "$runner" 1000 65536 "$work/non-executable" "$work/good"
[[ $(<"$work/fallback.out") == fallback ]] || fail "non-executable candidate did not fall back"
[[ ! -s $work/fallback.err ]] || fail "rejected primary leaked diagnostics after fallback"

ln -s "$work/good" "$work/symlink"
run_expect 126 symlink "$runner" 1000 65536 "$work/symlink" "$missing"
[[ $(<"$work/symlink.err") == *"rejected non-regular candidate"* ]] || fail "symlink was not rejected"

cp "$work/good" "$work/writable"
chmod 0775 "$work/writable"
run_expect 126 writable "$runner" 1000 65536 "$work/writable" "$missing"
[[ $(<"$work/writable.err") == *"rejected writable candidate"* ]] || fail "group-writable candidate was not rejected"

run_expect 126 unavailable "$runner" 1000 65536 "$work/non-executable" "$missing"
run_expect 2 internal-setup env RUNNER_TEST_FAIL_SETUP=1 \
  "$runner" 1000 65536 "$work/good" "$missing"


for backend_status in 124 127 137; do
  cat >"$work/backend-status" <<SCRIPT
#!/usr/bin/bash
exit $backend_status
SCRIPT
  chmod 0755 "$work/backend-status"
  run_expect 1 "backend-$backend_status" "$runner" 1000 65536 "$work/backend-status" "$missing"
done

cat >"$work/first" <<'SCRIPT'
#!/usr/bin/bash
printf 'first'
SCRIPT
chmod 0644 "$work/first"
cat >"$work/second" <<'SCRIPT'
#!/usr/bin/bash
printf 'second'
SCRIPT
chmod 0755 "$work/second"
run_expect 0 reset-fallback "$runner" 1000 65536 "$work/first" "$work/second"
[[ $(<"$work/reset-fallback.out") == second ]] || fail "initial fallback chose the wrong candidate"
[[ ! -s $work/reset-fallback.err ]] || fail "fallback diagnostics polluted backend stderr"
chmod 0755 "$work/first"
run_expect 0 reset-primary "$runner" 1000 65536 "$work/first" "$work/second"
[[ $(<"$work/reset-primary.out") == first ]] || fail "new invocation did not reset candidate selection"

cat >"$work/exact-limit" <<'SCRIPT'
#!/usr/bin/python3
import os
os.write(1, b"x" * 65536)
SCRIPT
cat >"$work/sustained-overflow" <<'SCRIPT'
#!/usr/bin/python3
import os
chunk = b"x" * 8192
while True:
    os.write(1, chunk)
SCRIPT
chmod 0755 "$work/sustained-overflow"
run_expect 125 sustained-overflow "$runner" 1000 65536 "$work/sustained-overflow" "$missing"
[[ $(wc -c <"$work/sustained-overflow.out") -eq 65536 ]] || fail "sustained output was not capped"

chmod 0755 "$work/exact-limit"
run_expect 0 exact-limit "$runner" 1000 65536 "$work/exact-limit" "$missing"
[[ $(wc -c <"$work/exact-limit.out") -eq 65536 ]] || fail "exact-limit output was not preserved"

cat >"$work/over-limit" <<'SCRIPT'
#!/usr/bin/python3
import os
os.write(1, b"x" * 65537)
SCRIPT
chmod 0755 "$work/over-limit"
run_expect 125 over-limit "$runner" 1000 65536 "$work/over-limit" "$missing"
[[ $(wc -c <"$work/over-limit.out") -eq 65536 ]] || fail "overflow output was not capped"

cat >"$work/stderr-over-limit" <<'SCRIPT'
#!/usr/bin/python3
import os
os.write(2, b"x" * 65537)
SCRIPT
chmod 0755 "$work/stderr-over-limit"
run_expect 125 stderr-over-limit "$runner" 1000 65536 "$work/stderr-over-limit" "$missing"
[[ $(wc -c <"$work/stderr-over-limit.err") -eq 65536 ]] || fail "stderr overflow was not capped"

cat >"$work/split-utf8" <<'SCRIPT'
#!/usr/bin/python3
import os
import time
os.write(1, b"\xe2")
time.sleep(0.02)
os.write(1, b"\x82\xac\n")
SCRIPT
chmod 0755 "$work/split-utf8"
run_expect 0 split-utf8 "$runner" 1000 65536 "$work/split-utf8" "$missing"
printf '\342\202\254\n' >"$work/expected-utf8"
cmp "$work/expected-utf8" "$work/split-utf8.out" || fail "UTF-8 bytes changed across reads"

cat >"$work/orphan" <<'SCRIPT'
#!/usr/bin/python3
import os
import subprocess
child = subprocess.Popen(
    ["/usr/bin/sleep", "30"],
    stdin=subprocess.DEVNULL,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)
with open(os.environ["PID_FILE"], "w", encoding="ascii") as marker:
    marker.write(str(child.pid))
SCRIPT
chmod 0755 "$work/orphan"
orphan_pid_file="$work/orphan.pid"
run_expect 0 orphan-cleanup env PID_FILE="$orphan_pid_file" "$runner" 1000 65536 "$work/orphan" "$missing"
[[ -s $orphan_pid_file ]] || fail "successful backend did not record its descendant"
assert_process_gone "$(<"$orphan_pid_file")" "successful backend"

cat >"$work/timeout" <<'SCRIPT'
#!/usr/bin/python3
import os
import subprocess
import time
child = subprocess.Popen(["/usr/bin/sleep", "30"])
with open(os.environ["PID_FILE"], "w", encoding="ascii") as marker:
    marker.write(str(child.pid))
time.sleep(30)
SCRIPT
chmod 0755 "$work/timeout"
pid_file="$work/descendant.pid"
run_expect 124 timeout env PID_FILE="$pid_file" "$runner" 200 65536 "$work/timeout" "$missing"
[[ -s $pid_file ]] || fail "timeout backend did not record its descendant"
assert_process_gone "$(<"$pid_file")" "timeout"
cat >"$work/timeout-flood" <<'SCRIPT'
#!/usr/bin/python3
import os
import signal
import time
def flood(_signal, _frame):
    chunk = b"x" * 8192
    while True:
        os.write(1, chunk)
signal.signal(signal.SIGTERM, flood)
while True:
    time.sleep(1)
SCRIPT
chmod 0755 "$work/timeout-flood"
run_expect 124 timeout-flood "$runner" 200 65536 "$work/timeout-flood" "$missing"

printf 'runner regressions: ok\n'
