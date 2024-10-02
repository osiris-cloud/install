# Overview

Osiris Cloud requires a minimun of 3 machines to be functional. Each of them serve the following roles

 - Controller - Used for running Osiris Cloud Controller. This also serves as the master node for the Kubernetes Cluster
 - Worker - For running workloads
 - Load Balancer - External gateway for clients to interact with the cloud

# Design Consideration

The most common way to expose services is through an external load balancer which is a dedicated machine that exposes services running on Node Ports through forewarding/NAT. It would need to have 2 interfaces, external and internal.

![Newtork Design](network-design.png)

# Installation

> [!NOTE]
> Osiris Cloud Requires Hardware Assisted Virtualization to be turned on when ran on a hypervisor

Follow these steps to have a minimum viable cluster. 3 machines are installed with each of the roles mentioned above.

Minimun Requirements

Controller: 2 CPU cores, 4GB RAM, 50GB Disk Space

Worker: 4 CPU cores, 10GB RAM, 120GB Disk Space

Load Balancer: 2 CPU cores, 2GB RAM, 20GB Disk Space

10G networking is recommended but 1G will also work fine.

## Prerequisites

OS: Fedora Server 40 or later

Update system first with  `sudo dnf -y update && sudo dnf -y upgrade`


## Controller

This will generate a token which you can use to join the cluster

```bash
curl -sSL https://raw.githubusercontent.com/osiris-cloud/install/refs/heads/main/install.sh | bash -s -- --role controller
```

## Worker

```bash
curl -sSL https://raw.githubusercontent.com/osiris-cloud/install/refs/heads/main/install.sh | bash -s -- --role worker --controller-ip <ip> --token <token>
```

## Load Balancer

```bash
curl -sSL https://raw.githubusercontent.com/osiris-cloud/install/refs/heads/main/install.sh | bash -s -- --role lb --node-ip "ip-1,ip-2,ip-3"
```
