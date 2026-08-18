# VictoriaLogs stack

This repository owns the shared K3s application chart and partition-migration
tool used by the independent VictoriaLogs deployments.

The chart provides:

- A single-node VictoriaLogs StatefulSet with retained local storage.
- A cloudflared connector.
- Optional Vector and vmauth ingress Deployments.
- Temporary migration-only NodePort and PVC helper resources.

Deployment repositories own their namespaces, image pins, component
configuration, resource sizing, Secrets, source Compose stacks, and migration
runbooks. They consume a released chart version instead of a sibling checkout.

## Validate and publish

```bash
make check
make package
helm registry login ghcr.io
make publish
```

`Chart.yaml` and `CHART_VERSION` in the Makefile must be advanced together for
each release. Published consumers pin an exact chart version and generate their
`Chart.lock` with `helm dependency update`; lock files are never edited by hand.

The default target repository is:

```text
oci://ghcr.io/func86/charts/victoria-logs-stack
```

## Migration tool

`tools/victoria-logs-migration.sh` contains the shared partition lifecycle and
resume logic. A deployment wrapper must provide at least:

```text
MIGRATION_NAMESPACE
MIGRATION_NEW_URL
MIGRATION_SOURCE_DATA_PATH
MIGRATION_DESTINATION_NODE
```

The old VictoriaLogs and vlagent URLs retain their loopback defaults. Run the
tool with `--help` for every supported override.
