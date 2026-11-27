#!/usr/bin/env bash
# =====================================================================
# ShackPulse — Azure infrastructure in one script.
#
# Run in Azure Cloud Shell (Bash):   bash infra/setup-azure.sh
#
# Safe to re-run: every step checks what already exists and skips it, so if a step fails
# you fix the cause and run the script again. Existing Key Vault secrets are reused,
# so database passwords never change on a re-run.
#
# Every name and size below can be overridden for one run, e.g.
#   NODE_SIZE=Standard_B2ms NODE_MAX=2 bash infra/setup-azure.sh
# =====================================================================
set -euo pipefail

# ---------- 0. Names and sizes (ACR + Key Vault names must be globally unique: add a suffix if taken) ----------

LOCATION=${LOCATION:-southindia}
RG=${RG:-rg-sathwick-shackpulse}
ACR=${ACR:-acrsathwickpulse}              # 5-50 lowercase letters/numbers
AKS=${AKS:-aks-sathwick-shackpulse}
LAW=${LAW:-law-sathwick-shackpulse}
PG=${PG:-psql-sathwick-shackpulse}        # gets a region suffix if it falls back
PG_ADMIN=${PG_ADMIN:-sathwickadmin}
KV=${KV:-kv-sathwick}                     # 3-24 chars
SP_NAME=${SP_NAME:-sp-sathwick-azure-devops}
NODE_SIZE=${NODE_SIZE:-Standard_D2as_v6}  # 2 vCPU / 8 GiB
NODE_MIN=${NODE_MIN:-2}
NODE_MAX=${NODE_MAX:-3}                   # set NODE_MAX=2 if quota is only 4 vCPUs

# PostgreSQL: tried in order until one is accepted (tier:sku:region). New subscriptions are often
# blocked from Burstable sizes in one region, so we fall back instead of failing.
PG_CHOICES=${PG_CHOICES:-"Burstable:Standard_B1ms:$LOCATION Burstable:Standard_B1ms:southindia Burstable:Standard_B2s:$LOCATION Burstable:Standard_B2s:southindia GeneralPurpose:Standard_D2ds_v5:$LOCATION"}

# Your domain becomes an Azure DNS zone. Sites: shackpulse-dev.<APP_DOMAIN> and shackpulse.<APP_DOMAIN>
APP_DOMAIN=${APP_DOMAIN:-prod-demo-99.site}
LETSENCRYPT_EMAIL=${LETSENCRYPT_EMAIL:-ksdutt6773@gmail.com}


step() { echo; echo "==> [$(date +%H:%M:%S)] $*"; }
exists() { "$@" -o none >/dev/null 2>&1; }

step "Using subscription: $(az account show --query name -o tsv)"
SUB_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
ME=$(az ad signed-in-user show --query id -o tsv)
# The managed Gateway API flags (--enable-gateway-api, --enable-app-routing-istio) need Azure CLI 2.86.0+.
AZ_VER=$(az version --query '"azure-cli"' -o tsv)
if [ "$(printf '%s\n2.86.0\n' "$AZ_VER" | sort -V | head -1)" != "2.86.0" ]; then
  echo "Azure CLI $AZ_VER is too old for the managed Gateway API. Run 'az upgrade' (Cloud Shell updates itself regularly)."; exit 1
fi
for tool in kubectl helm psql openssl; do
  command -v $tool >/dev/null || { echo "Missing $tool. Azure Cloud Shell has all of these; run the script there."; exit 1; }
done

# ---------- 1. Providers + resource group ----------
step "1/11 Registering resource providers (first time can take a few minutes each)"
for p in Microsoft.ContainerService Microsoft.ContainerRegistry Microsoft.DBforPostgreSQL Microsoft.KeyVault Microsoft.OperationalInsights Microsoft.Insights Microsoft.Network Microsoft.Compute; do
  state=$(az provider show --namespace $p --query registrationState -o tsv 2>/dev/null || echo NotRegistered)
  if [ "$state" = "Registered" ]; then echo "    $p already registered"; else echo "    registering $p ..."; az provider register --namespace $p --wait; fi
done
az group create -n $RG -l $LOCATION -o none
echo "    resource group $RG ready"

