#!/usr/bin/env bash
# Forced command (`command=`) of the deploy key. Installed at
# /usr/local/sbin/autoops-deploy-entrypoint (root:root 755).
# The key can only request allowlisted actions; any other is rejected.
# The `deploy` action is a placeholder: the real deployment is implemented in Phase 5.
set -euo pipefail

action="${SSH_ORIGINAL_COMMAND:-}"
logger -t autoops-deploy "deploy request: '${action}' from ${SSH_CONNECTION%% *}"

case "$action" in
  deploy)
    echo "autoops-deploy: 'deploy' action accepted; deployment not implemented (Phase 5)."
    ;;
  *)
    echo "autoops-deploy: action not allowed." >&2
    exit 1
    ;;
esac
