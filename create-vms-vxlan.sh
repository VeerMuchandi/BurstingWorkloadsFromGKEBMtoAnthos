#!/bin/bash
set -x
MACHINE_TYPE=n1-standard-8
VM_PREFIX=abm-$(cat /dev/urandom | env LC_CTYPE=C tr -dc 'a-z0-9' | fold -w 2 | head -n 1)
VM_WS=$VM_PREFIX-ws
VM_CP1=$VM_PREFIX-cp1
VM_CP2=$VM_PREFIX-cp2
VM_CP3=$VM_PREFIX-cp3
VM_W1=$VM_PREFIX-w1
VM_W2=$VM_PREFIX-w2
declare -a VMs=("$VM_WS" "$VM_CP1" "$VM_CP2" "$VM_CP3" "$VM_W1" "$VM_W2")
declare -a IPs=()
export PROJECT_ID=$(gcloud config get-value project)
export ZONE=us-central1-a
# check if baremetal-gcr SA is created
if gcloud iam service-accounts list | grep -q "baremetal-gcr"; then
    echo "The service account baremetal-gcr already exists. Continuing with the installation."
else
   gcloud iam service-accounts create baremetal-gcr
   gcloud iam service-accounts keys create bm-gcr.json \
     --iam-account=baremetal-gcr@${PROJECT_ID}.iam.gserviceaccount.com
fi
gcloud services enable \
    anthos.googleapis.com \
    anthosgke.googleapis.com \
    cloudresourcemanager.googleapis.com \
    container.googleapis.com \
    gkeconnect.googleapis.com \
    gkehub.googleapis.com \
    serviceusage.googleapis.com \
    stackdriver.googleapis.com \
    monitoring.googleapis.com \
    logging.googleapis.com
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:baremetal-gcr@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/gkehub.connect"
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:baremetal-gcr@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/gkehub.admin"
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:baremetal-gcr@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/logging.logWriter"
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:baremetal-gcr@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/monitoring.metricWriter"
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:baremetal-gcr@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/monitoring.dashboardEditor"
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:baremetal-gcr@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/stackdriver.resourceMetadata.writer"
for vm in "${VMs[@]}"
do
    gcloud compute instances create $vm \
              --image-family=ubuntu-2004-lts --image-project=ubuntu-os-cloud \
              --zone=$ZONE \
              --boot-disk-size 600G \
              --boot-disk-type pd-ssd \
              --can-ip-forward \
              --network default \
              --tags http-server,https-server \
              --min-cpu-platform "Intel Haswell" \
              --scopes cloud-platform \
              --machine-type $MACHINE_TYPE
    IP=$(gcloud compute instances describe $vm --format='get(networkInterfaces[0].networkIP)' --zone=$ZONE)
    IPs+=("$IP")
done

# create a firewall rule to be able to ssh

export CLOUDSHELL_IP=$(curl metadata/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip)

gcloud compute firewall-rules create gcloud-cloudshell --allow=tcp:22,tcp:3389,icmp --source-ranges $CLOUDSHELL_IP

# check if corp-ssh-helper is available so VPN isn't required e.g. on mac,
# glinux or cloudtop
EXTRA_SSH_ARGS=()
if command -v corp-ssh-helper &> /dev/null
then
  EXTRA_SSH_ARGS=(-- -o ProxyCommand='corp-ssh-helper %h %p' -ServerAliveInterval=30 -o ConnectTimeout=30)
fi
for vm in "${VMs[@]}"
do
    while ! gcloud compute ssh root@$vm --zone $ZONE  --command "echo SSH to $VM_NAME succeeded" "${EXTRA_SSH_ARGS[@]}"
    do
        echo "Trying to SSH into $vm failed. Sleeping for 5 seconds. zzzZZzzZZ"
        sleep  5
    done
done
i=2 # We start from 10.200.0.2/24
for vm in "${VMs[@]}"
do
gcloud compute ssh root@$vm --zone $ZONE "${EXTRA_SSH_ARGS[@]}" << EOF
apt-get -qq update > /dev/null
apt-get -qq install -y jq > /dev/null
set -x
ip link add vxlan0 type vxlan id 42 dev ens4 dstport 0
current_ip=\$(ip --json a show dev ens4 | jq '.[0].addr_info[0].local' -r)
echo "VM IP address is: \$current_ip"
for ip in ${IPs[@]}; do
    if [ "\$ip" != "\$current_ip" ]; then
        bridge fdb append to 00:00:00:00:00:00 dst \$ip dev vxlan0
    fi