# ---------- 2. Container registry (Basic) ----------
step "2/11 Container registry $ACR"
if exists az acr show -n $ACR; then echo "    exists, skipping"; else az acr create -g $RG -n $ACR --sku Basic -o none; fi

# ---------- 3. Log Analytics workspace (Container Insights) ----------
step "3/11 Log Analytics workspace $LAW"
if exists az monitor log-analytics workspace show -g $RG -n $LAW; then echo "    exists, skipping"
else az monitor log-analytics workspace create -g $RG -n $LAW -l $LOCATION -o none; fi
LAW_ID=$(az monitor log-analytics workspace show -g $RG -n $LAW --query id -o tsv)

# ---------- 4. AKS ----------
# Azure CNI overlay + Cilium (enforces our NetworkPolicies), Container Insights, AcrPull for the cluster's
# managed identity (no image pull secrets anywhere), and the Kubernetes Gateway API:
#   --enable-gateway-api        AKS installs and manages the Gateway API CRDs (Gateway, HTTPRoute, ...)
#   --enable-app-routing-istio  the app routing add-on in Gateway API mode: GatewayClass "approuting-istio",
#                               a lightweight Istio control plane that runs Envoy proxies for our Gateway
# This replaces the NGINX app routing add-on (--enable-app-routing), whose Azure support ended in November 2026.
step "4/11 AKS cluster $AKS (2 vCPU / 8 GiB nodes) with the managed Gateway API (10-15 minutes, this is the long one)"
if exists az aks show -g $RG -n $AKS; then echo "    exists, skipping create"
else
  # Pick the first 8 GiB node size this subscription can use in $LOCATION (some sizes are restricted
  # for new subscriptions). All of these are 2 vCPU / 8 GiB, enough for istiod and the Envoy proxies.
  chosen=""
  for size in $NODE_SIZE Standard_D2as_v5 Standard_D2s_v5 Standard_D2ds_v5; do
    ok=$(az vm list-skus -l $LOCATION --resource-type virtualMachines --size $size \
         --query "[?name=='$size' && length(restrictions)==\`0\`].name | [0]" -o tsv 2>/dev/null || true)
    if [ "$ok" = "$size" ]; then chosen=$size; break; fi
    echo "    $size is not available to this subscription in $LOCATION, trying the next size"
  done
  [ -n "$chosen" ] || { echo "None of the 8 GiB node sizes is available in $LOCATION. Set NODE_SIZE=<a 2 vCPU / 8 GiB size> and re-run."; exit 1; }
  [ "$chosen" = "$NODE_SIZE" ] || echo "    using $chosen instead of $NODE_SIZE"
  NODE_SIZE=$chosen
  az aks create -g $RG -n $AKS -l $LOCATION \
    --tier free \
    --node-count $NODE_MIN --node-vm-size $NODE_SIZE \
    --enable-cluster-autoscaler --min-count $NODE_MIN --max-count $NODE_MAX \
    --network-plugin azure --network-plugin-mode overlay --network-dataplane cilium \
    --enable-gateway-api --enable-app-routing-istio \
    --enable-addons monitoring --workspace-resource-id "$LAW_ID" \
    --attach-acr $ACR \
    --enable-managed-identity --generate-ssh-keys \
    -o none
fi
az aks get-credentials -g $RG -n $AKS --overwrite-existing >/dev/null
# A cluster created earlier (for example with the old NGINX script) gets the Gateway API switched on here.
if ! kubectl get gatewayclass approuting-istio -o name >/dev/null 2>&1; then
  echo "    enabling the managed Gateway API on the existing cluster..."
  az aks update -g $RG -n $AKS --enable-gateway-api --enable-app-routing-istio -o none
fi
for i in $(seq 1 30); do
  [ "$(kubectl get gatewayclass approuting-istio -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null)" = "True" ] && break
  sleep 10
done
kubectl get nodes
kubectl get gatewayclass approuting-istio
# istiod (in aks-istio-system) is the controller that turns our Gateway into Envoy pods. If it can't start
# (for example "Insufficient memory" on small nodes), the Gateway never gets an IP, so check it here.
echo "    waiting for istiod (the Gateway API controller) to be running..."
for i in $(seq 1 36); do
  running=$(kubectl -n aks-istio-system get pods --no-headers 2>/dev/null | grep '^istiod' | grep -c ' Running ' || true)
  [ "${running:-0}" -ge 1 ] && break; sleep 10
