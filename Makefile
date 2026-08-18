HELM ?= helm
CHART_DIR ?= charts/victoria-logs-stack
CHART_VERSION ?= 0.1.0
DIST_DIR ?= dist
OCI_REPOSITORY ?= oci://ghcr.io/func86/charts

.PHONY: lint
lint:
	$(HELM) lint $(CHART_DIR)
	$(HELM) lint $(CHART_DIR) -f tests/vector-values.yaml
	$(HELM) lint $(CHART_DIR) -f tests/vmauth-values.yaml

.PHONY: template
template:
	$(HELM) template vector $(CHART_DIR) -n vector-test \
		-f tests/vector-values.yaml >/dev/null
	$(HELM) template vmauth $(CHART_DIR) -n vmauth-test \
		-f tests/vmauth-values.yaml >/dev/null

.PHONY: check
check: lint template
	bash -n tools/victoria-logs-migration.sh
	shellcheck tools/victoria-logs-migration.sh

.PHONY: package
package: check
	mkdir -p $(DIST_DIR)
	$(HELM) package $(CHART_DIR) --destination $(DIST_DIR)

.PHONY: publish
publish: package
	$(HELM) push $(DIST_DIR)/victoria-logs-stack-$(CHART_VERSION).tgz $(OCI_REPOSITORY)
