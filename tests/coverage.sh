#!/usr/bin/env bash
# Measure coverage of scripts/render-formula.sh the way CI does.
#
#   tests/coverage.sh
#
# Three flags the numbers depend on, easy to get wrong by hand. The root must be
# absolute, or SimpleCov reads bashcov's relative paths as different files.
# --skip-uncovered drops bashcov's scan for files no test touched, which lists
# the traced script a second time under its relative path and halves the figure;
# the check at the end of this script is what notices an unmeasured script
# instead. And tracing needs bash 4 or newer for BASH_XTRACEFD, which the bash
# 3.2 macOS ships as /bin/bash does not have.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# SimpleCov reads .simplecov from the working directory, not from --root, and
# without it the harness counts towards the figure. Run from the repo either way.
cd "${root}"

bash_path="${BASHCOV_BASH_PATH:-}"
if [[ -z "${bash_path}" ]]
then
  for candidate in "$(command -v bash)" /bin/bash /usr/local/bin/bash /opt/homebrew/bin/bash
  do
    [[ -x "${candidate}" ]] || continue
    # shellcheck disable=SC2016  # the candidate expands it, not this shell
    major="$("${candidate}" -c 'echo ${BASH_VERSINFO[0]}')"
    if [[ "${major}" -ge 4 ]]
    then
      bash_path="${candidate}"
      break
    fi
  done
fi

[[ -n "${bash_path}" ]] || {
  printf 'No bash 4 or newer found. bashcov cannot trace with bash 3.2.\n' >&2
  exit 1
}

# Floors only rise. SimpleCov's own minimum_coverage is not enforced under
# bashcov, so the floor is checked here, where every run sees it.
FLOOR=100

bashcov --skip-uncovered --bash-path "${bash_path}" --root "${root}" -- \
  "${root}/tests/render-formula.test.sh"

# Asserted the way round where a missing number fails: jq -e exits non-zero on
# false and on null alike, so testing "at or above the floor" also catches a
# report that no longer carries the figure.
if ! jq -e --argjson floor "${FLOOR}" '.total.lines.percent >= $floor' \
   "${root}/coverage/coverage.json" >/dev/null
then
  percent="$(jq '.total.lines.percent' "${root}/coverage/coverage.json")"
  printf 'Line coverage %s is below the floor of %s%%.\n' "${percent}" "${FLOOR}" >&2
  exit 1
fi

# The only exclusion is tests/, reasoned in .simplecov. Everything this tap
# ships has to be measured, so a script that runs in no test fails here rather
# than passing unseen -- which is what bashcov's own scan would have done, had it
# not also double-counted the script it traced.
for script in "${root}"/scripts/*.sh
do
  shipped="${script#"${root}/"}"
  if ! jq -e --arg f "${shipped}" '.coverage | has($f)' \
     "${root}/coverage/coverage.json" >/dev/null
  then
    printf '%s runs in no test: it is absent from the coverage report.\n' \
      "${shipped}" >&2
    exit 1
  fi
done