done
if [ "${running:-0}" -lt 1 ]; then
  kubectl -n aks-istio-system get pods
  kubectl get events -n aks-istio-system --sort-by=.lastTimestamp | tail -5
  echo "istiod is not running (see the events above). If they say 'Insufficient memory', the nodes are too small:"
  echo "  az aks nodepool add -g $RG --cluster-name $AKS -n pool8g --mode System --node-vm-size Standard_D2as_v6 \\"
  echo "    --node-count 2 --enable-cluster-autoscaler --min-count 2 --max-count 3"
  echo "  az aks nodepool delete -g $RG --cluster-name $AKS -n nodepool1     # after the new nodes are Ready"
  echo "Then run this script again."
  exit 1
fi
echo "    istiod running"

# ---------- 5. Key Vault (RBAC) + secrets. Existing secrets are kept. ----------
step "5/11 Key Vault $KV and secrets"
if exists az keyvault show -n $KV; then echo "    vault exists"
else az keyvault create -g $RG -n $KV -l $LOCATION --enable-rbac-authorization true -o none; fi
KV_ID=$(az keyvault show -n $KV --query id -o tsv)
if ! az role assignment list --assignee $ME --scope $KV_ID --role "Key Vault Secrets Officer" --query "[0].id" -o tsv | grep -q .; then
  az role assignment create --assignee $ME --role "Key Vault Secrets Officer" --scope $KV_ID -o none
  echo "    waiting 60s for your Key Vault role to take effect..."; sleep 60
fi
gen() { openssl rand -base64 32 | tr -d '/+=' | cut -c1-${1:-32}; }
# secret NAME VALUE_IF_NEW -> prints the stored value (creates it only if missing)
secret() {
  local v
  v=$(az keyvault secret show --vault-name $KV -n "$1" --query value -o tsv 2>/dev/null || true)
  if [ -z "$v" ]; then v="$2"; az keyvault secret set --vault-name $KV -n "$1" --value "$v" -o none; echo "    created $1" >&2
  else echo "    kept    $1" >&2; fi
  printf '%s' "$v"
}
PG_PASSWORD=$(secret pg-admin-password "$(gen 24)Aa1!")
DEV_DB_PASSWORD=$(secret dev-db-password "$(gen)Aa1")
PROD_DB_PASSWORD=$(secret prod-db-password "$(gen)Aa1")
secret dev-jwt-secret "$(gen)$(gen)" >/dev/null
secret prod-jwt-secret "$(gen)$(gen)" >/dev/null
secret dev-admin-password "Dev-$(gen 12)1!" >/dev/null
secret prod-admin-password "Prod-$(gen 12)1!" >/dev/null

step "6/11 PostgreSQL Flexible Server (5-10 minutes)"
# ---------- 6. PostgreSQL Flexible Server (32 GiB, PG 16) + two databases ----------
# If a server already exists (an earlier run), wait for it to finish; recreate it only if it is broken.
# Some az versions print "ResourceNotFound" and still exit 0 for postgres, so trust only a real state word.
pg_state() { az postgres flexible-server show -g $RG -n $PG --query state -o tsv 2>/dev/null | grep -xE '[A-Za-z]+' || true; }
db_exists() { [ "$( { az postgres flexible-server db show -g $RG -s $PG -n "$1" --query name -o tsv 2>/dev/null \
                     || az postgres flexible-server db show -g $RG -s $PG -d "$1" --query name -o tsv 2>/dev/null; } | tr -d '\r' | head -1)" = "$1" ]; }
