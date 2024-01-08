# devops-toys

Fork this repo!

## Requirements

- Operating system:
  - Linux (tested)
  - MacOS (untested)
  - Windows (WSL2 required, not tested)
- Tools:
  - git
  - make
- Git:
  - working token
  - configured ssh key
    To generate the key use this command:
    ```shell
    ssh-keygen -t ed25519 -C "devops-toys" -f devops-toys
    ```

## Installation and configuration

Before you start make some adjustments.

### Adjust the .env file to your needs.

```
GITHUB_EMAIL=
GITHUB_USERNAME=
GITHUB_TOKEN=
GITHUB_WORK_EMAIL=
MINIO_ACCESS_KEY=
MINIO_SECRET_KEY=
ARGOCD_PASSWORD=
# cert-manager
CN=devops.toys
C=PL
ST=Kuyavian-Pomeranian
L=Bydgoszcz
O=DevOps Toys
OU=Local Environment
# minio
MINIO_ROOT_USER=
MINIO_ROOT_PASSWORD=
MINIO_USERNAME=
MINIO_PASSWORD=
SONARQUBE_ADMIN_PASSWORD=
```

### Adjust the /etc/hosts file to your needs.

```
127.0.0.1 localhost alert.local.devops grafana.local.devops cd.local.devops jaeger.local.devops prometheus.local.devops hotrod.local.devops jaeger.local.devops bookinfo.local.devops linkerd-viz.local.devops ci.local.devops minio.local.devops sonarqube.local.devops knative.local.devops

172.18.255.200 helloworld-go.default.knative.local.devops
```

### Adjust the Makefile to your needs.

Adding the CA certificate is supported only on Linux systems. By default Arch Linux is used. If you use Debian/Ubuntu based distribution, comment out the Arch Linux part and uncomment Debian/Ubuntu one.

If you sure that everything is configured properly, run `make all` to deploy a cluster and applications.

### Windows setup

If you use Windows make sure that you have **WSL2** installed and configured properly.

Run PowerShell as Administrator and execute this command:

```shell
Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform, Microsoft-Windows-Subsystem-Linux
```

Restart your computer if prompted.

Set WSL 2 as your default version

```shell
wsl --set-default-version 2
```

Turn on Docker Desktop WSL 2 backend:

1. Start Docker Desktop
2. Navigate to Settings > General and check **Use the WSL 2 based engine**.
3. Select Apply & Restart

Install Ubuntu

```shell
wsl --install -d Ubuntu
```

Make Ubuntu your default WSL distribution

```shell
wsl --set-default Ubuntu
```

Restart Docker Desktop and docker command should be available in Ubuntu shell.

If you want to create a Kubernetes Service with **sessionAffinity: ClientIP** it will not be accessible (and neither will any Service created afterwards). 
WSL2 kernel is missing **xt_recent** kernel module, which is used by **Kube Proxy** to implement session affinity. 
You need to compile a custom kernel to enable this feature.

To compile the kernel you need to run build docker container which will be used to build the kernel.

```shell
cd wsl2
docker build -t wsl-kernel-builder .
```

To run the container execute this command:

```shell
docker run --name wsl-kernel-builder -v "$(pwd)"/src:/build --rm -it wsl-kernel-builder
```

On Windows systems **docker run** command should look like this:

```shell
docker run --name wsl-kernel-builder -v "${PWD}"/src:/build --rm -it wsl-kernel-builder
```

The compiled kernel will be available in **src/arch/x86/boot/bzImage**.

Now create a **.wslconfig** file in your home directory and add this line:

```ini
[wsl2]
kernel=c:\\path\\to\\your\\kernel\\bzImage
```

If you want to terminate the WSL2 instance to save memory or “reboot”, open an admin PowerShell prompt and run:
```shell 
wsl --terminate Ubuntu. 
```

Closing a WSL2 window doesn’t shut it down automatically.

If you are using this setup you should skip **make install_docker** step.

### Basic requirements

Run `make install_prerequisutes` to install basic tools.

### Docker

This step is Linux (Debian based distributions)/WSL only! On MacOS use `brew cask install docker`.

Run `make install_docker` to install docker.

### Homebrew

To ensure the compatibility across different systems, use Homebrew as the package manager.
There's nothing preventing you from using tools native to your distribution.

Run `make install_brew` to install Homebrew

Please read the instructions to add Homebrew to your PATH.

### Required packages

Run `make install_packages` to install the required packages.

### Create Kubernetes cluster

Before creating the cluster chceck **kind/cluster-local.yaml** file and adjust it to your needs.

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: local
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP
  - role: worker
  - role: worker
  - role: worker
  - role: worker
  - role: worker
```

This configuration file will create a Kubernetes cluster using **Kind** with one **Control Plane** and five **worker** nodes.

Please pay attention to: **kubeadmConfigPatches** and **extraPortMappings**. The first one is a patch applied to the **InitConfiguration**,
adding a label **ingress-ready=true** to the kubelet. This label is used for targeting this node with specific workloads, especially those related to **ingress-nginx** in this case.
The second one expose ports form the node to the host machine. In our case port 80 and 443 (standard HTTP and HTTPS ports) of the container are mapped to the host's ports 80 and 443, respectively, using TCP protocol.

Run `make cluster_local` to create a cluster.

To check if cluster was created properly run:

```shell
kubectl get nodes
```

### Domain name

The domain name should be set in **.env** file.

To setup new domain name run `make domain_name`.

Make sure you have the appropriate entry in the **/etc/hosts** file or its equivalent.

### Initial setup

Initial setup will deploy a basic instance of **Argo CD**, **cert-manager**, **metallb**, **kube-prometheus-stack**, **sealed-secrets** and **ingress-nginx**. It will also create namespaces required by **bootstrap** application.

### Argo CD repository

Running `make add_repo` will add a **devops-tools** repository to Argo CD. It should be pointing to **your** fork of this repository.

## Certificate Authority

To generate a certificate authority run `make ca`. It will create and configure a certificate authority for the cluster and make this ca as trusted for your system.

### Minio

Run `make minio` to configure Minio credentials.

### SonarQube

Run `make sonarqube` to configure SonarQube credentials.

### Bootstrap

Run `make bootstrap` to deploy **bootstrap** application. It contains secrets, certificates and other resources required by other applications.

### Argo CD

Run `make argocd` to change the admin password in **Argo CD**.

## Exploring the cluster

* [Argo CD](https://cd.local.devops) is a declarative, GitOps continuous delivery tool for Kubernetes.
* [Argo Workflows](https://ci.local.devops) is an open source container-native workflow engine for orchestrating parallel jobs on Kubernetes.
* [Alert Manager](https://alert.local.devops) handles alerts sent by client applications such as the Prometheus server.
* [Grafana](https://grafana.local.devops) is a multi-platform open source analytics and interactive visualization web application.
* [Hotrod](https://hotrod.local.devops) is a demo application used to demonstrate distributed tracing.
* [Jaeger](https://jaeger.local.devops) is an open source end-to-end distributed tracing.
* [Knative](https://knative.local.devops) is a Kubernetes-based platform to build, deploy, and manage modern serverless workloads. Temporary disabled.
* [Linkerd Viz](https://linkerd-viz.local.devops) is a web-based dashboard for Linkerd.
* [Minio](https://minio.local.devops) is an open source object storage server compatible with Amazon S3 APIs.
* [Prometheus](https://prometheus.local.devops) is a monitoring system and time series database.
* [SonarQube](https://sonarqube.local.devops) is an open-source platform for continuous inspection of code quality.

## Tear down

Run `make destroy` to destroy the cluster.
