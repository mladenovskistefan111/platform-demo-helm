#!/usr/bin/env bash
# Promotion policy: what a pull request may do to the images in envs/<env>/values/<app>.yaml.
#
# For every changed envs/<env>/values/<app>.yaml the image.digest (and image.tag) of the merge base is compared with the head:
#   1. dev   any digest (the cosign gate of CI checks the signature).
#   2. stage the new digest must be the digest that envs/dev/values/<app>.yaml has on the base branch NOW, or one that the same stage
#            file has had before (a rollback, found in the git history of the base branch).
#   3. prod  the same, with stage as the previous environment.
#   4. A pull request that changes images changes them in ONE environment and nothing else: no other file, no other line of
#      that values file, no image of another environment. Otherwise a promotion could sneak into prod together with something
#      else. The label `allow-mixed-image-change` lifts only this rule (rules 2, 3, 5 always apply); it is meant for restructurings.
#   5. A pull request from the branch promote/<app>/<env> or rollback/<app>/<env> (what the automation opens) may change exactly
#      envs/<env>/values/<app>.yaml, whatever the labels.
# image.digest may not be removed from a file that had one.
#
# Needs the history of the base branch (checkout with fetch-depth: 0).
# Environment: BASE_REF (default origin/main), HEAD_REF (default HEAD), HEAD_BRANCH (name of the PR branch, optional),
#              LABELS (comma separated PR labels, optional).
# Also sourceable: the img_* helpers read a values file on stdin (used by the Promote workflow).