# A failed create in one region reserves the name there for a while, so a server in another region
# gets the region added to its name (e.g. psql-devopsshack-shackpulse-southindia).
PG_BASE=$PG
pg_name_for() { if [ "$1" = "$LOCATION" ]; then echo "$PG_BASE"; else echo "$PG_BASE-$1"; fi; }
# Delete a broken server and wait until Azure has really removed it (state "Dropping" can last
# several minutes); reusing the name before that fails with "Specified server name is already used".
pg_remove() {
  [ "$(pg_state)" = "Dropping" ] || az postgres flexible-server delete -g $RG -n $PG --yes -o none >/dev/null 2>&1 || true
  for i in $(seq 1 45); do
    local st; st=$(pg_state); [ -z "$st" ] && return 0
    echo "    waiting for $PG to be fully deleted (now: $st) ..."; sleep 20
  done
  echo "    $PG is still being deleted after 15 minutes"; return 1
}
for r in $LOCATION $(for c in $PG_CHOICES; do echo "${c##*:}"; done | sort -u); do
  PG=$(pg_name_for $r); [ -n "$(pg_state)" ] && break; PG=$PG_BASE
done
state=$(pg_state)
if [ -n "$state" ]; then
  echo "    exists ($(az postgres flexible-server show -g $RG -n $PG --query "join(' ', [sku.name, location])" -o tsv 2>/dev/null)), state: $state"
  for i in $(seq 1 60); do
    case "$state" in Ready|"") break ;; Stopped) az postgres flexible-server start -g $RG -n $PG -o none ;; esac
    case "$state" in Failed|Disabled|Dropping) break ;; esac
    echo "    waiting for it to become Ready (now: $state) ..."; sleep 20; state=$(pg_state)
  done
  case "$state" in
    Ready) echo "    ready, skipping create" ;;
    *) echo "    not usable (state: ${state:-gone}); deleting it so it can be recreated"
       pg_remove || true; state="" ;;
  esac
fi
if [ "$state" = "Ready" ]; then
  :
else
  created=""
  for choice in $PG_CHOICES; do
    IFS=: read -r tier sku region <<< "$choice"
    PG=$(pg_name_for $region)
    echo "    trying $tier $sku in $region as $PG ..."
    out=$(az postgres flexible-server create -g $RG -n $PG -l $region \
          --tier $tier --sku-name $sku --storage-size 32 --version 16 \
          --admin-user $PG_ADMIN --admin-password "$PG_PASSWORD" \
          --public-access 0.0.0.0 --yes -o none 2>&1) && rc=0 || rc=$?
    # Success only counts when the server really reaches Ready. A failed create can leave a
    # broken record behind (state Failed/Disabled), which must NOT be treated as created.
    state=$(pg_state)
    for i in $(seq 1 45); do
      case "$state" in Creating|Updating|Starting|Provisioning) echo "    server state: $state, waiting..."; sleep 20; state=$(pg_state) ;; *) break ;; esac
    done
    if [ "$state" = "Ready" ]; then
      echo "$out" | grep -v "^WARNING" || true; created="$tier $sku in $region"; break
    fi
    if [ -n "$state" ]; then
      echo "    leftover server record in state '$state'; deleting it"
      pg_remove || true
    fi
    [ $rc -eq 0 ] && { echo "    create returned success but the server is not Ready; trying the next option"; continue; }
    if echo "$out" | grep -qiE "SkuNotAvailable|not (supported|available)|quota|capacity|restricted|InvalidResourceLocation"; then
      echo "    not available: $(echo "$out" | grep -m1 -iE 'Message|SkuNotAvailable' | cut -c1-160)"
      # Azure sometimes leaves a failed server record behind for a moment; clear it, never stop on this.
      [ -z "$(pg_state)" ] || pg_remove || true
      continue
    fi
    if echo "$out" | grep -qiE "already used|already exists|NameAlreadyExists|ServerNameAlreadyExists"; then
      # The name is still held by a server Azure is deleting, or reserved after a failed create.
      # Wait for it to clear and try this option once more; otherwise move on to the next option
      # (servers in other regions get a different name, e.g. psql-...-southindia).
      echo "    server name $PG is still in use; waiting for it to be released"
      pg_remove || true
      if [ -z "${retried:-}" ]; then retried=1; echo "    retrying $tier $sku in $region ..."
        out=$(az postgres flexible-server create -g $RG -n $PG -l $region \
              --tier $tier --sku-name $sku --storage-size 32 --version 16 \
              --admin-user $PG_ADMIN --admin-password "$PG_PASSWORD" \
              --public-access 0.0.0.0 --yes -o none 2>&1) || true
        state=$(pg_state)
        for i in $(seq 1 45); do
          case "$state" in Creating|Updating|Starting|Provisioning) sleep 20; state=$(pg_state) ;; *) break ;; esac
        done
        if [ "$state" = "Ready" ]; then created="$tier $sku in $region"; break; fi
        echo "    retry did not work: $(echo "$out" | grep -m1 -iE 'ERROR|Message' | cut -c1-160)"
        [ -z "$state" ] || pg_remove || true
      fi
      unset retried; continue
    fi
    echo "$out"; echo "PostgreSQL create failed for a reason other than SKU availability (see above)."; exit 1
  done
  [ -n "$created" ] || { echo "None of PG_CHOICES could be created. Run: az postgres flexible-server list-skus -l <region> -o table"; exit 1; }
  echo "    created: $created"
