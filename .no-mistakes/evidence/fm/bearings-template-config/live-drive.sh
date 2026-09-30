#!/usr/bin/env bash
# Manual live drive of bin/fm-bearings-board.sh template selection against
# disposable lab homes. The real builder runs unmodified; only the vendor
# lavish-axi CLI is replaced by a local stub so no session is opened on the
# operator's shared Lavish server. Every assertion reads the board the real
# builder published (or refused to publish).
set -u
ROOT=/home/captain/.no-mistakes/worktrees/c398aff253bb/01M3T2Z1W26M0HV69MKB3DTBDH
EV=/home/captain/.no-mistakes/evidence/01M3T2Z1W26M0HV69MKB3DTBDH
BOARD="$ROOT/bin/fm-bearings-board.sh"
SHIPPED="$ROOT/.agents/skills/bearings/assets/board-template.html"
LABROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
STUBBIN="$LABROOT/stubbin"
mkdir -p "$STUBBIN"
HOMES=()
FAILS=0
cleanup() {
  local h
  for h in "${HOMES[@]}"; do
    FM_HOME="$h" FM_PROCEVENT_CLAIM_ROOT="$h/procevent-claims" LAVISH_FAKE_STATE="$h/lavish-state" \
      PATH="$STUBBIN:$PATH" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  done
  rm -rf "$LABROOT"
}
trap cleanup EXIT

cat > "$STUBBIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
# Local stand-in for the vendor lavish-axi CLI (shapes of lavish-axi 0.1.61+).
set -u
state=${LAVISH_FAKE_STATE:?}
emit() { printf 'session:\n  file: %s\n  url: "http://127.0.0.1:4387/session/0123456789abcdef"\n  status: %s\n' "$1" "$2"; }
case "${1-}" in
  --version) printf '0.1.61\n'; exit 0 ;;
  poll) limit=60; while [ ! -e "$state/poll-trigger" ]; do [ "$SECONDS" -lt "$limit" ] || exit 75; sleep 0.05; done; printf 'session:\n  status: ended\n'; exit 0 ;;
  '') printf 'sessions[1]{file,status,url,pending_prompts}:\n'
      if [ -s "$state/open" ]; then while IFS= read -r l; do [ -n "$l" ] && printf '  %s,open,"http://127.0.0.1:4387/session/0123456789abcdef",0\n' "$l"; done < "$state/open"; fi; exit 0 ;;
  end) : > "$state/open"; printf 'session:\n  status: ended\n'; exit 0 ;;
esac
file=$1; real=$(cd "$(dirname "$file")" && pwd -P)/$(basename "$file")
printf '%s\n' "$real" > "$state/open"
jq -n --arg file "$real" '{sessions:{"0123456789abcdef":{file:$file,url:"http://127.0.0.1:4387/session/0123456789abcdef"}}}' > "$state/state.json"
emit "$real" opened
SH
chmod +x "$STUBBIN/lavish-axi"

payload() {  # <path>
  sed -n '/^write_valid_payload() {/,/^EOF$/p' "$ROOT/tests/fm-bearings-board.test.sh" | sed '1,2d;$d' > "$1"
  jq empty "$1"
}
extract_payload() { sed -n '/<script id="bearings-data" type="application\/json">/,/<\/script>/p' "$1" | sed '1d;$d'; }

