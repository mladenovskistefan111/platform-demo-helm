#!/usr/bin/env bash
# Tests for promote.sh (plan, recheck). Builds throw-away git repositories in a temp dir (no GitHub, no network).
# Run:  .github/scripts/test-promote.sh
set -uo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0

D() { printf 'sha256:%063d%x' 0 "$1"; } # D n -> a distinct valid digest

# values <env> <app> <digest> [tag] [version] [extra-line]
values() {
  mkdir -p "envs/$1/values"
  {
    echo "# values of $2 in $1"
    echo "image:"
    [ -n "${4:-}" ] && echo "  tag: $4"
    echo "  digest: $3${5:+   # v$5}"
    echo "replicaCount: 1"
    [ -n "${6:-}" ] && echo "$6"
  } > "envs/$1/values/$2.yaml"
}
commit() { git add -A && git commit -q --allow-empty -m "$1"; }

# Three apps (a, b, c), everything promoted: dev = stage = prod, stage and prod at version 1.0.0.
new_repo() {
  rm -rf "$tmp/r" && mkdir "$tmp/r" && cd "$tmp/r" || exit 1
  git init -q -b main . && git config user.name t && git config user.email t@t
  local app n=0
  for app in a b c; do
    n=$((n + 1))
    values dev "$app" "$(D $n)" "sha-$n"
    values stage "$app" "$(D $n)" "sha-$n" 1.0.0
    values prod "$app" "$(D $n)" "sha-$n" 1.0.0
  done
  echo readme > README.md
  commit initial
  git tag -a -m t a-v1.0.0; git tag -a -m t b-v1.0.0; git tag -a -m t c-v1.0.0
}

# run <plan|recheck> <env vars...>: runs promote.sh in the work tree; sets OUT_FILE / SUM_FILE; returns its exit code
run() {
  local cmd=$1; shift
  : > "$tmp/out"; : > "$tmp/sum"
  env GITHUB_OUTPUT="$tmp/out" GITHUB_STEP_SUMMARY="$tmp/sum" GITHUB_REF=refs/heads/main "$@" bash "$script/promote.sh" "$cmd" > "$tmp/log" 2>&1
}
out() { sed -n "s/^$1=//p" "$tmp/out" | head -n 1; }
apps_planned() { out items | jq -r '[.[].app] | join(",")'; }

check() { # check <name> <expected> <got>
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1: expected '$2', got '$3'"; sed 's/^/    log: /' "$tmp/log" | tail -n 8; fi
}
check_grep() { # check_grep <name> <file> <fixed string>
  if grep -qF -- "$3" "$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1: '$3' not found in $2"; sed 's/^/    | /' "$2" | head -n 20; fi
}

# ---- changed-digest detection (automatic, stage <- dev) ------------------------------------------------------------------------------

new_repo; before=$(git rev-parse HEAD)
values dev a "$(D 11)" sha-11; commit "promote(dev): a sha-11 (#1)"
run plan MODE=auto TARGET_ENV=stage BEFORE="$before"; check "single app changed: exit" 0 $?
check "single app changed: apps" a "$(apps_planned)"
check "single app changed: count" 1 "$(out count)"
check "single app changed: computed version" 1.0.1 "$(out items | jq -r '.[0].version')"
check "single app changed: old digest" "$(D 1)" "$(out items | jq -r '.[0].old')"
check "single app changed: sha output" "$(git rev-parse HEAD)" "$(out sha)"
check_grep "summary says waiting for approval" "$tmp/sum" "Waiting for approval: 1 app(s) to \`stage\`"
check_grep "summary tells where to click" "$tmp/sum" "Review deployments"

# comment-only and non-digest changes are ignored
new_repo; before=$(git rev-parse HEAD)
values dev a "$(D 1)" sha-1 "" "# just a comment"; commit "docs: comment"
run plan MODE=auto TARGET_ENV=stage BEFORE="$before"; check "comment-only: exit" 0 $?
check "comment-only: count" 0 "$(out count)"
check "comment-only: items" '[]' "$(out items)"
check_grep "comment-only: summary" "$tmp/sum" "Nothing to promote to \`stage\`"

