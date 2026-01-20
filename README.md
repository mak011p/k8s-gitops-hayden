# 🍼 Overview
Repository showcases a declarative implementation of a Kubernetes cluster, following GitOps principles.

Demonstrates best practices for implementing enterprise-grade security, observability, and comprehensive cluster configuration management using GitOps in a Kubernetes environment.

Should demonstrate the power of the [CNCF ecosystem](https://landscape.cncf.io/).

## 📖 Table of contents

- [🍼 Overview](#-overview)
  - [📖 Table of contents](#-table-of-contents)
  - [🔧 Hardware](#-hardware)
  - [☁️ Cloud Services](#️-cloud-services)
  - [🖥️ Technology Stack](#️-technology-stack)
  - [🤖 Automation](#-automation)
  - [🤝 Acknowledgments](#-acknowledgments)
  - [👥 Contributing](#-contributing)
    - [🚫 Code of Conduct](#-code-of-conduct)
    - [💡 Reporting Issues and Requesting Features](#-reporting-issues-and-requesting-features)
  - [📄 License](#-license)

## 🔧 Hardware

| to do

### TrueNAS iSCSI Storage

The NAS provides iSCSI block storage to the cluster via [democratic-csi](https://github.com/democratic-csi/democratic-csi).

**Configuration notes for TrueNAS 25.x:**
- Use `next` image tag (TrueNAS 25.x changed version string format)
- Omit `zvolDedup` from driver config (Pydantic v2 strict validation rejects it)
- Include `targetGroups` array in iSCSI config

**Storage layout:**
- Pool: `tank` (RAIDZ2, 4x 8TB)
- SLOG: Micron 7450 960GB NVMe (write acceleration)
- Datasets: `tank/k8s/iscsi/v` (volumes), `tank/k8s/iscsi/s` (snapshots)

<details>

## ☁️ Cloud Services

Although I manage most of my infrastructure and workloads on my own, there are specific components of my setup that rely on cloud services.

| Service                                   | Description                                                                                                                     | Cost (AUD)     |
| ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- | -------------- |
| [Cloudflare](https://www.cloudflare.com/) | I use Cloudflare in my home network for DNS management and to secure my domain with Cloudflare's services.                      | ~$69/yr        |
| [GCP](https://cloud.google.com/)          | I use Google Cloud Platform (GCP) to manage backups using Google Cloud Storage (GCS) and employ GCP's OAuth for authentication. | ~20/yr         |
| [GitHub](https://github.com/)             | I use GitHub for code management and version control, enabling seamless collaboration in addition to OAuth for authentication   | Free
| [Lets Encrypt](https://letsencrypt.org/)  | I use Let's Encrypt to generate certificates for secure communication within my network.                                        | Free           |
|                                           |                                                                                                                                 | Total: ~$35/mo |

## 🖥️ Technology Stack

The below showcases the collection of open-source solutions currently implemented in the cluster. Each of these components has been meticulously documented, and their deployment is managed using FluxCD, which adheres to GitOps principles.

The Cloud Native Computing Foundation (CNCF) has played a crucial role in the development and popularization of many of these tools, driving the adoption of cloud-native technologies and enabling projects like this one to thrive.

|                                                                                                                             | Name                                             | Description                                                                                                                   |
| --------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------ |-------------------------------------------------------------------------------------------------------------------------------|
| <img width="32" src="https://github.com/cncf/artwork/raw/main/projects/kubernetes/icon/color/kubernetes-icon-color.svg">    | [Kubernetes](https://kubernetes.io/)             | An open-source system for automating deployment, scaling, and management of containerized applications                        |
| <img width="32" src="https://github.com/cncf/artwork/raw/main/projects/flux/icon/color/flux-icon-color.svg">                | [FluxCD](https://fluxcd.io/)                     | GitOps tool for deploying applications to Kubernetes                                                                          |
| <img width="32" src="https://www.talos.dev/images/logo.svg">                                                                | [Talos Linux](https://www.talos.dev/)            | Talos Linux is Linux designed for Kubernetes                                                                                  |
| <img width="62" src="https://github.com/cncf/artwork/raw/main/projects/cilium/icon/color/cilium_icon-color.svg">            | [Cilium](https://cilium.io/)                     | Cilium is an open source, cloud native solution for providing, securing, and observing network connectivity between workloads |
| <img width="62" src="https://github.com/cncf/artwork/raw/main/projects/istio/icon/color/istio-icon-color.svg">              | [Istio](https://istio.io/)                       | Istio extends Kubernetes to establish a programmable, application-aware network using the powerful Envoy service proxy.       |
| <img width="32" src="https://github.com/cncf/artwork/raw/main/projects/containerd/icon/color/containerd-icon-color.svg">    | [containerd](https://containerd.io/)             | Container runtime integrated with Talos Linux                                                                                 |
| <img width="32" src="https://github.com/cncf/artwork/raw/main/projects/coredns/icon/color/coredns-icon-color.svg">          | [CoreDNS](https://coredns.io/)                   | A DNS server that operates via chained plugins                                                                                |
| <img width="32" src="https://metallb.universe.tf/images/logo/metallb-blue.png">                                             | [MetalLB](https://metallb.universe.tf/)          | Load-balancer implementation for bare metal Kubernetes clusters, using standard routing protocols.                            |
| <img width="32" src="https://github.com/cncf/artwork/raw/main/projects/prometheus/icon/color/prometheus-icon-color.svg">    | [Prometheus](https://prometheus.io)              | Monitoring system and time series database                                                                                    |
| <img width="32" src="https://github.com/cncf/artwork/raw/main/projects/jaeger/icon/color/jaeger-icon-color.svg">            | [Jaeger](https://jaegertracing.io)               | Open-source, end-to-end distributed tracing for monitoring and troubleshooting transactions in complex distributed systems    |
| <img width="32" src="https://github.com/cncf/artwork/raw/main/projects/helm/icon/color/helm-icon-color.svg">                | [Helm](https://helm.sh)                          | The Kubernetes package manager                                                                                                |
| <img width="32" src="https://github.com/cncf/artwork/raw/main/projects/falco/icon/color/falco-icon-color.svg">              | [Falco](https://falco.org)                       | Container-native runtime security                                                                                             |
| <img width="32" src="https://github.com/cncf/artwork/raw/main/projects/flux/flagger/icon/color/flagger-icon-color.svg">     | [Flagger](https://flagger.app/)                  | Progressive delivery Kubernetes operator (Canary, A/B Testing and Blue/Green deployments)                                     |
| <img width="32" src="https://github.com/cncf/artwork/raw/main/projects/opa/icon/color/opa-icon-color.svg">                  | [Open Policy Agent](https://openpolicyagent.org) | An open-source, general-purpose policy engine                                                                                 |
| <img width="52" src="https://github.com/cncf/artwork/raw/main/projects/kyverno/icon/color/kyverno-icon-color.svg">          | [Kyverno](https://kyverno.io/)                   | Kubernetes Native Policy Management                                                                                           |
| <img width="32" src="https://github.com/cncf/artwork/raw/main/projects/dex/icon/color/dex-icon-color.svg">                  | [Dex](https://github.com/dexidp/dex)             | An identity service that uses OpenID Connect to drive authentication for other apps                                           |
| <img width="32" src="https://github.com/cncf/artwork/raw/main/projects/crossplane/icon/color/crossplane-icon-color.svg">    | [Crossplane](https://crossplane.io/)             | Manage any infrastructure your application needs directly from Kubernetes                                                     |
| <img width="32" src="https://github.com/cncf/artwork/raw/main/projects/litmus/icon/color/litmus-icon-color.svg">            | [Litmus](https://litmuschaos.io)                 | Chaos engineering for your Kubernetes                                                                                         |
| <img width="32" src="https://github.com/cncf/artwork/raw/main/projects/openebs/icon/color/openebs-icon-color.svg">          | [OpenEBS](https://openebs.io)                    | Container-attached storage                                                                                                    |
| <img width="32" src="https://github.com/cncf/artwork/raw/main/projects/opentelemetry/icon/color/opentelemetry-icon-color.svg"> | [OpenTelemetry](https://opentelemetry.io)        | Making robust, portable telemetry a built in feature of cloud-native software.                                                |
| <img width="32" src="https://github.com/cncf/artwork/raw/main/projects/thanos/icon/color/thanos-icon-color.svg">               | [Thanos](https://thanos.io)                      | Highly available Prometheus setup with long-term storage capabilities                                                         |
| <img width="32" src="https://github.com/cncf/artwork/raw/main/projects/cert-manager/icon/color/cert-manager-icon-color.svg">   | [Cert Manager](https://cert-manager.io/)         | X.509 certificate management for Kubernetes                                                                                   |
| <img width="32" src="https://grafana.com/static/img/menu/grafana2.svg">                                                     | [Grafana](https://grafana.com)                   | Analytics & monitoring solution for every database.                                                                           |
| <img width="32" src="https://github.com/grafana/loki/blob/main/docs/sources/logo.png?raw=true">                             | [Loki](https://grafana.com/oss/loki/)            | Horizontally-scalable, highly-available, multi-tenant log aggregation system                                                  |
| <img width="62" src="https://velero.io/img/Velero.svg">                                                                     | [Velero](https://velero.io/)                     | Backup and restore, perform disaster recovery, and migrate Kubernetes cluster resources and persistent volumes.               |

## 🤖 Automation

This repository is automatically managed by [Renovate](https://renovatebot.com/). Renovate will keep all of the container images within this repository up to date automatically. It can also be configured to keep Helm chart dependencies up to date as well.

## 📄 License

This repository is [Apache 2.0 licensed](./LICENSE)
