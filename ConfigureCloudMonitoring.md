# Setup Monitoring and Alerting

## Pre-requisites

* Create a cloud monitoring workspace as explained [here](https://cloud.google.com/monitoring/workspaces/create#single-project-workspace) if it is not already there.

## Setup PubSub Channels

We will create an alert to inform the system when to burst into GCP and when to scale back down. This scenario will use Pub/Sub as the notification channel. 
Later we will setup a Cloud Run trigger based on the pub/sub topic which will trigger the scale up/down events.

First create the notification channels

```
export PROJECT_ID=$(gcloud config list --format \
  "value(core.project)")
export REGION=us-central1
  
export SCALE_UP_CHANNEL=$(gcloud alpha monitoring channels create \
  --display-name="Hybrid Burst Scale Up" \
  --type=pubsub \
  --channel-labels=topic=projects/${PROJECT_ID}/topics/scale-up \
  --format='value(name)')

export SCALE_DOWN_CHANNEL=$(gcloud alpha monitoring channels create \
  --display-name="Hybrid Burst Scale Down" \
  --type=pubsub \
  --channel-labels=topic=projects/${PROJECT_ID}/topics/scale-down \
  --format='value(name)')
```

Next we need to create the pub/sub topics we referenced above
```
gcloud pubsub topics create scale-up --project ${PROJECT_ID}
gcloud pubsub topics create scale-down --project ${PROJECT_ID}
```


## Setup Alert Policies in Cloud Monitoring

Now create the alert policies
```
# Specify a regular expression to match nodes
export REG_EX_NODES=".*-w[0-9]"

cat > scale-up-policy.yaml <<EOF
combiner: OR
conditions:
- conditionMonitoringQueryLanguage:
    duration: 0s
    query: |-
      fetch k8s_node
      | filter (resource.node_name =~ '${REG_EX_NODES}')
      | { t_0:
            metric 'kubernetes.io/anthos/node_memory_Active_bytes'
            | align mean_aligner()
            | group_by [resource.cluster_name],
                [value_node_memory_Active_bytes_aggregate:
                   aggregate(value.node_memory_Active_bytes)]
        ; t_1:
            metric 'kubernetes.io/anthos/node_memory_MemTotal_bytes'
            | align mean_aligner()
            | group_by [resource.cluster_name],
                [value_node_memory_MemTotal_bytes_aggregate:
                   aggregate(value.node_memory_MemTotal_bytes)] }
      | ratio
      | window 1m
      | condition ratio > .65 '1'
    trigger:
      count: 1
  displayName: High On-Prem Cluster Saturation
displayName: Scale Up Cloud
enabled: true
notificationChannels:
- ${SCALE_UP_CHANNEL}
EOF

cat > scale-down-policy.yaml <<EOF
combiner: OR
conditions:
- conditionMonitoringQueryLanguage:
    duration: 0s
    query: |-
      fetch k8s_node
      | filter (resource.node_name =~ '${REG_EX_NODES}')
      | { t_0:
            metric 'kubernetes.io/anthos/node_memory_Active_bytes'
            | align mean_aligner()
            | group_by [resource.cluster_name],
                [value_node_memory_Active_bytes_aggregate:
                   aggregate(value.node_memory_Active_bytes)]
        ; t_1:
            metric 'kubernetes.io/anthos/node_memory_MemTotal_bytes'
            | align mean_aligner()
            | group_by [resource.cluster_name],
                [value_node_memory_MemTotal_bytes_aggregate:
                   aggregate(value.node_memory_MemTotal_bytes)] }
      | ratio
      | window 1m
      | condition ratio < .25 '1'
    trigger:
      count: 1
  displayName: Low On-Prem Cluster Saturation
displayName: Scale Down Cloud
enabled: true
notificationChannels:
- ${SCALE_DOWN_CHANNEL}
EOF

gcloud alpha monitoring policies create --policy-from-file=scale-up-policy.yaml
gcloud alpha monitoring policies create --policy-from-file=scale-down-policy.yaml
```


Set up permissions for monitoring to publish messages to pubsub


```
export PROJECT_NUMBER=$(gcloud projects describe ${PROJECT_ID} \
  --format="value(projectNumber)")
  
gcloud pubsub topics add-iam-policy-binding \
projects/${PROJECT_ID}/topics/scale-up --role=roles/pubsub.publisher \
--member=serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-monitoring-notification.iam.gserviceaccount.com

gcloud pubsub topics add-iam-policy-binding \
projects/${PROJECT_ID}/topics/scale-down --role=roles/pubsub.publisher \
--member=serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-monitoring-notification.iam.gserviceaccount.com
```

## Deploy Cloud Functions for Scale Up and Scale Down

Next we need to create the function that cloud run will use to trigger the scale up and scale down events. 
Note, these instructions were influenced by the following blog post: 
https://medium.com/google-cloud/executing-bash-scripts-with-a-webhook-in-google-cloud-75ea4b173c9

Create a python flask wrapper which will execute a bash script to update the URL Map. 
This is required because as of the time of this writing, Google Cloud Run only supports services with HTTP Endppoints.
```
mkdir app
cat > app/app.py <<EOF
import os, subprocess
from flask import Flask, request, abort

app = Flask(__name__)

@app.route("/", methods=["POST"])
def main():
    d = dict(os.environ)
    o = subprocess.run(
        ["./app/scale.sh"], 
        env=d,stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
    )

    return {"results": o.stdout}

if __name__ == "__main__":
    app.run(
        debug=True, 
        host="0.0.0.0", 
        port=int(os.environ.get("PORT", 8080))
    )
EOF
```
Create the bash script which will execute gcloud command to update our URL Map. This script is called from our Python Flask Wrapper
```
cat > app/scale.sh <<EOF
#!/bin/sh

gcloud compute url-maps import td-hybrid-url-map --quiet <<STDIN
defaultService: global/backendServices/td-on-prem-backend-service
name: td-hybrid-url-map
description: ''
hostRules:
- hosts:
  - '*'
  pathMatcher: matcher1
pathMatchers:
- name: matcher1
  defaultService: global/backendServices/\${_ON_PREM_BACKEND_SERVICE}
  routeRules:
  - priority: 0
    matchRules:
    - prefixMatch: ''
    routeAction:
      weightedBackendServices:
      - backendService: global/backendServices/\${_ON_PREM_BACKEND_SERVICE}
        weight: \${_ON_PREM_WEIGHT}
        headerAction:
          requestHeadersToAdd:
            - headerName: "Host"
              headerValue: "\${_ON_PREM_HOST}"
              replace: True
      - backendService: global/backendServices/\${_ON_GCP_BACKEND_SERVICE}
        weight: \${_ON_GCP_WEIGHT}
        headerAction:
          requestHeadersToAdd:
            - headerName: "Host"
              headerValue: "\${_ON_GCP_HOST}"
              replace: True  
STDIN
EOF
```

Add execute permissions to this script file

```
chmod +x ./app/scale.sh
```


Create the dockerfile and build and push the image
```
export IMAGENAME=gcr.io/${PROJECT_ID}/scaler:v1
cat > Dockerfile <<EOF
# https://medium.com/google-cloud/executing-bash-scripts-with-a-webhook-in-google-cloud-75ea4b173c9
# Use the Google Cloud SDK image.
FROM gcr.io/google.com/cloudsdktool/cloud-sdk:slim

RUN apt-get update && apt-get install -y python3-pip python3

# Copy local code to the container image.
WORKDIR /app
COPY . ./

# Install production dependencies.
RUN pip3 install Flask

# Run the web service on container startup
#CMD exec gunicorn --bind :8080 --workers 1 --threads 8 app:app
CMD ["python3", "./app/app.py"]
EOF

docker build -t ${IMAGENAME} .
docker push ${IMAGENAME}
```

Create two Cloud Run services, one for scaling up and the other to scale down
```
gcloud beta run deploy cloud-burst-scale-up --image ${IMAGENAME} \
  --region=${REGION} \
  --no-allow-unauthenticated \
  --platform=managed \
  --ingress=internal \
  --set-env-vars=_ON_GCP_BACKEND_SERVICE=td-on-gcp-backend-service \
  --set-env-vars=_ON_GCP_HOST=${KUBERUN_ENDPOINT#*//} \
  --set-env-vars=_ON_GCP_WEIGHT=50 \
  --set-env-vars=_ON_PREM_BACKEND_SERVICE=td-on-prem-backend-service \
  --set-env-vars=_ON_PREM_HOST=${ONPREM_ENDPOINT#*//} \
  --set-env-vars=_ON_PREM_WEIGHT=50

gcloud beta run deploy cloud-burst-scale-down --image ${IMAGENAME} \
  --region=${REGION} \
  --no-allow-unauthenticated \
  --platform=managed \
  --ingress=internal \
  --set-env-vars=_ON_GCP_BACKEND_SERVICE=td-on-gcp-backend-service \
  --set-env-vars=_ON_GCP_HOST=${KUBERUN_ENDPOINT#*//} \
  --set-env-vars=_ON_GCP_WEIGHT=0 \
  --set-env-vars=_ON_PREM_BACKEND_SERVICE=td-on-prem-backend-service \
  --set-env-vars=_ON_PREM_HOST=${ONPREM_ENDPOINT#*//} \
  --set-env-vars=_ON_PREM_WEIGHT=100
``` 


## Add a Service Account to invoke CloudRun from EventArc

Retrieve project number
```
PROJECT_NUMBER=$(gcloud projects describe ${PROJECT_ID} \>   --format="value(projectNumber)")
```

Enable Pub/Sub to create authentication tokens in your project:
```
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
     --member=serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-pubsub.iam.gserviceaccount.com \
     --role=roles/iam.serviceAccountTokenCreator
```

Add a service account
```
gcloud iam service-accounts create cloud-run-pubsub-invoker \
     --display-name "Cloud Run Pub/Sub Invoker"
```

Allow service account to invoke both scale up and scale down services

```
gcloud run services add-iam-policy-binding cloud-burst-scale-up \
   --member=serviceAccount:cloud-run-pubsub-invoker@${PROJECT_ID}.iam.gserviceaccount.com \
   --role=roles/run.invoker \
   --platform=managed \
   --region=${REGION}

gcloud run services add-iam-policy-binding cloud-burst-scale-down \
   --member=serviceAccount:cloud-run-pubsub-invoker@${PROJECT_ID}.iam.gserviceaccount.com \
   --role=roles/run.invoker \
   --platform=managed \
   --region=${REGION}

```


## Deploy Event Arc Triggers


Enable Event Arc services in the project

```
gcloud services enable eventarc.googleapis.com
```

Lastly, create the Eventarc triggers for each service. Note the service account that we configured in the last step to invoke scale up and scale down services.

```
gcloud beta eventarc triggers create --location=${REGION} \
  --destination-run-service=cloud-burst-scale-up \
  --matching-criteria="type=google.cloud.pubsub.topic.v1.messagePublished" \
  --transport-topic=projects/${PROJECT_ID}/topics/scale-up cloud-scale-up \
  --service-account=cloud-run-pubsub-invoker@${PROJECT_ID}.iam.gserviceaccount.com

gcloud beta eventarc triggers create --location=${REGION} \
  --destination-run-service=cloud-burst-scale-down \
  --matching-criteria="type=google.cloud.pubsub.topic.v1.messagePublished" \
  --transport-topic=projects/${PROJECT_ID}/topics/scale-down cloud-scale-down \
  --service-account=cloud-run-pubsub-invoker@${PROJECT_ID}.iam.gserviceaccount.com
``` 