new_repo; before=$(git rev-parse HEAD)
values dev a "$(D 1)" sha-other; commit "chore: tag only"          # same digest, other tag
run plan MODE=auto TARGET_ENV=stage BEFORE="$before"; check "tag-only change: count" 0 "$(out count)"

new_repo; before=$(git rev-parse HEAD)
sed -i 's/replicaCount: 1/replicaCount: 3/' envs/dev/values/a.yaml; commit "chore: replicas"
run plan MODE=auto TARGET_ENV=stage BEFORE="$before"; check "other line changed: count" 0 "$(out count)"

# a rollback commit is ignored
new_repo; before=$(git rev-parse HEAD)
values dev a "$(D 11)" sha-11; commit "promote(dev): a sha-11 (#1)"
mid=$(git rev-parse HEAD)
run plan MODE=auto TARGET_ENV=stage BEFORE="$before"; check "setup: a promoted in dev" a "$(apps_planned)"
values dev a "$(D 1)" sha-1; commit "rollback(dev): a to previous (#2)"
run plan MODE=auto TARGET_ENV=stage BEFORE="$mid"; check "rollback commit: exit" 0 $?
check "rollback commit: count" 0 "$(out count)"
check_grep "rollback commit: summary" "$tmp/sum" "Nothing to promote"

# a rollback commit in dev to a digest that stage does NOT have (so a real difference exists) still starts nothing
new_repo
values dev a "$(D 11)" sha-11; commit "promote(dev): a (#1)"
values dev a "$(D 5)" sha-5; before=$(git rev-parse HEAD); commit "rollback(dev): a to sha256:5 (#2)"
run plan MODE=auto TARGET_ENV=stage BEFORE="$before"; check "rollback to a digest stage lacks: count" 0 "$(out count)"
check_grep "rollback: summary names the reason" "$tmp/sum" "Nothing to promote"

# several apps in one push -> one plan
new_repo; before=$(git rev-parse HEAD)
values dev a "$(D 11)" sha-11; values dev c "$(D 13)" sha-13; commit "promote(dev): batch (#3)"
run plan MODE=auto TARGET_ENV=stage BEFORE="$before"; check "multi-app push: apps" a,c "$(apps_planned)"

# a push of several commits: a rollback in the middle does not hide the others, and does not count itself
new_repo; before=$(git rev-parse HEAD)
values dev a "$(D 11)" sha-11; commit "promote(dev): a (#1)"
values dev a "$(D 1)" sha-1; commit "rollback(dev): a to previous (#2)"
values dev b "$(D 12)" sha-12; commit "promote(dev): b (#3)"
run plan MODE=auto TARGET_ENV=stage BEFORE="$before"; check "multi-commit push: apps" b "$(apps_planned)"

# the first push of a branch: BEFORE is all zeros -> only the tip commit
new_repo
values dev b "$(D 12)" sha-12; commit "promote(dev): b (#3)"
run plan MODE=auto TARGET_ENV=stage BEFORE=0000000000000000000000000000000000000000; check "zero before: apps" b "$(apps_planned)"
run plan MODE=auto TARGET_ENV=stage BEFORE=1111111111111111111111111111111111111111; check "unknown before: apps" b "$(apps_planned)"

# a dev change that lands on the digest stage already has -> nothing to approve
new_repo; before=$(git rev-parse HEAD)
values dev a "$(D 11)" sha-11; commit "promote(dev): a (#1)"; mid=$(git rev-parse HEAD)
values stage a "$(D 11)" sha-11 1.0.1; commit "promote(stage): a (#2)"; before=$mid
values dev a "$(D 11)" sha-11b; commit "chore: other tag"
run plan MODE=auto TARGET_ENV=stage BEFORE="$before"; check "stage has it already: count" 0 "$(out count)"

# ---- carry-over: an app of an earlier (replaced) run is offered again ----------------------------------------------------------------------

new_repo
values dev a "$(D 11)" sha-11; commit "promote(dev): a (#1)"          # waiting; its run will be replaced
before=$(git rev-parse HEAD)
values dev b "$(D 12)" sha-12; commit "promote(dev): b (#2)"
run plan MODE=auto TARGET_ENV=stage BEFORE="$before"; check "carry-over: apps" a,b "$(apps_planned)"
check "carry-over: reason of a" "still waiting from an earlier dev change" \
  "$(grep -o 'still waiting from an earlier dev change' "$tmp/sum" | head -n 1)"
