#!/bin/bash
# /opt/vibestack/modules/zfs.sh
# Module: ZFS Snapshot, Clone, Restore, Destroy, List
# Operates on this container's own ZFS dataset only.
# All actions require --uid verification (handled by vibestack-api.sh before this runs).

# --- 0. MANDATORY INCLUDES ---
source /opt/vibestack/includes/common.sh

# --- 1. ARGUMENTS ---
ZFS_ACTION=$1         # snapshot | clone | restore | destroy | list
SNAPSHOT_LABEL=$2     # human label e.g. "pre-update" (snapshot/destroy/restore/clone)
CLONE_TARGET=$3       # target container name for clone e.g. "wpo-abc123staging"

# --- 2. VALIDATION ---
[[ -z "$ZFS_ACTION" ]] && fatal_error 3000 "ZFS action missing in zfs.sh"

# Build the full dataset path for this container from vibestack.conf
DATASET="${ZFS_LXD_BASE}/${CONTAINER_NAME}"

# Verify the dataset actually exists before doing anything
if ! zfs list "$DATASET" >/dev/null 2>&1; then
    fatal_error 3001 "ZFS dataset not found: ${DATASET}"
fi

# Timestamp always appended to snapshot names for uniqueness
TIMESTAMP=$(date -u +"%Y%m%d-%H%M%S")

# --- 3. HELPERS ---

# List all snapshots for this container dataset, newest first
_list_snapshots() {
    zfs list -t snapshot -o name,creation,used -s creation -r "$DATASET" 2>/dev/null \
    | grep "^${DATASET}@" \
    | awk '{print $1, $2, $3, $4}' \
    | while read -r name date time used; do
        # Strip dataset prefix to return just the snapshot name
        snap_name="${name#${DATASET}@}"
        echo "{\"snapshot\":\"${snap_name}\",\"full_name\":\"${name}\",\"created\":\"${date} ${time}\",\"used\":\"${used}\"}"
    done \
    | jq -s '.'
}

# Resolve a label to a full snapshot name
# If label already contains the timestamp suffix, use as-is
# Otherwise find the most recent snapshot matching the label
_resolve_snapshot() {
    local label=$1
    # If it looks like a full snapshot name (contains timestamp pattern), use it directly
    if [[ "$label" =~ -[0-9]{8}-[0-9]{6}$ ]]; then
        echo "${DATASET}@${label}"
        return
    fi
    # Otherwise find the most recent snapshot with this label prefix
    local match
    match=$(zfs list -t snapshot -o name -s creation -r "$DATASET" 2>/dev/null \
        | grep "^${DATASET}@${label}-" \
        | tail -1)
    if [[ -z "$match" ]]; then
        fatal_error 3004 "No snapshot found matching label: ${label}"
    fi
    echo "$match"
}

