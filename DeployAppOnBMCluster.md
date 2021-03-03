# Deploy Application on BareMetal Cluster


Create the application
```
cat > app.py <<EOF
import os
import datetime
import time
from flask import Flask

app = Flask(__name__)

@app.route('/')
def hello_world():
    target = os.environ.get('TARGET', 'World')
    timestamp = str(datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S'))      
    return timestamp + ' Hello {}!\n'.format(target)

if __name__ == "__main__":
    app.run(debug=True,host='0.0.0.0',port=int(os.environ.get('PORT', 8080)))
EOF

```

Create Dockerfile

```
cat >Dockerfile <<EOF
# Use the official lightweight Python image.
# https://hub.docker.com/_/python
FROM python:3.7-slim

# Allow statements and log messages to immediately appear in the Knative logs
ENV PYTHONUNBUFFERED True

# Copy local code to the container image.
ENV APP_HOME /app
WORKDIR \$APP_HOME
COPY . ./

# Install production dependencies.
RUN pip install Flask gunicorn

# Run the web service on container startup. Here we use the gunicorn
# webserver, with one worker process and 8 threads.
# For environments with multiple CPU cores, increase the number of workers
# to be equal to the cores available.
CMD exec gunicorn --bind :\$PORT --workers 1 --threads 8 --timeout 0 app:app
EOF

```

Build and push the image
```
export IMAGENAME=gcr.io/${PROJECT_ID}/helloworld-python
docker build -t ${IMAGENAME} .
docker push ${IMAGENAME}
```

Create service definition and deploy

```
cat >service.yaml <<EOF
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: helloworld-python
  namespace: default
spec:
  template:
    spec:
      containers:
      - image: ${IMAGENAME}
        env:
        - name: TARGET
          value: "From Anthos On Prem"
EOF

kubectl apply -f service.yaml
```

Test the service

Get the EndpointURL for the service
```
export ENDPOINT=$(kubectl get ksvc helloworld-python  -o=jsonpath='{.status.url}')
```

Since the ingress is via Nginx proxy running on the Admin Workstation, get its external IP

```
WS_EXTERNAL_IP=$(gcloud compute instances list --filter="name=${VM_WS}" --format "get(networkInterfaces[0].accessConfigs[0].natIP)")
```

If required, create a firewall rule to access port 80 from your cloudshell.

```
gcloud compute firewall-rules create gcloud-80 --allow=tcp:80 --source-ranges $CLOUDSHELL_IP
```

Access the URL as shown below
```
curl -H "Host: ${ENDPOINT#*//}" $WS_EXTERNAL_IP
```
and you should see the output `Hello From Anthos On Prem!`

