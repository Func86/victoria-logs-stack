# VictoriaLogs stack

This repository owns the shared K3s application chart and partition-migration
tool used by the independent VictoriaLogs deployments.

The chart provides:

- A single-node VictoriaLogs StatefulSet with retained local storage.
- A cloudflared connector.
- Optional Vector and vmauth ingress Deployments. Vector can mount a
  deployment-owned Secret for its directory secret provider.
- Temporary migration-only NodePort and PVC helper resources.

Deployment repositories own their namespaces, image pins, component
configuration, resource sizing, Secrets, source Compose stacks, and migration
runbooks. They consume a released chart version instead of a sibling checkout.

## Validate

```bash
make check
make package
```

## Publish

Update the version in `Chart.yaml`, commit it, and push an exactly matching tag:

```bash
git tag v0.1.1
git push origin v0.1.1
```

The tag-triggered GitHub Actions workflow validates the chart and migration
tool, verifies that the tag is `v<Chart.yaml version>`, and publishes with the
repository's temporary `GITHUB_TOKEN`. No long-lived publishing token is
required. A workflow-created package inherits the repository's visibility and
permissions; confirm that the first package is public before converting the
deployment repositories.

For a manual publication, log in to GHCR and run `make publish`.

Published consumers pin an exact chart version and generate their `Chart.lock`
with `helm dependency update`; lock files are never edited by hand.

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