# --- 4. ACTION ROUTER ---
case "$ZFS_ACTION" in

    # -------------------------------------------------------------------------
    "snapshot")
        [[ -z "$SNAPSHOT_LABEL" ]] && fatal_error 3002 "Snapshot label required for snapshot action"

        SNAPSHOT_NAME="${SNAPSHOT_LABEL}-${TIMESTAMP}"
        FULL_SNAPSHOT="${DATASET}@${SNAPSHOT_NAME}"

        zfs snapshot "$FULL_SNAPSHOT"
        if [ $? -ne 0 ]; then
            fatal_error 3003 "Failed to create ZFS snapshot: ${FULL_SNAPSHOT}"
        fi

        MODULE_RESULT=$(jq -n \
            --arg action "snapshot" \
            --arg container "$CONTAINER_NAME" \
            --arg dataset "$DATASET" \
            --arg snapshot "$SNAPSHOT_NAME" \
            --arg full_snapshot "$FULL_SNAPSHOT" \
            --arg created "$TIMESTAMP" \
            '{
                action: $action,
                container: $container,
                dataset: $dataset,
                snapshot: $snapshot,
                full_snapshot: $full_snapshot,
                created_at: $created
            }')
        ;;

    # -------------------------------------------------------------------------
    "restore")
        [[ -z "$SNAPSHOT_LABEL" ]] && fatal_error 3002 "Snapshot label required for restore action"

        FULL_SNAPSHOT=$(_resolve_snapshot "$SNAPSHOT_LABEL")
        SNAPSHOT_NAME="${FULL_SNAPSHOT#${DATASET}@}"

        # Auto-snapshot before restore so the current state is never lost
        PRE_RESTORE_SNAP="${DATASET}@pre-restore-${TIMESTAMP}"
        zfs snapshot "$PRE_RESTORE_SNAP"

        # Roll back — -r destroys any snapshots newer than the target
        zfs rollback -r "$FULL_SNAPSHOT"
        if [ $? -ne 0 ]; then
            fatal_error 3005 "Failed to restore ZFS snapshot: ${FULL_SNAPSHOT}"
        fi

        MODULE_RESULT=$(jq -n \
            --arg action "restore" \
            --arg container "$CONTAINER_NAME" \
            --arg dataset "$DATASET" \
            --arg restored_snapshot "$SNAPSHOT_NAME" \
            --arg safety_snapshot "$PRE_RESTORE_SNAP" \
            --arg restored_at "$TIMESTAMP" \
            '{
                action: $action,
                container: $container,
                dataset: $dataset,
                restored_snapshot: $restored_snapshot,
                safety_snapshot: $safety_snapshot,
                restored_at: $restored_at
            }')
        ;;

    # -------------------------------------------------------------------------
    "clone")
        [[ -z "$SNAPSHOT_LABEL" ]] && fatal_error 3002 "Snapshot label required for clone action"
        [[ -z "$CLONE_TARGET" ]]   && fatal_error 3006 "Clone target container name required (--clone-target)"

        FULL_SNAPSHOT=$(_resolve_snapshot "$SNAPSHOT_LABEL")
        SNAPSHOT_NAME="${FULL_SNAPSHOT#${DATASET}@}"
        CLONE_DATASET="${ZFS_LXD_BASE}/${CLONE_TARGET}"

        # Ensure clone target doesn't already exist
        if zfs list "$CLONE_DATASET" >/dev/null 2>&1; then
            fatal_error 3007 "Clone target dataset already exists: ${CLONE_DATASET}"
        fi

        zfs clone "$FULL_SNAPSHOT" "$CLONE_DATASET"
        if [ $? -ne 0 ]; then
            fatal_error 3008 "Failed to clone ZFS snapshot: ${FULL_SNAPSHOT} -> ${CLONE_DATASET}"
        fi

        MODULE_RESULT=$(jq -n \
            --arg action "clone" \
            --arg source_container "$CONTAINER_NAME" \
            --arg source_snapshot "$SNAPSHOT_NAME" \
            --arg clone_container "$CLONE_TARGET" \
            --arg clone_dataset "$CLONE_DATASET" \
            --arg cloned_at "$TIMESTAMP" \
            '{
                action: $action,
                source_container: $source_container,
                source_snapshot: $source_snapshot,
                clone_container: $clone_container,
                clone_dataset: $clone_dataset,
                cloned_at: $cloned_at
            }')
        ;;

    # -------------------------------------------------------------------------
    "destroy")
        [[ -z "$SNAPSHOT_LABEL" ]] && fatal_error 3002 "Snapshot label required for destroy action"

        FULL_SNAPSHOT=$(_resolve_snapshot "$SNAPSHOT_LABEL")
        SNAPSHOT_NAME="${FULL_SNAPSHOT#${DATASET}@}"

        zfs destroy "$FULL_SNAPSHOT"
        if [ $? -ne 0 ]; then
            fatal_error 3009 "Failed to destroy ZFS snapshot: ${FULL_SNAPSHOT}"
        fi

        MODULE_RESULT=$(jq -n \
            --arg action "destroy" \
            --arg container "$CONTAINER_NAME" \
            --arg snapshot "$SNAPSHOT_NAME" \
            --arg full_snapshot "$FULL_SNAPSHOT" \
            --arg destroyed_at "$TIMESTAMP" \
            '{
                action: $action,
                container: $container,
                snapshot: $snapshot,
                full_snapshot: $full_snapshot,
                destroyed_at: $destroyed_at
            }')
        ;;

    # -------------------------------------------------------------------------
    "list")
        SNAPSHOTS=$(_list_snapshots)
        SNAPSHOT_COUNT=$(echo "$SNAPSHOTS" | jq 'length')

        MODULE_RESULT=$(jq -n \
            --arg container "$CONTAINER_NAME" \
            --arg dataset "$DATASET" \
            --argjson count "$SNAPSHOT_COUNT" \
            --argjson snapshots "$SNAPSHOTS" \
            '{
                container: $container,
                dataset: $dataset,
                snapshot_count: $count,
                snapshots: $snapshots
            }')
        ;;

    *)
        fatal_error 3010 "Unknown ZFS action: ${ZFS_ACTION}. Valid: snapshot, restore, clone, destroy, list"
        ;;
esac