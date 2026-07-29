#!/bin/bash
# Helpers for registering a custom OpenAI-compatible model provider.
#
# Sourced by /etc/cont-init.d/21-setup-custom-provider. Depends on curl and jq.
#
# Header values and the API key are written literally into openclaw.json rather
# than as "${VAR}" placeholders: OpenClaw does not expand ${VAR} inside header
# blocks (openclaw/openclaw#70901). openclaw.json is mode 0600 and is encrypted
# inside Restic backups.

CP_DEFAULT_NAME="custom"
CP_API_KEY_PLACEHOLDER="not-required"
CP_DISCOVERY_ATTEMPTS="${CP_DISCOVERY_ATTEMPTS:-3}"
CP_DISCOVERY_TIMEOUT="${CP_DISCOVERY_TIMEOUT:-10}"
CP_DISCOVERY_RETRY_DELAY="${CP_DISCOVERY_RETRY_DELAY:-2}"

cp_log()  { echo "[custom-provider] $*"; }
cp_warn() { echo "[custom-provider] WARNING: $*" >&2; }
cp_err()  { echo "[custom-provider] ERROR: $*" >&2; }

cp_enabled() { [ -n "${CUSTOM_PROVIDER_BASE_URL:-}" ]; }

cp_provider_name() {
  local name="${CUSTOM_PROVIDER_NAME:-$CP_DEFAULT_NAME}"
  if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    cp_err "CUSTOM_PROVIDER_NAME '$name' is invalid (allowed: A-Z a-z 0-9 _ -)"
    return 1
  fi
  printf '%s' "$name"
}

cp_base_url() { printf '%s' "${CUSTOM_PROVIDER_BASE_URL%/}"; }

# cp_int <value> <default> - print value when it is a positive integer, else default.
cp_int() {
  if [[ "$1" =~ ^[0-9]+$ ]]; then printf '%s' "$1"; else printf '%s' "$2"; fi
}

# Merged static headers as compact JSON. CUSTOM_PROVIDER_HEADERS is the base;
# the CF_ACCESS_* convenience variables merge on top and win on collision.
cp_headers_json() {
  local base='{}'
  if [ -n "${CUSTOM_PROVIDER_HEADERS:-}" ]; then
    if printf '%s' "$CUSTOM_PROVIDER_HEADERS" | jq -e 'type == "object"' >/dev/null 2>&1; then
      base="$CUSTOM_PROVIDER_HEADERS"
    else
      cp_warn "CUSTOM_PROVIDER_HEADERS is not a JSON object; ignoring it"
    fi
  fi
  printf '%s' "$base" | jq -c \
    --arg id "${CF_ACCESS_CLIENT_ID:-}" \
    --arg secret "${CF_ACCESS_CLIENT_SECRET:-}" '
      .
      + (if $id     != "" then {"CF-Access-Client-Id": $id}         else {} end)
      + (if $secret != "" then {"CF-Access-Client-Secret": $secret} else {} end)
    '
}

# Optional: when no key is configured, a harmless placeholder is written.
# OpenClaw expects a credential for a public https baseUrl, and neither a vLLM
# server started without --api-key nor Cloudflare Access inspects Authorization.
cp_api_key() {
  if [ -n "${CUSTOM_PROVIDER_API_KEY:-}" ]; then
    printf '%s' "$CUSTOM_PROVIDER_API_KEY"
  else
    printf '%s' "$CP_API_KEY_PLACEHOLDER"
  fi
}

# cp_models_from_list <csv> - expand "a, b" into a JSON array of model entries.
cp_models_from_list() {
  printf '%s' "$1" | jq -Rc \
    --argjson ctx "$(cp_int "${CUSTOM_PROVIDER_CONTEXT_WINDOW:-}" 128000)" \
    --argjson max "$(cp_int "${CUSTOM_PROVIDER_MAX_TOKENS:-}" 8192)" '
      split(",")
      | map(gsub("^[[:space:]]+|[[:space:]]+$"; ""))
      | map(select(length > 0))
      | map({
          id: ., name: ., reasoning: false, input: ["text"],
          contextWindow: $ctx, maxTokens: $max
        })
    '
}

# cp_curl_header_args <headers-json> - print one "Name: value" line per header.
cp_curl_header_args() {
  printf '%s' "$1" | jq -r 'to_entries[] | "\(.key): \(.value)"'
}

