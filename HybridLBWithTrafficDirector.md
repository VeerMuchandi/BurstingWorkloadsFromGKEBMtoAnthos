# Hybrid Load Balancing with Traffic Director

Hybrid configurations with Traffic Director require hybrid connectivity using Cloud VPN or an interconnect. In this example we are using [BM Cluster on GCE](./StandUpBareMetalClusterOnGCP.md). Hence we do not need a VPN connection.

## Prerequisites

* [Application deployed on Bare Metal Cluster](./DeployAppOnBMCluster.md)
* [Application deployed on GKE Cluster with KubeRun](./DeployAppOnKuberun.md)


## Setting up Traffic Director

Enable Traffic Director API

```
gcloud services enable trafficdirector.googleapis.com
```

### Create Managed Instance Group

Create a managed instance group for the Traffic Director Middle Proxy which will run on GCP.

```
export REGION=us-central1
export ZONE=${REGION}-a
export MIGTEMPNAME=td-middle-proxy
export MIGNAME="${MIGTEMPNAME}-${ZONE}"
gcloud compute instance-templates create ${MIGTEMPNAME} \
    --service-proxy=enabled,access-log=/var/log/envoy/access.log \
    --tags=allow-hc

gcloud compute instance-groups managed create ${MIGNAME} \
  --zone ${ZONE} \
  --template=${MIGTEMPNAME} \
  --size=1

export INSTANCENAME=$(gcloud compute instance-groups list-instances \
  ${MIGNAME} --zone ${ZONE} --format 'value(NAME)')

export TDPROXYIP=$(gcloud compute instances describe ${INSTANCENAME} \
  --zone=${ZONE} \
  --format='get(networkInterfaces[0].networkIP)')
```

### Connect the Service on On-Prem Cluster

The environment variable WS_EXTERNAL_IP has the entrypoint for the baremetal cluster to the Nginx Proxy.

Create a Network Endpoint Group (NEG) with this IP, set up health checks, and a backend service that associates with this NEG for the on-prem environment.

```
gcloud compute network-endpoint-groups create td-on-prem-neg \
    --network-endpoint-type non-gcp-private-ip-port \
    --zone ${ZONE}

gcloud compute network-endpoint-groups update td-on-prem-neg \
  --zone=${ZONE} \
  --add-endpoint="ip=${WS_EXTERNAL_IP},port=80"

gcloud compute health-checks create http td-on-prem-health-check

gcloud compute backend-services create td-on-prem-backend-service \
    --global \
    --load-balancing-scheme=INTERNAL_SELF_MANAGED \
    --health-checks=td-on-prem-health-check

gcloud compute backend-services add-backend td-on-prem-backend-service \
    --global \
    --network-endpoint-group=td-on-prem-neg \
    --network-endpoint-group-zone=${ZONE} \
    --balancing-mode=RATE \
    --max-rate-per-endpoint=5

```

Verify to make sure you have an NEG and a Backend Service deployed

```

$ gcloud compute network-endpoint-groups list
NAME               LOCATION       ENDPOINT_TYPE            SIZE
td-on-prem-neg     us-central1-a  NON_GCP_PRIVATE_IP_PORT  1

$ gcloud compute backend-services list

NAME                              BACKENDS                                               PROTOCOL
td-on-prem-backend-service        us-central1-a/networkEndpointGroups/td-on-prem-neg     HTTP
ac0a289936eef48278bef14774ecbcd7  us-central1-a/instanceGroups/k8s-ig--f7d25e44c3cbe779  TCP


$ gcloud compute health-checks list
NAME                       PROTOCOL
k8s-f7d25e44c3cbe779-node  HTTP
td-on-prem-health-check    HTTP
```

### Connect the KubeRun Service running on GKE

Annotate the KubeRun cluster with `cloud.google.com/neg='{"exposed_ports": {"80":{"name": "istio-ingress-neg"}}}'`, so that an istio ingress NEG is created.

```
kubectl annotate svc -n gke-system istio-ingress   cloud.google.com/neg='{"exposed_ports": {"80":{"name": "istio-ingress-neg"}}}' --overwrite
```

Verify the NEGs now, there should be one with name `istio-ingress-neg`

