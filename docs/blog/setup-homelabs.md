# From Cloud to Core: Building the "Absolute Beast" Homelab

For the past year, my digital life lived on **Rackspace**. It was perfect: for less than $20 a month, I had a reliable 3-node Kubernetes cluster running Grafana, Prometheus, n8n, and Postgres. It was cheap, stable, and it worked.

But as any developer knows, eventually, you hit a wall where "enough" isn't enough anymore. This weekend, I finally pulled the trigger, wiped a brand-new Minisforum UM890 Pro, and began my journey into the world of self-hosted infrastructure.

---

## 1. Why Leave the Cloud?
While Rackspace served me well, the allure of a homelab was too strong to resist. Here’s why I made the leap:

* **Compute Power vs. Cost:** In the cloud, 32GB of RAM and an 8-core/16-thread CPU (like the Ryzen 9 in my UM890 Pro) would cost hundreds of dollars a month. Locally, it’s a one-time hardware investment.
* **Investment in Learning:** Running your own hardware forces you to learn about the underlying systems. It’s not just about Kubernetes; it’s about storage, networking, and hardware management. I want to understand it to get some ideas for upcoming projects about infrastructure and DevOps.
* **AI and GPU Potential:** With the rise of local LLMs and AI workloads, when this project does not serve me well, I can repurpose it as a dedicated AI node. The UM890 Pro's Ryzen 9 CPU is powerful, but the real game-changer will be adding an eGPU via the OCuLink port for AI acceleration.

---

## 2. The Build: Provisioning the Iron
I chose **Proxmox VE (PVE)** as my base layer. Why? Because I prioritize my weekends. If I break a Kubernetes node while experimenting, I want to restore a snapshot in seconds rather than re-imaging an entire SSD.

### Step 1: Installing PVE and Storage Logic
I encountered my first architectural choice at the storage screen. I went with **LVM-Thin** on my 1TB NVMe.
* **Why?** While ZFS is powerful, LVM-Thin provides excellent performance for a single-drive setup without the memory overhead of ZFS.

### Step 2: Creating the Trinity (Jarvis, Edith, and Karen)
I decided to build a 3-node cluster manually to ensure a "clean room" environment for each.

| Node Name | Role | Resources |
| :--- | :--- | :--- |
| **Jarvis** | Master (Control Plane) | 4 vCPU, 16GB RAM |
| **Edith** | Worker 01 | 4 vCPU, 6GB RAM |
| **Karen** | Worker 02 | 4 vCPU, 6GB RAM |

**Problem Encountered: The QEMU Roadblock**
Initially, Proxmox couldn't see the internal IP addresses of my VMs.
* **The Fix:** You must install the `qemu-guest-agent` inside the Ubuntu VM.
```bash
sudo apt update && sudo apt install qemu-guest-agent -y
```

### Step 3: Remote Access with Tailscale
I chose **Tailscale** over a Cloudflare Tunnel for my management layer. It’s simpler to set up, and I can access my cluster from anywhere without worrying about port forwarding or dynamic DNS.

```bashbash
# On each VM
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --authkey <YOUR_TAILSCALE_AUTH_KEY>
```

### Step 4: Bootstrapping k3s

On **Jarvis** (the Master), I initialized k3s with a flag to allow remote access via the Tailscale IP:

```bash
curl -sfL https://get.k3s.io | sh -s - server --tls-san <MY_TAILSCALE_IP>
```

Get the token for joining the cluster:

```bash
sudo cat /var/lib/rancher/k3s/server/node-token
```

On **Edith** and **Karen** (the Workers), I joined the cluster using the token from Jarvis:

```bash
curl -sfL https://get.k3s.io | K3S_URL=https://<JARVIS_TAILSCALE_IP>:6443 K3S_TOKEN=<TOKEN_FROM_JARVIS> sh -
```

Go to Jarvis and check the nodes:

```bash
kubectl get nodes
```

### Step 5: Setting Up the Kubeconfig

To manage the cluster from my local machine, I copied the kubeconfig file from Jarvis:

**On Jarvis**

```bash
sudo cp /etc/rancher/k3s/k3s.yaml ~/temp.yaml
sudo chown $USER:$USER ~/temp.yaml
```

On my local machine, I copied the file over using `scp`:

```bash
scp user@jarvis:~/temp.yaml ~/.kube/config-homelab
```

Then, I edited the `~/.kube/config-homelab` file to replace `127.0.0.1` with Jarvis's Tailscale IP:

```bash
sed -i 's/127.0.0.1/<JARVIS_TAILSCALE_IP>/g' ~/.kube/config-homelab
```

**The "Command Center" - (Merging Configs)**
I didn't want to lose access to my existing Rackspace or Minikube clusters. I needed a way to switch between "Jarvis" and "Rackspace" instantly.

I merged them into a single Kubeconfig using the "flatten" trick:

```bash
export KUBECONFIG=~/.kube/config:~/.kube/config-rackspace:~/.kube/config-homelab
kubectl config view --flatten > ~/.kube/config_merged
mv ~/.kube/config_merged ~/.kube/config
```

Now, I use `kubectx` to switch environments like a pro:
```bash
kubectx homelander     # Talking to my local homelab
kubectx rackspace     # Now I'm talking to the Cloud
```
