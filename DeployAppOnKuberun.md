# Deploy Service on GKE Cluster with KubeRun

In this section we will setup a GKE cluster on GCP with Kuberun and deploy our application on this cluster. This section is based on documentation [here](https://cloud.google.com/solutions/deploying-internal-services-using-cloud-run-on-gke)

## Setup a GKE Cluster with Kuberun enabled

Set up the environment variables by choosing specific zone and cluster name.

```
CLUSTER_ZONE=us-central1-a
CLUSTER=kuberun-central1-a
```

Set the configurations for the gcloud environment

```
gcloud config set compute/zone $ZONE
gcloud config set run/cluster $CLUSTER
gcloud config set run/cluster_location $CLUSTER_ZONE
```

Create a cluster with `CloudRun` enabled.

```
gcloud beta container clusters create $CLUSTER  \
--addons HorizontalPodAutoscaling,HttpLoadBalancing,CloudRun    \
--enable-ip-alias   \
--enable-stackdriver-kubernetes \
--machine-type n1-standard-2
```

Get credentials to create a kubernetes context to the newly created cluster

```
gcloud container clusters get-credentials $CLUSTER_NAME \
--zone $CLUSTER_ZONE \
--project $PROJECT_ID
```

## Configuring Internal TCP/UDP Load Balancing

Patch the Istio Ingress Gateway to use TCP/UDP Load Balancing

```
kubectl -n gke-system patch svc istio-ingress -p     '{"metadata":{"annotations":{"cloud.google.com/load-balancer-type":"Internal"}}}'
```

Run the following command to poll your GKE cluster for change. Look for the value of EXTERNAL-IP to change to a private IP address:

```
kubectl -n gke-system get svc istio-ingress --watch
```

Press `Ctrl+C` to stop the polling when you see a private IP address in the `EXTERNAL-IP` field. Note this private IP address.

```
export EXTERNAL_IP=$(kubectl -n gke-system get svc istio-ingress \
-o jsonpath='{.status.loadBalancer.ingress[0].ip}' | tee external-ip.txt)
```

Now the variable `EXTERNAL_IP` has the value of internal IP for the `istio-ingress` service.


## Deploy the application to this cluster

Set environment variables for `IMAGENAME` and `SERVICENAME`

```
export IMAGENAME=gcr.io/${PROJECT_ID}/helloworld-python
export SERVICENAME=helloworld-python

```

Deploy the service

```
gcloud run deploy ${SERVICENAME} \
--image ${IMAGENAME} \
--namespace default \
--platform gke \
--set-env-vars=TARGET="From KubeRun on GCP"
```

Note the resultant URL of the service

## Test the service

Set up a temporary VM

```
VM=cloudrun-test-vm
gcloud compute instances create $VM
```

SSH into this VM from Cloud Console, and  `curl` the service to test after substituting the URL and EXTERNAL_IP with the respective values.

```
curl -s -w'\n' -H Host:$URL $EXTERNAL_IP
```

Now we have the KubeRun service ready on the GCP cluster to use.




