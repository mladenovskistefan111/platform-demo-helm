#!/usr/bin/env bash
# The ONE implementation of "what does a promotion to stage / prod do", shared by the three promotion workflows:
#   promote-stage.yaml  (automatic: a dev change)     promote-prod.yaml  (automatic: a stage change)     promote.yaml  (the manual form)
#
#   promote.sh plan      read-only. Decides which apps are promoted, to which version, and prints it (run summary + job outputs).
#   promote.sh recheck   runs AFTER the approval click: the plan is recomputed from the current main and must still be what was approved.
#   promote.sh result    after the promotions: links the pull request of every app.
#
# Environment (all):  TARGET_ENV = stage | prod        GITHUB_STEP_SUMMARY, GITHUB_OUTPUT (default /dev/null)
# plan:     MODE = auto | manual
#           auto    BEFORE (push event "before"), SHA (default HEAD). The apps are the ones whose image.digest changed in the push
#                   (rollback commits do not count) plus the ones still waiting from an earlier change (see pending_apps).
#           manual  APP = an app name or `all`, VERSION (stage: empty = computed; prod: empty, or equal to stage's)
# recheck:  ITEMS (the approved plan, JSON), VERSION (as in plan)
# result:   ITEMS, PROMOTE_RESULT (result of the promotion jobs), SOURCE_SHA, GH_TOKEN, GITHUB_REPOSITORY
#
# The digest is read from the PREVIOUS environment's file in the checkout (stage <- dev, prod <- stage). Nothing is rebuilt and the
# registry is never asked for "the newest". Tests: .github/scripts/test-promote.sh
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR source=promotion-policy.sh
source "$here/promotion-policy.sh"

SEMVER='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
SUMMARY=${GITHUB_STEP_SUMMARY:-/dev/null}
OUT=${GITHUB_OUTPUT:-/dev/null}
VERSION=${VERSION:-}
problems=0

problem() { echo "::error::$1"; problems=$((problems + 1)); }
short() { echo "${1:0:19}"; }
digest_at() { { git show "$1:$2" 2> /dev/null || true; } | img_digest; } # digest of a file at a revision (empty when absent)

init_env() {
  case "${TARGET_ENV:-}" in
    stage) PREV=dev ;;
    prod) PREV=stage ;;
    *) echo "::error::env must be stage or prod (got '${TARGET_ENV:-}')."; exit 1 ;;
  esac
  [ "${GITHUB_REF:-refs/heads/main}" = refs/heads/main ] || { echo "::error::Promotions run from main (this run is for $GITHUB_REF)."; exit 1; }
  if [ -n "$VERSION" ] && ! [[ "$VERSION" =~ $SEMVER ]]; then echo "::error::version must be X.Y.Z (got '$VERSION')."; exit 1; fi
}

# The next PATCH after the newest <app>-vX.Y.Z tag of this repository (none: 1.0.0). $2 = the version already in the stage file, if any:
# a version that is in stage but whose tag is not made yet (stage-release.yaml runs after the merge) counts as taken.
next_version() {
  local newest
  newest=$({ git tag --list "$1-v*" | sed -n "s/^$1-v//p"; [ -z "${2:-}" ] || echo "$2"; } | grep -E "$SEMVER" | sort -V | tail -n 1 || true)
  if [ -z "$newest" ]; then echo 1.0.0; return; fi
  local maj min pat
  IFS=. read -r maj min pat <<< "$newest"
  echo "$maj.$min.$((pat + 1))"
}

# ---- automatic runs: which apps? ------------------------------------------------------------------------------------------------