fi
# Newer az versions name the database with --name, older ones with --database-name; try both.
for d in shackpulse_dev shackpulse_prod; do
  if db_exists $d; then
    echo "    database $d exists"
  else
    # Try --name first; fall back to --database-name only if this az version doesn't know --name,
    # so a real error (server missing, not ready) is shown instead of a misleading usage message.
    if ! err=$(az postgres flexible-server db create -g $RG -s $PG -n $d -o none 2>&1); then
      if echo "$err" | grep -qiE "unrecognized arguments|the following arguments are required: --database-name"; then
        az postgres flexible-server db create -g $RG -s $PG -d $d -o none
      else
        echo "$err"; echo "Creating database $d on $PG failed (see above)."; exit 1
      fi
    fi
    echo "    database $d created"
  fi
done
PG_HOST=$PG.postgres.database.azure.com
echo "    server $PG is Ready ($PG_HOST)"

# ---------- 7. Database logins: one per environment, each owns its database ----------
step "7/11 Database logins shackpulse_dev / shackpulse_prod"
# --public-access 0.0.0.0 above allows connections from Azure services, which includes Cloud Shell.
psql_admin() { PGPASSWORD="$PG_PASSWORD" psql "host=$PG_HOST port=5432 dbname=$1 user=$PG_ADMIN sslmode=require" -v ON_ERROR_STOP=1 -q "${@:2}"; }
psql_admin postgres <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='shackpulse_dev')  THEN CREATE ROLE shackpulse_dev  LOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='shackpulse_prod') THEN CREATE ROLE shackpulse_prod LOGIN; END IF;
END \$\$;
ALTER ROLE shackpulse_dev  PASSWORD '${DEV_DB_PASSWORD}';
ALTER ROLE shackpulse_prod PASSWORD '${PROD_DB_PASSWORD}';
GRANT shackpulse_dev  TO ${PG_ADMIN} WITH INHERIT TRUE, SET TRUE;
GRANT shackpulse_prod TO ${PG_ADMIN} WITH INHERIT TRUE, SET TRUE;
ALTER DATABASE shackpulse_dev  OWNER TO shackpulse_dev;
ALTER DATABASE shackpulse_prod OWNER TO shackpulse_prod;
SQL
# On Azure the public schema in a new database isn't owned by the database owner. Without this
# grant the API's first migration fails with "permission denied for schema public" (CrashLoopBackOff).
for e in dev prod; do
  psql_admin shackpulse_$e -c "GRANT USAGE, CREATE ON SCHEMA public TO shackpulse_$e;"
done
echo "    logins ready; passwords are the dev-db-password / prod-db-password secrets"

