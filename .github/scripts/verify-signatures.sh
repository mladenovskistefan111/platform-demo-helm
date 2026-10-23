#!/usr/bin/env bash
# Every image of ours in the rendered charts must be pinned by digest and carry a keyless cosign signature from one of the workflows in
# verifyImages.signers (policies/values.yaml; the same list the Kyverno policy enforces at admission).
#   usage: .github/scripts/verify-signatures.sh <rendered-dir>
# Environment (all optional):
#   UNSIGNED_ALLOWLIST  space separated image names that may have NO signature (never: a wrong signer, never: a registry error)
#   ATTEMPTS            tries per image for transient errors (default 5)
#   BACKOFF             seconds before the 2nd try; doubles each time (default 3: 3, 6, 12, 24 s)
#   SIGNER_REGEXP       override of the certificate-identity regexp (tests); default: signer-identities.py regexp
#   COSIGN              the cosign binary (tests)
# What is retried: anything that is not a verdict. "no signatures found" and "no matching signatures" are verdicts and are NEVER retried;
# neither are errors the registry answers definitively (MANIFEST_UNKNOWN, NAME_UNKNOWN, UNAUTHORIZED, DENIED). Rate limits (429),
# 5xx, timeouts, resets, TUF/Rekor hiccups are retried.
# Needs: cosign, jq, python3 + PyYAML (for the regexp).
set -uo pipefail

rendered=${1:?usage: verify-signatures.sh <rendered-dir>}
cosign=${COSIGN:-cosign}
attempts=${ATTEMPTS:-5}
backoff=${BACKOFF:-3}
allowlist=${UNSIGNED_ALLOWLIST:-}
issuer=https://token.actions.githubusercontent.com
regexp=${SIGNER_REGEXP:-$(python3 "$(dirname "$0")/signer-identities.py" regexp)} || exit 1
summary=${GITHUB_STEP_SUMMARY:-/dev/null}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

images=$(grep -hE '^\s+image:' "$rendered"/*.yaml | sed -E 's/^\s*image:\s*//; s/"//g' | sort -u | grep '^mladenovskistefan/' || true)
[ -n "$images" ] || { echo "::error::no application images found in the rendered charts"; exit 1; }

# The one line that says why cosign failed: its "Error:" line, without the deprecation notice and the repeated final line.
reason() { { grep -E '^Error' "$1" | head -1; } || true; }

status=0
{ echo "### Cosign verify"; echo; echo "| image | result | detail |"; echo "|---|---|---|"; } >> "$summary"
row() { echo "| \`$1\` | $2 | $3 |" >> "$summary"; }

for ref in $images; do
  name=${ref#mladenovskistefan/}; name=${name%%[@:]*}
  if [[ "$ref" != *@sha256:* ]]; then
    echo "::error::$ref is not pinned by digest"; row "$ref" "FAILED" "not pinned by digest"; status=1; continue
  fi

  verdict=""; detail=""; delay=$backoff
  for ((try = 1; try <= attempts; try++)); do
    if "$cosign" verify --new-bundle-format=false \
         --certificate-oidc-issuer "$issuer" --certificate-identity-regexp "$regexp" \
         "$ref" > "$tmp/out" 2> "$tmp/err"; then
      verdict=signed
      detail=$(jq -r '[.[].optional.Subject // empty] | unique | join(", ")' "$tmp/out" 2> /dev/null || true)
      break
    fi
    msg=$(reason "$tmp/err"); [ -n "$msg" ] || msg=$(tail -n 1 "$tmp/err")
    case "$msg" in
      *"no matching signatures"*) verdict=wrong-signer; detail=${msg#Error: no matching signatures: }; break ;;
      *"no signatures found"*) verdict=unsigned; detail="no signature found (the image is unsigned, or the digest does not exist in the registry)"; break ;;
      *MANIFEST_UNKNOWN* | *NAME_UNKNOWN* | *UNAUTHORIZED* | *DENIED*) verdict=registry-refused; detail=$msg; break ;;
    esac
    detail=$msg # transient: try again
    if ((try < attempts)); then
      echo "::warning::$ref: attempt $try/$attempts failed (${msg:0:300}); retrying in ${delay}s"
      sleep "$delay"; delay=$((delay * 2))
    fi
  done
  [ -n "$verdict" ] || verdict=transient-exhausted

  case "$verdict" in
    signed)
      echo "signed    $ref  ($detail)"; row "$ref" "signed" "$detail" ;;
    unsigned)
      if [[ " $allowlist " == *" $name "* ]]; then
        echo "::warning::$ref has no signature (allow-listed: $name is a hand-built image)"; row "$ref" "unsigned (allow-listed)" "$name"
      else
        echo "::error::$ref: $detail"; row "$ref" "FAILED" "$detail"; status=1
      fi ;;
    wrong-signer)
      echo "::error::$ref is signed, but not by one of our publish workflows: $detail"; row "$ref" "FAILED" "signed by an identity we do not accept: ${detail:0:300}"; status=1 ;;
    registry-refused)
      echo "::error::$ref: the registry refused the lookup: ${detail:0:400}"; row "$ref" "FAILED" "registry refused: ${detail:0:300}"; status=1 ;;
    transient-exhausted)
      echo "::error::$ref: registry or network error after $attempts attempts, no verdict (this is not a missing signature): ${detail:0:400}"
      row "$ref" "FAILED" "registry/network error after $attempts attempts: ${detail:0:300}"; status=1 ;;
  esac
done
exit $status
