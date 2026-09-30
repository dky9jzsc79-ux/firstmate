#!/usr/bin/env bash
# Before/after: run the same scenario through (a) the pre-feature base resolver,
# (b) the pre-ci-fix resolver, and (c) the target resolver, each staged as a
# copy of bin/ with only fm-bearings-board.sh swapped, against fresh lab homes.
set -u
ROOT=/home/captain/.no-mistakes/worktrees/c398aff253bb/01M3T2Z1W26M0HV69MKB3DTBDH
EV=/home/captain/.no-mistakes/evidence/01M3T2Z1W26M0HV69MKB3DTBDH
LABROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); STUBBIN="$LABROOT/stubbin"; mkdir -p "$STUBBIN"
sed -n "/^cat > \"\$STUBBIN\/lavish-axi\" <<'SH'$/,/^SH$/p" "$EV/live-drive.sh" | sed '1d;$d' > "$STUBBIN/lavish-axi"; chmod +x "$STUBBIN/lavish-axi"
HOMES=()
cleanup() { for h in "${HOMES[@]}"; do FM_HOME="$h" FM_PROCEVENT_CLAIM_ROOT="$h/procevent-claims" LAVISH_FAKE_STATE="$h/lavish-state" PATH="$STUBBIN:$PATH" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true; done; rm -rf "$LABROOT"; }
trap cleanup EXIT
stage() {  # <rev> -> prints staged bin dir
  local d="$LABROOT/stage-$1"; mkdir -p "$d"; cp -r "$ROOT/bin" "$d/bin"; ln -s "$ROOT/.agents" "$d/.agents"
  (cd "$ROOT" && git show "$1:bin/fm-bearings-board.sh") > "$d/bin/fm-bearings-board.sh"; chmod +x "$d/bin/fm-bearings-board.sh"; printf '%s\n' "$d/bin"
}
for rev in 23e55847 f20fb4b4 04468233; do
  bin=$(stage "$rev")
  for scen in home-config-absolute override-is-regular-file; do
    h="$LABROOT/$rev-$scen"; "$ROOT/bin/fm-lab-home.sh" create "$h" >/dev/null; mkdir -p "$h/lavish-state" "$h/procevent-claims" "$h/.lavish"; HOMES+=("$h")
    sed -n '/^write_valid_payload() {/,/^EOF$/p' "$ROOT/tests/fm-bearings-board.test.sh" | sed '1,2d;$d' > "$h/payload.json"
    cp "$ROOT/.agents/skills/bearings/assets/board-template.html" "$h/custom.html"; printf '\n<!-- home-template-marker -->\n' >> "$h/custom.html"
    printf 'existing board\n' > "$h/.lavish/bearings-board.html"
    extra=()
    case $scen in
      home-config-absolute) printf '%s\n' "$h/custom.html" > "$h/config/bearings-board-template" ;;
      override-is-regular-file) printf 'not a directory\n' > "$h/alt-config"; extra=(FM_CONFIG_OVERRIDE="$h/alt-config") ;;
    esac
    out=$(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_BEARINGS_BOARD_TEMPLATE \
        PATH="$STUBBIN:$PATH" FM_HOME="$h" FM_PROCEVENT_CLAIM_ROOT="$h/procevent-claims" LAVISH_FAKE_STATE="$h/lavish-state" LAVISH_AXI_STATE_DIR="$h/lavish-state" "${extra[@]}" \
        "$bin/fm-bearings-board.sh" build "$h/payload.json" 2>&1); rc=$?
    b="$h/.lavish/bearings-board.html"
    if [ "$(cat "$b")" = 'existing board' ]; then state='board untouched'
    elif grep -q home-template-marker "$b"; then state='published HOME template'
    else state='published SHIPPED template'; fi
    printf '%-9s %-26s rc=%s  %s\n          %s\n' "$rev" "$scen" "$rc" "$state" "$(printf '%s' "$out" | grep -E '^fm-bearings-board:|^board:' | head -1)"
  done
done
