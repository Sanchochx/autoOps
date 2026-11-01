# Managed by scripts/provision/70_systemd.sh (rendered from infra/systemd/autoops-deploy.path.tpl).
# Starts autoops-deploy.service when the runner leaves `request` in the inbox. The runner writes `request.tmp` and
# renames it, so a half-written file never matches. PathExists= (not PathChanged=) on purpose: a request that arrives
# while a deploy is running is not lost, because the path unit checks again when the service stops; deploy.sh deletes
# the request as soon as it has read it, so it does not retrigger.
[Unit]
Description=AutoOps deploy inbox (request from the runner)
Documentation=file:@@APP_DIR@@/infra/systemd/README.md

[Path]
PathExists=@@DEPLOY_INBOX_DIR@@/request
Unit=autoops-deploy.service

[Install]
WantedBy=multi-user.target
