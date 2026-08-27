# okdp-lib

Library chart shared by every OKDP chart. It replaces what KuboCD did around a
package: the platform Context (`global.okdp`), contracts and connections, the
package `outputs` and `usage`, generated secrets, and the rendering of module
values from a template.

- Chart: this repository's root (type `library`), published to
  `oci://quay.io/okdp/platform-charts/okdp-lib`.
- Contracts: [`contracts/<contract>.schema.json`](contracts/) (draft-07), the
  canonical definition of `database-server`, `s3`, `hive`, `iceberg-catalog`
  and `trino`. Go code reads them from the module
  `github.com/okdp/okdp-lib/contracts` (`contracts.FS`).
- Tests: [`tests/run.sh`](tests/run.sh) (offline, helm only) and `go test ./...`.
- Releases: release-please tags `vX.Y.Z`, which is both the chart version and
  the Go module version.

## Using it

```yaml
# Chart.yaml
dependencies:
  - name: okdp-lib
    version: 0.1.0
    # TODO(no-kubocd): switch to oci://quay.io/okdp/platform-charts
    repository: file://../../../../okdp-lib
```

During the no-kubocd migration the consumers (platform-packages,
community-packages, sandbox-dependencies) take the library from a checkout of
this repository next to theirs (`../okdp-lib`); their CI clones it there with
the `sibling_repositories` input of `okdp-chart-ci.yml`.

`helm dependency build` before `helm template`/`helm lint`.

A service chart is typically:

```
Chart.yaml            version <upstream>-<okdp semver>, appVersion <upstream>
values.yaml           global/connections placeholders + the former KuboCD parameters
values.schema.json    draft-07, x-ui-* hints, x-okdp-connection-ref on connection refs
vendor.yaml           upstream charts rendered with computed values (see okdp.vendor.render)
vendor/<name>/        their pristine unpacked copy (scripts/vendor-charts.sh)
templates/
  _instance.tpl       okdp.instance.url / usage / outputs overrides
  _values.tpl         one define per upstream chart: its values, computed (the former module `values:`)
  <name>.yaml         {{ include "okdp.vendor.render" (dict "ctx" $ "chart" "<name>" "values" ...) }}
  descriptor.yaml     {{ include "okdp.descriptor" . }}
ci/*-values.yaml      include a global.okdp block: platform values are not in values.yaml
```

Calling convention: helpers shown taking `$` accept the root context or a
dict carrying it as `ctx`. Helpers with options always take a dict with `ctx`.
Helpers returning structured data return YAML: pipe them to `fromYaml`.

## Translating a KuboCD package

| KuboCD | Helm + okdp-lib |
|---|---|
| `.Context.X` | `.Values.global.okdp.X` (same keys) |
| `.Parameters.X` | `.Values.X` (same names, top level) |
| `.Release.metadata.name` | `.Release.Name` (now `<project>-<instance>`) |
| `.Release.spec.targetNamespace` | `.Release.Namespace` |
| `type: connectionRef, contract: c` | `"type": "string", "x-okdp-connection-ref": {"contract": "c"}` + `okdp.connection` |
| title `"Group \| Label \| widget \| order:1 columns:2 advanced:true condition:a=b"` | `title`, `x-ui-group`, `x-ui-widget`, `x-ui-order`, `x-ui-columns`, `x-ui-advanced`, `x-ui-condition: {field: a, value: b}` |
| `required: true` on a property | parent `required: [...]` |
| module `values:` template | a define returning YAML, passed to `okdp.vendor.render` |
| module `enabled: "{{ expr }}"` | `{{ if expr }}` around the `okdp.vendor.render` include; for OIDC modes use `okdp.oidc` (`.dcr.enabled`, `.kubauth.enabled`) |
| module `dependsOn` | nothing: resources must converge in any order |
| `outputs` | `okdp.instance.outputs` + `okdp.contract.<c>.provide` |
| `usage` | `okdp.instance.usage` |
| `internal-secrets` (StringSecret) / `randAlphaNum` + `lookup` | `okdp.generatedSecret` (ESO Password generator) |
| `kcd-<release>-<output>` connection name | the provider release name `<project>-<instance>` |