# Block-style top-level `image:` key, direct children only. Prints the value of $1 (tag|digest) without quotes.
img_get() {
  awk -v key="$1" '
    /^image:[ \t]*(#.*)?$/ { inimg = 1; ind = -1; next }
    inimg {
      if ($0 ~ /^[ \t]*(#.*)?$/) next
      match($0, /^[ \t]*/); n = RLENGTH
      if (n == 0) { inimg = 0; next }
      if (ind < 0) ind = n
      if (n == ind && $0 ~ ("^[ \t]+" key ":")) {
        v = $0; sub("^[ \t]+" key ":[ \t]*", "", v); sub(/[ \t]+#.*$/, "", v); sub(/[ \t]+$/, "", v); print v; exit
      }
    }' | tr -d "\"'"
}
img_digest() { img_get digest; }
img_tag() { img_get tag; }
# The `# vX.Y.Z` comment on the digest line.
img_version() {
  awk '
    /^image:[ \t]*(#.*)?$/ { inimg = 1; ind = -1; next }
    inimg {
      if ($0 ~ /^[ \t]*(#.*)?$/) next
      match($0, /^[ \t]*/); n = RLENGTH
      if (n == 0) { inimg = 0; next }
      if (ind < 0) ind = n
      if (n == ind && $0 ~ /^[ \t]+digest:/ && match($0, /#[ \t]*v[0-9]+\.[0-9]+\.[0-9]+[ \t]*$/)) {
        v = substr($0, RSTART, RLENGTH); gsub(/[# \tv]/, "", v); print v; exit
      }
    }'
}
# The file without its image.tag / image.digest lines: what must not change in a promotion.
img_mask() {
  awk '
    /^image:[ \t]*(#.*)?$/ { inimg = 1; ind = -1; print; next }
    inimg {
      if ($0 ~ /^[ \t]*(#.*)?$/) { print; next }
      match($0, /^[ \t]*/); n = RLENGTH
      if (n == 0) inimg = 0
      else {
        if (ind < 0) ind = n
        if (n == ind && $0 ~ /^[ \t]+(tag|digest):/) next
      }
    }
    { print }'
}

policy_main() {
  set -euo pipefail
  local base_ref=${BASE_REF:-origin/main} head_ref=${HEAD_REF:-HEAD} head_branch=${HEAD_BRANCH:-} labels=${LABELS:-}
  local allow_label=allow-mixed-image-change
  local errors=0
  err() { # $1 = file (or empty), $2 = message
    if [ -n "$1" ]; then echo "::error file=$1::$2"; else echo "::error::$2"; fi
    errors=$((errors + 1))
  }
  show() { git show "$1:$2" 2> /dev/null; }       # content of a file at a revision, failing when absent
  digest_at() { local c; if c=$(show "$1" "$2"); then img_digest <<< "$c"; fi; }
  tag_at() { local c; if c=$(show "$1" "$2"); then img_tag <<< "$c"; fi; }
  prev_env() { case "$1" in stage) echo dev ;; prod) echo stage ;; esac; }

  git rev-parse --verify --quiet "$base_ref^{commit}" > /dev/null || { echo "::error::base '$base_ref' not found (is the checkout complete? use fetch-depth: 0)"; return 1; }
  git rev-parse --verify --quiet "$head_ref^{commit}" > /dev/null || { echo "::error::head '$head_ref' not found"; return 1; }
  local mb
  mb=$(git merge-base "$base_ref" "$head_ref") || { echo "::error::no merge base between $base_ref and $head_ref (use fetch-depth: 0)"; return 1; }

  local -a changed=() image_files=() summary=()
  local -A envs_with_images=() is_image_file=()
  mapfile -t changed < <(git diff --name-only --no-renames "$mb" "$head_ref")
  if [ "${#changed[@]}" -eq 0 ]; then echo "No changed files: nothing to check."; return 0; fi

  local allow_mixed=false
  case ",$labels," in *",$allow_label,"*) allow_mixed=true ;; esac

  local f env app old new oldtag newtag re='^envs/(dev|stage|prod)/values/([^/]+)\.yaml$'
  for f in "${changed[@]}"; do
    [[ "$f" =~ $re ]] || continue
    env=${BASH_REMATCH[1]}; app=${BASH_REMATCH[2]}
    old=$(digest_at "$mb" "$f"); new=$(digest_at "$head_ref" "$f")
    oldtag=$(tag_at "$mb" "$f"); newtag=$(tag_at "$head_ref" "$f")
    if [ -n "$old" ] && [ -z "$new" ] && show "$head_ref" "$f" > /dev/null; then
      err "$f" "image.digest was removed from $f. Images are always pinned by digest."
      continue
    fi
    [ -n "$new" ] || continue # file deleted, or not an image file
    if [ "$old" = "$new" ] && [ "$oldtag" = "$newtag" ]; then continue; fi
    is_image_file[$f]=1; image_files+=("$f"); envs_with_images[$env]=1
    if [ "$old" = "$new" ]; then summary+=("| $f | $env | tag only | \`${oldtag:-none}\` -> \`$newtag\` |"); continue; fi

    if ! [[ "$new" =~ ^sha256:[0-9a-f]{64}$ ]]; then
      err "$f" "image.digest '$new' is not a sha256:<64 hex> digest."
      continue
    fi
    case "$env" in
      dev) summary+=("| $f | dev | allowed | any digest in dev (signature checked by the cosign gate) |") ;;
      stage | prod)
        local pe pf pd ok=false why
        pe=$(prev_env "$env"); pf="envs/$pe/values/$app.yaml"
        pd=$(digest_at "$base_ref" "$pf")
        if [ -n "$pd" ] && [ "$new" = "$pd" ]; then
          ok=true; why="the digest $pe has on $base_ref"
        else
          local c
          while read -r c; do
            [ -n "$c" ] || continue
            if [ "$(digest_at "$c" "$f")" = "$new" ]; then ok=true; why="a digest $env already had before (rollback), commit ${c:0:7}"; break; fi
          done < <(git log --format=%H "$base_ref" -- "$f")
        fi
        if $ok; then
          summary+=("| $f | $env | allowed | ${why} |")
        elif [ -z "$pd" ]; then
          err "$f" "$new is not allowed in $env: $pf has no image.digest on $base_ref to promote from, and $env never had this digest. Promote through $pe first."
        else
          err "$f" "$new is not allowed in $env. $env may only get the digest that $pe has now ($pd) or a digest $env had before (rollback). Promote $app through $pe first."
        fi
        ;;
    esac
  done

  # Rule 4: images change in one environment and nothing else changes.
  if [ "${#image_files[@]}" -gt 0 ] && ! $allow_mixed; then
    local n=${#envs_with_images[@]}
    if [ "$n" -gt 1 ]; then
      err "" "This pull request changes images in more than one environment (${!envs_with_images[*]}). One environment per pull request; or add the label '$allow_label' for a restructuring."
    fi
    local only_env=${!envs_with_images[*]} other=() m1 m2
    only_env=${only_env%% *}
    for f in "${changed[@]}"; do
      if [ -n "${is_image_file[$f]:-}" ]; then
        # an image file may differ in its image lines only
        m1=$(show "$mb" "$f" | img_mask || true); m2=$(show "$head_ref" "$f" | img_mask || true)
        [ "$m1" = "$m2" ] || other+=("$f (more than the image changed)")
      else
        other+=("$f")
      fi
    done
    if [ "${#other[@]}" -gt 0 ]; then
      err "" "This pull request changes images in $only_env and also other things: ${other[*]}. An image promotion changes nothing else (so it cannot carry anything along into $only_env). Split it, or add the label '$allow_label' for a restructuring."
    fi
  fi

  # Rule 5: the automation's branches carry exactly their one file.
  local br_re='^(promote|rollback)/([a-z0-9][a-z0-9-]*)/(dev|stage|prod)$'
  if [[ "$head_branch" =~ $br_re ]]; then
    local want="envs/${BASH_REMATCH[3]}/values/${BASH_REMATCH[2]}.yaml"
    for f in "${changed[@]}"; do
      [ "$f" = "$want" ] || err "$f" "The branch $head_branch may change only $want, but this pull request also changes $f."
    done
  fi

  {
    echo "### Promotion policy"
    echo
    if [ "${#summary[@]}" -gt 0 ]; then
      echo "| File | Env | Result | Why |"
      echo "|---|---|---|---|"
      printf '%s\n' "${summary[@]}"
    else
      echo "No image changed."
    fi
    $allow_mixed && echo && echo "Label \`$allow_label\` is set: the one-environment-and-nothing-else rule was not applied."
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

  if [ "$errors" -gt 0 ]; then
    echo "Promotion policy: $errors problem(s)."
    return 1
  fi
  echo "Promotion policy: ok (${#image_files[@]} image file(s) checked)."
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  policy_main "$@"
fi
