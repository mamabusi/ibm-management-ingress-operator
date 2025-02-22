#
# Copyright 2021 IBM Corporation
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Specify whether this repo is build locally or not, default values is '1';
# If set to 1, then you need to also set 'DOCKER_USERNAME' and 'DOCKER_PASSWORD'
# environment variables before build the repo.
BUILD_LOCALLY ?= 1

# image version for each single arch
VERSION ?= $(shell date +v%Y%m%d)-$(shell git describe --match=$(git rev-parse --short=8 HEAD) --tags --always --dirty)
# image version for the multiarch
RELEASE_VERSION ?= $(shell cat ./version/version.go | grep "Version =" | awk '{ print $$3}' | tr -d '"')

# current CSV version
CSV_VERSION ?= $(RELEASE_VERSION)

# used for make bundle
CHANNELS ?= dev,beta,stable-v1
DEFAULT_CHANNEL ?= stable-v1

# unsed for build image
VCS_URL ?= https://github.com/IBM/ibm-management-ingress-operator
VCS_REF ?= $(shell git rev-parse HEAD)

# used for skip markdown lint rule
MARKDOWN_LINT_WHITELIST=https://quay.io/cnr

# operator image repo and name
REGISTRY ?= hyc-cloud-private-integration-docker-local.artifactory.swg-devops.com/ibmcom
IMG ?= ibm-management-ingress-operator

TESTARGS_DEFAULT := "-v"
export TESTARGS ?= $(TESTARGS_DEFAULT)

LOCAL_OS := $(shell uname)
ARCH := $(shell uname -m)
LOCAL_ARCH := "amd64"
ifeq ($(ARCH),x86_64)
    LOCAL_ARCH="amd64"
else ifeq ($(ARCH),ppc64le)
    LOCAL_ARCH="ppc64le"
else ifeq ($(ARCH),s390x)
    LOCAL_ARCH="s390x"
else
    $(error "This system's ARCH $(ARCH) isn't recognized/supported")
endif

ifeq ($(LOCAL_OS),Linux)
    TARGET_OS ?= linux
    XARGS_FLAGS="-r"
    STRIP_FLAGS=
else ifeq ($(LOCAL_OS),Darwin)
    TARGET_OS ?= darwin
    XARGS_FLAGS=
    STRIP_FLAGS="-x"
else
    $(error "This system's OS $(LOCAL_OS) isn't recognized/supported")
endif

include common/Makefile.common.mk

# Produce CRDs that work back to Kubernetes 1.11 (no version conversion)
CRD_OPTIONS ?= "crd:trivialVersions=true"

# Default bundle image tag
BUNDLE_IMG ?= ibm-management-ingress-operator-bundle
# Options for 'bundle-build'
ifneq ($(origin CHANNELS), undefined)
BUNDLE_CHANNELS := --channels=$(CHANNELS)
endif
ifneq ($(origin DEFAULT_CHANNEL), undefined)
BUNDLE_DEFAULT_CHANNEL := --default-channel=$(DEFAULT_CHANNEL)
endif
BUNDLE_METADATA_OPTS ?= $(BUNDLE_CHANNELS) $(BUNDLE_DEFAULT_CHANNEL)

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

all: manager

check: lint-all ## Check all files lint error

# Run tests
# ENVTEST_ASSETS_DIR = $(shell pwd)/testbin
# test: generate fmt vet manifests
# 	mkdir -p $(ENVTEST_ASSETS_DIR)
# 	test -f $(ENVTEST_ASSETS_DIR)/setup-envtest.sh || curl -sSLo $(ENVTEST_ASSETS_DIR)/setup-envtest.sh https://raw.githubusercontent.com/kubernetes-sigs/controller-runtime/v0.6.3/hack/setup-envtest.sh
# 	source $(ENVTEST_ASSETS_DIR)/setup-envtest.sh; fetch_envtest_tools $(ENVTEST_ASSETS_DIR); setup_envtest_env $(ENVTEST_ASSETS_DIR); go test ./... -coverprofile cover.out

test:
	@go test $(TESTARGS) ./...

coverage: ## Run code coverage test
	@common/scripts/codecov.sh $(BUILD_LOCALLY)

# Build manager binary
manager: generate fmt vet
	go build -o bin/manager main.go

build: generate fmt vet
	@echo "Building ibm-management-ingress-operator binary for $(LOCAL_ARCH)..."
	@GOARCH=$(LOCAL_ARCH) common/scripts/gobuild.sh build/_output/bin/$(IMG) ./
	@strip $(STRIP_FLAGS) build/_output/bin/$(IMG)

# Run against the configured Kubernetes cluster in ~/.kube/config
run: generate fmt vet manifests
	go run ./main.go

# Install CRDs into a cluster
install: manifests kustomize
	$(KUSTOMIZE) build config/crd | kubectl apply -f -

# Uninstall CRDs from a cluster
uninstall: manifests kustomize
	$(KUSTOMIZE) build config/crd | kubectl delete -f -

# Deploy controller in the configured Kubernetes cluster in ~/.kube/config
deploy: manifests kustomize
	cd config/manager && $(KUSTOMIZE) edit set image controller=$(REGISTRY)/$(IMG):$(VERSION)
	$(KUSTOMIZE) build config/default | kubectl apply -f -