## Helpers

### Platform (`global.okdp`)

| Helper | Returns |
|---|---|
| `okdp.require (dict "ctx" $ "keys" (list "ingress.suffix" ...))` | nothing; fails with "global.okdp.X is required ... platform/platform-values.yaml" |
| `okdp.platform.get (dict "ctx" $ "path" "a.b")` | YAML `{v: <value or null>}` |
| `okdp.oidc $` | YAML: `global.okdp.oidc` with defaults (`enabled: true`, `scope: "openid profile email groups"`, `clientProvisioning: existing`) and computed booleans `dcr.enabled`, `kubauth.enabled`, `existing` |
| `okdp.proxy.env $` | YAML map `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` (empty ones left out) |
| `okdp.proxy.envList $` | the same as a Kubernetes `env` list |

### Names and labels

| Helper | Returns |
|---|---|
| `okdp.fullname (dict "ctx" $ "suffix" "x")` | `<release>-x` (63 chars max); `okdp.fullname $` is the release name |
| `okdp.labels $` / `(dict "ctx" $ "component" "c")` | standard labels + `app.kubernetes.io/instance: <release>`, `okdp.io/instance`, `okdp.io/service` |
| `okdp.selectorLabels` | the stable subset |
| `okdp.ingressHost $` / `(dict "ctx" $ "name" "trino")` | `<name>-<namespace>.<ingress.suffix>`, name defaults to the chart name (the KuboCD-era hosts) |
| `okdp.url` | `https://` + `okdp.ingressHost` |
| `okdp.ingressAnnotations $` | `cert-manager.io/cluster-issuer: <certificateIssuers.selfSigned.name>` |

### Consuming a connection: `okdp.connection`

```yaml
{{- $hive := include "okdp.connection" (dict "ctx" $ "ref" .metastore "contract" "hive" "field" "hiveCatalogs[0].metastore") | fromYaml }}
hive.metastore.uri={{ $hive.thriftUri }}
```

Resolution of `ref`:

1. `.Values.connections.<ref>` (an external connection: a values layer from
   `projects/<p>/connections/<ref>.yaml`). Its `contract` must match; its fields
   must belong to the contract; secret fields are refused (they live in the
   Secret named by `secretRef: {name}`).
2. Otherwise an internal OKDP instance: `ref` is a release name in the same
   namespace. The fields come from the contract's naming convention
   (`x-okdp-internal` in its schema, placeholders `${ref}`, `${namespace}`,
   `${suffix}`), `secretRef.name` is `<ref>-<contract>-credentials`.
   `s3` and `database-server` have no convention: reference them through a
   connection file.

Then defaults and derived fields (`x-okdp-derived`, e.g. the JDBC `driver` from
`engine`) are filled in, and required fields and enums checked.

The result holds the contract's non-secret fields, `secretRef: {name}` when
known, and `okdp: {ref, contract, source: external|internal}`. Credentials are
read at runtime with `secretKeyRef` on `secretRef.name`, never copied.

Internal conventions (the provider charts must follow them, `okdp.contract.provide` checks it):

| Contract | Fields for `ref` in namespace `ns` |
|---|---|
| `hive` | `thriftUri: thrift://<ref>-hive-metastore.<ns>.svc:9083` |
| `iceberg-catalog` | `uri: https://polaris-<ns>.<suffix>/api/catalog`, `internalUri: http://<ref>-polaris.<ns>.svc:8181/api/catalog` (no `realm`) |
| `trino` | `url: https://trino-<ns>.<suffix>`, `uri: trino://trino@trino-<ns>.<suffix>:443`, `internalUri: trino://trino@<ref>-trino.<ns>.svc:8080` (no `catalogs`) |
| `s3`, `database-server` | none: external connections only |

### Providing a connection and the descriptor

