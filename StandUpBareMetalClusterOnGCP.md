# Standup a BareMetal Simulated Cluster on GCE

This section follows the process described in [go/anthos-bm-gce-vxlan](go/anthos-bm-gce-vxlan) guide to stand up an Anthos Bare Metal cluster after spinning up a few GCE VMs and connecting them via VPC.

## Standing up a BareMetal Cluster

Download the script `create-vms-vxlan.sh` from this repository.

**Note**: A few tweaks have been made to this script to run from CloudShell IDE. Commands have been added to add firewall rules to allow SSH access.

```
chmod +x create-vms-vxlan.sh
source ./create-vms-vxlan.sh
```

If you have issues and have to clean up these VMS, run 

```
gcloud compute instances list | grep 'abm' | awk '{ print $1 }' |   xargs gcloud --quiet compute instances delete --zone=$ZONE
```

## Verifying the cluster was created successfully

```
export VM_PREFIX=$(gcloud compute instances list | grep 'abm' | awk 'NR==1{ print $1 }'| cut -d "-" -f 1,2)
VM_WS=$VM_PREFIX-ws
VM_CP1=$VM_PREFIX-cp1
VM_CP2=$VM_PREFIX-cp2
VM_CP3=$VM_PREFIX-cp3
VM_W1=$VM_PREFIX-w1
VM_W2=$VM_PREFIX-w2
declare -a VMs=("$VM_WS" "$VM_CP1" "$VM_CP2" "$VM_CP3" "$VM_W1" "$VM_W2")
```

The cluster’s kubeconfig is stored on the Admin workstation in the bmctl-workspace directory. Export the kubeconfig path to the KUBECONFIG environment variable to be able to run kubectl commands on the cluster.

### SSH to Admin Workstation

Create a firewall rule to be able to SSH

```
export CLOUDSHELL_IP=$(curl metadata/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip)

gcloud compute firewall-rules create gcloud-cloudshell --allow=tcp:22,tcp:3389,icmp --source-ranges $CLOUDSHELL_IP
```

SSH into the admin workstation:

```
gcloud compute ssh root@$VM_WS --zone $ZONE "${EXTRA_SSH_ARGS[@]}"
```

### Verify Cluster Creation
For example then run the following :

```
export clusterid=$(find ~/bmctl-workspace -type d -name "cluster-*" | rev | cut -d "/" -f 1 | rev)
echo $clusterid
export KUBECONFIG=$HOME/bmctl-workspace/$clusterid/$clusterid-kubeconfig
kubectl get nodes
```

**NOTE** the clusterid displayed above.

Currently the cluster connectivity is available only from the admin workstation that is on VPN.  Otherwise, you can only deploy applications by logging into this admin workstation.

## Kubectl access to the BM Cluster

