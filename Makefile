CONTROLLER_GEN_VERSION := 0.4.1
CONVERSION_GEN_VERSION := 0.23.1
LINT_VERSION := 1.51.2
GOSEC_VERSION := "v2.16.0"
KUSTOMIZE_VERSION := 4.5.7

GOLANGCI_EXIT_CODE ?= 1
# Produce CRDs that work back to Kubernetes 1.11 (no version conversion)
CRD_OPTIONS ?= crd
# Set PATH to pick up cached tools. The additional 'sed' is required for cross-platform support of quoting the args to 'env'
SHELL := /usr/bin/env PATH=$(shell echo $(GITROOT)/bin:${PATH} | sed 's/ /\\ /g') bash
# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
	GOBIN = $(shell go env GOPATH)/bin
else
	GOBIN = $(shell go env GOBIN)
endif

GITCOMMIT ?= $(shell git rev-parse --short HEAD 2>/dev/null)
GITROOT ?= $(shell git rev-parse --show-toplevel)

CAPVCD_IMG := cluster-api-provider-cloud-director
ARTIFACT_IMG := capvcd-manifest-airgapped
VERSION ?= $(shell cat $(GITROOT)/release/version)

REGISTRY ?= projects-stg.registry.vmware.com/vmware-cloud-director

PLATFORM ?= linux/amd64
OS ?= linux
ARCH ?= amd64
CGO ?= 0

KUSTOMIZE ?= bin/kustomize
CONTROLLER_GEN ?= bin/controller-gen
CONVERSION_GEN ?= bin/conversion-gen
GOLANGCI_LINT ?= bin/golangci-lint
GOSEC ?= bin/gosec
SHELLCHECK ?= bin/shellcheck


.PHONY: all
all: vendor lint dev

.PHONY: capvcd
capvcd: vendor lint docker-build-capvcd ## Run checks, and build capvcd docker image.

##@ General

# The help target prints out all targets with their descriptions organized
# beneath their categories. The categories are represented by '##@' and the
# target descriptions by '##'. The awk commands is responsible for reading the
# entire set of makefiles included in this invocation, looking for lines of the
# file as xyz: ## something, and then pretty-format the target and help. Then,
# if there's a line with ##@ something, that gets pretty-printed as a category.
# More info on the usage of ANSI control characters for terminal formatting:
# https://en.wikipedia.org/wiki/ANSI_escape_code#SGR_parameters
# More info on the awk command:
# http://linuxcommand.org/lc3_adv_awk.php

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)



##@ Development

.PHONY: vendor
vendor: ## Update go mod dependencies.
	go mod edit -go=1.20
	go mod tidy -compat=1.20
	go mod vendor

.PHONY: fmt
fmt: ## Run go fmt against code.
	go fmt ./...

.PHONY: vet
vet: ## Run go vet against code.
	go vet ./...

.PHONY: golangci-lint
golangci-lint: $(GOLANGCI_LINT) ## Run golangci-lint against code.
	$(GOLANGCI_LINT) run --issues-exit-code $(GOLANGCI_EXIT_CODE)

.PHONY: gosec
gosec: $(GOSEC) ## Run gosec against code.
	$(GOSEC) -conf .gosec.json ./...

.PHONY: shellcheck
shellcheck: $(SHELLCHECK) ## Run shellcheck against code.
	find . -name '*.*sh' -not -path '*/vendor/*' | xargs $(SHELLCHECK) --color

.PHONY: lint
lint: lint-deps golangci-lint gosec shellcheck ## Run golangci-lint, gosec, shellcheck.

.PHONY: lint-fix
lint-fix: $(GOLANGCI_LINT)
	$(GOLANGCI_LINT) run --fix

.PHONY: manifests
manifests: controller-gen ## Generate manifests e.g. CRD, RBAC etc.
	$(CONTROLLER_GEN) $(CRD_OPTIONS) rbac:roleName=manager-role webhook paths="./..." output:crd:artifacts:config=config/crd/bases

.PHONY: generate
generate: controller-gen ## Run controller-gen.
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./..."

