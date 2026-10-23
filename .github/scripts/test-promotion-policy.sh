#!/usr/bin/env bash
# Tests for promotion-policy.sh. Builds throw-away git repositories in a temp dir (no GitHub, no network) and checks which
# changes the policy allows and which it refuses. Run:  .github/scripts/test-promotion-policy.sh
set -uo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/promotion-policy.sh"
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

new_repo() { # builds main: dev/stage/prod for app a and b, all at digest 1 (a) and 2 (b); stage a has history 0 -> 1
  rm -rf "$tmp/r" && mkdir "$tmp/r" && cd "$tmp/r" || exit 1
  git init -q -b main . && git config user.name t && git config user.email t@t
  values dev a "$(D 1)" sha-1; values dev b "$(D 2)" sha-2
  values stage a "$(D 0)" sha-0 1.0.0; values stage b "$(D 2)" sha-2 1.0.0
  values prod a "$(D 0)" sha-0 1.0.0; values prod b "$(D 2)" sha-2 1.0.0
  echo readme > README.md
  commit initial
  values stage a "$(D 1)" sha-1 1.1.0; commit "promote(stage): a"
  values prod a "$(D 1)" sha-1 1.1.0; commit "promote(prod): a"
  values dev a "$(D 3)" sha-3; commit "promote(dev): a"          # dev a is now 3; stage/prod a are 1; stage had 0 before
}

# case <name> <expected: allow|deny> <expected message fragment or -> <branch> <labels> -- then the function body edits the work tree
check() { # name expect fragment branch labels  (changes already committed on branch "pr")
  local name=$1 expect=$2 frag=$3 branch=$4 labels=$5 out rc
  out=$(BASE_REF=main HEAD_REF=pr HEAD_BRANCH="$branch" LABELS="$labels" GITHUB_STEP_SUMMARY=/dev/null "$script" 2>&1); rc=$?
  local ok=true
  [ "$expect" = allow ] && [ $rc -ne 0 ] && ok=false
  [ "$expect" = deny ] && [ $rc -eq 0 ] && ok=false
  if $ok && [ "$expect" = deny ] && [ "$frag" != - ] && ! grep -qF -- "$frag" <<< "$out"; then ok=false; fi
  if $ok; then pass=$((pass + 1)); printf 'ok    %s\n' "$name"
  else fail=$((fail + 1)); printf 'FAIL  %s (expected %s, exit %s)\n%s\n' "$name" "$expect" "$rc" "$out" | sed 's/^/      /'; fi
}
pr() { git checkout -q -b pr main; }

