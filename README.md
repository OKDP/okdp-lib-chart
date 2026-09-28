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
    version: ">=0.1.0 <1.0.0"
    # TODO(no-kubocd): switch to oci://quay.io/okdp/platform-charts
    repository: file://../../../../okdp-lib
```

During the no-kubocd migration the consumers (platform-packages,
community-packages, sandbox-dependencies) take the library from a checkout of
this repository next to theirs (`../okdp-lib`); their CI clones it there with
the `sibling_repositories` input of `okdp-chart-ci.yml`.

The range, not an exact version: Helm checks the constraint against the
`file://` chart too, so an exact pin breaks `helm dependency build` of every
consumer as soon as release-please bumps okdp-lib. A breaking okdp-lib release
(1.0.0) needs the consumers' range raised on purpose.

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
| module `enabled: "{{ expr }}"` | `{{ if expr }}` around the `okdp.vendor.render` include; for OIDC modes use `okdp.oidc` (`.dcr.enabled`, `.existing`) |
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
| `okdp.oidc $` | YAML: `global.okdp.oidc` with defaults (`enabled: true`, `scope: "openid profile email groups"`, `clientProvisioning: existing`) and computed booleans `dcr.enabled`, `existing` |
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
   `${suffix}`); for contracts with secret fields only, `secretRef.name` is
   `<ref>-<contract>-credentials` (today none: `hive`, `iceberg-catalog` and
   `trino` have no secret field, so internal references carry no `secretRef`).
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
release name), `secretRef` and `secret`: `{stringData: {...}}` for a plain
Secret, or `{generate: [<okdp.generatedSecret keys>], stringData: {...}}` for
generated credentials. The output carries a `secretRef` only when one of the
two is given (`secret` alone names it `<name>-<contract>-credentials`): give
`secretRef` alone when something else creates the Secret (an upstream chart,
an operator), neither when consumers bring their own credentials (e.g. an s3
store whose consumers use their own grants). An output never points at a
Secret that nobody creates.
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
`name`. Arguments:

| Argument | Default | Meaning |
|---|---|---|
| `ctx`, `name` | required | root context; Secret (and ExternalSecret) name |
| `keys[]` | required | `key` (Secret key), `length` (32), `digits` (6), `symbols` (0), `noUpper` (false), `transform`: `sha256` (hex SHA-256, 64 characters) or `b64enc` (base64 of the password, e.g. an Airflow Fernet key) |
| `stringData` | none | static keys written alongside, literally (a value containing `{{` is escaped for ESO templating) |
| `labels` | none | extra labels on every object and on the target Secret |
| `annotations` | none | added to every object (generators and ExternalSecret), e.g. `helm.sh/resource-policy: keep` + `argocd.argoproj.io/sync-options: Delete=false` for credentials that outlive the release (the target Secret is owned by the ExternalSecret) |
| `type` | none | target Secret `type` (e.g. `Opaque`) |
| `namespace` | release namespace | |
| `refreshInterval` | `"0"` | generated once |
| `apiVersion` | `external-secrets.io/v1` | ExternalSecret API; ESO >= 0.17 serves only `v1` (the platform runs ESO 2.11). The `Password` generators are `generators.external-secrets.io/v1alpha1` |

Generators are named `<name>-<key>` (lowercased, `_` and `.` as `-`); a name
longer than 63 characters is cut and suffixed with 8 hex characters of the
key's SHA-256, so long keys never collide. Nothing random is ever computed by
Helm, so `helm template` is deterministic.

The generated Secret is **frozen once written** (verified on ESO 0.15.1):
with `refreshInterval: "0"` ESO never re-reads the ExternalSecret, so a later
change to its spec (a key added or removed, a new `stringData` value, new
labels) never reaches the Secret, and forcing a refresh would regenerate every
key. To change the keys, render a new Secret name (e.g. suffix `-v2`) and point
the consumers at it; that regenerates its values. Deleting the Secret makes
ESO regenerate it. ESO >= 0.16 keeps this behaviour by default (`refreshPolicy`
unset = `Periodic`, no refresh at interval 0).

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

