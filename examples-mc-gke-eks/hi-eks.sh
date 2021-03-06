#!/bin/bash

set -e

export HYBRID_ENV=$HYBRID_HOME/mc-r2-eks.env
source $HYBRID_ENV

export ASM_HOME=$HYBRID_HOME/istio-$ASM_VERSION
export PATH=$ASM_HOME/bin:$PATH

export APIGEECTL_HOME=$HYBRID_HOME/$(tar tf $HYBRID_HOME/$APIGEECTL_TARBALL | grep VERSION.txt | cut -d "/" -f 1)
export PATH=$APIGEECTL_HOME:$PATH


kubectl config use-context $R2_CLUSTER

kubectl create namespace cert-manager

kubectl --context=$R1_CLUSTER get secret apigee-ca --namespace=cert-manager -o yaml | kubectl --context=$R2_CLUSTER apply --namespace=cert-manager -f -

kubectl apply --validate=false -f $CERT_MANAGER_MANIFEST

export ASM_PROFILE=asm-multicloud
sed -i -E "s/^(export ASM_PROFILE=).*/\1$ASM_PROFILE/g" $HYBRID_ENV
export ASM_RELEASE=$(echo "$ASM_VERSION"|awk '{sub(/\.[0-9]+-asm\.[0-9]+/,"");print}')

cp $AHR_HOME/templates/istio-operator-$ASM_RELEASE-$ASM_PROFILE.yaml $HYBRID_HOME/istio-operator-eks-template.yaml

yq merge -i $HYBRID_HOME/istio-operator-eks-template.yaml - <<"EOF"
spec:
  components:
    ingressGateways:
      - name: istio-ingressgateway
        k8s:
          serviceAnnotations:
            service.beta.kubernetes.io/aws-load-balancer-internal: "true"
EOF

yq delete -i $HYBRID_HOME/istio-operator-eks-template.yaml '**.k8s.service.loadBalancerIP'

# for internal nlb, remove http and leave only https port 
# as healthcheck is incorrectly auto-assigned and makes instances out of service
# we know it's an array element 0
yq delete -i $HYBRID_HOME/istio-operator-eks-template.yaml '**.k8s.service.ports[0]'



ahr-cluster-ctl template $HYBRID_HOME/istio-operator-eks-template.yaml > $ASM_CONFIG

istioctl install -f $ASM_CONFIG

# Cassandra replication
export CS_USERNAME=jmxuser
export CS_PASSWORD=iloveapis123

CS_STATUS=$(kubectl --context $R1_CLUSTER -n apigee exec apigee-cassandra-default-0 -- nodetool -u $CS_USERNAME -pw $CS_PASSWORD status)

export DC1_CS_SEED_NODE=$(echo "$CS_STATUS" | awk '/dc-1/{getline;getline;getline;getline;getline; print $2}')

ahr-runtime-ctl install-profile small asm-gcp -c runtime-config

yq m -i $RUNTIME_CONFIG - <<EOF
cassandra:
  multiRegionSeedHost: $DC1_CS_SEED_NODE
  datacenter: "dc-2"
  rack: "ra-1"
EOF

ahr-runtime-ctl install-profile small asm-gcp -c runtime

# TODO: [ ] ?? check that result is as expected for two DCS; at least output the status
kubectl --context $R1_CLUSTER -n apigee exec apigee-cassandra-default-0 -- nodetool -u $CS_USERNAME -pw $CS_PASSWORD status

kubectl --context $R2_CLUSTER exec apigee-cassandra-default-0 -n apigee  -- nodetool -u $CS_USERNAME -pw $CS_PASSWORD rebuild -- dc-1 

# reset seed node
yq d -i $RUNTIME_CONFIG cassandra.multiRegionSeedHost

ahr-runtime-ctl apigeectl apply --datastore -f $RUNTIME_CONFIG