```
$ gcloud compute network-endpoint-groups listNAME               LOCATION       ENDPOINT_TYPE            SIZE
istio-ingress-neg  us-central1-a  GCE_VM_IP_PORT           0
td-on-prem-neg     us-central1-a  NON_GCP_PRIVATE_IP_PORT  1
```


Create backend service for the KubeRun on GCP Service

```
gcloud compute health-checks create http td-on-gcp-health-check

gcloud compute backend-services create td-on-gcp-backend-service \
    --global \
    --load-balancing-scheme=INTERNAL_SELF_MANAGED \
    --health-checks=td-on-gcp-health-check

gcloud compute backend-services add-backend td-on-gcp-backend-service \
    --global \
    --network-endpoint-group=istio-ingress-neg \
    --network-endpoint-group-zone=${ZONE} \
    --balancing-mode=RATE \
    --max-rate-per-endpoint=5
```

Now verify that you have the respective backend services configured

```
$ gcloud compute health-checks list
NAME                       PROTOCOL
k8s-f7d25e44c3cbe779-node  HTTP
td-on-gcp-health-check     HTTP
td-on-prem-health-check    HTTP

$ gcloud compute backend-services list
NAME                              BACKENDS                                               PROTOCOL
td-on-gcp-backend-service         us-central1-a/networkEndpointGroups/istio-ingress-neg  HTTP
td-on-prem-backend-service        us-central1-a/networkEndpointGroups/td-on-prem-neg     HTTP
ac0a289936eef48278bef14774ecbcd7  us-central1-a/instanceGroups/k8s-ig--f7d25e44c3cbe779  TCP

```

### Create URL Map on Traffic Director

Create a URL Map that will allow you to shift traffic between services. 

```
gcloud compute url-maps create td-hybrid-url-map \
  --default-service td-on-prem-backend-service
```

### Configure URL Map

Configure this URL map with the map file that has traffic distribution weights. You can edit these weight values if you want to change the traffic percentages. So save this file `hybrid-map.yaml` as you can come back and test.


* Create `hybrid-map.yaml` file. We are configuring 100% traffic to go to on-prem cluster (we can change this distribution later)

**Note:** The values of environment variables `ONPREM_ENDPOINT` and `KUBERUN_ENDPOINT` are required for creating this URL Map. If these values are empty, switch kubernetes context and fill them again. 

```
cat > hybrid-map.yaml <<EOF
defaultService: global/backendServices/td-on-prem-backend-service
name: td-hybrid-url-map
description: ''
hostRules:
- hosts:
  - '*'
  pathMatcher: matcher1

pathMatchers:
- name: matcher1
  defaultService: global/backendServices/td-on-prem-backend-service
  routeRules:
  - priority: 0
    matchRules:
    - prefixMatch: ''
    routeAction:
      weightedBackendServices:
      - backendService: global/backendServices/td-on-prem-backend-service
        weight: 100
        headerAction:
          requestHeadersToAdd:
            - headerName: "Host"
              headerValue: "${ONPREM_ENDPOINT#*//}"
              replace: True
      - backendService: global/backendServices/td-on-gcp-backend-service
        weight: 0
        headerAction:
          requestHeadersToAdd:
            - headerName: "Host"
              headerValue: "${KUBERUN_ENDPOINT#*//}"
              replace: True
EOF

```

Apply the map file to URL map by importing this file.

```

gcloud compute url-maps import td-hybrid-url-map \
     --source=hybrid-map.yaml --quiet

```

### Configure Target Proxy and Forwarding Rules


```
cat > target_proxy.yaml <<EOF
name: td-hybrid-proxy
proxyBind: true
urlMap: global/urlMaps/td-hybrid-url-map
EOF

gcloud compute target-http-proxies import td-hybrid-proxy \
   --source target_proxy.yaml

gcloud compute forwarding-rules create td-hybrid-forwarding-rule \
   --global \
   --load-balancing-scheme=INTERNAL_SELF_MANAGED \
   --address=0.0.0.0 \
   --target-http-proxy=td-hybrid-proxy \
   --ports=8080 \
   --network=default
```


### Configure External LB

Configuration for External LB is very similar to what we did with Traffic Director above

Create a static IP