To attain Kubectl Access to this BM cluster from outside the Admin VM, you an follow this [Connect Gateway Alpha User Guide](https://docs.google.com/document/d/1JNazhLOZn-La96isNOUpwKaLD6KD5trAfz2OKpqkboQ/edit#)


Fill out [this form](https://docs.google.com/forms/d/e/1FAIpQLSdCI7vqM_ehVnwvfvfAPoVuidDwbsi2oaJCK8oKbjWsf1VEAA/viewform) to get access

Once you get access, here is what you can do in short. Detailed notes are in the [user guide](https://docs.google.com/document/d/1JNazhLOZn-La96isNOUpwKaLD6KD5trAfz2OKpqkboQ/edit#). 


### Add Impersonation Policy for Connect Agent 

Create impersonation policy to give ConnectAgent (`connect-agent-sa` in the `gke-connect` namespace) authorization to send user requests to K8S API Server on user's behalf.

**Note:** Run these commands from the workstation where kubeconfig is already setup.  `gcloud compute ssh root@$VM_WS --zone $ZONE "${EXTRA_SSH_ARGS[@]}"`

While you are still logged into admin workstation run the following commands

```
# [USER_ACCOUNT] is an email, either USER_EMAIL_ADDRESS or GCPSA_EMAIL_ADDRESS
$ USER_ACCOUNT=foo@example.com
$ cat <<EOF > /tmp/impersonate.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: gateway-impersonate
rules:
- apiGroups:
  - ""
  resourceNames:
  - ${USER_ACCOUNT}
  resources:
  - users
  verbs:
  - impersonate
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: gateway-impersonate
roleRef:
  kind: ClusterRole
  name: gateway-impersonate
  apiGroup: rbac.authorization.k8s.io
subjects:
- kind: ServiceAccount
  name: connect-agent-sa
  namespace: gke-connect
EOF

# Apply impersonation policy to the cluster.
$ kubectl apply -f /tmp/impersonate.yaml

```

### Add RBAC access to to the user account

Add any necessary RBAC access to the user accessing this account. As an example, here I am adding a `cluster-admin` role to the user
```
kubectl create clusterrolebinding user-cluster-admin --clusterrole=cluster-admin --user=$USER_ACCOUNT
```

Exit out of the admin workstation

```
exit
```

### Grant Cloud IAM roles for Cluster Gateway Users


**Note:** Run these commands from CloudShell or the Workstation from where you spun up the cluster.

```
export PROJECT_ID=$(gcloud config get-value project)
MEMBER=user:YOUREMAIL@ADDRESS
```


Commands for granting this permission to a specific user in a project.

```
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
--member ${MEMBER} \
--role roles/gkehub.gatewayAdmin
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
--member ${MEMBER} \
--role roles/gkehub.viewer

```

Register baremetal cluster created above, if it is not already there. The cluster we have spun up should be already listed when you try `gcloud container hub memberships list`

```
gcloud container hub memberships register [CLUSTER_NAME] \
--context=[CLUSTER_CONTEXT] \
--service-account-key-file=[LOCAL_KEY_PATH] \
--kubeconfig=[KUBECONFIG_PATH] \
--project=[PROJECT_ID]

```

### Set the GCP Account (if required)

Verify current identity 

```
$ gcloud config list
[core]
account = [USER_EMAIL_ADDRESS]/[GCPSA_EMAIL_ADDRESS]
disable_usage_reporting = False
project = my-project

```

If `account` is not set or is different from the MEMBER set above, set the value of the `iam-account` to the corect value.

```
# Switch the current account to a GCPSA.
$ gcloud iam service-accounts keys create
  --iam-account=[GCPSA_EMAIL_ADDRESS] /tmp/keyfile.json
$ gcloud auth activate-service-account --key-file=/tmp/keyfile.json
$ kubectl … # I am the GCPSA now

```

### Download Cluster's KubeConfig

This will generate kubeconfig entry for cluster gateway and set it as the current context.

```
export clusterid=[value of clusterid noted earlier]
gcloud alpha container hub memberships get-credentials $clusterid --project $PROJECT_ID
```

Now you can run kubectl commands on the cluster created from the CloudShell without SSHing to the Admin Workstation.

## Install Anthos Service Mesh

Download ASM and unpack it

```
curl -LO https://storage.googleapis.com/gke-release/asm/istio-1.8.1-asm.5-linux-amd64.tar.gz

tar xzf istio-1.8.1-asm.5-linux-amd64.tar.gz
```

Add tools to your path

```
cd istio-1.8.1-asm.5
export PATH=$PWD/bin:$PATH
```

Configure certs

```
mkdir -p certs && \
pushd certs

make -f ../tools/certs/Makefile.selfsigned.mk root-ca
make -f ../tools/certs/Makefile.selfsigned.mk anthos-on-bm-cacerts
```

Create CA certs secret

```
kubectl create namespace istio-system
kubectl create secret generic cacerts -n istio-system \
  --from-file=anthos-on-bm/ca-cert.pem \
  --from-file=anthos-on-bm/ca-key.pem \
  --from-file=anthos-on-bm/root-cert.pem \
  --from-file=anthos-on-bm/cert-chain.pem
```

Set network annotation for istio-system namespace

```
kubectl label namespace istio-system topology.istio.io/network=anthos-on-bm-network
```

Create ASM cluster configuration file `cluster.yaml` with the following contents

```
$ cat certs/cluster.yaml
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  profile: asm-multicloud
  revision: asm-181-5
  values:
    global:
      meshID: asm
      multiCluster:
        clusterName: anthos-on-bm
      network: anthos-on-bm-network
  components:
    ingressGateways:
      - name: istio-ingressgateway
        enabled: true
      - name: cluster-local-gateway
        enabled: true
        label:
          istio: cluster-local-gateway
          app: cluster-local-gateway
        k8s:
          service:
            type: ClusterIP
            ports:
            - port: 15020
              name: status-port
            - port: 80
              targetPort: 8080
              name: http2
            - port: 443
              targetPort: 8443
              name: https
```

Install Istio

```
istioctl install -f cluster.yaml
```


## Install Knative Serving

Install Knative as listed [here](https://knative.dev/docs/install/any-kubernetes-cluster/)

In short here are the commands (verify the version in the docs above)

```
kubectl apply --filename https://github.com/knative/serving/releases/download/v0.21.0/serving-crds.yaml
kubectl apply --filename https://github.com/knative/serving/releases/download/v0.21.0/serving-core.yaml
```

Configure Knative to use Istio Ingress Gateway
```
kubectl apply --filename https://github.com/knative/net-istio/releases/download/v0.21.0/net-istio.yaml
```

Note the external IP for the istio ingress gateway by running the following command. Since we have setup a cluster using VxLAN, the External IP will be in the VxLAN IP in the range of `10.200.0.xx`

```
kubectl --namespace istio-system get service istio-ingressgateway
```

This IP is not accessible from outside the VxLAN. Hence we need to setup an extra ingress mechanism to reach the istio ingress gateway.

## Set up Ingress

To setup ingress to istio ingress gateway, we will use an Nginx reverse proxy as explained in [this article](https://www.hostinger.com/tutorials/how-to-set-up-nginx-reverse-proxy/).

We will set it up on the admin workstation.

[SSH to Admin VM](#SSH-to-Admin-Workstation) again

```
apt-get update
apt-get install nginx
unlink /etc/nginx/sites-enabled/default
cd /etc/nginx/sites-available/

```

Create a file named [custom-server.conf](./custom-server.conf) here with the following content

```
# cat custom-server.conf
log_format upstreamlog '[$time_local] $remote_addr - $remote_user - $server_name $host to: $upstream_addr: $request $status upstream_response_time $upstream_response_time msec $msec request_time $request_time';

server {

listen 80;

location / {
proxy_set_header Host $host;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-Port $server_port;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_pass http://10.200.0.51;
proxy_http_version 1.1;
proxy_set_header Upgrade $http_upgrade;
access_log /var/log/nginx/access.log upstreamlog;
}

}
```

```
ln -s /etc/nginx/sites-available/custom-server.conf /etc/nginx/sites-enabled/custom-server.conf
```

Start Nginx
```
 service nginx configtest
 service nginx restart
```
