new_home() {  # <name>  -> prints lab home path
  local h="$LABROOT/$1"
  "$ROOT/bin/fm-lab-home.sh" create "$h" >/dev/null || { echo "cannot create lab home $h" >&2; exit 1; }
  mkdir -p "$h/lavish-state" "$h/procevent-claims"
  payload "$h/payload.json"
  HOMES+=("$h")
  printf '%s\n' "$h"
}
# Run the real builder with the lab home and a clean environment (no fleet
# overrides inherited), printing the transcript.
build() {  # <home> [VAR=value ...]
  local h=$1; shift
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
      -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_BEARINGS_BOARD_TEMPLATE \
      PATH="$STUBBIN:$PATH" FM_HOME="$h" FM_PROCEVENT_CLAIM_ROOT="$h/procevent-claims" \
      LAVISH_FAKE_STATE="$h/lavish-state" LAVISH_AXI_STATE_DIR="$h/lavish-state" "$@" \
      "$BOARD" build "$h/payload.json" 2>&1
}
custom_template() {  # <path>  - shipped template plus a visible home banner
  cp "$SHIPPED" "$1"
  perl -0pi -e 's{<body([^>]*)>}{<body$1>\n<div id="home-template-banner" style="background:#b91c1c;color:#fff;font:700 22px/1.4 system-ui;padding:14px 20px;text-align:center">HOME-LOCAL TEMPLATE (config/bearings-board-template)</div>}' "$1"
  grep -q 'home-template-banner' "$1"
}
report() {  # <scenario> <pass|fail> <detail>
  printf '\n=== %s: %s ===\n%s\n' "$1" "$2" "$3"
  [ "$2" = pass ] || FAILS=$((FAILS + 1))
}
show() { printf -- '--- %s\n%s\n' "$1" "$2"; }

# ---------------------------------------------------------------- S1 fallback
h=$(new_home fallback-no-config-file)
out=$(build "$h"); rc=$?
show "transcript (no config file; config/ dir present)" "$out"
b="$h/.lavish/bearings-board.html"
if [ $rc -eq 0 ] && [ -f "$b" ] && ! grep -q home-template-banner "$b" \
   && extract_payload "$b" | jq -e '.schema=="fm-bearings-board.v1"' >/dev/null \
   && cmp -s <(sed '/__FM_BEARINGS_BOARD_DATA__/d' "$SHIPPED") <(sed '/<script id="bearings-data"/,/<\/script>/{/^<script/!{/^<\/script>/!d}}' "$b" | sed '/__FM_BEARINGS_BOARD_DATA__/d' ); then
  report "S1a shipped fallback (config file absent)" pass "rc=0; board published from shipped template; payload round-trips"
else
  report "S1a shipped fallback (config file absent)" fail "rc=$rc"
fi
h=$(new_home fallback-no-config-dir); rmdir "$h/config"
out=$(build "$h"); rc=$?
show "transcript (no config directory at all)" "$out"
b="$h/.lavish/bearings-board.html"
if [ $rc -eq 0 ] && [ -f "$b" ] && extract_payload "$b" | jq -e '.schema=="fm-bearings-board.v1"' >/dev/null; then
  report "S1b shipped fallback (config directory absent)" pass "rc=0; board published; payload round-trips"
else report "S1b shipped fallback (config directory absent)" fail "rc=$rc"; fi

# ---------------------------------------------------------------- S2 absolute
h=$(new_home absolute)
mkdir -p "$h/custom templates"; custom_template "$h/custom templates/board.html"
printf '%s\n' "$h/custom templates/board.html" > "$h/config/bearings-board-template"
show "config/bearings-board-template" "$(cat "$h/config/bearings-board-template")"
out=$(build "$h"); rc=$?
show "transcript" "$out"
b="$h/.lavish/bearings-board.html"
if [ $rc -eq 0 ] && grep -q 'HOME-LOCAL TEMPLATE' "$b" && extract_payload "$b" | jq -e '.schema=="fm-bearings-board.v1" and (.captains_call|length)==2' >/dev/null \
   && ! grep -qxF '__FM_BEARINGS_BOARD_DATA__' "$b"; then
  report "S2 absolute config path selects the home template" pass "rc=0; published board carries the home banner, no leftover slot, payload round-trips"
  cp "$b" "$EV/built-board-home-template.html"
  ABS_BOARD="$b"; ABS_HOME="$h"
else report "S2 absolute config path selects the home template" fail "rc=$rc"; fi

# Rebuild with the same home: the configured template is re-read on every build
# (survives repeated builds without the env var).
out2=$(build "$h"); rc2=$?
show "rebuild transcript" "$out2"
if [ $rc2 -eq 0 ] && grep -q 'HOME-LOCAL TEMPLATE' "$b"; then
  report "S2b rebuild keeps using the home template without FM_BEARINGS_BOARD_TEMPLATE" pass "rc=0; banner still present after rebuild"
else report "S2b rebuild keeps using the home template" fail "rc=$rc2"; fi