```
gcloud compute addresses create external-lb-vip \
    --ip-version=IPV4 \
    --global
```

Create Health Check for middleware proxy

```
  gcloud compute health-checks create tcp tcp-basic-check \
        --port 8080
```

Create Firewall Rule to allow Health Checking from Load Balancer

```
gcloud compute firewall-rules create fw-allow-health-checks \
  --network default \
  --action ALLOW \
  --direction INGRESS \
  --source-ranges 35.191.0.0/16,130.211.0.0/22 \
  --target-tags allow-hc \
  --rules tcp
```

Create the backend service for the middleware proxy

```
gcloud compute backend-services create td-middle-proxy-backend-service \
        --protocol HTTP \
        --health-checks tcp-basic-check \
        --global

```

Add Traffic Director Managed Instance Group as the backend

```
  gcloud compute backend-services add-backend td-middle-proxy-backend-service \
        --instance-group=${MIGNAME} \
        --instance-group-zone=${ZONE} \
        --global
```

Create a URL Map

```
gcloud compute url-maps create lb-map-http \
        --default-service td-middle-proxy-backend-service

```

Create a target proxy

```
gcloud compute target-http-proxies create http-lb-proxy \
        --url-map lb-map-http
```

Create a forwarding rule

```
  gcloud compute forwarding-rules create http-forwarding-rule \
        --address=external-lb-vip\
        --global \
        --load-balancing-scheme=EXTERNAL \
        --target-http-proxy=http-lb-proxy \
        --ports=80
```

Create a named port for the instance group

```
gcloud compute instance-groups managed set-named-ports ${MIGNAME} \
    --named-ports http:8080 \
    --zone ${ZONE}
```


## Test the service from External LB

You may have to open the firewall for TD to reach On-Prem service.

```
gcloud compute firewall-rules create gcloud-80-8080 --allow=tcp:80,tcp:8080 --source-ranges 0.0.0.0/0
```

Get the static ip of the external LB

```
LB_IP=$(gcloud compute addresses list --filter="name=external-lb-vip" --format="get(address)"
```

Repeatedly curl against the LB to see how the traffic is flowing

```
for i in {1..20};do curl $LB_IP; done
```

You should see all the traffic going to the On-Prem service now

```
Hello From Anthos On Prem!
Hello From Anthos On Prem!
Hello From Anthos On Prem!
Hello From Anthos On Prem!
Hello From Anthos On Prem!
Hello From Anthos On Prem!
Hello From Anthos On Prem!
Hello From Anthos On Prem!
Hello From Anthos On Prem!
Hello From Anthos On Prem!
Hello From Anthos On Prem!
Hello From Anthos On Prem!
Hello From Anthos On Prem!
Hello From Anthos On Prem!
Hello From Anthos On Prem!
Hello From Anthos On Prem!
Hello From Anthos On Prem!
Hello From Anthos On Prem!
Hello From Anthos On Prem!
Hello From Anthos On Prem!
```

Now change the weights in the `hybrid_map.yaml` file to 50-50 between on-prem and kuberun services and apply the changes by running

```
gcloud compute url-maps import td-hybrid-url-map      --source=hybrid-map.yaml --quiet
```

Test it again. You should see the traffic distributed between the onprem and KubeRun services as below

```     
$ for i in {1..20};do curl $LB_IP ;done                                                                                                  
Hello From KubeRun on GCP!
Hello From KubeRun on GCP!
Hello From Anthos On Prem!
Hello From Anthos On Prem!
Hello From Anthos On Prem!
Hello From Anthos On Prem!
Hello From Anthos On Prem!
Hello From KubeRun on GCP!
Hello From Anthos On Prem!
Hello From KubeRun on GCP!
Hello From Anthos On Prem!
Hello From Anthos On Prem!
Hello From Anthos On Prem!
Hello From Anthos On Prem!
Hello From KubeRun on GCP!
Hello From KubeRun on GCP!
Hello From KubeRun on GCP!
Hello From KubeRun on GCP!
Hello From KubeRun on GCP!
Hello From Anthos On Prem!
```

Change the map back to 100% On-Prem.

We are now ready to configure Cloud Monitoring to handle updates to this URL Map based on the on prem cluster workload.

























