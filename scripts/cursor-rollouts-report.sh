#!/usr/bin/env bash
# Report deployments to Cursor Rollouts (Factory Deployments API).
# Usage: cursor-rollouts-report.sh <bootstrap|start|finish> [succeeded|failed|aborted]
# Requires: CURSOR_API_KEY, CHANGE_MONITOR_ENV, CHANGE_MONITOR_SERVICE,
#           DEPLOY_VERSION (git sha), and optionally DEPLOY_ACTOR / GITHUB_RUN_URL.
set -euo pipefail

CMD="${1:-}"
OUTCOME="${2:-succeeded}"

DEPLOY_SOURCE_URI="${DEPLOY_SOURCE_URI:-https://github.com/mathews-cloud-tester/ledger-d-empty-placeholder}"
ENV_ID="${CHANGE_MONITOR_ENV:?CHANGE_MONITOR_ENV is required}"
SERVICE_ID="${CHANGE_MONITOR_SERVICE:?CHANGE_MONITOR_SERVICE is required}"
DEPLOY_VERSION="${DEPLOY_VERSION:-${GITHUB_SHA:-}}"
ACTOR="${DEPLOY_ACTOR:-${GITHUB_SERVER_URL:-}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-unknown}}"
STATE_FILE="${RUNNER_TEMP:-/tmp}/cursor-rollouts-deployment-name"

api_post() {
  local url="$1"
  local body="$2"
  local token="$3"
  curl -sS --max-time 15 \
    -X POST "$url" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -H "Connect-Protocol-Version: 1" \
    -d "$body"
}

exchange_token() {
  local key="${CURSOR_API_KEY:?CURSOR_API_KEY is required}"
  local resp
  resp="$(curl -sS --max-time 15 \
    -X POST "https://api2.cursor.sh/auth/exchange_user_api_key" \
    -H "Authorization: Bearer ${key}" \
    -H "Content-Type: application/json" \
    -d '{}')"
  echo "$resp" | jq -r '.accessToken // empty'
}

bootstrap() {
  local token
  token="$(exchange_token)"
  if [[ -z "$token" ]]; then
    echo "cursor-rollouts: failed to exchange API key" >&2
    return 0
  fi

  local env_resp svc_resp
  env_resp="$(api_post \
    "https://api.cursor.com/factory.v1.DeploymentsService/CreateEnvironment" \
    "{\"environmentId\":\"${ENV_ID}\",\"environment\":{\"displayName\":\"${ENV_ID}\"}}" \
    "$token" || true)"
  svc_resp="$(api_post \
    "https://api.cursor.com/factory.v1.DeploymentsService/CreateService" \
    "{\"serviceId\":\"${SERVICE_ID}\",\"service\":{\"displayName\":\"${SERVICE_ID}\"}}" \
    "$token" || true)"
  echo "cursor-rollouts: bootstrap env=${ENV_ID} service=${SERVICE_ID}"
  echo "cursor-rollouts: CreateEnvironment -> ${env_resp}"
  echo "cursor-rollouts: CreateService -> ${svc_resp}"
}

start() {
  local token
  token="$(exchange_token)"
  if [[ -z "$token" ]]; then
    echo "cursor-rollouts: failed to exchange API key" >&2
    return 0
  fi
  if [[ -z "$DEPLOY_VERSION" ]]; then
    echo "cursor-rollouts: DEPLOY_VERSION / GITHUB_SHA is required" >&2
    return 0
  fi

  local body resp name
  body="$(jq -nc \
    --arg src "$DEPLOY_SOURCE_URI" \
    --arg env "environments/${ENV_ID}" \
    --arg ver "$DEPLOY_VERSION" \
    --arg svc "services/${SERVICE_ID}" \
    --arg actor "$ACTOR" \
    '{deployment:{deploySourceUri:$src,environment:$env,deployVersion:$ver,service:$svc},event:{started:{},actor:$actor}}')"
  resp="$(api_post \
    "https://api.cursor.com/factory.v1.DeploymentsService/CreateDeployment" \
    "$body" \
    "$token" || true)"
  name="$(echo "$resp" | jq -r '.deployment.name // .name // empty')"
  if [[ -n "$name" ]]; then
    printf '%s' "$name" >"$STATE_FILE"
    echo "cursor-rollouts: started deployment ${name}"
  else
    echo "cursor-rollouts: CreateDeployment response: ${resp}" >&2
  fi
}

finish() {
  local token
  token="$(exchange_token)"
  if [[ -z "$token" ]]; then
    echo "cursor-rollouts: failed to exchange API key" >&2
    return 0
  fi

  local name=""
  if [[ -f "$STATE_FILE" ]]; then
    name="$(cat "$STATE_FILE")"
  fi
  if [[ -z "$name" ]]; then
    echo "cursor-rollouts: no deployment name to finish" >&2
    return 0
  fi

  local event body resp
  case "$OUTCOME" in
    failed)
      event="$(jq -nc --arg actor "$ACTOR" --arg msg "${DEPLOY_FAILURE_MESSAGE:-deploy failed}" \
        '{completed:{failed:{message:$msg}},actor:$actor}')"
      ;;
    aborted)
      event="$(jq -nc --arg actor "$ACTOR" '{aborted:{},actor:$actor}')"
      ;;
    *)
      event="$(jq -nc --arg actor "$ACTOR" '{completed:{succeeded:{}},actor:$actor}')"
      ;;
  esac

  body="$(jq -nc --arg name "$name" --argjson event "$event" '{name:$name,event:$event}')"
  resp="$(api_post \
    "https://api.cursor.com/factory.v1.DeploymentsService/AppendDeploymentEvent" \
    "$body" \
    "$token" || true)"
  echo "cursor-rollouts: finished deployment ${name} outcome=${OUTCOME}"
  echo "cursor-rollouts: AppendDeploymentEvent -> ${resp}"
}

case "$CMD" in
  bootstrap) bootstrap ;;
  start) start ;;
  finish) finish ;;
  *)
    echo "usage: $0 <bootstrap|start|finish> [succeeded|failed|aborted]" >&2
    exit 1
    ;;
esac