.PHONY: conversion
conversion: conversion-gen ## Run conversion-gen.
	rm -f $(GITROOT)/api/*/zz_generated.conversion.*
	$(CONVERSION_GEN) \
		--input-dirs=./api/v1alpha4,./api/v1beta1 \
		--build-tag=ignore_autogenerated_conversions \
		--output-file-base=zz_generated.conversion \
		--go-header-file=./boilerplate.go.txt

.PHONY: autogen-files
autogen-files: manifests generate conversion release-manifests



##@ Build

.PHONY: build
build: bin ## Build CAPVCD binary. To be used from within a Dockerfile
	GOOS=$(OS) GOARCH=$(ARCH) CGO_ENABLED=$(CGO) go build -ldflags "-s -w -X github.com/vmware/cluster-api-provider-cloud-director/release.Version=$(VERSION)" -o bin/cluster-api-provider-cloud-director main.go

.PHONY: test
test: bin/testbin manifests generate ## Run tests.
	test -f bin/testbin/setup-envtest.sh || curl -sSLo bin/testbin/setup-envtest.sh https://raw.githubusercontent.com/kubernetes-sigs/controller-runtime/v0.8.3/hack/setup-envtest.sh
	source bin/testbin/setup-envtest.sh
	fetch_envtest_tools bin/testbin
	setup_envtest_env bin/testbin
	go test ./... -coverprofile cover.out

.PHONY: manager
manager: bin generate ## Build manager binary.
	go build -o bin/manager main.go

.PHONY: run
run: manifests generate ## Run a controller from your host.
	go run ./main.go

.PHONY: docker-build-capvcd
docker-build-capvcd: generate release-manifests build
	docker build  \
		--platform $(PLATFORM) \
		--file Dockerfile \
		--tag $(REGISTRY)/$(CAPVCD_IMG):$(VERSION) \
		--build-arg CAPVCD_BUILD_DIR=bin \
		.

.PHONY: docker-build-artifacts
docker-build-artifacts: release-prep
	docker build  \
		--platform $(PLATFORM) \
		--file artifacts/Dockerfile \
		--tag $(REGISTRY)/$(ARTIFACT_IMG):$(VERSION) \
		.

.PHONY: docker-build
docker-build: docker-build-capvcd docker-build-artifacts ## Build CAPVCD docker image and artifact image.



##@ Deploymet

.PHONY: install
install: manifests kustomize ## Install CRDs into the K8s cluster specified in ~/.kube/config.
	$(KUSTOMIZE) build config/crd | kubectl apply -f -

.PHONY: uninstall
uninstall: manifests kustomize ## Uninstall CRDs from the K8s cluster specified in ~/.kube/config.
	$(KUSTOMIZE) build config/crd | kubectl delete -f -

.PHONY: deploy
deploy: manifests kustomize ## Deploy controller to the K8s cluster specified in ~/.kube/config.
	cd config/manager && kustomize edit set image controller=${CAPVCD_IMG}
	$(KUSTOMIZE) build config/default | kubectl apply -f -

.PHONY: teardown
teardown: manifests kustomize ## Teardown controller from the K8s cluster specified in ~/.kube/config.
	$(KUSTOMIZE) build config/default | kubectl delete -f -



##@ Publish

.PHONY: dev
dev: VERSION := $(VERSION)-$(GITCOMMIT)
dev: git-check release ## Build development images and push to registry.

.PHONY: release
release: docker-build docker-push ## Build release images and push to registry.

.PHONY: release-manifests
release-manifests: kustomize ## Generate release manifests e.g. CRD, RBAC etc.
	sed -e "s/__VERSION__/$(VERSION)/g" config/manager/manager.yaml.template > config/manager/manager.yaml
	$(KUSTOMIZE) build config/default > templates/infrastructure-components.yaml

.PHONY: release-prep
release-prep: ## Generate BOM and dependencies files.
	sed -e "s/__VERSION__/$(VERSION)/g" -e "s~__REGISTRY__~$(REGISTRY)~g" artifacts/bom.json.template > artifacts/bom.json
	sed -e "s/__VERSION__/$(VERSION)/g" -e "s~__REGISTRY__~$(REGISTRY)~g" artifacts/dependencies.txt.template > artifacts/dependencies.txt

.PHONY: docker-push-capvcd
docker-push-capvcd: # Push capvcd image to registry.
	docker push $(REGISTRY)/$(CAPVCD_IMG):$(VERSION)

.PHONY: docker-push-artifacts
docker-push-artifacts: # Push artifacts image to registry
	docker push $(REGISTRY)/$(ARTIFACT_IMG):$(VERSION)

.PHONY: docker-push
docker-push: docker-push-capvcd docker-push-artifacts ## Push images to container registry.



##@ Dependencies

.PHONY: deps
deps: lint-deps kustomize controller-gen conversion-gen ## Download all dependencies locally.

.PHONY: lint-deps
lint-deps: $(GOLANGCI_LINT) $(GOSEC) $(SHELLCHECK) ## Download lint dependencies locally.

.PHONY: kustomize
kustomize: $(KUSTOMIZE) ## Download kustomize binary locally.

.PHONY: controller-gen
controller-gen: $(CONTROLLER_GEN) ## Download controller-gen binary locally.

.PHONY: conversion-gen
conversion-gen: $(CONVERSION_GEN) ## Download conversion-gen binary locally.





.PHONY: clean
clean:
	rm -rf bin
	rm artifacts/bom.json artifacts/dependencies.txt

bin:
	@mkdir -p bin

bin/testbin:
	@mkdir -p bin/testbin

$(KUSTOMIZE): bin
	@cd bin && \
		set -ex -o pipefail && \
		wget "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh"; \
		chmod +x ./install_kustomize.sh; \
		./install_kustomize.sh $(KUSTOMIZE_VERSION) .; \
		rm -f ./install_kustomize.sh;

$(CONTROLLER_GEN): bin
	@GOBIN=$(GITROOT)/bin go install sigs.k8s.io/controller-tools/cmd/controller-gen@v${CONTROLLER_GEN_VERSION}

$(CONVERSION_GEN): bin
	@GOBIN=$(GITROOT)/bin go install k8s.io/code-generator/cmd/conversion-gen@v${CONVERSION_GEN_VERSION}

$(GOLANGCI_LINT): bin
	@set -o pipefail && \
		wget -q -O - https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh -s -- -b $(GITROOT)/bin v$(LINT_VERSION);

$(GOSEC): bin
	@GOBIN=$(GITROOT)/bin go install github.com/securego/gosec/v2/cmd/gosec@${GOSEC_VERSION}

$(SHELLCHECK): bin
	@cd bin && \
		set -o pipefail && \
		wget -q -O - https://github.com/koalaman/shellcheck/releases/download/stable/shellcheck-stable.$$(uname).x86_64.tar.xz | tar -xJv --strip-components=1 shellcheck-stable/shellcheck && \
		chmod +x $(GITROOT)/bin/shellcheck

.PHONY: git-check
git-check:
	@git diff --exit-code --quiet api/ artifacts/ config/ controllers/ pkg/ main.go Dockerfile || (echo 'Uncommitted changes found. Please commit your changes before proceeding.'; exit 1)