check_grep "carry-over: reason of b" "$tmp/sum" "changed in this push"

# stage was rolled back on purpose AFTER dev moved: not offered again by an unrelated dev change
new_repo
values dev a "$(D 11)" sha-11; commit "promote(dev): a (#1)"
values stage a "$(D 11)" sha-11 1.0.1; commit "promote(stage): a (#2)"
values stage a "$(D 1)" sha-1 1.0.0; commit "rollback(stage): a to previous (#3)"
before=$(git rev-parse HEAD)
values dev b "$(D 12)" sha-12; commit "promote(dev): b (#4)"
run plan MODE=auto TARGET_ENV=stage BEFORE="$before"; check "stage rollback is respected: apps" b "$(apps_planned)"

# dev was rolled back: the rolled-back app is not offered (dev's latest digest change is a rollback commit)
new_repo
values dev a "$(D 11)" sha-11; commit "promote(dev): a (#1)"
values dev a "$(D 1)" sha-1; commit "rollback(dev): a to previous (#2)"
values stage a "$(D 0)" sha-0 0.9.0; commit "chore: make stage differ"   # stage differs, but its change is newer than... still no
before=$(git rev-parse HEAD)
values dev b "$(D 12)" sha-12; commit "promote(dev): b (#3)"
run plan MODE=auto TARGET_ENV=stage BEFORE="$before"; check "dev rollback is not carried over: apps" b "$(apps_planned)"

# ---- version computation (stage) ---------------------------------------------------------------------------------------------------------

version_for() { # version_for <app> -> the computed version for a stage promotion of <app> when its dev digest changed
  local before; before=$(git rev-parse HEAD)
  values dev "$1" "$(D 21)" sha-21; commit "promote(dev): $1 (#9)"
  run plan MODE=auto TARGET_ENV=stage BEFORE="$before" && out items | jq -r --arg a "$1" '.[] | select(.app == $a) | .version'
}
new_repo
check "version: next patch after the only tag" 1.0.1 "$(version_for a)"

new_repo
git tag -a -m t a-v1.0.9; git tag -a -m t a-v1.0.10; git tag -a -m t a-v1.2.0; git tag -a -m t a-v1.1.7
check "version: highest semver, not newest or alphabetical" 1.2.1 "$(version_for a)"

new_repo   # no tags at all, and stage without a version
git tag -d a-v1.0.0 b-v1.0.0 c-v1.0.0 > /dev/null
values stage a "$(D 1)" sha-1; commit "stage without version"
check "version: no tag -> 1.0.0" 1.0.0 "$(version_for a)"

new_repo   # tags of other apps and look-alikes do not count
git tag -a -m t b-v7.0.0; git tag -a -m t a-extra-v9.9.9; git tag -a -m t a-v2.0.0-rc1; git tag -a -m t prod-v5.0.0; git tag -a -m t v8.0.0
check "version: other apps, look-alikes and pre-releases ignored" 1.0.1 "$(version_for a)"

new_repo   # a version in the stage file whose tag is not made yet counts as taken
values stage a "$(D 1)" sha-1 1.4.0; commit "promote(stage): a v1.4.0 (tag pending)"
check "version: stage file version without tag counts" 1.4.1 "$(version_for a)"

new_repo   # an explicit version is used as typed (manual), and a taken one is refused
run plan MODE=manual TARGET_ENV=stage APP=a VERSION=2.0.0; check "manual typed version differing from the one the digest has: refused" 1 $?
values dev a "$(D 11)" sha-11; commit "promote(dev): a (#1)"
run plan MODE=manual TARGET_ENV=stage APP=a VERSION=2.0.0; check "manual typed version: exit" 0 $?
check "manual typed version: used" 2.0.0 "$(out items | jq -r '.[0].version')"
run plan MODE=manual TARGET_ENV=stage APP=a VERSION=1.0.0; check "manual taken version refused" 1 $?
run plan MODE=manual TARGET_ENV=stage APP=a VERSION=1.0; check "manual malformed version refused" 1 $?
run plan MODE=manual TARGET_ENV=stage APP=a; check "manual empty version is computed: exit" 0 $?
check "manual empty version is computed" 1.0.1 "$(out items | jq -r '.[0].version')"
run plan MODE=manual TARGET_ENV=stage APP=all; check "manual all: apps" a "$(apps_planned)"
run plan MODE=manual TARGET_ENV=stage APP=nope; check "manual unknown app refused" 1 $?
run plan MODE=manual TARGET_ENV=stage APP=B1_x; check "manual bad app name refused" 1 $?
run plan MODE=manual TARGET_ENV=dev APP=a; check "env dev refused" 1 $?