# Generate manifests e.g. CRD, RBAC etc.
manifests: controller-gen
	# $(CONTROLLER_GEN) $(CRD_OPTIONS) rbac:roleName=manager-role webhook paths="./..." output:crd:artifacts:config=config/crd/bases
	# @morvencao to add custimize labels for CRD
	# cd config/crd && $(KUSTOMIZE) edit add label -f app.kubernetes.io/name:ibm-management-ingress-operator,app.kubernetes.io/instance:ibm-management-ingress-operator,app.kubernetes.io/managed-by:ibm-management-ingress-operator && cd ../..

# Run go fmt against code
fmt:
	# go fmt ./...

# Run go vet against code
vet:
	# go vet ./...

# Generate code
generate: controller-gen
	# $(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./..."

# Build the docker image
docker-build: test
	docker build -t $(REGISTRY)/$(IMG)-$(LOCAL_ARCH):$(VERSION) --build-arg VCS_REF=$(VCS_REF) --build-arg VCS_URL=$(VCS_URL) -f build/Dockerfile .

# Push the docker image
docker-push:
	docker push $(REGISTRY)/$(IMG)-$(LOCAL_ARCH):$(VERSION)

ifeq ($(BUILD_LOCALLY),0)
    export CONFIG_DOCKER_TARGET = config-docker
endif

build-push-image: build-image push-image

build-image: $(CONFIG_DOCKER_TARGET) build
	@echo "Building the $(IMG) docker image for $(LOCAL_ARCH)..."
	@docker build -t $(REGISTRY)/$(IMG)-$(LOCAL_ARCH):$(VERSION) --build-arg VCS_REF=$(VCS_REF) --build-arg VCS_URL=$(VCS_URL) -f build/Dockerfile .

push-image: $(CONFIG_DOCKER_TARGET) build-image
	@echo "Pushing the $(IMG) docker image for $(LOCAL_ARCH)..."
	@docker push $(REGISTRY)/$(IMG)-$(LOCAL_ARCH):$(VERSION)

# multiarch-image section
multiarch-image: $(CONFIG_DOCKER_TARGET)
	@MAX_PULLING_RETRY=20 RETRY_INTERVAL=30 common/scripts/multiarch_image.sh $(REGISTRY) $(IMG) $(VERSION) $(RELEASE_VERSION)

csv: ## Push CSV package to the catalog
	@RELEASE=$(CSV_VERSION) common/scripts/push-csv.sh

# find or download controller-gen
# download controller-gen if necessary
controller-gen:
ifeq (, $(shell which controller-gen))
	@{ \
	set -e ;\
	CONTROLLER_GEN_TMP_DIR=$$(mktemp -d) ;\
	cd $$CONTROLLER_GEN_TMP_DIR ;\
	go mod init tmp ;\
	go get sigs.k8s.io/controller-tools/cmd/controller-gen@v0.3.0 ;\
	rm -rf $$CONTROLLER_GEN_TMP_DIR ;\
	}
CONTROLLER_GEN=$(GOBIN)/controller-gen
else
CONTROLLER_GEN=$(shell which controller-gen)
endif

kustomize:
ifeq (, $(shell which kustomize))
	@{ \
	set -e ;\
	KUSTOMIZE_GEN_TMP_DIR=$$(mktemp -d) ;\
	cd $$KUSTOMIZE_GEN_TMP_DIR ;\
	go mod init tmp ;\
	go get sigs.k8s.io/kustomize/kustomize/v3@v3.5.4 ;\
	rm -rf $$KUSTOMIZE_GEN_TMP_DIR ;\
	}
KUSTOMIZE=$(GOBIN)/kustomize
else
KUSTOMIZE=$(shell which kustomize)
endif

# Generate bundle manifests and metadata, then validate generated files.
.PHONY: bundle
bundle: manifests
	# operator-sdk generate kustomize manifests -q
	# cd config/manager && $(KUSTOMIZE) edit set image controller=$(REGISTRY)/$(IMG):$(VERSION)
	$(KUSTOMIZE) build config/manifests | operator-sdk generate bundle -q --overwrite --version $(CSV_VERSION) $(BUNDLE_METADATA_OPTS)
	cp config/manifests/bases/ibm-management-ingress-operator.clusterserviceversion.yaml bundle/manifests/ibm-management-ingress-operator.clusterserviceversion.yaml
	cp config/crd/bases/operator.ibm.com_managementingresses.yaml bundle/manifests/operator.ibm.com_managementingresses.yaml
ifeq ($(LOCAL_OS),Linux)
	# add -app suffix for operators.operatorframework.io.bundle.package.v1
	sed -i 's|bundle.package.v1=ibm-management-ingress-operator|bundle.package.v1=ibm-management-ingress-operator-app|g' bundle.Dockerfile
	sed -i 's|bundle.package.v1: ibm-management-ingress-operator|bundle.package.v1: ibm-management-ingress-operator-app|g' bundle/metadata/annotations.yaml
else ifeq ($(LOCAL_OS),Darwin)
	# add -app suffix for operators.operatorframework.io.bundle.package.v1
	sed -i "" 's|bundle.package.v1=ibm-management-ingress-operator|bundle.package.v1=ibm-management-ingress-operator-app|g' bundle.Dockerfile
	sed -i "" 's|bundle.package.v1: ibm-management-ingress-operator|bundle.package.v1: ibm-management-ingress-operator-app|g' bundle/metadata/annotations.yaml
endif
	# operator-sdk bundle validate ./bundle

# Build the bundle image.
.PHONY: bundle-build
bundle-build:
	docker build -f bundle.Dockerfile -t $(REGISTRY)/$(BUNDLE_IMG):$(VERSION) .
