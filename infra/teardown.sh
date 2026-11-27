#!/usr/bin/env bash
# Save money between recording sessions, or delete everything when you're done.
#   bash infra/teardown.sh pause    stop AKS, PostgreSQL and the agent VM (storage still costs a little)
#   bash infra/teardown.sh resume   start them again
#   bash infra/teardown.sh delete   delete the whole resource group and the service principal
RG=${RG:-rg-sathwick-shackpulse}; AKS=${AKS:-aks-sathwick-shackpulse}; VM=${VM:-vm-shackpulse-agent}
KV=${KV:-kv-shackpulse}; SP_NAME=${SP_NAME:-sp-shackpulse-azure-devops}
PG=$(az postgres flexible-server list -g $RG --query "[0].name" -o tsv 2>/dev/null)   # may carry a region suffix
case "${1:-}" in
  pause)  az aks stop -g $RG -n $AKS; [ -n "$PG" ] && az postgres flexible-server stop -g $RG -n $PG; az vm deallocate -g $RG -n $VM ;;
  resume) az aks start -g $RG -n $AKS; [ -n "$PG" ] && az postgres flexible-server start -g $RG -n $PG; az vm start -g $RG -n $VM ;;
  delete) az group delete -n $RG --yes --no-wait
          az ad sp delete --id "$(az ad sp list --display-name $SP_NAME --query [0].appId -o tsv)"
          echo "Key Vault stays soft-deleted for 90 days. To reuse the name now: az keyvault purge -n $KV" ;;
  *) echo "usage: $0 pause|resume|delete" ;;
esac