# ---------------------------------------------------------------- S3 relative
h=$(new_home relative)
mkdir -p "$h/custom templates"; custom_template "$h/custom templates/board.html"
printf '%s' 'custom templates/board.html' > "$h/config/bearings-board-template"   # no final newline
cd /  # cwd must not matter: relative resolves against FM_HOME, not $PWD
out=$(build "$h"); rc=$?; cd "$ROOT"
show "config (no trailing newline): $(cat "$h/config/bearings-board-template")" "$out"
b="$h/.lavish/bearings-board.html"
if [ $rc -eq 0 ] && grep -q 'HOME-LOCAL TEMPLATE' "$b" && extract_payload "$b" | jq -e '.schema=="fm-bearings-board.v1"' >/dev/null; then
  report "S3 FM_HOME-relative config path (run from cwd=/)" pass "rc=0; home banner present"
else report "S3 FM_HOME-relative config path" fail "rc=$rc"; fi

# ---------------------------------------------------------------- S4 FM_CONFIG_OVERRIDE
h=$(new_home config-override)
mkdir -p "$h/custom templates" "$h/alt-config"; custom_template "$h/custom templates/board.html"
printf '%s\n' "$h/missing.html" > "$h/config/bearings-board-template"           # must be ignored
printf '%s\n' 'custom templates/board.html' > "$h/alt-config/bearings-board-template"  # relative -> FM_HOME
out=$(build "$h" FM_CONFIG_OVERRIDE="$h/alt-config"); rc=$?
show "transcript (FM_CONFIG_OVERRIDE=alt-config; home config names a missing file)" "$out"
b="$h/.lavish/bearings-board.html"
if [ $rc -eq 0 ] && grep -q 'HOME-LOCAL TEMPLATE' "$b"; then
  report "S4 FM_CONFIG_OVERRIDE directory wins; relative path resolves against FM_HOME" pass "rc=0; alt-config template used, home config ignored"
else report "S4 FM_CONFIG_OVERRIDE directory wins" fail "rc=$rc"; fi
# Reverse: with the override set, a home config alone must NOT be honored.
h=$(new_home config-override-ignores-home)
mkdir -p "$h/custom templates" "$h/alt-config"; custom_template "$h/custom templates/board.html"
printf '%s\n' "$h/custom templates/board.html" > "$h/config/bearings-board-template"
out=$(build "$h" FM_CONFIG_OVERRIDE="$h/alt-config"); rc=$?
show "transcript (override dir has no config; home config has a valid template)" "$out"
b="$h/.lavish/bearings-board.html"
if [ $rc -eq 0 ] && ! grep -q 'HOME-LOCAL TEMPLATE' "$b"; then
  report "S4b with FM_CONFIG_OVERRIDE set, the home config is not consulted" pass "rc=0; shipped template published"
else report "S4b with FM_CONFIG_OVERRIDE set, the home config is not consulted" fail "rc=$rc"; fi

# ---------------------------------------------------------------- S5 env override wins
h=$(new_home env-wins)
mkdir -p "$h/custom templates"; custom_template "$h/custom templates/board.html"
printf '%s\n' "$h/missing.html" > "$h/config/bearings-board-template"
out=$(build "$h" FM_BEARINGS_BOARD_TEMPLATE="$h/custom templates/board.html"); rc=$?
show "transcript (FM_BEARINGS_BOARD_TEMPLATE set; config names a missing file)" "$out"
b="$h/.lavish/bearings-board.html"
if [ $rc -eq 0 ] && grep -q 'HOME-LOCAL TEMPLATE' "$b"; then
  report "S5 FM_BEARINGS_BOARD_TEMPLATE (tests-only) still wins over config" pass "rc=0"
else report "S5 FM_BEARINGS_BOARD_TEMPLATE still wins over config" fail "rc=$rc"; fi

