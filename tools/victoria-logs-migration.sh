#!/usr/bin/env bash

# Helper scripts are single-quoted so positional parameters expand in the pod.
# shellcheck disable=SC2016
set -Eeuo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly DEFAULT_OLD_URL="http://127.0.0.1:9428"
readonly DEFAULT_VLAGENT_URL="http://127.0.0.1:9429"
readonly DEFAULT_SOURCE_CONTAINER_DATA_PATH="/victoria-logs-data"
readonly DEFAULT_DESTINATION_POD="victoria-logs-0"
readonly DEFAULT_HELPER_DEPLOYMENT="victoria-logs-migration-helper"
readonly DEFAULT_HELPER_CONTAINER="migration-helper"
readonly DEFAULT_DESTINATION_DATA_PATH="/victoria-logs-data"

MIGRATION_NAMESPACE="${MIGRATION_NAMESPACE:-}"
MIGRATION_OLD_URL="${MIGRATION_OLD_URL:-$DEFAULT_OLD_URL}"
MIGRATION_NEW_URL="${MIGRATION_NEW_URL:-}"
MIGRATION_VLAGENT_URL="${MIGRATION_VLAGENT_URL:-$DEFAULT_VLAGENT_URL}"
MIGRATION_SOURCE_DATA_PATH="${MIGRATION_SOURCE_DATA_PATH:-}"
MIGRATION_SOURCE_CONTAINER_DATA_PATH="${MIGRATION_SOURCE_CONTAINER_DATA_PATH:-$DEFAULT_SOURCE_CONTAINER_DATA_PATH}"
MIGRATION_DESTINATION_POD="${MIGRATION_DESTINATION_POD:-$DEFAULT_DESTINATION_POD}"
MIGRATION_DESTINATION_NODE="${MIGRATION_DESTINATION_NODE:-}"
MIGRATION_HELPER_DEPLOYMENT="${MIGRATION_HELPER_DEPLOYMENT:-$DEFAULT_HELPER_DEPLOYMENT}"
MIGRATION_HELPER_CONTAINER="${MIGRATION_HELPER_CONTAINER:-$DEFAULT_HELPER_CONTAINER}"
MIGRATION_DESTINATION_DATA_PATH="${MIGRATION_DESTINATION_DATA_PATH:-$DEFAULT_DESTINATION_DATA_PATH}"

MIGRATION_SOURCE_DATA_PATH="${MIGRATION_SOURCE_DATA_PATH%/}"
MIGRATION_SOURCE_CONTAINER_DATA_PATH="${MIGRATION_SOURCE_CONTAINER_DATA_PATH%/}"
MIGRATION_DESTINATION_DATA_PATH="${MIGRATION_DESTINATION_DATA_PATH%/}"
MIGRATION_STATE_PATH="${MIGRATION_STATE_PATH:-${MIGRATION_DESTINATION_DATA_PATH}/.migration}"
MIGRATION_STATE_PATH="${MIGRATION_STATE_PATH%/}"

read -r -a KUBECTL_COMMAND <<< "${KUBECTL:-sudo kubectl}"
# Keep the EXIT-trap target valid even if the replacement workflow has unwound.
DETACHED_PARTITION_RECOVERY_TARGET=""
# Track the source snapshot while its exact API path is still available.
SOURCE_SNAPSHOT_PATH=""
declare -A TRANSFER=()
declare -a MIGRATION_RESUME_PLAN=()
declare -a MIGRATION_COPY_PLAN=()
declare -a MIGRATION_REPLACE_PLAN=()
declare -a MIGRATION_COMPLETED_PLAN=()
declare -a MIGRATION_BLOCKERS=()
MIGRATION_BRIDGE_ACTION=""

# Print the supported migration commands and environment overrides.
usage() {
  cat <<EOF
Usage: $SCRIPT_NAME <command> [options]

Commands:
  preflight
      Verify the old Compose endpoints, the new K3s instance, the migration
      NodePort, and the helper pod's shared PVC mount and tar support.

  status
      Show both VictoriaLogs instances, vlagent fan-out counters, and K3s state.

  partitions
      Compare the active per-day partitions on the old and new instances.

  migrate-partitions BRIDGE_START_DATE [--yes]
      Plan all closed-partition transfers from the recorded bridge-start date.
      With --yes, copy every older source-only partition and reconcile the
      partial bridge-start partition. Successful operations are resumable.
      No producer may backfill these dates while the plan executes.

Environment:
  KUBECTL                         kubectl command (default: "sudo kubectl")
  MIGRATION_NAMESPACE             K3s namespace (required)
  MIGRATION_OLD_URL               Old VictoriaLogs URL
  MIGRATION_NEW_URL               New migration NodePort URL (required)
  MIGRATION_VLAGENT_URL           Old vlagent URL
  MIGRATION_SOURCE_DATA_PATH      Old VictoriaLogs storage directory (required
                                  for preflight and migration)
  MIGRATION_SOURCE_CONTAINER_DATA_PATH
                                  Its path inside the old container
  MIGRATION_DESTINATION_POD       New VictoriaLogs pod name
  MIGRATION_DESTINATION_NODE      Expected new Kubernetes node (required for
                                  preflight and migration)
  MIGRATION_HELPER_DEPLOYMENT     Migration helper Deployment name
  MIGRATION_HELPER_CONTAINER      Migration helper container name
  MIGRATION_DESTINATION_DATA_PATH Shared PVC mount inside the helper
  MIGRATION_STATE_PATH            Migration state directory inside the PVC
EOF
}

log() {
  printf '==> %s\n' "$*"
}