`vendor.yaml` entries take exactly `name` (directory under `vendor/`),
`repository` (`https://`, `oci://` or `file://<path relative to the wrapper>`),
`version` (exact), optional `chart` (upstream name, default `name`) and
optional `drop` (paths relative to the vendored chart root removed after
unpacking, e.g. `charts/postgresql` for a bundled subchart the wrapper
disables, or `templates/secret.yaml`; no `..`, each must exist). Any other key
fails. `scripts/vendor-charts.sh` of `OKDP/platform-packages` is canonical: the copies in
other repositories stay identical to it.

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
scalars replace; a `null` sets the key to null where Helm would delete it,
which templates read the same except `hasKey`). The upstream templates
see the wrapper's `.Release` (names and `app.kubernetes.io/instance` derive from
`<project>-<instance>`), `.Chart` from the vendored `Chart.yaml`,
`.Capabilities`, `.Template.BasePath` and `.Files` (literal `.Files.Get "x"`
paths are redirected to the vendored directory). Partials (`templates/_*`) of
the chart and of its library subcharts load and, as with Helm, what they print
outside a `define` is discarded; `templates/tests/` and `NOTES.txt` are
skipped; hook annotations are kept. A vendored chart bundling an application subchart
is refused: vendor that subchart separately.

Objects and workload pod templates without `app.kubernetes.io/instance` get
it (the console finds workloads by it); only those documents are
re-serialised. Pass `"instanceLabel" false` to leave the output untouched.
Upstream `values.schema.json` files are not enforced (Helm offers no schema
validation function to templates).

#### `okdp.vendor.crds`

```yaml
{{ include "okdp.vendor.crds" (dict "ctx" $ "chart" "spark-operator") }}
```

Helm installs the `crds/` directory of the chart being installed only, never
of a vendored chart. This renders every `*.yaml`/`*.yml` of
`vendor/<chart>/crds/` (sub-directories included; files are not templates) as
regular objects annotated `helm.sh/resource-policy: keep` and
`argocd.argoproj.io/sync-options: Delete=false,ServerSideApply=true`: kept on
uninstall, server-side applied by Argo (large CRDs exceed the client-side apply
annotation), and upgraded with the chart. The annotations are inserted as text
when the layout allows it (large CRDs are not re-serialised). Fails when a
document is not a `CustomResourceDefinition` or when there is none. A chart
never creates custom resources of a CRD it installs in the same release.

#### `okdp.vendor.secretKeyRef`

```yaml
{{- $out := include "okdp.vendor.render" (dict "ctx" $ "chart" "jupyterhub" "values" $v) }}
{{ include "okdp.vendor.secretKeyRef" (dict "rendered" $out "name" "<release>-hub" "key" "token" "to" "<release>-generated" "toKey" "token") }}
```

For an upstream chart that hard-wires a `secretKeyRef` to a Secret it
generates itself (`lookup` + `rand*`) with no value to point it elsewhere: the
wrapper feeds the chart a placeholder and re-points every container and
init-container env `valueFrom.secretKeyRef {name, key}` of the workload pod
templates (Deployment, StatefulSet, DaemonSet, ReplicaSet, Job, CronJob) to
Secret `to` (key `toKey`, default `key`). Only the changed documents are
re-serialised. Fails when nothing was re-pointed (the upstream chart changed).

#### `okdp.vendor.oidcDcr`

```yaml
{{- if (include "okdp.oidc" . | fromYaml).dcr.enabled }}
{{ include "okdp.vendor.oidcDcr" (dict "ctx" $ "values" (include "mychart.values.dcr" . | fromYaml)) }}
{{- end }}
```

Renders `vendor/oidc-dcr` (the Job registering the OAuth client of
`clientProvisioning: dcr` and writing it to a Secret) like `okdp.vendor.render`,
with names of its own: oidc-dcr 0.3.3 names its Job, ConfigMap, RoleBinding and
headless Service `dcr`/`dcr-headless` whatever the release, so two DCR clients of
one namespace would replace each other's. They are all named `name` (default
`<release>-oidc-dcr`; the Service `<name>-headless`), the ServiceAccount and Role
too, with the references to them. A release with two clients passes a second
`name`, e.g. `<release>-console-oidc-dcr`. Fails when an expected object is
missing (the upstream chart changed). The Job image is pinned
(`alpine:3.24.2` by digest) instead of the chart's `alpine:latest`, unless the
values set `image`; the upstream script still installs curl, jq and kubectl
with `apk` when it starts.

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