A service chart overrides three hooks (a chart's own define wins over the
library's) and includes the descriptor:

```yaml
{{/* templates/_instance.tpl */}}
{{- define "okdp.instance.url" -}}{{ include "okdp.url" . }}{{- end -}}
{{- define "okdp.instance.usage" -}}
Open {{ include "okdp.url" . }}.
{{- end -}}
{{- define "okdp.instance.outputs" -}}
{{ include "okdp.contract.hive.provide" (dict "ctx" . "values" (dict "thriftUri" $uri)) }}
{{- end -}}

{{/* templates/descriptor.yaml */}}
{{ include "okdp.descriptor" . }}
```

`okdp.contract.provide` (and the shortcuts `okdp.contract.<contract>.provide`)
takes `ctx`, `values` (non-secret fields), optional `name` (default: the
release name), `secretRef` (default `<name>-<contract>-credentials`) and
`secret`: `{stringData: {...}}` for a plain Secret, or
`{generate: [<okdp.generatedSecret keys>], stringData: {...}}` for generated
credentials. Leave `secret` out when something else creates that Secret.
It validates the fields against the contract and, for an output named after
the release, against the contract's internal convention.

`okdp.descriptor` renders ConfigMap `<release>-okdp` (labels `okdp.io/instance`,
`okdp.io/service`, `okdp.io/provides-<contract>`; data `service`, `version`,
`url`, `usage`, `outputs.yaml`) and the credentials Secrets declared with
`secret`. The console lists these ConfigMaps.

### Generated secrets: `okdp.generatedSecret`

```yaml
{{ include "okdp.generatedSecret" (dict "ctx" $ "name" (printf "%s-internal" .Release.Name)
     "keys" (list (dict "key" "shared-secret" "length" 32))) }}
```

One ESO `Password` generator per key and one `ExternalSecret` writing Secret
`name`. Key options: `length` (32), `digits` (6), `symbols` (0), `noUpper`
(false), `transform: sha256` (64 hex characters). `stringData` adds static
keys; `refreshInterval` defaults to `"0"` (generated once); `apiVersion`
defaults to `external-secrets.io/v1` (ESO >= 0.17 serves only `v1`; the
`Password` generators are `generators.external-secrets.io/v1alpha1`).
Nothing random is ever computed by Helm, so `helm template` is deterministic.

### Upstream charts: `okdp.vendor.render`

A Helm dependency only receives static values; a KuboCD module computed them.
So the wrapper vendors the upstream chart and renders it with computed values:

```yaml
# vendor.yaml
charts:
  - name: trino
    repository: https://trinodb.github.io/charts
    version: 1.42.1
```

```sh
scripts/vendor-charts.sh packages/services/trino          # unpack under vendor/trino
scripts/vendor-charts.sh --check packages/services/trino  # CI: vendor/ matches vendor.yaml
```

```yaml
{{- if .Values.enableOPA }}
{{ include "okdp.vendor.render" (dict "ctx" $ "chart" "opa-kube-mgmt" "values" (include "trino.opa.values" . | fromYaml)) }}
{{- end }}
```

The values are merged over the vendored `values.yaml` (maps merge, lists and
scalars replace, a `null` does not delete a default). The upstream templates
see the wrapper's `.Release` (names and `app.kubernetes.io/instance` derive from
`<project>-<instance>`), `.Chart` from the vendored `Chart.yaml`,
`.Capabilities`, `.Template.BasePath` and `.Files` (literal `.Files.Get "x"`
paths are redirected to the vendored directory). Partials of the chart and of
its library subcharts load; `templates/tests/` and `NOTES.txt` are skipped;
hook annotations are kept. A vendored chart bundling an application subchart
is refused: vendor that subchart separately.

The upstream chart must itself respect the forbidden patterns (no `lookup`,
no random function, hooks limited to pre/post-install/upgrade): review it when
vendoring or upgrading.

## Tests

```sh
tests/run.sh           # contracts, golden renders, lint, failure cases
tests/run.sh --update  # after an intended output change
hack/gen-contracts.sh  # after editing contracts/*.schema.json
go test ./...          # the Go package of the contracts
```

`tests/chart` is an application chart exercising every helper;
`tests/golden/` holds its expected output per `ci/*-values.yaml`;
`tests/cases/fail-*.yaml` each assert one error message.