# 1 dev: any digest
new_repo; pr; values dev a "$(D 9)" sha-9; commit x; check "dev: any new digest" allow - "promote/a/dev" ""
# 2 dev: two apps at once is fine (one environment)
new_repo; pr; values dev a "$(D 9)" sha-9; values dev b "$(D 8)" sha-8; commit x; check "dev: two apps in one PR" allow - "" ""
# 3 stage: digest equals dev now
new_repo; pr; values stage a "$(D 3)" sha-3 1.2.0; commit x; check "stage: digest equal to dev" allow - "promote/a/stage" ""
# 4 stage: unknown digest
new_repo; pr; values stage a "$(D 9)" sha-9 1.2.0; commit x; check "stage: digest neither in dev nor in stage history" deny "may only get the digest that dev has now" "" ""
# 5 stage: digest that dev had before (older dev digest, never in stage)
new_repo; pr; values stage a "$(D 2)" sha-2 1.2.0; commit x; check "stage: digest only dev had earlier (not stage)" deny "may only get the digest" "" ""
# 6 stage: rollback to a digest stage had before
new_repo; pr; values stage a "$(D 0)" sha-0 1.0.0; commit x; check "stage: rollback to earlier stage digest" allow - "rollback/a/stage" ""
# 7 stage: unchanged digest, version comment only
new_repo; pr; values stage a "$(D 1)" sha-1 1.1.1; commit x; check "stage: comment-only change (no image change)" allow - "" ""
# 8 prod: digest equals stage now
new_repo; pr; values prod a "$(D 1)" sha-1 1.1.0 ; commit x; check "prod: unchanged" allow - "" ""
new_repo; pr; values stage a "$(D 3)" sha-3 1.2.0; commit s; git checkout -q main; git merge -q --ff-only pr; git branch -q -D pr; pr
values prod a "$(D 3)" sha-3 1.2.0; commit x; check "prod: digest equal to stage now" allow - "promote/a/prod" ""
# 9 prod: digest that is only in dev, not in stage
new_repo; pr; values prod a "$(D 3)" sha-3 1.2.0; commit x; check "prod: digest only in dev (skipping stage)" deny "may only get the digest that stage has now" "" ""
# 10 prod: rollback to a digest prod had before
new_repo; pr; values prod a "$(D 0)" sha-0 1.0.0; commit x; check "prod: rollback to earlier prod digest" allow - "rollback/a/prod" ""
# 11 two environments in one PR
new_repo; pr; values dev a "$(D 9)" sha-9; values stage a "$(D 3)" sha-3 1.2.0; commit x; check "dev and stage images in one PR" deny "more than one environment" "" ""
new_repo; pr; values dev a "$(D 9)" sha-9; values stage a "$(D 3)" sha-3 1.2.0; commit x; check "dev and stage images, label lifts rule 4 (rule 2 still holds)" allow - "" "bug,allow-mixed-image-change"
# 12 promotion + unrelated file
new_repo; pr; values stage a "$(D 3)" sha-3 1.2.0; echo more >> README.md; commit x; check "stage promotion plus README change" deny "also other things: README.md" "" ""
new_repo; pr; values stage a "$(D 3)" sha-3 1.2.0; echo more >> README.md; commit x; check "... with the label" allow - "" "allow-mixed-image-change"
# 13 promotion + other values of same file
new_repo; pr; values stage a "$(D 3)" sha-3 1.2.0 "replicaCount: 5"; commit x; check "stage promotion plus another value in the same file" deny "more than the image changed" "" ""
# 14 promotion of a plus other app's values
new_repo; pr; values stage a "$(D 3)" sha-3 1.2.0; values stage b "$(D 2)" sha-2 1.0.0 "extra: 1"; commit x; check "stage promotion plus another app's non-image change" deny "envs/stage/values/b.yaml" "" ""
# 15 branch rule
new_repo; pr; values dev a "$(D 9)" sha-9; values dev b "$(D 8)" sha-8; commit x; check "promote/a/dev branch touching b as well" deny "may change only envs/dev/values/a.yaml" "promote/a/dev" ""
new_repo; pr; values dev a "$(D 9)" sha-9; commit x; check "promote/a/stage branch changing the dev file" deny "may change only envs/stage/values/a.yaml" "promote/a/stage" ""
new_repo; pr; values dev a "$(D 9)" sha-9; values dev b "$(D 8)" sha-8; commit x; check "branch rule is not lifted by the label" deny "may change only" "promote/a/dev" "allow-mixed-image-change"
# 16 digest removed
new_repo; pr; mkdir -p envs/stage/values; printf 'image:\n  tag: x\nreplicaCount: 1\n' > envs/stage/values/a.yaml; commit x; check "stage: digest removed" deny "image.digest was removed" "" ""
# 17 not a digest
new_repo; pr; values dev a "latest"; commit x; check "dev: not a sha256 digest" deny "not a sha256" "" ""
# 18 new stage file, equal to dev (restructuring) needs the label only when mixed
new_repo; pr; values stage c "$(D 5)" sha-5 1.0.0; values dev c "$(D 5)" sha-5; commit x; check "new app in dev and stage at once" deny "more than one environment" "" ""
new_repo; git checkout -q -b pr main; values dev c "$(D 5)" sha-5; commit d; git checkout -q main; git merge -q --ff-only pr; git branch -q -D pr; pr
values stage c "$(D 5)" sha-5 1.0.0; commit x; check "new stage file (a restructuring needs the label)" deny "more than the image changed" "" ""
new_repo; git checkout -q -b pr main; values dev c "$(D 5)" sha-5; commit d; git checkout -q main; git merge -q --ff-only pr; git branch -q -D pr; pr
values stage c "$(D 5)" sha-5 1.0.0; commit x; check "new stage file with the dev digest, label" allow - "" "allow-mixed-image-change"
new_repo; git checkout -q -b pr main; values dev c "$(D 5)" sha-5; commit d; git checkout -q main; git merge -q --ff-only pr; git branch -q -D pr; pr
values stage c "$(D 6)" sha-6 1.0.0; commit x; check "new stage file with another digest, even with the label" deny "may only get the digest that dev has now" "" "allow-mixed-image-change"
# 19 stale: dev moved on after the PR was made
new_repo; pr; values stage a "$(D 3)" sha-3 1.2.0; commit x
git checkout -q main; values dev a "$(D 7)" sha-7; commit "dev moved"; check "stage PR made when dev was 3, dev is 7 now" deny "may only get the digest that dev has now" "" ""
# 20 tag only
new_repo; pr; values dev a "$(D 3)" sha-other; commit x; check "dev: tag-only change" allow - "" ""
# 21 file deleted / no changes
new_repo; pr; git rm -q envs/stage/values/b.yaml; commit x; check "stage file deleted" allow - "" ""
new_repo; pr; commit "empty"; check "no change" allow - "" ""
# 22 unrelated files only
new_repo; pr; echo x >> README.md; commit x; check "README only" allow - "" ""
# 23 a shallow checkout is reported, never passed silently
new_repo; pr; values dev a "$(D 9)" sha-9; commit x
rm -rf "$tmp/shallow"; git clone -q --depth 1 --branch pr "file://$tmp/r" "$tmp/shallow" 2> /dev/null
(cd "$tmp/shallow" && git fetch -q --depth 1 origin main:refs/remotes/origin/main 2> /dev/null; BASE_REF=origin/main HEAD_REF=HEAD "$script" > "$tmp/shallow.out" 2>&1; echo "rc=$?" >> "$tmp/shallow.out")
if grep -q "no merge base" "$tmp/shallow.out" && grep -q "rc=1" "$tmp/shallow.out"; then pass=$((pass + 1)); echo "ok    shallow clone is an error"; else fail=$((fail + 1)); echo "FAIL  shallow clone"; cat "$tmp/shallow.out"; fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