# ---------- 8. Service principal for Azure DevOps (scoped to this resource group, ACR and Key Vault) ----------
step "8/11 Service principal $SP_NAME"
RG_ID=$(az group show -n $RG --query id -o tsv)
ACR_ID=$(az acr show -n $ACR --query id -o tsv)
SP_APP_ID=$(az ad sp list --display-name $SP_NAME --query "[0].appId" -o tsv)
SP_SECRET="(unchanged - created on an earlier run. New one: az ad sp credential reset --id <client id> --query password -o tsv)"
if [ -z "$SP_APP_ID" ]; then
  SP_JSON=$(az ad sp create-for-rbac --name $SP_NAME --role Contributor --scopes $RG_ID -o json)
  SP_APP_ID=$(echo "$SP_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin)["appId"])')
  SP_SECRET=$(echo "$SP_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin)["password"])')
  echo "    created; waiting 30s for it to appear everywhere"; sleep 30
else
  echo "    exists ($SP_APP_ID), keeping it"
fi
for pair in "Contributor|$RG_ID" "AcrPush|$ACR_ID" "Key Vault Secrets User|$KV_ID"; do
  role=${pair%%|*}; scope=${pair#*|}
  if az role assignment list --assignee $SP_APP_ID --scope "$scope" --role "$role" --query "[0].id" -o tsv | grep -q .; then echo "    has $role"
  else az role assignment create --assignee $SP_APP_ID --role "$role" --scope "$scope" -o none; echo "    granted $role"; fi
done

# ---------- 9. cert-manager in Gateway API mode + Let's Encrypt issuers ----------
step "9/11 cert-manager (Gateway API mode) and the Let's Encrypt issuers"
# Install once. On re-runs we skip Helm: AKS's admissions enforcer edits cert-manager's webhook
# (namespaceSelector), and a Helm upgrade then fails with "conflict with admissionsenforcer".
# --enable-gateway-api makes cert-manager watch Gateways as well as Ingresses. The Gateway API CRDs must
# exist before cert-manager starts, which step 4 guarantees.
if kubectl get deploy cert-manager-webhook -n cert-manager -o name >/dev/null 2>&1; then
  echo "    cert-manager already installed, skipping Helm"
  if ! kubectl -n cert-manager get deploy cert-manager -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q -- '--enable-gateway-api'; then
    echo "    switching the existing cert-manager to Gateway API mode"
    kubectl -n cert-manager patch deploy cert-manager --type json \
      -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--enable-gateway-api"}]'
  fi
else
  helm repo add jetstack https://charts.jetstack.io --force-update >/dev/null
  helm upgrade --install cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace \
    --set crds.enabled=true --set "extraArgs={--enable-gateway-api}" --wait --timeout 10m
fi
kubectl -n cert-manager rollout status deploy/cert-manager --timeout=180s
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=180s
# Same content as k8s/platform/cluster-issuer.yaml, inlined so the script works from any folder.
for issuer in prod staging; do
  server=https://acme-v02.api.letsencrypt.org/directory
  [ $issuer = staging ] && server=https://acme-staging-v02.api.letsencrypt.org/directory
  kubectl apply -f - <<YAML
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-$issuer
spec:
  acme:
    server: $server
    email: $LETSENCRYPT_EMAIL
    privateKeySecretRef:
      name: letsencrypt-$issuer-account-key
    solvers:
      - http01:
          gatewayHTTPRoute:
            parentRefs:
              - name: shackpulse-gateway
                namespace: shackpulse-gateway
                kind: Gateway
                sectionName: http
YAML
done
kubectl get clusterissuer

# ---------- 10. The shared Gateway (platform layer) ----------
step "10/11 Shared Gateway shackpulse-gateway: one public IP, HTTPS listeners for dev and prod"
# Same content as k8s/platform/gateway.yaml, inlined so the script works from any folder.
kubectl apply -f - <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: shackpulse-gateway
  labels:
    app.kubernetes.io/part-of: shackpulse
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: shackpulse-gateway
  namespace: shackpulse-gateway
  annotations:
    # cert-manager reads this and creates one Certificate per HTTPS listener below.
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  gatewayClassName: approuting-istio
  listeners:
    # Port 80: only the HTTP->HTTPS redirect and Let's Encrypt's domain check attach here.
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: Same
    # https://shackpulse-dev.<domain>: only routes from the shackpulse-dev namespace may attach.
    - name: https-dev
      protocol: HTTPS
      port: 443
      hostname: shackpulse-dev.$APP_DOMAIN
      tls:
        mode: Terminate
        certificateRefs:
          - name: shackpulse-dev-tls        # created by cert-manager in this namespace
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchLabels:
              kubernetes.io/metadata.name: shackpulse-dev
    # https://shackpulse.<domain>: only routes from the shackpulse-prod namespace may attach.
    - name: https-prod
      protocol: HTTPS
      port: 443
      hostname: shackpulse.$APP_DOMAIN
      tls:
        mode: Terminate
        certificateRefs:
          - name: shackpulse-prod-tls
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchLabels:
              kubernetes.io/metadata.name: shackpulse-prod
---
# Every plain-HTTP request gets a 301 to HTTPS. Let's Encrypt's checks still work: cert-manager's
# temporary route matches the exact /.well-known/acme-challenge/<token> path, which is more specific
# than "/" here, so Gateway API sends the check to cert-manager first.
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: http-to-https
  namespace: shackpulse-gateway
spec:
  parentRefs:
    - name: shackpulse-gateway
      sectionName: http
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      filters:
        - type: RequestRedirect
          requestRedirect:
            scheme: https
            statusCode: 301
YAML
echo "    waiting for Azure to give the Gateway a public IP..."
# We wait for the address, not for "Programmed": the HTTPS listeners stay unresolved until cert-manager has
# issued their certificates, and that needs the DNS records we create in the next step.
GW_IP=""
for i in $(seq 1 60); do
  GW_IP=$(kubectl -n shackpulse-gateway get gateway shackpulse-gateway -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
  [ -n "$GW_IP" ] && break; sleep 10
done
[ -n "$GW_IP" ] || { echo "The Gateway got no IP in 10 minutes. Check: kubectl -n shackpulse-gateway describe gateway shackpulse-gateway"; exit 1; }
echo "    Gateway IP: $GW_IP"
kubectl -n shackpulse-gateway get gateway,httproute,svc,deploy

# ---------- 11. Azure DNS zone + the two site records ----------
# With the Gateway API, the app routing add-on does not write DNS records for us (that automation needs
# its ExternalDNS custom resource plus a workload identity). We point both names at the one Gateway IP
# ourselves. The IP only changes if the Gateway is deleted and recreated; then re-run this script.
step "11/11 Azure DNS zone $APP_DOMAIN and A records for the sites"
if exists az network dns zone show -g $RG -n $APP_DOMAIN; then echo "    zone exists"
else az network dns zone create -g $RG -n $APP_DOMAIN -o none; echo "    zone created"; fi
for host in shackpulse-dev shackpulse; do
  current=$(az network dns record-set a show -g $RG -z $APP_DOMAIN -n $host --query "ARecords[0].ipv4Address" -o tsv 2>/dev/null || true)
  if [ "$current" = "$GW_IP" ]; then echo "    $host.$APP_DOMAIN -> $GW_IP (already set)"; continue; fi
  [ -n "$current" ] && az network dns record-set a delete -g $RG -z $APP_DOMAIN -n $host --yes -o none
  az network dns record-set a add-record -g $RG -z $APP_DOMAIN -n $host -a "$GW_IP" --ttl 300 -o none
  echo "    $host.$APP_DOMAIN -> $GW_IP"
done
NS_SERVERS=$(az network dns zone show -g $RG -n $APP_DOMAIN --query "nameServers" -o tsv | sed 's/\.$//' | tr '\n' ' ')

cat <<SUMMARY

======================= SAVE THIS SUMMARY =======================
Azure DevOps service connection  (manual: "App registration or managed identity (manual)" -> Secret)
  Service connection name : sc-shackpulse-azure
  Subscription ID         : $SUB_ID
  Subscription name       : $(az account show --query name -o tsv)
  Tenant ID               : $TENANT_ID
  Client (app) ID         : $SP_APP_ID
  Client secret           : $SP_SECRET
                            ^ shown only once on the run that creates it: copy it now

Variable group "shackpulse-keyvault" -> link to Key Vault : $KV
  secrets: dev-db-password dev-jwt-secret dev-admin-password prod-db-password prod-jwt-secret prod-admin-password

Your domain (once, at the registrar where you bought $APP_DOMAIN)
  Change its nameservers to:  $NS_SERVERS
  Sites after the first pipeline run:
    https://shackpulse-dev.$APP_DOMAIN
    https://shackpulse.$APP_DOMAIN

Reference only (the pipeline looks up the database host itself on every run)
  Registry       : $ACR.azurecr.io
  Cluster        : $AKS in $RG
  Database host  : $PG_HOST
  Gateway IP     : $GW_IP  (shackpulse-dev and shackpulse A records point here)
=================================================================
SUMMARY