done
ip addr add 10.200.0.$i/24 dev vxlan0
ip link set up dev vxlan0
systemctl stop apparmor.service
systemctl disable apparmor.service
EOF
i=$((i+1))
done

#adding firewall rule again
gcloud compute firewall-rules create gcloud-cloudshell --allow=tcp:22,tcp:3389,icmp --source-ranges $CLOUDSHELL_IP
echo "Continuing to install anthos on BM on the workstation"
gcloud compute ssh root@$VM_WS --zone $ZONE "${EXTRA_SSH_ARGS[@]}" << EOF
set -x
echo "Creating service account keys for service-account baremetal-gcr"
export PROJECT_ID=\$(gcloud config get-value project)
export ZONE=\$(gcloud config get-value compute/zone)
gcloud iam service-accounts keys create bm-gcr.json \
--iam-account=baremetal-gcr@\${PROJECT_ID}.iam.gserviceaccount.com
echo "Installing kubectl"
curl -LO "https://storage.googleapis.com/kubernetes-release/release/\$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
mv kubectl /usr/local/sbin/
mkdir baremetal && cd baremetal
gsutil cp gs://anthos-baremetal-release/bmctl/1.6.0/linux-amd64/bmctl . && chmod a+x bmctl
mv bmctl /usr/local/sbin/
cd ~
echo "Installing docker"
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh
echo "Generating SSH key for root user"
ssh-keygen -t rsa -N "" -f /root/.ssh/id_rsa
sed 's/ssh-rsa/root:ssh-rsa/' ~/.ssh/id_rsa.pub > ssh-metadata
for vm in ${VMs[@]}
do
gcloud compute instances add-metadata \$vm --zone $ZONE --metadata-from-file ssh-keys=ssh-metadata
done
echo "Deploying Anthos on BM"
clusterid=cluster-\$(cat /dev/urandom | env LC_CTYPE=C tr -dc 'a-z0-9' | fold -w 4 | head -n 1)
bmctl create config -c \$clusterid
cat > bmctl-workspace/\$clusterid/\$clusterid.yaml << EOB
---
gcrKeyPath: /root/bm-gcr.json
sshPrivateKeyPath: /root/.ssh/id_rsa
gkeConnectAgentServiceAccountKeyPath: /root/bm-gcr.json
gkeConnectRegisterServiceAccountKeyPath: /root/bm-gcr.json
cloudOperationsServiceAccountKeyPath: /root/bm-gcr.json
---
apiVersion: v1
kind: Namespace
metadata:
  name: cluster-\$clusterid
---
apiVersion: baremetal.cluster.gke.io/v1
kind: Cluster
metadata:
  name: \$clusterid
  namespace: cluster-\$clusterid
spec:
  anthosBareMetalVersion: 1.6.0
  type: hybrid
  gkeConnect:
    projectID: \$PROJECT_ID
  controlPlane:
    nodePoolSpec:
      clusterName: \$clusterid
      nodes:
      - address: 10.200.0.3
      - address: 10.200.0.4
      - address: 10.200.0.5
  clusterNetwork:
    pods:
      cidrBlocks:
      - 192.168.0.0/16
    services:
      cidrBlocks:
      - 172.26.232.0/24
  loadBalancer:
    mode: bundled
    ports:
      controlPlaneLBPort: 443
    vips:
      controlPlaneVIP: 10.200.0.49
      ingressVIP: 10.200.0.50
    addressPools:
    - name: pool1
      addresses:
      - 10.200.0.50-10.200.0.70
  clusterOperations:
    location: us-central1-a
    projectID: \$PROJECT_ID
  storage:
    lvpNodeMounts:
      path: /mnt/localpv-disk
      storageClassName: node-disk
    lvpShare:
      numPVUnderSharedPath: 5
      path: /mnt/localpv-share
      storageClassName: standard
---
apiVersion: baremetal.cluster.gke.io/v1
kind: NodePool
metadata:
  name: node-pool-1
  namespace: cluster-\$clusterid
spec:
  clusterName: \$clusterid
  nodes:
  - address: 10.200.0.6
  - address: 10.200.0.7
EOB
bmctl create cluster -c \$clusterid
EOF