# cp_discover_models <base-url> <headers-json> <api-key>
# Prints a JSON array of OpenClaw model entries. Exit 1 on failure/empty result.
cp_discover_models() {
  local base_url="${1%/}" headers_json="$2" api_key="$3"
  local url="${base_url}/models"
  local -a curl_args=(-fsS --max-time "$CP_DISCOVERY_TIMEOUT" -H "Authorization: Bearer ${api_key}")
  local line

  while IFS= read -r line; do
    [ -n "$line" ] && curl_args+=(-H "$line")
  done < <(cp_curl_header_args "$headers_json")

  local attempt=1 body="" ok=false
  while [ "$attempt" -le "$CP_DISCOVERY_ATTEMPTS" ]; do
    if body=$(curl "${curl_args[@]}" "$url" 2>/dev/null); then
      ok=true
      break
    fi
    cp_warn "model discovery attempt ${attempt}/${CP_DISCOVERY_ATTEMPTS} failed for $url"
    attempt=$((attempt + 1))
    [ "$attempt" -le "$CP_DISCOVERY_ATTEMPTS" ] && sleep "$CP_DISCOVERY_RETRY_DELAY"
  done

  if [ "$ok" != "true" ]; then
    cp_err "model discovery failed for $url after ${CP_DISCOVERY_ATTEMPTS} attempt(s)"
    return 1
  fi

  local models
  models=$(printf '%s' "$body" | jq -c \
    --argjson ctx "$(cp_int "${CUSTOM_PROVIDER_CONTEXT_WINDOW:-}" 128000)" \
    --argjson max "$(cp_int "${CUSTOM_PROVIDER_MAX_TOKENS:-}" 8192)" '
      (.data // [])
      | map(select((.id // "") != ""))
      | map({
          id: .id, name: .id, reasoning: false, input: ["text"],
          contextWindow: (if (.max_model_len | type) == "number" then .max_model_len else $ctx end),
          maxTokens: $max
        })
    ' 2>/dev/null)

  if [ -z "$models" ]; then
    cp_err "model discovery returned unparseable JSON from $url"
    return 1
  fi
  if [ "$(printf '%s' "$models" | jq 'length')" -eq 0 ]; then
    cp_err "model discovery returned no usable models from $url"
    return 1
  fi

  printf '%s' "$models"
}

# cp_first_model_id <config-file> <provider-name>
cp_first_model_id() {
  jq -r --arg n "$2" '.models.providers[$n].models[0].id // ""' "$1"
}

# cp_apply_to_config <config-file>
# Connection fields always refresh from the environment, so credentials can be
# rotated by restarting. The model catalog is resolved only at setup (no models
# yet) or when CUSTOM_PROVIDER_REFRESH_MODELS=true, so a brief endpoint outage
# cannot wipe a working list. Returns 1 without touching the config when no
# models can be resolved at all.
cp_apply_to_config() {
  local config_file="$1"
  local name base_url headers api_key models existing existing_count

  cp_enabled || return 0

  name=$(cp_provider_name) || return 1
  base_url=$(cp_base_url)
  headers=$(cp_headers_json)
  api_key=$(cp_api_key)

  if [ ! -f "$config_file" ]; then
    cp_err "config file not found: $config_file"
    return 1
  fi

  existing=$(jq -c --arg n "$name" '.models.providers[$n].models // []' "$config_file")
  existing_count=$(printf '%s' "$existing" | jq 'length')

  if [ -n "${CUSTOM_PROVIDER_MODELS:-}" ]; then
    models=$(cp_models_from_list "$CUSTOM_PROVIDER_MODELS")
    cp_log "using explicit CUSTOM_PROVIDER_MODELS ($(printf '%s' "$models" | jq 'length') model(s)); discovery skipped"
  elif [ "$existing_count" -gt 0 ] && [ "${CUSTOM_PROVIDER_REFRESH_MODELS:-false}" != "true" ]; then
    models="$existing"
    cp_log "reusing ${existing_count} model(s) already in config"
  else
    cp_log "discovering models from ${base_url}/models"
    if models=$(cp_discover_models "$base_url" "$headers" "$api_key"); then
      cp_log "discovered $(printf '%s' "$models" | jq 'length') model(s)"
    elif [ "$existing_count" -gt 0 ]; then
      models="$existing"
      cp_warn "refresh failed; keeping the ${existing_count} model(s) already in config"
    else
      cp_err "no models available for provider '${name}' at ${base_url}"
      cp_err "provider NOT registered - fix the endpoint or set CUSTOM_PROVIDER_MODELS, then restart"
      return 1
    fi
  fi

  jq --arg n "$name" --arg url "$base_url" --arg key "$api_key" \
     --argjson headers "$headers" --argjson models "$models" '
      .models.mode //= "merge"
      | .models.providers[$n].baseUrl = $url
      | .models.providers[$n].api = "openai-completions"
      | .models.providers[$n].apiKey = $key
      | .models.providers[$n].models = $models
      | if ($headers | length) > 0
        then .models.providers[$n].headers = $headers
        else del(.models.providers[$n].headers)
        end
    ' "$config_file" > "${config_file}.tmp" || {
      cp_err "failed to merge provider into $config_file"
      rm -f "${config_file}.tmp"
      return 1
    }
  mv "${config_file}.tmp" "$config_file"

  cp_log "registered provider '${name}' -> ${base_url}"
}