warn() {
  printf 'WARNING: %s\n' "$*" >&2
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

# Require a local executable before beginning an operation.
require_command() {
  local command_name="$1"
  command -v "$command_name" >/dev/null 2>&1 || \
    die "Required command not found: ${command_name}"
}

# Require a non-empty deployment setting.
require_setting() {
  local setting_name="$1"
  local setting_value="$2"

  [[ -n "$setting_value" ]] || die "${setting_name} must be set"
}

# Validate settings shared by every command that contacts the destination.
validate_runtime_configuration() {
  require_setting MIGRATION_NAMESPACE "$MIGRATION_NAMESPACE"
  require_setting MIGRATION_NEW_URL "$MIGRATION_NEW_URL"
  [[ "$MIGRATION_NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || \
    die "Invalid namespace: ${MIGRATION_NAMESPACE}"
}

# Require the local tools shared by preflight and partition transfer.
require_transfer_commands() {
  local command_name

  for command_name in curl jq tar date realpath; do
    require_command "$command_name"
  done
}

# Return success when a path contains traversal, current-dir, or empty segments.
has_unsafe_path_segment() {
  local path="/${1#/}/"

  [[ "$path" == *"/../"* || "$path" == *"/./"* || "$path" == *"//"* ]]
}

# Return success for an absolute, non-root container storage path.
valid_container_data_root() {
  local path="$1"

  [[ "$path" =~ ^/[A-Za-z0-9._/-]+$ ]] &&
    ! has_unsafe_path_segment "$path"
}

# Validate local paths and helper settings required by a partition transfer.
validate_transfer_environment() {
  require_setting MIGRATION_SOURCE_DATA_PATH "$MIGRATION_SOURCE_DATA_PATH"
  require_setting MIGRATION_DESTINATION_NODE "$MIGRATION_DESTINATION_NODE"
  require_transfer_commands
  [[ -d "$MIGRATION_SOURCE_DATA_PATH/partitions" ]] || \
    die "Source partition directory not found: ${MIGRATION_SOURCE_DATA_PATH}/partitions"
  valid_container_data_root "$MIGRATION_SOURCE_CONTAINER_DATA_PATH" || \
    die "Invalid container data path: ${MIGRATION_SOURCE_CONTAINER_DATA_PATH:-<empty>}"
  valid_container_data_root "$MIGRATION_DESTINATION_DATA_PATH" || \
    die "Invalid helper data path: ${MIGRATION_DESTINATION_DATA_PATH:-<empty>}"
  if [[ "$MIGRATION_STATE_PATH" != "${MIGRATION_DESTINATION_DATA_PATH}/"* ]] ||
    ! valid_container_data_root "$MIGRATION_STATE_PATH"; then
    die "Migration state must remain inside the helper data mount"
  fi
  [[ "$MIGRATION_HELPER_DEPLOYMENT" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || \
    die "Invalid helper Deployment name: ${MIGRATION_HELPER_DEPLOYMENT}"
  [[ "$MIGRATION_HELPER_CONTAINER" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || \
    die "Invalid helper container name: ${MIGRATION_HELPER_CONTAINER}"
}

# Invoke the configured kubectl command without evaluating shell text.
kube() {
  "${KUBECTL_COMMAND[@]}" "$@"
}

# Execute a command in the single-replica migration helper Deployment.
helper_exec() {
  kube -n "$MIGRATION_NAMESPACE" exec \
    "deployment/${MIGRATION_HELPER_DEPLOYMENT}" \
    -c "$MIGRATION_HELPER_CONTAINER" -- "$@"
}

# Stream standard input to a command in the migration helper Deployment.
helper_exec_input() {
  kube -n "$MIGRATION_NAMESPACE" exec -i \
    "deployment/${MIGRATION_HELPER_DEPLOYMENT}" \
    -c "$MIGRATION_HELPER_CONTAINER" -- "$@"
}

# Validate and normalize a UTC partition date in YYYYMMDD form.
validate_partition_date() {
  local partition_date="$1"
  local normalized

  [[ "$partition_date" =~ ^[0-9]{8}$ ]] || \
    die "Partition date must use YYYYMMDD"
  normalized="$(date -u -d "$partition_date" +%Y%m%d 2>/dev/null)" || \
    die "Invalid partition date: ${partition_date}"
  [[ "$normalized" == "$partition_date" ]] || \
    die "Invalid partition date: ${partition_date}"
}

# Return the JSON partition list from a VictoriaLogs endpoint.
partition_list() {
  local base_url="$1"
  curl -fsS "${base_url}/internal/partition/list"
}

# Print unique YYYYMMDD partition names from a partition-list response.
partition_names() {
  jq -r '.. | strings | select(test("^[0-9]{8}$"))' | sort -u
}

# Print "present" or "absent" for a partition, failing if it cannot be listed.
partition_state() {
  local base_url="$1"
  local partition_date="$2"
  local response
  local names

  response="$(partition_list "$base_url")" || return 1
  names="$(partition_names <<< "$response")" || return 1
  if grep -Fxq "$partition_date" <<< "$names"; then
    printf 'present\n'
  else
    printf 'absent\n'
  fi
}

# Attach or detach a partition through the destination management API.
manage_destination_partition() {
  local action="$1"
  local partition_date="$2"

  curl -fsSG --data-urlencode "name=${partition_date}" \
    "${MIGRATION_NEW_URL}/internal/partition/${action}" && printf '\n'
}

# Attach a destination partition and return 0=active, 1=inactive, 2=unknown.
attach_destination_partition() {
  local partition_date="$1"
  local request_ok=true
  local destination_state

  manage_destination_partition attach "$partition_date" || request_ok=false
  if ! destination_state="$(partition_state "$MIGRATION_NEW_URL" "$partition_date")"; then
    [[ "$request_ok" == true ]] || warn "The attach request also returned an error"
    return 2
  fi
  if [[ "$destination_state" == present ]]; then
    [[ "$request_ok" == true ]] || \
      log "The attach request returned an error, but partition ${partition_date} is active"
    return 0
  fi
  [[ "$request_ok" == true ]] || warn "The attach request returned an error"
  return 1
}

# Best-effort recovery for an exit after detach but before a completed swap.
best_effort_reattach_partition() {
  local partition_date="$1"
  local recovery_status

  log "Recovery: attempting to reattach destination partition ${partition_date}"
  if attach_destination_partition "$partition_date"; then
    log "Recovery: destination partition ${partition_date} is active"
    return
  else
    recovery_status=$?
  fi
  if (( recovery_status == 1 )); then
    warn "Recovery did not make partition ${partition_date} active"
  else
    warn "Recovery outcome is unknown for partition ${partition_date}"
  fi
}

# Preserve the original exit status after attempting detached-partition recovery.
recover_detached_partition_on_exit() {
  local exit_status="$?"

  trap - EXIT
  best_effort_reattach_partition "$DETACHED_PARTITION_RECOVERY_TARGET"
  exit "$exit_status"
}

# Print the durable pending or completed marker path for a partition operation.
operation_marker_path() {
  local marker_kind="$1"
  local operation="$2"
  local partition_date="$3"

  [[ "$marker_kind" == pending || "$marker_kind" == completed ]] || \
    die "Unsupported marker kind: ${marker_kind}"
  [[ "$operation" == copy || "$operation" == replace ]] || \
    die "Unsupported marker operation: ${operation}"
  printf '%s/markers/%s/%s-%s.marker\n' \
    "$MIGRATION_STATE_PATH" "$marker_kind" "$operation" "$partition_date"
}

# Print "present" or "absent" for a durable PVC operation marker.
operation_marker_state() {
  local marker_kind="$1"
  local operation="$2"
  local partition_date="$3"
  local marker_path

  marker_path="$(operation_marker_path "$marker_kind" "$operation" "$partition_date")"
  [[ "$marker_path" == "${MIGRATION_STATE_PATH}/markers/"* ]] || \
    die "Unsafe marker path: ${marker_path}"
  helper_exec sh -c '
    if test -f "$1"; then
      printf "present\n"
    elif test ! -e "$1"; then
      printf "absent\n"
    else
      exit 1
    fi
  ' migration-helper "$marker_path"
}

# Write a durable marker and verify ambiguous kubectl exec outcomes.
write_operation_marker() {
  local marker_kind="$1"
  local operation="$2"
  local partition_date="$3"
  local marker_path
  local marker_root
  local marker_state

  marker_path="$(operation_marker_path "$marker_kind" "$operation" "$partition_date")"
  marker_root="${marker_path%/*}"
  [[ "$marker_path" == "${MIGRATION_STATE_PATH}/markers/"* ]] || \
    die "Unsafe marker path: ${marker_path}"

  if helper_exec sh -c 'mkdir -p "$1" && touch "$2"' \
    migration-helper "$marker_root" "$marker_path"; then
    return
  fi
  marker_state="$(operation_marker_state "$marker_kind" "$operation" "$partition_date")" || \
    die "Cannot create or verify marker ${marker_path}"
  [[ "$marker_state" == present ]] || die "Cannot create marker ${marker_path}"
  log "Marker creation response was lost, but ${marker_path} exists"
}

# Remove a durable operation marker, accepting a lost successful response.
remove_operation_marker() {
  local marker_kind="$1"
  local operation="$2"
  local partition_date="$3"
  local marker_path
  local marker_state

  marker_path="$(operation_marker_path "$marker_kind" "$operation" "$partition_date")"
  [[ "$marker_path" == "${MIGRATION_STATE_PATH}/markers/"* ]] || \
    die "Unsafe marker path: ${marker_path}"
  if helper_exec rm -f "$marker_path"; then
    return
  fi
  marker_state="$(operation_marker_state "$marker_kind" "$operation" "$partition_date")" || return 1
  [[ "$marker_state" == absent ]]
}

# List strict marker filenames for a pending or completed state directory.
list_operation_markers() {
  local marker_kind="$1"
  local marker_root="${MIGRATION_STATE_PATH}/markers/${marker_kind}"

  [[ "$marker_kind" == pending || "$marker_kind" == completed ]] || \
    die "Unsupported marker kind: ${marker_kind}"
  [[ "$marker_root" == "${MIGRATION_STATE_PATH}/markers/"* ]] || \
    die "Unsafe marker root: ${marker_root}"
  helper_exec sh -c '
    test -d "$1" || exit 0
    for marker in "$1"/*; do
      test -f "$marker" || continue
      printf "%s\n" "${marker##*/}"
    done
  ' migration-helper "$marker_root"
}

# Resolve and verify the shared RWO claim and co-located helper pod.
destination_mount_info() {
  local access_modes
  local destination_claim
  local destination_node
  local helper_claim
  local helper_node
  local helper_pod

  helper_pod="$(kube -n "$MIGRATION_NAMESPACE" get pod \
    -l 'app.kubernetes.io/name=victoria-logs-migration-helper,app.kubernetes.io/component=migration' \
    -o jsonpath='{.items[0].metadata.name}')" || \
    die "Cannot find the migration helper pod"
  [[ -n "$helper_pod" ]] || die "Migration helper pod not found"

  destination_claim="$(kube -n "$MIGRATION_NAMESPACE" get pod "$MIGRATION_DESTINATION_POD" \
    -o jsonpath='{.spec.volumes[?(@.name=="victoria-logs-data")].persistentVolumeClaim.claimName}')"
  [[ -n "$destination_claim" ]] || \
    die "${MIGRATION_DESTINATION_POD} does not expose a victoria-logs-data PVC"
  helper_claim="$(kube -n "$MIGRATION_NAMESPACE" get pod "$helper_pod" \
    -o jsonpath='{.spec.volumes[?(@.name=="victoria-logs-data")].persistentVolumeClaim.claimName}')"
  [[ "$helper_claim" == "$destination_claim" ]] || \
    die "Helper mounts ${helper_claim:-<none>}, but VictoriaLogs mounts ${destination_claim}"

  destination_node="$(kube -n "$MIGRATION_NAMESPACE" get pod "$MIGRATION_DESTINATION_POD" \
    -o jsonpath='{.spec.nodeName}')"
  helper_node="$(kube -n "$MIGRATION_NAMESPACE" get pod "$helper_pod" \
    -o jsonpath='{.spec.nodeName}')"
  [[ "$destination_node" == "$MIGRATION_DESTINATION_NODE" ]] || \
    die "${MIGRATION_DESTINATION_POD} runs on ${destination_node}, expected ${MIGRATION_DESTINATION_NODE}"
  [[ "$helper_node" == "$destination_node" ]] || \
    die "Migration helper runs on ${helper_node}, not ${destination_node}"

  access_modes="$(kube -n "$MIGRATION_NAMESPACE" get pvc "$destination_claim" \
    -o jsonpath='{.spec.accessModes[*]}')"
  [[ " $access_modes " == *" ReadWriteOnce "* ]] || \
    die "PVC ${destination_claim} does not use ReadWriteOnce"

  printf '%s\t%s\t%s\n' "$destination_claim" "$destination_node" "$helper_pod"
}

# Show the migration-relevant vlagent buffer and delivery counters.
fanout_status() {
  curl -fsS "${MIGRATION_VLAGENT_URL}/metrics" | awk '
    /^vlagent_remotewrite_(pending_data_bytes|pending_inmemory_blocks|queue_blocked|packets_dropped_total|errors_total|retries_count_total)/ ||
    /^vm_persistentqueue_(blocks|bytes)_dropped_total/ ||
    /^vl_rows_dropped_total/ {
      print
    }
  '
}

# Verify all read-only prerequisites for dual-write and partition transfer.
preflight() {
  local destination_node
  local helper_pod
  local pvc_name

  validate_transfer_environment

  log "Checking the old VictoriaLogs instance"
  curl -fsS "${MIGRATION_OLD_URL}/health"
  printf '\n'

  log "Checking the old vlagent"
  curl -fsS "${MIGRATION_VLAGENT_URL}/health"
  printf '\n'

  log "Checking the new VictoriaLogs migration endpoint"
  curl -fsS "${MIGRATION_NEW_URL}/health"
  printf '\n'

  log "Checking the new K3s workload and storage"
  kube -n "$MIGRATION_NAMESPACE" get pod "$MIGRATION_DESTINATION_POD" -o wide
  kube -n "$MIGRATION_NAMESPACE" get deployment "$MIGRATION_HELPER_DEPLOYMENT"
  IFS=$'\t' read -r pvc_name destination_node helper_pod < <(destination_mount_info)
  printf 'PVC=%s\nNODE=%s\nHELPER_POD=%s\n' \
    "$pvc_name" "$destination_node" "$helper_pod"

  log "Checking the helper PVC mount and tar support"
  helper_exec sh -ec '
    command -v tar >/dev/null
    test -d "$1"
    test -w "$1"
  ' migration-helper "$MIGRATION_DESTINATION_DATA_PATH"
  log "Preflight passed"
}

# Print the live state of both instances and the fan-out agent.
status() {
  log "Old VictoriaLogs health"
  curl -fsS "${MIGRATION_OLD_URL}/health"
  printf '\n'

  log "New VictoriaLogs health"
  curl -fsS "${MIGRATION_NEW_URL}/health"
  printf '\n'

  log "vlagent fan-out counters"
  fanout_status

  log "K3s workloads"
  kube -n "$MIGRATION_NAMESPACE" get deploy,statefulset,pod,svc,pvc -o wide
}

# Compare the old and new active partition names.
partitions() {
  local old_file
  local new_file

  old_file="$(mktemp)"
  new_file="$(mktemp)"

  partition_list "$MIGRATION_OLD_URL" | partition_names > "$old_file"
  partition_list "$MIGRATION_NEW_URL" | partition_names > "$new_file"

  log "Old partitions"
  sed 's/^/  /' "$old_file"
  log "New partitions"
  sed 's/^/  /' "$new_file"
  log "Present only on the old instance"
  comm -23 "$old_file" "$new_file" | sed 's/^/  /'
  log "Present on both instances"
  comm -12 "$old_file" "$new_file" | sed 's/^/  /'
  rm -f -- "$old_file" "$new_file"
}

# Resolve and validate stable destination paths for one operation and date.
set_transfer_paths() {
  local operation="$1"
  local partition_date="$2"

  TRANSFER=()
  [[ "$operation" == copy || "$operation" == replace ]] || \
    die "Unsupported transfer operation: ${operation}"
  TRANSFER[operation]="$operation"
  TRANSFER[date]="$partition_date"
  TRANSFER[storage]="$MIGRATION_DESTINATION_DATA_PATH"
  TRANSFER[state]="$MIGRATION_STATE_PATH"
  TRANSFER[destination]="${TRANSFER[storage]}/partitions/${partition_date}"
  TRANSFER[incoming_root]="${TRANSFER[state]}/incoming"
  TRANSFER[incoming]="${TRANSFER[incoming_root]}/${operation}-${partition_date}"
  TRANSFER[temporary_root]="${TRANSFER[state]}/transfer"
  TRANSFER[temporary]="${TRANSFER[temporary_root]}/${operation}-${partition_date}.tmp"
  TRANSFER[quarantine_root]="${TRANSFER[state]}/quarantine"
  TRANSFER[quarantine]="${TRANSFER[quarantine_root]}/${partition_date}"

  if [[ "${TRANSFER[destination]}" != "${MIGRATION_DESTINATION_DATA_PATH}/partitions/${partition_date}" ]] ||
    has_unsafe_path_segment "${TRANSFER[destination]}"; then
    die "Unsafe destination path: ${TRANSFER[destination]}"
  fi
  if [[ "${TRANSFER[incoming]}" != "${MIGRATION_STATE_PATH}/incoming/${operation}-${partition_date}" ]] ||
    has_unsafe_path_segment "${TRANSFER[incoming]}"; then
    die "Unsafe incoming path: ${TRANSFER[incoming]}"
  fi
  if [[ "${TRANSFER[temporary]}" != "${MIGRATION_STATE_PATH}/transfer/${operation}-${partition_date}.tmp" ]] ||
    has_unsafe_path_segment "${TRANSFER[temporary]}"; then
    die "Unsafe temporary path: ${TRANSFER[temporary]}"
  fi
  if [[ "${TRANSFER[quarantine]}" != "${MIGRATION_STATE_PATH}/quarantine/${partition_date}" ]] ||
    has_unsafe_path_segment "${TRANSFER[quarantine]}"; then
    die "Unsafe quarantine path: ${TRANSFER[quarantine]}"
  fi
}

# Initialize one new closed-partition transfer after rechecking API state.
initialize_transfer() {
  local operation="$1"
  local partition_date="$2"
  local expected_destination_state="$3"
  local destination_state
  local source_state
  local today

  validate_partition_date "$partition_date"
  today="$(date -u +%Y%m%d)"
  [[ "$partition_date" < "$today" ]] || \
    die "Only closed partitions before ${today} may be transferred"
  source_state="$(partition_state "$MIGRATION_OLD_URL" "$partition_date")" || \
    die "Cannot list source partitions"
  [[ "$source_state" == present ]] || \
    die "Source partition ${partition_date} is not active"
  destination_state="$(partition_state "$MIGRATION_NEW_URL" "$partition_date")" || \
    die "Cannot list destination partitions"
  [[ "$destination_state" == "$expected_destination_state" ]] || \
    die "Destination partition ${partition_date} is ${destination_state}, expected ${expected_destination_state}"

  set_transfer_paths "$operation" "$partition_date"
}

# Remove the exact source snapshot after its stable PVC copy is ready.
delete_source_snapshot() {
  if [[ -n "$SOURCE_SNAPSHOT_PATH" ]]; then
    log "Removing the source snapshot"
    if curl -fsSG --data-urlencode "path=${SOURCE_SNAPSHOT_PATH}" \
      "${MIGRATION_OLD_URL}/internal/partition/snapshot/delete"; then
      printf '\n'
      SOURCE_SNAPSHOT_PATH=""
    else
      warn "Source snapshot ${SOURCE_SNAPSHOT_PATH} was retained"
      return 1
    fi
  fi
}

# Retry source snapshot deletion when an operation exits unexpectedly.
delete_source_snapshot_on_exit() {
  local exit_status="$?"

  trap - EXIT
  warn "Transfer interrupted; retrying source snapshot cleanup"
  delete_source_snapshot || warn "The source snapshot remains"
  exit "$exit_status"
}

# Release the source snapshot once the stable incoming copy is ready.
cleanup_source_snapshot() {
  if delete_source_snapshot; then
    trap - EXIT
    return
  fi
  die "Cannot clean the source snapshot; the prepared incoming copy was retained and the live partition was not changed"
}

# Snapshot the source partition and stream it into the helper's PVC mount.
create_and_stream_snapshot() {
  local snapshot_response
  local snapshot_path
  local source_data_path_real
  local source_path

  log "Creating a consistent source snapshot for ${TRANSFER[date]}"
  snapshot_response="$(curl -fsSG \
    --data-urlencode "partition_prefix=${TRANSFER[date]}" \
    "${MIGRATION_OLD_URL}/internal/partition/snapshot/create")" || \
    die "Cannot create source snapshot for ${TRANSFER[date]}"
  snapshot_path="$(jq -er '
    if type == "array" and length == 1 and (.[0] | type) == "string"
    then .[0]
    else error("expected exactly one snapshot path")
    end
  ' <<< "$snapshot_response")" || die "Unexpected snapshot response: ${snapshot_response}"

  SOURCE_SNAPSHOT_PATH="$snapshot_path"
  trap delete_source_snapshot_on_exit EXIT

  if [[ "$snapshot_path" == "${MIGRATION_SOURCE_CONTAINER_DATA_PATH}"/* ]]; then
    source_path="${MIGRATION_SOURCE_DATA_PATH}/${snapshot_path#"${MIGRATION_SOURCE_CONTAINER_DATA_PATH}"/}"
  elif [[ "$snapshot_path" == "${MIGRATION_SOURCE_DATA_PATH}"/* ]]; then
    source_path="$snapshot_path"
  elif [[ "$snapshot_path" == /* ]]; then
    die "Snapshot uses an unexpected absolute path: ${snapshot_path}"
  else
    if [[ ! "$snapshot_path" =~ ^[A-Za-z0-9._/-]+$ ]] ||
      has_unsafe_path_segment "$snapshot_path"; then
      die "Unsafe relative snapshot path: ${snapshot_path}"
    fi
    source_path="${MIGRATION_SOURCE_DATA_PATH}/${snapshot_path}"
  fi
  source_data_path_real="$(realpath -e -- "$MIGRATION_SOURCE_DATA_PATH")" || \
    die "Cannot resolve source data path: ${MIGRATION_SOURCE_DATA_PATH}"
  source_path="$(realpath -e -- "$source_path")" || \
    die "Snapshot directory not found: ${source_path}"
  [[ "$source_path" == "${source_data_path_real}"/* ]] || \
    die "Snapshot is outside the source data path: ${source_path}"
  [[ -d "$source_path" ]] || die "Snapshot directory not found: ${source_path}"

  TRANSFER[source]="$source_path"
  printf 'SOURCE=%s\nDESTINATION=%s\n' \
    "${TRANSFER[source]}" "${TRANSFER[destination]}"

  log "Streaming ${TRANSFER[date]} into the migration helper"
  if ! tar -C "${TRANSFER[source]}" -cpf - . |
    helper_exec_input sh -ec '
      temporary=$1
      temporary_root=$2
      incoming=$3
      incoming_root=$4

      rm -rf "$temporary"
      mkdir -p "$temporary_root" "$incoming_root" "$temporary"
      if ! tar -C "$temporary" -xpf -; then
        rm -rf "$temporary"
        exit 1
      fi
      rm -rf "$incoming"
      mv "$temporary" "$incoming"
    ' migration-helper \
      "${TRANSFER[temporary]}" "${TRANSFER[temporary_root]}" \
      "${TRANSFER[incoming]}" "${TRANSFER[incoming_root]}"; then
    helper_exec rm -rf "${TRANSFER[temporary]}" || \
      warn "Partial transfer ${TRANSFER[temporary]} could not be removed"
    die "Cannot stream partition ${TRANSFER[date]} into the helper PVC"
  fi
}

# Atomically move a prepared source-only copy into its final directory.
install_prepared_copy() {
  log "Installing ${TRANSFER[date]} into the retained K3s volume"
  helper_exec sh -ec '
    test ! -e "$1"
    test -d "$2"
    mv "$2" "$1"
  ' migration-helper "${TRANSFER[destination]}" "${TRANSFER[incoming]}"
}

# Detach an active partition and atomically install its complete replacement.
swap_replacement_partition() {
  local destination_state

  log "Detaching destination partition ${TRANSFER[date]}"
  DETACHED_PARTITION_RECOVERY_TARGET="${TRANSFER[date]}"
  trap recover_detached_partition_on_exit EXIT
  manage_destination_partition detach "${TRANSFER[date]}" || \
    die "Cannot detach destination partition ${TRANSFER[date]}"
  destination_state="$(partition_state "$MIGRATION_NEW_URL" "${TRANSFER[date]}")" || \
    die "Cannot verify destination partition ${TRANSFER[date]} after detach"
  [[ "$destination_state" == absent ]] || \
    die "Destination partition ${TRANSFER[date]} is still active after detach; refusing to move its files"

  log "Atomically replacing the destination partition"
  helper_exec sh -ec '
    destination=$1
    incoming=$2
    quarantine=$3
    quarantine_root=$4

    test -d "$destination"
    test -d "$incoming"
    test ! -e "$quarantine"
    mkdir -p "$quarantine_root"
    mv "$destination" "$quarantine"
    if ! mv "$incoming" "$destination"; then
      mv "$quarantine" "$destination"
      exit 1
    fi
  ' migration-helper \
    "${TRANSFER[destination]}" "${TRANSFER[incoming]}" \
    "${TRANSFER[quarantine]}" "${TRANSFER[quarantine_root]}" || \
    die "The directory swap failed; detached-partition recovery will run before exit"
  trap - EXIT
  DETACHED_PARTITION_RECOVERY_TARGET=""
}

# Restore the quarantined destination after a confirmed inactive replacement.
restore_original_partition() {
  helper_exec sh -ec '
    destination=$1
    incoming=$2
    quarantine=$3

    test -d "$destination"
    test -d "$quarantine"
    test ! -e "$incoming"
    mv "$destination" "$incoming"
    if ! mv "$quarantine" "$destination"; then
      mv "$incoming" "$destination"
      exit 1
    fi
  ' migration-helper \
    "${TRANSFER[destination]}" "${TRANSFER[incoming]}" "${TRANSFER[quarantine]}"
}

# Restore a quarantined original when the final directory is temporarily absent.
restore_quarantined_partition() {
  helper_exec sh -ec '
    test ! -e "$1"
    test -d "$2"
    mv "$2" "$1"
  ' migration-helper "${TRANSFER[destination]}" "${TRANSFER[quarantine]}"
}

# Print "directory", "absent", or "other" for a validated helper path.
helper_directory_state() {
  local path="$1"

  helper_exec sh -c '
    if test -d "$1"; then
      printf "directory\n"
    elif test ! -e "$1"; then
      printf "absent\n"
    else
      printf "other\n"
    fi
  ' migration-helper "$path"
}

# Refresh filesystem states for the active transfer context.
inspect_transfer_directories() {
  local state_name

  TRANSFER[destination_fs]="$(helper_directory_state "${TRANSFER[destination]}")" || \
    die "Cannot inspect ${TRANSFER[destination]}"
  TRANSFER[incoming_fs]="$(helper_directory_state "${TRANSFER[incoming]}")" || \
    die "Cannot inspect ${TRANSFER[incoming]}"
  TRANSFER[quarantine_fs]="$(helper_directory_state "${TRANSFER[quarantine]}")" || \
    die "Cannot inspect ${TRANSFER[quarantine]}"
  for state_name in destination_fs incoming_fs quarantine_fs; do
    [[ "${TRANSFER[$state_name]}" == directory || "${TRANSFER[$state_name]}" == absent ]] || \
      die "Unexpected filesystem object at ${state_name%_fs}: ${TRANSFER[$state_name]}"
  done
}

# Remove a stable, tool-owned incoming directory after a committed operation.
remove_prepared_partition() {
  helper_exec rm -rf "${TRANSFER[incoming]}"
}

# Remove the quarantined old copy after the replacement is committed.
remove_quarantined_partition() {
  helper_exec rm -rf "${TRANSFER[quarantine]}"
}

# Copy one source-only partition as an internal batch operation.
copy_partition() {
  local partition_date="$1"
  local attach_status

  initialize_transfer copy "$partition_date" absent
  create_and_stream_snapshot
  cleanup_source_snapshot
  write_operation_marker pending copy "$partition_date"
  install_prepared_copy
  log "Attaching ${partition_date} to the new VictoriaLogs instance"
  if attach_destination_partition "$partition_date"; then
    :
  else
    attach_status=$?
    if (( attach_status == 1 )); then
      die "The destination did not report attached partition ${partition_date}"
    fi
    die "Cannot verify attachment of partition ${partition_date}; transferred files were retained"
  fi
  write_operation_marker completed copy "$partition_date"
  remove_operation_marker pending copy "$partition_date" || \
    die "Partition ${partition_date} is active, but its pending marker could not be removed; rerun migration"
  log "Partition ${partition_date} copied successfully"
}

# Activate a swapped replacement or restore the quarantined original on failure.
activate_replacement_or_restore() {
  local partition_date="${TRANSFER[date]}"
  local attach_status

  log "Attaching ${partition_date} to the new VictoriaLogs instance"
  if attach_destination_partition "$partition_date"; then
    return
  else
    attach_status=$?
  fi
  (( attach_status == 1 )) || \
    die "Cannot verify replacement attachment; installed and quarantined partitions were retained"

  log "Replacement attachment failed; restoring the original partition"
  restore_original_partition || \
    die "Replacement attachment failed and the original directory could not be restored"
  if attach_destination_partition "$partition_date"; then
    die "Replacement attachment failed; the original partition is active and the complete copy remains at ${TRANSFER[incoming]}"
  else
    attach_status=$?
  fi
  if (( attach_status == 1 )); then
    die "The original directory was restored, but its partition is not active"
  fi
  die "The original directory was restored, but its attachment cannot be verified"
}

# Replace one unmarked common partition as an internal batch operation.
replace_partition() {
  local partition_date="$1"

  initialize_transfer replace "$partition_date" present
  create_and_stream_snapshot
  cleanup_source_snapshot
  write_operation_marker pending replace "$partition_date"
  swap_replacement_partition
  activate_replacement_or_restore
  write_operation_marker completed replace "$partition_date"
  log "Removing the superseded destination partition"
  remove_quarantined_partition || \
    die "Replacement is active, but ${TRANSFER[quarantine]} could not be removed; rerun migration"
  remove_operation_marker pending replace "$partition_date" || \
    die "Replacement is complete, but its pending marker could not be removed; rerun migration"
  log "Partition ${partition_date} replaced successfully"
}

# Finish a pending copy from its durable marker and stable on-disk paths.
resume_copy_partition() {
  local partition_date="$1"
  local attach_status
  local completed_state
  local destination_state

  set_transfer_paths copy "$partition_date"
  completed_state="$(operation_marker_state completed copy "$partition_date")" || \
    die "Cannot read the completed copy marker for ${partition_date}"
  destination_state="$(partition_state "$MIGRATION_NEW_URL" "$partition_date")" || \
    die "Cannot list destination partitions while resuming ${partition_date}"
  inspect_transfer_directories
  if [[ "$destination_state" == present && "${TRANSFER[destination_fs]}" != directory ]]; then
    die "Copy ${partition_date} is active but its destination directory is missing"
  fi
  [[ "${TRANSFER[quarantine_fs]}" == absent ]] || \
    die "Pending copy ${partition_date} unexpectedly has a quarantine directory"

  if [[ "$destination_state" == present ]]; then
    if [[ "$completed_state" == absent && "${TRANSFER[incoming_fs]}" == directory ]]; then
      die "Destination partition ${partition_date} became active after its copy was prepared. This may be backfill visible only on the destination; refusing to replace it automatically. Keep the pending marker and reconcile both copies manually"
    fi
  elif [[ "${TRANSFER[destination_fs]}" == directory && "${TRANSFER[incoming_fs]}" == absent ]]; then
    log "Reattaching installed copy ${partition_date}"
    if attach_destination_partition "$partition_date"; then
      destination_state=present
    else
      attach_status=$?
      (( attach_status == 1 )) && die "Installed copy ${partition_date} remains inactive"
      die "Cannot verify reattachment of installed copy ${partition_date}"
    fi
  elif [[ "${TRANSFER[destination_fs]}" == absent && "${TRANSFER[incoming_fs]}" == directory ]]; then
    install_prepared_copy
    if attach_destination_partition "$partition_date"; then
      destination_state=present
    else
      attach_status=$?
      (( attach_status == 1 )) && die "Resumed copy ${partition_date} remains inactive"
      die "Cannot verify attachment of resumed copy ${partition_date}"
    fi
  else
    die "Pending copy ${partition_date} has an unrecoverable directory layout"
  fi

  [[ "$destination_state" == present ]] || die "Copy ${partition_date} is not active"
  write_operation_marker completed copy "$partition_date"
  if [[ "${TRANSFER[incoming_fs]}" == directory ]]; then
    remove_prepared_partition || die "Cannot remove obsolete incoming copy ${TRANSFER[incoming]}"
  fi
  remove_operation_marker pending copy "$partition_date" || \
    die "Copy ${partition_date} is active, but its pending marker could not be removed"
  log "Pending copy ${partition_date} reconciled"
}

# Commit a verified replacement and clear all durable pending state.
finish_resumed_replacement() {
  local partition_date="${TRANSFER[date]}"

  write_operation_marker completed replace "$partition_date"
  inspect_transfer_directories
  [[ "${TRANSFER[destination_fs]}" == directory ]] || \
    die "Replacement ${partition_date} is active but its destination directory is missing"
  if [[ "${TRANSFER[quarantine_fs]}" == directory ]]; then
    remove_quarantined_partition || \
      die "Replacement ${partition_date} is active, but quarantine cleanup failed"
  fi
  if [[ "${TRANSFER[incoming_fs]}" == directory ]]; then
    remove_prepared_partition || \
      die "Replacement ${partition_date} is active, but incoming cleanup failed"
  fi
  remove_operation_marker pending replace "$partition_date" || \
    die "Replacement ${partition_date} is active, but its pending marker could not be removed"
  log "Pending replacement ${partition_date} reconciled"
}

# Resume a replacement from its pending marker and stable filesystem layout.
resume_replace_partition() {
  local partition_date="$1"
  local attach_status
  local completed_state
  local destination_state

  set_transfer_paths replace "$partition_date"
  completed_state="$(operation_marker_state completed replace "$partition_date")" || \
    die "Cannot read the completed replacement marker for ${partition_date}"
  destination_state="$(partition_state "$MIGRATION_NEW_URL" "$partition_date")" || \
    die "Cannot list destination partitions while resuming ${partition_date}"
  inspect_transfer_directories
  if [[ "$destination_state" == present && "${TRANSFER[destination_fs]}" != directory ]]; then
    die "Replacement ${partition_date} is active but its destination directory is missing"
  fi

  if [[ "$completed_state" == present ]]; then
    if [[ "$destination_state" != present && "${TRANSFER[destination_fs]}" == directory ]]; then
      if attach_destination_partition "$partition_date"; then
        destination_state=present
      else
        attach_status=$?
        (( attach_status == 1 )) && die "Completed replacement ${partition_date} remains inactive"
        die "Cannot verify completed replacement ${partition_date}"
      fi
    fi
    [[ "$destination_state" == present ]] || \
      die "Completed replacement ${partition_date} has no active destination directory"
    finish_resumed_replacement
    return
  fi

  if [[ "${TRANSFER[quarantine_fs]}" == directory ]]; then
    if [[ "${TRANSFER[destination_fs]}" == absent ]]; then
      restore_quarantined_partition || \
        die "Cannot restore quarantined partition ${partition_date}"
      if attach_destination_partition "$partition_date"; then
        if [[ "${TRANSFER[incoming_fs]}" == absent ]]; then
          remove_operation_marker pending replace "$partition_date" || \
            die "Original partition ${partition_date} was restored, but stale pending state remains"
        fi
        die "Original partition ${partition_date} was restored; rerun migration to retry its prepared replacement"
      fi
      die "Original partition ${partition_date} was restored but could not be attached"
    fi
    [[ "${TRANSFER[destination_fs]}" == directory ]] || \
      die "Replacement ${partition_date} has an unexpected destination object"
    if [[ "$destination_state" != present ]]; then
      activate_replacement_or_restore
    fi
    finish_resumed_replacement
    return
  fi

  [[ "${TRANSFER[incoming_fs]}" == directory ]] || \
    die "Pending replacement ${partition_date} has no prepared incoming directory"
  [[ "${TRANSFER[destination_fs]}" == directory ]] || \
    die "Pending replacement ${partition_date} has no original destination directory"
  if [[ "$destination_state" != present ]]; then
    if attach_destination_partition "$partition_date"; then
      destination_state=present
    else
      attach_status=$?
      (( attach_status == 1 )) && die "Original partition ${partition_date} could not be reattached before retry"
      die "Cannot verify original partition ${partition_date} before retry"
    fi
  fi
  swap_replacement_partition
  activate_replacement_or_restore
  finish_resumed_replacement
}

# Dispatch one durable pending operation discovered by the batch planner.
resume_partition_operation() {
  local operation="${1%%:*}"
  local partition_date="${1#*:}"

  case "$operation" in
    copy)
      resume_copy_partition "$partition_date"
      ;;
    replace)
      resume_replace_partition "$partition_date"
      ;;
    *)
      die "Unexpected pending operation: ${operation}"
      ;;
  esac
}

# Build a complete, non-mutating migration plan from the two active partition sets.
build_migration_plan() {
  local bridge_start_date="$1"
  local completed_names
  local destination_names
  local marker_name
  local operation
  local partition_date
  local pending_names
  local source_names
  local -A all_partitions=()
  local -A completed_copy=()
  local -A completed_replace=()
  local -A destination_partitions=()
  local -A pending_copy=()
  local -A pending_replace=()
  local -A source_partitions=()

  MIGRATION_RESUME_PLAN=()
  MIGRATION_COPY_PLAN=()
  MIGRATION_REPLACE_PLAN=()
  MIGRATION_COMPLETED_PLAN=()
  MIGRATION_BLOCKERS=()
  MIGRATION_BRIDGE_ACTION=""

  source_names="$(partition_list "$MIGRATION_OLD_URL" | partition_names)" || \
    die "Cannot list source partitions"
  destination_names="$(partition_list "$MIGRATION_NEW_URL" | partition_names)" || \
    die "Cannot list destination partitions"
  pending_names="$(list_operation_markers pending)" || \
    die "Cannot list pending partition operations"
  completed_names="$(list_operation_markers completed)" || \
    die "Cannot list completed partition operations"
  while IFS= read -r partition_date; do
    if [[ -n "$partition_date" ]]; then
      source_partitions["$partition_date"]=1
      all_partitions["$partition_date"]=1
    fi
  done <<< "$source_names"
  while IFS= read -r partition_date; do
    [[ -n "$partition_date" ]] && destination_partitions["$partition_date"]=1
  done <<< "$destination_names"
  while IFS= read -r marker_name; do
    [[ -n "$marker_name" ]] || continue
    if [[ "$marker_name" =~ ^(copy|replace)-([0-9]{8})\.marker$ ]]; then
      operation="${BASH_REMATCH[1]}"
      partition_date="${BASH_REMATCH[2]}"
      all_partitions["$partition_date"]=1
      if [[ "$operation" == copy ]]; then
        pending_copy["$partition_date"]=1
      else
        pending_replace["$partition_date"]=1
      fi
    else
      MIGRATION_BLOCKERS+=("Unexpected pending marker filename: ${marker_name}")
    fi
  done <<< "$pending_names"
  while IFS= read -r marker_name; do
    [[ -n "$marker_name" ]] || continue
    if [[ "$marker_name" =~ ^(copy|replace)-([0-9]{8})\.marker$ ]]; then
      operation="${BASH_REMATCH[1]}"
      partition_date="${BASH_REMATCH[2]}"
      if [[ "$operation" == copy ]]; then
        completed_copy["$partition_date"]=1
      else
        completed_replace["$partition_date"]=1
      fi
    else
      MIGRATION_BLOCKERS+=("Unexpected completed marker filename: ${marker_name}")
    fi
  done <<< "$completed_names"
  all_partitions["$bridge_start_date"]=1

  while IFS= read -r partition_date; do
    if [[ -n "${pending_copy[$partition_date]+present}" &&
      -n "${pending_replace[$partition_date]+present}" ]]; then
      MIGRATION_BLOCKERS+=("Partition ${partition_date} has both copy and replacement operations pending")
      if [[ "$partition_date" == "$bridge_start_date" ]]; then
        MIGRATION_BRIDGE_ACTION=blocked
      fi
      continue
    fi
    if [[ -n "${pending_copy[$partition_date]+present}" ||
      -n "${pending_replace[$partition_date]+present}" ]]; then
      if [[ "$partition_date" > "$bridge_start_date" ]]; then
        MIGRATION_BLOCKERS+=("Pending operation ${partition_date} is after the bridge date")
        continue
      fi
      if [[ -n "${pending_copy[$partition_date]+present}" ]]; then
        MIGRATION_RESUME_PLAN+=("copy:${partition_date}")
        operation=copy
      else
        MIGRATION_RESUME_PLAN+=("replace:${partition_date}")
        operation=replace
      fi
      if [[ "$partition_date" == "$bridge_start_date" ]]; then
        MIGRATION_BRIDGE_ACTION="resume-${operation}"
      fi
      continue
    fi

    if [[ "$partition_date" > "$bridge_start_date" ]]; then
      if [[ -n "${source_partitions[$partition_date]+present}" &&
        -z "${destination_partitions[$partition_date]+present}" ]]; then
        MIGRATION_BLOCKERS+=("Source-only partition ${partition_date} is after the bridge; investigate the dual-write gap")
      fi
      continue
    fi
    if [[ -n "${completed_copy[$partition_date]+present}" ||
      -n "${completed_replace[$partition_date]+present}" ]]; then
      if [[ -n "${destination_partitions[$partition_date]+present}" ]]; then
        MIGRATION_COMPLETED_PLAN+=("partition:${partition_date}")
        if [[ "$partition_date" == "$bridge_start_date" ]]; then
          MIGRATION_BRIDGE_ACTION=complete
        fi
      else
        MIGRATION_BLOCKERS+=("Partition ${partition_date} is marked complete but is not active on the destination")
        if [[ "$partition_date" == "$bridge_start_date" ]]; then
          MIGRATION_BRIDGE_ACTION=blocked
        fi
      fi
      continue
    fi
    if [[ -z "${source_partitions[$partition_date]+present}" ]]; then
      MIGRATION_BLOCKERS+=("Partition ${partition_date} is unavailable on the authoritative source")
      if [[ "$partition_date" == "$bridge_start_date" ]]; then
        MIGRATION_BRIDGE_ACTION=blocked
      fi
    elif [[ -n "${destination_partitions[$partition_date]+present}" ]]; then
      MIGRATION_REPLACE_PLAN+=("$partition_date")
      if [[ "$partition_date" == "$bridge_start_date" ]]; then
        MIGRATION_BRIDGE_ACTION=replace
      fi
    else
      MIGRATION_COPY_PLAN+=("$partition_date")
      if [[ "$partition_date" == "$bridge_start_date" ]]; then
        MIGRATION_BRIDGE_ACTION=copy
      fi
    fi
  done < <(printf '%s\n' "${!all_partitions[@]}" | sort)
}

# Print the current batch plan in execution order.
print_migration_plan() {
  local item

  log "Partition migration plan"
  if (( ${#MIGRATION_RESUME_PLAN[@]} > 0 )); then
    printf 'Resume pending operations:\n'
    printf '  %s\n' "${MIGRATION_RESUME_PLAN[@]}"
  else
    printf 'Resume pending operations: none\n'
  fi
  if (( ${#MIGRATION_COPY_PLAN[@]} > 0 )); then
    printf 'Copy from source, oldest first:\n'
    printf '  %s\n' "${MIGRATION_COPY_PLAN[@]}"
  else
    printf 'Copy from source: none\n'
  fi
  if (( ${#MIGRATION_REPLACE_PLAN[@]} > 0 )); then
    printf 'Replace from authoritative source:\n'
    printf '  %s\n' "${MIGRATION_REPLACE_PLAN[@]}"
  else
    printf 'Replace from authoritative source: none\n'
  fi
  printf 'Bridge action: %s\n' "$MIGRATION_BRIDGE_ACTION"
  if (( ${#MIGRATION_COMPLETED_PLAN[@]} > 0 )); then
    printf 'Already completed:\n'
    for item in "${MIGRATION_COMPLETED_PLAN[@]}"; do
      printf '  %s\n' "$item"
    done
  fi
  if (( ${#MIGRATION_BLOCKERS[@]} > 0 )); then
    printf 'Blockers:\n'
    for item in "${MIGRATION_BLOCKERS[@]}"; do
      printf '  %s\n' "$item"
    done
  fi
}

# Plan or execute every partition operation from one recorded bridge date.
migrate_partitions() {
  local bridge_start_date="${1:-}"
  local confirmed=false
  local partition_date
  local today

  (( $# == 1 || $# == 2 )) || \
    die "migrate-partitions requires BRIDGE_START_DATE and optional --yes"
  if (( $# == 2 )); then
    [[ "$2" == --yes ]] || die "Unexpected argument: $2"
    confirmed=true
  fi
  validate_partition_date "$bridge_start_date"
  today="$(date -u +%Y%m%d)"
  [[ "$bridge_start_date" < "$today" ]] || \
    die "Bridge partition ${bridge_start_date} is not closed; wait until after UTC midnight"
  validate_transfer_environment
  destination_mount_info >/dev/null
  helper_exec sh -c 'command -v tar >/dev/null' || \
    die "tar is unavailable in the migration helper"

  build_migration_plan "$bridge_start_date"
  print_migration_plan
  (( ${#MIGRATION_BLOCKERS[@]} == 0 )) || \
    die "Resolve the partition-plan blockers before migration"
  if [[ "$confirmed" != true ]]; then
    log "Plan only; rerun with --yes to execute it"
    return
  fi

  for partition_date in "${MIGRATION_RESUME_PLAN[@]}"; do
    resume_partition_operation "$partition_date"
  done
  for partition_date in "${MIGRATION_COPY_PLAN[@]}"; do
    copy_partition "$partition_date"
  done
  for partition_date in "${MIGRATION_REPLACE_PLAN[@]}"; do
    replace_partition "$partition_date"
  done

  build_migration_plan "$bridge_start_date"
  (( ${#MIGRATION_BLOCKERS[@]} == 0 && ${#MIGRATION_RESUME_PLAN[@]} == 0 && ${#MIGRATION_COPY_PLAN[@]} == 0 && ${#MIGRATION_REPLACE_PLAN[@]} == 0 )) || \
    die "Post-migration partition verification found unresolved work"
  [[ "$MIGRATION_BRIDGE_ACTION" == complete ]] || \
    die "Bridge partition ${bridge_start_date} is not marked complete"
  log "All planned partitions are active on the destination"
}

# Dispatch exactly one requested migration command.
main() {
  local command_name="${1:-help}"
  if (( $# > 0 )); then
    shift
  fi

  case "$command_name" in
    help|-h|--help)
      usage
      ;;
    preflight)
      (( $# == 0 )) || die "preflight does not accept arguments"
      validate_runtime_configuration
      preflight
      ;;
    status)
      (( $# == 0 )) || die "status does not accept arguments"
      validate_runtime_configuration
      status
      ;;
    partitions)
      (( $# == 0 )) || die "partitions does not accept arguments"
      validate_runtime_configuration
      partitions
      ;;
    migrate-partitions)
      validate_runtime_configuration
      migrate_partitions "$@"
      ;;
    *)
      usage >&2
      die "Unknown command: ${command_name}"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