# Apps whose image.digest changed in the commits of the push (BEFORE..SHA), rollback commits excluded.
changed_apps() {
  local sha=${SHA:-HEAD} before=${BEFORE:-} c parent f subject
  local -a commits=()
  if [[ "$before" =~ ^0*$ ]] || ! git cat-file -e "$before^{commit}" 2> /dev/null; then
    commits=("$(git rev-parse "$sha")") # new branch, or a history we do not have: only the tip
  else
    mapfile -t commits < <(git rev-list --reverse "$before..$sha")
  fi
  for c in "${commits[@]}"; do
    subject=$(git log -1 --format=%s "$c")
    [[ "$subject" != rollback\(* ]] || continue
    parent=$(git rev-parse --verify --quiet "$c^" || git hash-object -t tree /dev/null)
    while read -r f; do
      [ -n "$f" ] || continue
      [ -n "$(digest_at "$c" "$f")" ] || continue
      [ "$(digest_at "$c" "$f")" != "$(digest_at "$parent" "$f")" ] || continue
      basename "$f" .yaml
    done < <(git diff --name-only --no-renames "$parent" "$c" -- "envs/$PREV/values/*.yaml")
  done | sort -u
}

# Apps still waiting from an EARLIER change: the previous environment differs from the target, the last change of its digest is not a
# rollback, and it is newer than the last change of the target's digest. A newer run replaces a waiting older one, so without this an
# app of the replaced run would silently never be offered again. A target that was rolled back later than the change stays as it is.
pending_apps() {
  local f app src dst sd dd cs ct
  for f in envs/"$PREV"/values/*.yaml; do
    [ -f "$f" ] || continue
    app=$(basename "$f" .yaml); src=$f; dst="envs/$TARGET_ENV/values/$app.yaml"
    sd=$(img_digest < "$src"); [ -n "$sd" ] && [ -f "$dst" ] || continue
    dd=$(img_digest < "$dst"); [ "$sd" != "$dd" ] || continue
    cs=$(git log -1 --format=%H -G'^[[:space:]]+digest:' HEAD -- "$src"); [ -n "$cs" ] || continue
    [[ "$(git log -1 --format=%s "$cs")" != rollback\(* ]] || continue
    ct=$(git log -1 --format=%H -G'^[[:space:]]+digest:' HEAD -- "$dst")
    if [ -n "$ct" ]; then
      [ "$ct" != "$cs" ] || continue                       # one commit changed both: not waiting
      git merge-base --is-ancestor "$ct" "$cs" || continue # the target changed later than the source: it was rolled back on purpose
    fi
    echo "$app"
  done
}

# ---- one app ----------------------------------------------------------------------------------------------------------------------

# plan_app <app>   Sets ITEM (JSON) and NOTE. Returns 0 when the target has to change, 2 when it already has what
# the previous environment has (or the app has no target file in a list), 1 on a problem (reported with ::error::).
plan_app() {
  local app=$1 src dst sd dd dv sv st expected ver="" need=false how=""
  src="envs/$PREV/values/$app.yaml"; dst="envs/$TARGET_ENV/values/$app.yaml"
  ITEM=""; NOTE=""
  sd=""; [ -f "$src" ] && sd=$(img_digest < "$src")
  if [ -z "$sd" ]; then problem "$src has no image.digest: nothing to promote from."; return 1; fi
  if [ ! -f "$dst" ]; then
    if [ "${SINGLE:-false}" = true ]; then problem "$dst does not exist. Create it first (copy $src) in a normal pull request."; return 1; fi
    echo "::warning::$dst does not exist; $app skipped."; return 2
  fi
  dd=$(img_digest < "$dst"); dv=$(img_version < "$dst"); sv=$(img_version < "$src"); st=$(img_tag < "$src")

  if [ "$TARGET_ENV" = prod ]; then
    ver=$sv
    if [ -n "$VERSION" ] && [ -n "$ver" ] && [ "$VERSION" != "$ver" ]; then
      problem "$app: stage has version $ver, not $VERSION. Prod takes the version from stage."; return 1
    fi
  fi
  expected=$VERSION; [ "$TARGET_ENV" != prod ] || expected=$ver
  # Same rule as gitops-promote: a different digest changes the file; the same digest only when it still lacks the version.
  if [ "$sd" != "$dd" ]; then need=true
  elif [ -z "$dv" ] && { [ "$TARGET_ENV" = stage ] || [ -n "$ver" ]; }; then need=true
  elif [ "${SINGLE:-false}" = true ] && [ -n "$expected" ] && [ "$dv" != "$expected" ]; then
    problem "$app: $TARGET_ENV already has this digest as version $dv, not $expected."; return 1
  fi
  if ! $need; then NOTE="$app: $TARGET_ENV already has ${sd:0:19}."; echo "$NOTE"; return 2; fi

  if [ "$TARGET_ENV" = stage ]; then
    if [ -n "$VERSION" ]; then ver=$VERSION; how="typed"
    else ver=$(next_version "$app" "$dv"); how="computed"; fi
    if git rev-parse --quiet --verify "refs/tags/$app-v$ver" > /dev/null; then
      problem "$app: the tag $app-v$ver exists already. Choose the next version."; return 1
    fi
  else
    how="from stage"
    if [ -z "$ver" ]; then
      problem "$app: stage has no version for this digest (no '# vX.Y.Z' on its image.digest line). Promote it to stage first."; return 1
    fi
  fi
  [ -n "$st" ] || st="sha256-${sd:7:12}"
  ITEM=$(jq -nc --arg app "$app" --arg tag "$st" --arg digest "$sd" --arg version "$ver" --arg old "$dd" --arg how "$how" \
    '{app: $app, tag: $tag, digest: $digest, version: $version, old: $old, how: $how}')
  return 0
}

# ---- plan ---------------------------------------------------------------------------------------------------------------------------

write_outputs() { # $1 = items JSON
  local count; count=$(jq length <<< "$1")
  {
    echo "items=$1"
    echo "count=$count"
    echo "sha=$(git rev-parse HEAD)"
  } >> "$OUT"
}

cmd_plan() {
  local mode=${MODE:?MODE is auto or manual} items='[]' app ignored="" reason f
  local -a apps=() rows=()
  local -A changed=()
  init_env
  case "$mode" in
    auto)
      local -a ch=() pend=()
      mapfile -t ch < <(changed_apps)
      if [ "${#ch[@]}" -eq 0 ]; then
        ignored="No \`image.digest\` changed in \`$PREV\` in this push (a rollback, or only comments and other lines), so nothing is promoted."
      else
        for app in "${ch[@]}"; do changed[$app]=1; done
        mapfile -t pend < <(pending_apps)
        mapfile -t apps < <(printf '%s\n' "${ch[@]}" "${pend[@]}" | sed '/^$/d' | sort -u)
      fi
      ;;
    manual)
      local want=${APP:?APP is an app name or all}
      if [ "$want" = all ]; then
        for f in envs/"$PREV"/values/*.yaml; do [ -n "$(img_digest < "$f")" ] && apps+=("$(basename "$f" .yaml)"); done
      else
        [[ "$want" =~ ^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$ ]] || { echo "::error::app '$want' is not a chart name."; exit 1; }
        apps=("$want"); SINGLE=true
      fi
      ;;
    *) echo "::error::MODE must be auto or manual."; exit 1 ;;
  esac

  local rc
  for app in "${apps[@]}"; do
    rc=0; plan_app "$app" || rc=$?
    if [ "$rc" -eq 0 ]; then
      items=$(jq -c --argjson i "$ITEM" '. + [$i]' <<< "$items")
      if [ "$mode" = manual ]; then reason="asked for"
      elif [ -n "${changed[$app]:-}" ]; then reason="changed in this push"
      else reason="still waiting from an earlier $PREV change"; fi
      rows+=("| $app | \`$(jq -r .version <<< "$ITEM")\` ($(jq -r .how <<< "$ITEM")) | \`$(short "$(jq -r .old <<< "$ITEM")")\` | \`$(short "$(jq -r .digest <<< "$ITEM")")\` | $reason |")
    fi
  done
  [ "$problems" -eq 0 ] || exit 1
  write_outputs "$items"

  local count src_sha; count=$(jq length <<< "$items"); src_sha=$(git rev-parse --short HEAD)
  {
    if [ "$count" -eq 0 ]; then
      echo "### Nothing to promote to \`$TARGET_ENV\`"
      echo
      echo "${ignored:-\`$TARGET_ENV\` already has what \`$PREV\` has.}"
    else
      echo "### Waiting for approval: $count app(s) to \`$TARGET_ENV\`"
      echo
      echo "Nothing is deployed yet. Open **Review deployments** on this run, tick \`$TARGET_ENV\`, and approve (or reject)."
      if [ "$mode" = auto ]; then
        echo "A newer \`$PREV\` change replaces this run while it waits: the newer run lists these apps again."
      fi
      echo
      echo "| App | Version | \`$TARGET_ENV\` now | will become | Why |"
      echo "|---|---|---|---|---|"
      printf '%s\n' "${rows[@]}"
    fi
    echo
    echo "<details><summary>Details</summary>"
    echo
    echo "- source: \`$PREV\` on main at \`$src_sha\`; the digest is copied unchanged, the registry is never asked for \"the newest\""
    if [ "$TARGET_ENV" = stage ]; then
      echo "- version: typed in the form, or computed as the next patch after the newest \`<app>-vX.Y.Z\` tag (none yet: \`1.0.0\`)"
    else
      echo "- version: taken from \`stage\` unchanged"
    fi
    echo "- each promotion is a pull request \`promote/<app>/$TARGET_ENV\` that passes the normal checks and auto-merges"
    echo
    echo "</details>"
  } >> "$SUMMARY"
}

# ---- recheck (after the approval) ---------------------------------------------------------------------------------------------------

cmd_recheck() {
  local items=${ITEMS:?ITEMS is the approved plan} app want now rc stale=0 approver="" rows=()
  init_env
  while read -r want; do
    app=$(jq -r .app <<< "$want")
    rc=0; plan_app "$app" || rc=$?
    case "$rc" in
      0)
        now=$(jq -c '{app, tag, digest, version}' <<< "$ITEM")
        if [ "$now" != "$(jq -c '{app, tag, digest, version}' <<< "$want")" ]; then
          echo "::error::$app: main changed after the plan was made. Approved: $(jq -c '{tag, digest, version}' <<< "$want"). Now: $(jq -c '{tag, digest, version}' <<< "$ITEM")."
          stale=$((stale + 1)); continue
        fi
        ;;
      2)
        if [ "$(img_digest < "envs/$TARGET_ENV/values/$app.yaml")" != "$(jq -r .digest <<< "$want")" ]; then
          echo "::error::$app: main changed after the plan was made (the promotion that was approved is no longer what $PREV has)."
          stale=$((stale + 1)); continue
        fi
        echo "$app is already in $TARGET_ENV; nothing to do for it."
        ;;
      *) stale=$((stale + 1)); continue ;;
    esac
    rows+=("| $app | \`$(jq -r .version <<< "$want")\` | \`$(short "$(jq -r .old <<< "$want")")\` | \`$(short "$(jq -r .digest <<< "$want")")\` |")
  done < <(jq -c '.[]' <<< "$items")

  if [ "$stale" -gt 0 ]; then
    {
      echo "### Not promoted: the plan is out of date"
      echo
      echo "\`main\` changed after the plan was made (for example a rollback of \`$PREV\`), so what you approved is no longer what would be deployed. **Nothing was promoted.** A newer \`$PREV\` change starts a new run; or use Actions -> Promote."
    } >> "$SUMMARY"
    exit 1
  fi
  if [ -n "${GH_TOKEN:-}" ] && [ -n "${GITHUB_RUN_ID:-}" ]; then
    approver=$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/approvals" --jq '[.[].user.login] | unique | join(", ")' 2> /dev/null || true)
  fi
  {
    echo "### Approved: promoting to \`$TARGET_ENV\`${approver:+ (approved by $approver)}"
    echo
    echo "The plan still matches \`main\`. The pull requests are opened next (jobs \`Promote <app>\`); the digests are not rebuilt."
    echo
    echo "| App | Version | \`$TARGET_ENV\` before | now deploying |"
    echo "|---|---|---|---|"
    printf '%s\n' "${rows[@]}"
  } >> "$SUMMARY"
}

# ---- result ---------------------------------------------------------------------------------------------------------------------------

cmd_result() {
  local items=${ITEMS:?ITEMS is the approved plan} status=${PROMOTE_RESULT:-unknown} item app d line pr state rows=() repo=${GITHUB_REPOSITORY:-}
  init_env
  while read -r item; do
    app=$(jq -r .app <<< "$item"); d=$(jq -r .digest <<< "$item")
    pr="-"; state="no pull request found (nothing needed changing, or the promotion failed)"
    if [ -n "$repo" ]; then
      # The branch is reused for every promotion of this app; the digest in the body tells which pull request is this one.
      line=$(gh api "repos/$repo/pulls?state=all&head=${repo%%/*}:promote/$app/$TARGET_ENV&per_page=5" 2> /dev/null | jq -r --arg d "$d" '
        [.[] | select((.body // "") | contains($d))][0] | if . == null then empty else
        "\(.html_url) \(if .merged_at then "merged" elif .state == "open" then "open, merges when the checks pass" else "closed without merging" end)" end' || true)
      if [ -n "$line" ]; then pr="[${line%% *}](${line%% *})"; state=${line#* }; fi
    fi
    rows+=("| $app | \`$(jq -r .version <<< "$item")\` | \`$(short "$(jq -r .old <<< "$item")")\` -> \`$(short "$d")\` | $pr | $state |")
  done < <(jq -c '.[]' <<< "$items")
  {
    if [ "$status" = success ]; then
      echo "### Promoted to \`$TARGET_ENV\`: pull requests are open"
      echo
      echo "Argo CD applies each one within about 2 minutes after its pull request merges."
    else
      echo "### Promotion to \`$TARGET_ENV\` did not complete ($status)"
      echo
      echo "Open the failed \`Promote <app>\` job for the reason. Nothing is half-applied: a promotion is one pull request."
    fi
    echo
    echo "| App | Version | Image | Pull request | State |"
    echo "|---|---|---|---|---|"
    printf '%s\n' "${rows[@]}"
  } >> "$SUMMARY"
  [ "$status" = success ]
}

case "${1:-}" in
  plan) cmd_plan ;;
  recheck) cmd_recheck ;;
  result) cmd_result ;;
  *) echo "usage: promote.sh plan|recheck|result" >&2; exit 2 ;;
esac