# ---- prod (stage -> prod) ---------------------------------------------------------------------------------------------------------------------

new_repo; before=$(git rev-parse HEAD)
values stage a "$(D 11)" sha-11 1.0.1; commit "promote(stage): a sha-11 (v1.0.1) (#1)"
git tag -a -m t a-v1.0.1
run plan MODE=auto TARGET_ENV=prod BEFORE="$before"; check "prod: exit" 0 $?
check "prod: apps" a "$(apps_planned)"
check "prod: version comes from stage" 1.0.1 "$(out items | jq -r '.[0].version')"
check_grep "prod summary" "$tmp/sum" "Waiting for approval: 1 app(s) to \`prod\`"
run plan MODE=manual TARGET_ENV=prod APP=a VERSION=1.0.2; check "prod: typed version must equal stage's" 1 $?
run plan MODE=manual TARGET_ENV=prod APP=a VERSION=1.0.1; check "prod: equal typed version ok" 0 $?

# a prod promotion (or rollback) does not start anything: the script is never asked, but a stage rollback commit is ignored
new_repo; before=$(git rev-parse HEAD)
values stage a "$(D 0)" sha-0 0.9.0; commit "rollback(stage): a to previous (#4)"
run plan MODE=auto TARGET_ENV=prod BEFORE="$before"; check "stage rollback: count" 0 "$(out count)"

# prod: stage digest without a version is a problem
new_repo; before=$(git rev-parse HEAD)
values stage a "$(D 11)" sha-11; commit "hand edit"
run plan MODE=auto TARGET_ENV=prod BEFORE="$before"; check "prod: stage without version fails" 1 $?
check_grep "prod: message" "$tmp/log" "stage has no version"

# prod: stage legacy file already in prod without version -> gets the version
new_repo; before=$(git rev-parse HEAD)
values stage b "$(D 2)" sha-2 1.0.5; commit "promote(stage): b version only (#5)"
run plan MODE=manual TARGET_ENV=prod APP=b; check "prod: same digest but another version in stage than in prod: refused" 1 $?
run plan MODE=auto TARGET_ENV=prod BEFORE="$before"; check "prod: version-only stage change starts nothing: count" 0 "$(out count)"

# ---- recheck ---------------------------------------------------------------------------------------------------------------------------------------

new_repo; before=$(git rev-parse HEAD)
values dev a "$(D 11)" sha-11; commit "promote(dev): a (#1)"
run plan MODE=auto TARGET_ENV=stage BEFORE="$before"; items=$(out items)
run recheck TARGET_ENV=stage ITEMS="$items"; check "recheck unchanged: exit" 0 $?
check_grep "recheck summary" "$tmp/sum" "Approved: promoting to \`stage\`"
# dev rolled back while the run waited
values dev a "$(D 1)" sha-1; commit "rollback(dev): a (#2)"
run recheck TARGET_ENV=stage ITEMS="$items"; check "recheck after dev rollback: refused" 1 $?
check_grep "recheck refusal says nothing was promoted" "$tmp/sum" "Nothing was promoted"
# somebody else promoted the same digest meanwhile
values dev a "$(D 11)" sha-11; commit "promote(dev): a again (#3)"
values stage a "$(D 11)" sha-11 1.0.1; commit "promote(stage): a (#4)"
run recheck TARGET_ENV=stage ITEMS="$items"; check "recheck already promoted: ok" 0 $?
# the version was taken in the meantime by another digest
values dev a "$(D 12)" sha-12; commit "promote(dev): a new (#5)"
run recheck TARGET_ENV=stage ITEMS="$items"; check "recheck other digest: refused" 1 $?

echo "promote.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
