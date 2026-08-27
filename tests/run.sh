#!/usr/bin/env bash
#
# Copyright 2026 The OKDP Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# okdp-lib tests, offline (helm only).
#
#   tests/run.sh            run everything
#   tests/run.sh --update   rewrite tests/golden/ from the current output
#
# 1. templates/_contracts.gen.tpl is in sync with contracts/*.schema.json.
# 2. tests/chart renders every ci/*-values.yaml exactly as tests/golden/<name>.yaml
#    (release demo-mini, namespace demo) and passes helm lint.
# 3. every tests/cases/fail-*.yaml (layered over ci/full-values.yaml) fails
#    with the message in its "# expect:" line.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
lib=$(cd "${here}/.." && pwd)
chart="${here}/chart"
update=false
[[ "${1:-}" == "--update" ]] && update=true

rc=0
pass() { echo "ok   $*"; }
failed() { echo "FAIL $*"; rc=1; }
# Helm 4 prints plugin warnings on stderr on some machines: keep only real output.
helm_() { helm "$@" 2> >(grep -v 'failed to load plugins' >&2); }

"${lib}/hack/gen-contracts.sh" --check && pass "contracts embedded" || failed "contracts embedded"

for f in "${lib}"/contracts/*.schema.json; do
  if jq -e '."$schema" == "http://json-schema.org/draft-07/schema#" and .type == "object" and (."x-okdp-contract" | type == "string") and ((.required // []) - (.properties | keys) == [])' "$f" >/dev/null; then
    pass "schema $(basename "$f")"
  else
    failed "schema $(basename "$f"): draft-07, x-okdp-contract, required fields declared"
  fi
done

helm_ dependency build "${chart}" >/dev/null

for values in "${chart}"/ci/*-values.yaml; do
  name=$(basename "${values}" -values.yaml)
  golden="${here}/golden/${name}.yaml"
  out=$(helm_ template demo-mini "${chart}" --namespace demo -f "${values}")
  if ${update}; then
    printf '%s\n' "${out}" > "${golden}"
    pass "golden ${name} (updated)"
  elif diff -u "${golden}" <(printf '%s\n' "${out}"); then
    pass "golden ${name}"
  else
    failed "golden ${name}: output differs from tests/golden/${name}.yaml (run tests/run.sh --update if intended)"
  fi
  if helm_ lint "${chart}" --namespace demo -f "${values}" >/dev/null; then
    pass "lint ${name}"
  else
    failed "lint ${name}"
  fi
done

for case in "${here}"/cases/fail-*.yaml; do
  name=$(basename "${case}" .yaml)
  expect=$(sed -n 's/^# expect: //p' "${case}")
  if err=$(helm_ template demo-mini "${chart}" --namespace demo -f "${chart}/ci/full-values.yaml" -f "${case}" 2>&1 >/dev/null); then
    failed "${name}: rendered, expected a failure"
  elif grep -qF -- "${expect}" <<<"${err}"; then
    pass "${name}"
  else
    failed "${name}: expected '${expect}', got: ${err}"
  fi
done

exit "${rc}"