# ---------------------------------------------------------------- S6 adversarial: FM_CONFIG_OVERRIDE unusable
for kind in regular-file dangling-symlink missing unreadable-dir; do
  h=$(new_home "override-$kind"); ov="$h/alt-config"
  mkdir -p "$h/.lavish"; printf 'existing board\n' > "$h/.lavish/bearings-board.html"
  case $kind in
    regular-file) printf 'not a directory\n' > "$ov" ;;
    dangling-symlink) ln -s "$h/absent" "$ov" ;;
    missing) ;;
    unreadable-dir) mkdir "$ov"; chmod 000 "$ov"; if [ -r "$ov" ] && [ -x "$ov" ]; then report "S6 $kind" pass "skipped: this user can read mode-000 dirs"; continue; fi ;;
  esac
  out=$(build "$h" FM_CONFIG_OVERRIDE="$ov"); rc=$?
  show "transcript ($kind)" "$out"
  if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q 'FM_CONFIG_OVERRIDE' && printf '%s' "$out" | grep -qF "$ov" \
     && [ "$(cat "$h/.lavish/bearings-board.html")" = 'existing board' ] && [ -z "$(ls -A "$h/.lavish" | grep -v '^bearings-board.html$')" ]; then
    report "S6 unusable FM_CONFIG_OVERRIDE ($kind) refuses, names variable+path, board untouched" pass "rc=$rc"
  else report "S6 unusable FM_CONFIG_OVERRIDE ($kind)" fail "rc=$rc; .lavish=$(ls -A "$h/.lavish" | tr '\n' ' ')"; fi
done

# ---------------------------------------------------------------- S7 adversarial: bad configured template
for kind in missing symlink slotless duplicate-slot directory empty-config multiline-config config-is-dir crlf-config; do
  h=$(new_home "tmpl-$kind"); cfg="$h/config/bearings-board-template"; sel="$h/custom.html"
  mkdir -p "$h/.lavish"; printf 'existing board\n' > "$h/.lavish/bearings-board.html"
  printf '%s\n' "$sel" > "$cfg"
  case $kind in
    missing) ;;
    symlink) ln -s "$SHIPPED" "$sel" ;;
    slotless) printf '<html>no slot</html>\n' > "$sel" ;;
    duplicate-slot) printf '__FM_BEARINGS_BOARD_DATA__\n__FM_BEARINGS_BOARD_DATA__\n' > "$sel" ;;
    directory) mkdir "$sel" ;;
    empty-config) : > "$cfg" ;;
    multiline-config) printf '%s\n%s\n' "$sel" "$sel" > "$cfg" ;;
    config-is-dir) rm "$cfg"; mkdir "$cfg" ;;
    crlf-config) cp "$SHIPPED" "$sel"; printf '%s\r\n' "$sel" > "$cfg" ;;
  esac
  out=$(build "$h"); rc=$?
  show "transcript ($kind)" "$out"
  if [ $rc -ne 0 ] && printf '%s' "$out" | grep -qF "$cfg" && [ "$(cat "$h/.lavish/bearings-board.html")" = 'existing board' ]; then
    case $kind in
      empty-config|multiline-config|config-is-dir|crlf-config) report "S7 invalid template config ($kind) refuses, names config, board untouched" pass "rc=$rc" ;;
      *) if printf '%s' "$out" | grep -qF "$sel"; then report "S7 invalid template ($kind) refuses, names config+resolved path, board untouched" pass "rc=$rc"; else report "S7 invalid template ($kind)" fail "resolved path missing from message"; fi ;;
    esac
  else report "S7 invalid template config ($kind)" fail "rc=$rc"; fi
done

# ---------------------------------------------------------------- S8 screenshot of the home-template board
if [ -n "${ABS_BOARD:-}" ]; then
  export CHROME_DEVTOOLS_AXI_SESSION=fm-test-bearings
  chrome-devtools-axi open "file://$ABS_BOARD" >/dev/null 2>&1 && chrome-devtools-axi resize 1280 900 >/dev/null 2>&1
  chrome-devtools-axi wait 1500 >/dev/null 2>&1
  banner=$(chrome-devtools-axi eval 'document.getElementById("home-template-banner")?.textContent + " | cards=" + document.querySelectorAll("[data-key],.card,article").length + " | title=" + document.title' 2>&1)
  show "browser eval" "$banner"
  chrome-devtools-axi screenshot "$EV/board-home-template.png" 2>&1 | tail -2
  chrome-devtools-axi stop >/dev/null 2>&1 || true
fi

printf '\nTOTAL FAILURES: %d\n' "$FAILS"
