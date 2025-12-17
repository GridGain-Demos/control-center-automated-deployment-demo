#!/usr/bin/env bash
#
# Copyright (C) GridGain Systems. All Rights Reserved.
#  _________        _____ __________________        _____
#  __  ____/___________(_)______  /__  ____/______ ____(_)_______
#  _  / __  __  ___/__  / _  __  / _  / __  _  __ `/__  / __  __ \
#  / /_/ /  _  /    _  /  / /_/ /  / /_/ /  / /_/ / _  /  _  / / /
#  \____/   /_/     /_/   \_,__/   \____/   \__,_/  /_/   /_/ /_/
#
# Control Center Automated Deployment Script
#
# This script demonstrates GitOps/Infrastructure-as-Code pattern for
# fully automated Control Center deployment using REST API.
#
# API Reference: See openapi/rest-api.yaml for OpenAPI specification
#
# Usage:
#   ./deploy.sh [options]
#
# Options:
#   --dry-run       Preview changes without applying them
#   --verbose       Enable verbose/debug output
#   --skip-health   Skip health check and proceed immediately
#   --help          Show this help message

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Required environment variables
: "${CC_BASE_URL:?CC_BASE_URL is required}"
: "${CC_ADMIN_EMAIL:?CC_ADMIN_EMAIL is required}"
: "${CC_ADMIN_PASSWORD:?CC_ADMIN_PASSWORD is required}"

# Optional environment variables with defaults
CC_HEALTH_TIMEOUT="${CC_HEALTH_TIMEOUT:-300}"
CC_CONNECTOR_TIMEOUT="${CC_CONNECTOR_TIMEOUT:-120}"
CC_CLUSTER_INIT_TIMEOUT="${CC_CLUSTER_INIT_TIMEOUT:-60}"
CC_DRY_RUN="${CC_DRY_RUN:-false}"

# Global state
JWT_TOKEN=""
SYNC_COMPONENTS=""  # Comma-separated list of components to sync (empty = all)

# =============================================================================
# Colors & Logging
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_section() { echo -e "\n${BOLD}[INFO] === $* ===${NC}"; }
log_header()  { echo -e "\n========================================\n  $*\n========================================"; }

# =============================================================================
# Counters for Summary
# =============================================================================
USERS_CREATED=0
USERS_UPDATED=0
USERS_FAILED=0
TEAMS_CREATED=0
TEAMS_UPDATED=0
TEAMS_FAILED=0
CLUSTERS_INITIALIZED=0
CLUSTERS_INIT_SKIPPED=0
CLUSTERS_INIT_FAILED=0
CLUSTERS_ATTACHED=0
CLUSTERS_SKIPPED=0
CLUSTERS_FAILED=0
NOTIFICATIONS_CREATED=0
NOTIFICATIONS_UPDATED=0
NOTIFICATIONS_SKIPPED=0
NOTIFICATIONS_FAILED=0
ALERTS_CREATED=0
ALERTS_UPDATED=0
ALERTS_FAILED=0
DRIFT_WARNINGS=0

# =============================================================================
# Utility Functions
# =============================================================================

is_dry_run() { [[ "$CC_DRY_RUN" == "true" ]]; }

# Check if a component should be synced
# Returns 0 (true) if SYNC_COMPONENTS is empty (sync all) or contains the component
should_sync() {
    local component="$1"
    [[ -z "$SYNC_COMPONENTS" ]] && return 0
    [[ ",$SYNC_COMPONENTS," == *",$component,"* ]]
}

# Print warning about dependency when running partial sync
warn_dependency() {
    local component="$1"
    local depends_on="$2"
    if [[ -n "$SYNC_COMPONENTS" ]] && ! should_sync "$depends_on"; then
        log_warn "$component depends on $depends_on - ensure it was synced previously"
    fi
}


# =============================================================================
# Authentication
# POST /rest/v1/authentication/login
# Request: { username, password }
# Response: JWT token as plain text
# =============================================================================
cc_login() {
    log_info "Authenticating as: ${CC_ADMIN_EMAIL}"

    if is_dry_run; then
        log_info "[DRY-RUN] Would authenticate"
        JWT_TOKEN="dry-run-token"
        return 0
    fi

    local response http_code body
    response=$(curl -s -w "\n%{http_code}" \
        -X POST "${CC_BASE_URL}/rest/v1/authentication/login" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"${CC_ADMIN_EMAIL}\",\"password\":\"${CC_ADMIN_PASSWORD}\"}" \
        2>/dev/null)

    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" == "200" ]]; then
        JWT_TOKEN="$body"
        log_success "Authentication successful"
        return 0
    else
        log_error "Authentication failed (HTTP $http_code)"
        return 1
    fi
}

# =============================================================================
# Health Checks
# GET /actuator/health
# =============================================================================
wait_for_cc() {
    local timeout="$CC_HEALTH_TIMEOUT"
    local interval=5
    local elapsed=0

    log_info "Waiting for Control Center to be healthy..."

    while [[ $elapsed -lt $timeout ]]; do
        local response
        response=$(curl -s "${CC_BASE_URL}/actuator/health" 2>/dev/null || echo '{}')
        local status
        status=$(echo "$response" | jq -r '.status // "UNKNOWN"' 2>/dev/null)

        if [[ "$status" == "UP" ]]; then
            log_success "Control Center is healthy"
            return 0
        fi

        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    log_error "Control Center did not become healthy within ${timeout}s"
    return 1
}

# GET /rest/v1/connectors
# Response: Array of connector names
wait_for_connector() {
    local connector_name="$1"
    local timeout="$CC_CONNECTOR_TIMEOUT"
    local interval=5
    local elapsed=0

    log_info "Waiting for connector '$connector_name' to be available..."

    if is_dry_run; then
        log_info "[DRY-RUN] Would wait for connector: $connector_name"
        return 0
    fi

    while [[ $elapsed -lt $timeout ]]; do
        local response
        response=$(curl -s \
            -X GET "${CC_BASE_URL}/rest/v1/connectors" \
            -H "Authorization: Bearer ${JWT_TOKEN}" \
            2>/dev/null)

        if echo "$response" | jq -e ".[] | select(. == \"$connector_name\")" &>/dev/null; then
            log_success "Connector '$connector_name' is available"
            return 0
        fi

        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    log_error "Connector '$connector_name' did not become available within ${timeout}s"
    return 1
}

# =============================================================================
# Ignite Cluster Initialization
# =============================================================================

# Wait for Ignite cluster REST API to be available
# GET /management/v1/cluster/state
wait_for_ignite_rest() {
    local init_url="$1"
    local timeout="$CC_CLUSTER_INIT_TIMEOUT"
    local interval=5
    local elapsed=0

    log_info "Waiting for Ignite REST API at '$init_url'..."

    while [[ $elapsed -lt $timeout ]]; do
        local response
        response=$(curl -s -o /dev/null -w "%{http_code}" \
            "${init_url}/management/v1/cluster/state" \
            2>/dev/null)

        if [[ "$response" == "200" || "$response" == "409" ]]; then
            log_success "Ignite REST API is available at '$init_url'"
            return 0
        fi

        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    log_error "Ignite REST API at '$init_url' did not become available within ${timeout}s"
    return 1
}

# Get Ignite cluster initialization state
# GET /management/v1/cluster/state
# Returns: JSON with clusterState, cmgNodes, msNodes, clusterTag (name)
get_cluster_state() {
    local init_url="$1"

    curl -s \
        -X GET "${init_url}/management/v1/cluster/state" \
        2>/dev/null
}

# Wait for Ignite cluster to be initialized
# GET /management/v1/cluster/state returns 200 when cluster is ready
wait_for_cluster_ready() {
    local init_url="$1"
    local timeout="${2:-30}"
    local interval=2
    local elapsed=0

    while [[ $elapsed -lt $timeout ]]; do
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" "${init_url}/management/v1/cluster/state" 2>/dev/null)

        if [[ "$http_code" == "200" ]]; then
            return 0
        fi

        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    return 1
}

# Initialize an Ignite cluster
# POST /management/v1/cluster/init
# Request: { metaStorageNodes, cmgNodes, clusterName, clusterConfiguration }
# Response: 200 (success), 400 (already initialized or bad config), 500 (internal error)
init_ignite_cluster() {
    local init_url="$1"
    local cluster_name="$2"
    local meta_storage_node="$3"

    local request_body
    request_body=$(cat <<EOF
{
    "metaStorageNodes": ["${meta_storage_node}"],
    "cmgNodes": ["${meta_storage_node}"],
    "clusterName": "${cluster_name}",
    "clusterConfiguration": ""
}
EOF
)

    local response http_code body
    response=$(curl -s -w "\n%{http_code}" \
        -X POST "${init_url}/management/v1/cluster/init" \
        -H "Content-Type: application/json" \
        -d "$request_body" \
        2>/dev/null)

    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    case "$http_code" in
        200)
            log_success "Initialized Ignite cluster: $cluster_name"
            ((++CLUSTERS_INITIALIZED))
            # Wait for cluster to be ready
            wait_for_cluster_ready "$init_url" || true
            return 0
            ;;
        400)
            # Check if already initialized with correct name
            local state_response current_name
            state_response=$(get_cluster_state "$init_url")
            current_name=$(echo "$state_response" | jq -r '.clusterTag // .name // ""' 2>/dev/null)

            if [[ "$current_name" == "$cluster_name" ]]; then
                log_info "Ignite cluster already initialized: $cluster_name"
                ((++CLUSTERS_INIT_SKIPPED))
                return 0
            else
                log_error "Ignite cluster initialized with different name: '$current_name' (expected '$cluster_name')"
                ((++CLUSTERS_INIT_FAILED))
                return 1
            fi
            ;;
        *)
            log_error "Failed to initialize Ignite cluster: $cluster_name (HTTP $http_code)"
            ((++CLUSTERS_INIT_FAILED))
            return 2
            ;;
    esac
}

# Synchronize Ignite cluster initialization
sync_cluster_initialization() {
    local clusters_file="${SCRIPT_DIR}/../state/clusters.json"

    log_section "Ignite Cluster Initialization"

    if [[ ! -f "$clusters_file" ]]; then
        log_warn "Clusters state file not found: $clusters_file"
        return 0
    fi

    local cluster_count
    cluster_count=$(jq '.clusters | length' "$clusters_file")
    log_info "Processing $cluster_count clusters for initialization..."

    local index=0
    while [[ $index -lt $cluster_count ]]; do
        local cluster_name init_url meta_storage_node
        cluster_name=$(jq -r ".clusters[$index].clusterName // .clusters[$index].tag" "$clusters_file")
        init_url=$(jq -r ".clusters[$index].initUrl // .clusters[$index].restUrl" "$clusters_file")
        meta_storage_node=$(jq -r ".clusters[$index].metaStorageNode // \"\"" "$clusters_file")

        if [[ -z "$meta_storage_node" || "$meta_storage_node" == "null" ]]; then
            log_warn "No metaStorageNode specified for cluster: $cluster_name, skipping initialization"
            ((++index))
            continue
        fi

        if is_dry_run; then
            log_info "[DRY-RUN] Would initialize Ignite cluster: $cluster_name"
        else
            # Wait for Ignite REST API
            if wait_for_ignite_rest "$init_url"; then
                init_ignite_cluster "$init_url" "$cluster_name" "$meta_storage_node" || true
            else
                log_error "Cannot initialize cluster '$cluster_name': REST API not available"
                ((++CLUSTERS_INIT_FAILED))
            fi
        fi

        ((++index))
    done
}

# =============================================================================
# User Management
# =============================================================================

# GET /rest/v1/users
# Response: Array of UserResponse objects
list_users() {
    curl -s \
        -X GET "${CC_BASE_URL}/rest/v1/users" \
        -H "Authorization: Bearer ${JWT_TOKEN}" \
        2>/dev/null
}

# POST /rest/v1/users
# Request: { username, password, firstName, lastName, company, country }
# Note: admin field stripped on create (API restriction), applied via PATCH
# Response: 201 Created | 409 Conflict
create_user() {
    local user_json="$1"
    local username
    username=$(echo "$user_json" | jq -r '.username')

    # Strip admin field - can only be set via PATCH after user creation
    local create_json
    create_json=$(echo "$user_json" | jq 'del(.admin)')

    local response http_code body
    response=$(curl -s -w "\n%{http_code}" \
        -X POST "${CC_BASE_URL}/rest/v1/users" \
        -H "Authorization: Bearer ${JWT_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$create_json" \
        2>/dev/null)

    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    case "$http_code" in
        200|201)
            log_success "Created user: $username"
            ((++USERS_CREATED))
            return 0
            ;;
        409)
            return 1  # Signal to update
            ;;
        *)
            log_error "Failed to create user: $username (HTTP $http_code)"
            ((++USERS_FAILED))
            return 2
            ;;
    esac
}

# PATCH /rest/v1/users/{username}
# Request: { password, firstName, lastName, company, country, admin, locked }
# Response: 204 No Content
update_user() {
    local username="$1"
    local update_json="$2"

    local response http_code body
    response=$(curl -s -w "\n%{http_code}" \
        -X PATCH "${CC_BASE_URL}/rest/v1/users/${username}" \
        -H "Authorization: Bearer ${JWT_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$update_json" \
        2>/dev/null)

    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" == "204" || "$http_code" == "200" ]]; then
        log_success "Updated user: $username"
        ((++USERS_UPDATED))
        return 0
    else
        log_error "Failed to update user: $username (HTTP $http_code)"
        ((++USERS_FAILED))
        return 1
    fi
}

sync_users() {
    local users_file="${SCRIPT_DIR}/../state/users.json"

    log_section "User Synchronization"

    if [[ ! -f "$users_file" ]]; then
        log_warn "Users state file not found: $users_file"
        return 0
    fi

    local user_count
    user_count=$(jq '.users | length' "$users_file")
    log_info "Processing $user_count users..."

    local index=0
    while [[ $index -lt $user_count ]]; do
        local user_json
        user_json=$(jq -c ".users[$index]" "$users_file")
        local username
        username=$(echo "$user_json" | jq -r '.username')

        if is_dry_run; then
            log_info "[DRY-RUN] Would sync user: $username"
        else
            local create_result=0
            create_user "$user_json" || create_result=$?
            if [[ $create_result -eq 0 ]]; then
                # User created - apply admin flag if set (can't be set on POST)
                local is_admin
                is_admin=$(echo "$user_json" | jq -r '.admin // false')
                if [[ "$is_admin" == "true" ]]; then
                    local admin_json='{"admin": true}'
                    update_user "$username" "$admin_json" || true
                fi
            elif [[ $create_result -eq 1 ]]; then
                # User exists, update instead
                local update_json
                update_json=$(echo "$user_json" | jq 'del(.username)')
                update_user "$username" "$update_json" || true
            fi
        fi

        ((++index))
    done

    # Detect drift
    if ! is_dry_run; then
        detect_user_drift "$users_file"
    fi
}

detect_user_drift() {
    local users_file="$1"

    local managed_users actual_users

    managed_users=$(jq -r '.users[].username' "$users_file" 2>/dev/null | sort)
    actual_users=$(list_users | jq -r '.[].username' 2>/dev/null | sort)

    while IFS= read -r user; do
        [[ -z "$user" ]] && continue
        [[ "$user" == "$CC_ADMIN_EMAIL" ]] && continue

        if ! echo "$managed_users" | grep -q "^${user}$"; then
            log_warn "DRIFT: User '$user' exists but is not managed"
            ((++DRIFT_WARNINGS))
        fi
    done <<< "$actual_users"
}

# =============================================================================
# Team Management
# =============================================================================

# GET /rest/v1/teams
# Response: Array of TeamResponse objects
list_teams() {
    curl -s \
        -X GET "${CC_BASE_URL}/rest/v1/teams" \
        -H "Authorization: Bearer ${JWT_TOKEN}" \
        2>/dev/null
}

# POST /rest/v1/teams
# Request: { name, owner? }
# Response: 201 Created | 409 Conflict
create_team() {
    local team_name="$1"

    local response http_code body
    response=$(curl -s -w "\n%{http_code}" \
        -X POST "${CC_BASE_URL}/rest/v1/teams" \
        -H "Authorization: Bearer ${JWT_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"${team_name}\"}" \
        2>/dev/null)

    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    case "$http_code" in
        200|201)
            log_success "Created team: $team_name"
            ((++TEAMS_CREATED))
            return 0
            ;;
        409)
            return 1
            ;;
        *)
            log_error "Failed to create team: $team_name (HTTP $http_code)"
            ((++TEAMS_FAILED))
            return 2
            ;;
    esac
}

# GET /rest/v1/teams/{name}/members
# Response: Array of TeamMemberResponse objects
get_team_members() {
    local team_name="$1"

    curl -s \
        -X GET "${CC_BASE_URL}/rest/v1/teams/${team_name}/members" \
        -H "Authorization: Bearer ${JWT_TOKEN}" \
        2>/dev/null
}

# POST /rest/v1/teams/{name}/members
# Request: Array of usernames
# Response: 200 OK
add_team_members() {
    local team_name="$1"
    local members_json="$2"

    local response http_code body
    response=$(curl -s -w "\n%{http_code}" \
        -X POST "${CC_BASE_URL}/rest/v1/teams/${team_name}/members" \
        -H "Authorization: Bearer ${JWT_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$members_json" \
        2>/dev/null)

    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" == "200" || "$http_code" == "201" ]]; then
        return 0
    else
        return 1
    fi
}

# DELETE /rest/v1/teams/{name}/members
# Request: Array of usernames
# Response: 204 No Content
delete_team_members() {
    local team_name="$1"
    local members_json="$2"

    local response http_code body
    response=$(curl -s -w "\n%{http_code}" \
        -X DELETE "${CC_BASE_URL}/rest/v1/teams/${team_name}/members" \
        -H "Authorization: Bearer ${JWT_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$members_json" \
        2>/dev/null)

    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" == "204" || "$http_code" == "200" ]]; then
        return 0
    else
        return 1
    fi
}

# Sync team members - add missing, remove extra
sync_team_members() {
    local team_name="$1"
    local desired_members_json="$2"

    # Get current members
    local current_members_json
    current_members_json=$(get_team_members "$team_name")

    if ! echo "$current_members_json" | jq empty 2>/dev/null; then
        return 1
    fi

    # Extract usernames from current members (API returns objects with username field)
    local current_members desired_members
    current_members=$(echo "$current_members_json" | jq -r '.[].username' 2>/dev/null | sort)
    desired_members=$(echo "$desired_members_json" | jq -r '.[]' 2>/dev/null | sort)

    # Find members to add (in desired but not in current)
    local to_add=""
    while IFS= read -r member; do
        [[ -z "$member" ]] && continue
        if ! echo "$current_members" | grep -q "^${member}$"; then
            to_add="${to_add}${member}\n"
        fi
    done <<< "$desired_members"

    # Find members to remove (in current but not in desired)
    # Skip the admin user as they may be the owner and can't be removed
    local to_remove=""
    while IFS= read -r member; do
        [[ -z "$member" ]] && continue
        [[ "$member" == "$CC_ADMIN_EMAIL" ]] && continue  # Skip admin/owner
        if ! echo "$desired_members" | grep -q "^${member}$"; then
            to_remove="${to_remove}${member}\n"
        fi
    done <<< "$current_members"

    local changes_made=false

    # Add missing members
    if [[ -n "$to_add" ]]; then
        local add_json
        add_json=$(echo -e "$to_add" | grep -v '^$' | jq -R . | jq -s .)
        if [[ "$add_json" != "[]" ]]; then
            if add_team_members "$team_name" "$add_json"; then
                changes_made=true
            fi
        fi
    fi

    # Remove extra members
    if [[ -n "$to_remove" ]]; then
        local remove_json
        remove_json=$(echo -e "$to_remove" | grep -v '^$' | jq -R . | jq -s .)
        if [[ "$remove_json" != "[]" ]]; then
            if delete_team_members "$team_name" "$remove_json"; then
                changes_made=true
            fi
        fi
    fi

    # Report changes
    if [[ "$changes_made" == "true" ]]; then
        log_success "Updated team members: $team_name"
        ((++TEAMS_UPDATED))
    fi

    return 0
}

sync_teams() {
    local teams_file="${SCRIPT_DIR}/../state/teams.json"

    log_section "Team Synchronization"

    if [[ ! -f "$teams_file" ]]; then
        log_warn "Teams state file not found: $teams_file"
        return 0
    fi

    local team_count
    team_count=$(jq '.teams | length' "$teams_file")
    log_info "Processing $team_count teams..."

    local index=0
    while [[ $index -lt $team_count ]]; do
        local team_name members_json
        team_name=$(jq -r ".teams[$index].name" "$teams_file")
        members_json=$(jq -c ".teams[$index].members // []" "$teams_file")

        if is_dry_run; then
            log_info "[DRY-RUN] Would sync team: $team_name"
        else
            create_team "$team_name" || true

            # Sync members (add missing, remove extra)
            sync_team_members "$team_name" "$members_json" || true
        fi

        ((++index))
    done

    # Detect drift
    if ! is_dry_run; then
        detect_team_drift "$teams_file"
    fi
}

detect_team_drift() {
    local teams_file="$1"

    local managed_teams actual_teams

    managed_teams=$(jq -r '.teams[].name' "$teams_file" 2>/dev/null | sort)
    actual_teams=$(list_teams | jq -r '.[].name' 2>/dev/null | sort)

    while IFS= read -r team; do
        [[ -z "$team" ]] && continue

        if ! echo "$managed_teams" | grep -q "^${team}$"; then
            log_warn "DRIFT: Team '$team' exists but is not managed"
            ((++DRIFT_WARNINGS))
        fi
    done <<< "$actual_teams"
}

# =============================================================================
# Cluster Management
# =============================================================================

# GET /rest/v1/clusters
# Response: Array of ClusterResponse objects
list_clusters() {
    curl -s \
        -X GET "${CC_BASE_URL}/rest/v1/clusters" \
        -H "Authorization: Bearer ${JWT_TOKEN}" \
        2>/dev/null
}

# POST /rest/v1/clusters
# Request: { restUrl, connectorName, username?, password?, owner?, thinClient? }
# Response: ClusterResponse | 409 Conflict
attach_cluster() {
    local cluster_json="$1"
    local tag
    tag=$(echo "$cluster_json" | jq -r '.tag // "unknown"')

    local response http_code body
    response=$(curl -s -w "\n%{http_code}" \
        -X POST "${CC_BASE_URL}/rest/v1/clusters" \
        -H "Authorization: Bearer ${JWT_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$cluster_json" \
        2>/dev/null)

    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    case "$http_code" in
        200|201)
            log_success "Attached cluster: $tag"
            ((++CLUSTERS_ATTACHED))
            echo "$body"
            return 0
            ;;
        409)
            log_info "Cluster already attached: $tag"
            ((++CLUSTERS_SKIPPED))
            return 1
            ;;
        *)
            log_error "Failed to attach cluster: $tag (HTTP $http_code)"
            ((++CLUSTERS_FAILED))
            return 2
            ;;
    esac
}

# POST /rest/v1/clusters/{connectionId}/actions/share
# Request: Array of team names or usernames
# Response: 201 Created
share_cluster() {
    local connection_id="$1"
    local share_with_json="$2"

    local response http_code body
    response=$(curl -s -w "\n%{http_code}" --max-time 30 \
        -X POST "${CC_BASE_URL}/rest/v1/clusters/${connection_id}/actions/share" \
        -H "Authorization: Bearer ${JWT_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$share_with_json" \
        2>/dev/null)

    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" == "200" || "$http_code" == "201" ]]; then
        log_success "Shared cluster with teams/users"
        return 0
    else
        log_warn "Failed to share cluster (HTTP $http_code) - may already be shared"
        return 0  # Don't fail on share errors
    fi
}

get_cluster_id_by_tag() {
    local tag="$1"
    local clusters_json
    clusters_json=$(list_clusters)

    if ! echo "$clusters_json" | jq empty 2>/dev/null; then
        return 1
    fi

    echo "$clusters_json" | jq -r ".[] | select(.tag == \"$tag\") | .id" 2>/dev/null | head -n1
}

sync_clusters() {
    local clusters_file="${SCRIPT_DIR}/../state/clusters.json"

    log_section "Cluster Attachment"

    if [[ ! -f "$clusters_file" ]]; then
        log_warn "Clusters state file not found: $clusters_file"
        return 0
    fi

    # Wait for connector if any cluster uses one
    local connector_name
    connector_name=$(jq -r '[.clusters[].connectorName // empty] | first // empty' "$clusters_file")
    if [[ -n "$connector_name" ]]; then
        wait_for_connector "$connector_name" || return 1
    fi

    local cluster_count
    cluster_count=$(jq '.clusters | length' "$clusters_file")
    log_info "Processing $cluster_count clusters..."

    local index=0
    while [[ $index -lt $cluster_count ]]; do
        local tag rest_url connector share_with_json cluster_json
        tag=$(jq -r ".clusters[$index].tag" "$clusters_file")
        rest_url=$(jq -r ".clusters[$index].restUrl" "$clusters_file")
        connector=$(jq -r ".clusters[$index].connectorName // empty" "$clusters_file")
        share_with_json=$(jq -c ".clusters[$index].shareWith // []" "$clusters_file")

        # Build cluster JSON - include connectorName only if specified
        if [[ -n "$connector" ]]; then
            cluster_json=$(jq -n --arg url "$rest_url" --arg conn "$connector" '{restUrl: $url, connectorName: $conn}')
        else
            cluster_json=$(jq -n --arg url "$rest_url" '{restUrl: $url}')
        fi

        if is_dry_run; then
            log_info "[DRY-RUN] Would attach cluster: $tag"
        else
            local connection_id=""

            # Try to attach cluster
            local attach_response attach_code attach_body
            attach_response=$(curl -s -w "\n%{http_code}" --max-time 30 \
                -X POST "${CC_BASE_URL}/rest/v1/clusters" \
                -H "Authorization: Bearer ${JWT_TOKEN}" \
                -H "Content-Type: application/json" \
                -d "$cluster_json" \
                2>/dev/null)

            attach_code=$(echo "$attach_response" | tail -n1)
            attach_body=$(echo "$attach_response" | sed '$d')

            case "$attach_code" in
                200|201)
                    log_success "Attached cluster: $tag"
                    ((++CLUSTERS_ATTACHED))
                    if echo "$attach_body" | jq empty 2>/dev/null; then
                        connection_id=$(echo "$attach_body" | jq -r '.id // empty')
                    fi
                    ;;
                409)
                    log_info "Cluster already attached: $tag"
                    ((++CLUSTERS_SKIPPED))
                    connection_id=$(get_cluster_id_by_tag "$tag") || true
                    ;;
                *)
                    log_error "Failed to attach cluster: $tag (HTTP $attach_code)"
                    ((++CLUSTERS_FAILED))
                    ;;
            esac

            # Share with teams/users
            if [[ -n "$connection_id" && "$share_with_json" != "[]" ]]; then
                share_cluster "$connection_id" "$share_with_json" || true
            elif [[ -z "$connection_id" ]]; then
                log_warn "Could not get connection ID for cluster: $tag"
            fi
        fi

        ((++index))
    done

    # Detect drift
    if ! is_dry_run; then
        detect_cluster_drift "$clusters_file"
    fi
}

detect_cluster_drift() {
    local clusters_file="$1"

    local managed_tags actual_tags

    managed_tags=$(jq -r '.clusters[].tag' "$clusters_file" 2>/dev/null | sort)
    actual_tags=$(list_clusters | jq -r '.[].tag' 2>/dev/null | sort)

    while IFS= read -r tag; do
        [[ -z "$tag" ]] && continue

        if ! echo "$managed_tags" | grep -q "^${tag}$"; then
            log_warn "DRIFT: Cluster '$tag' exists but is not managed"
            ((++DRIFT_WARNINGS))
        fi
    done <<< "$actual_tags"
}

# =============================================================================
# Notification Channels
# =============================================================================

# POST /rest/v1/clusters/{connectionId}/notifications
# Request: { tag, type, emails? (for EMAIL), url? (for WEBHOOK), phoneNumbers? (for SMS) }
# Response: 200 OK | 409 Conflict
create_notification_channel() {
    local connection_id="$1"
    local channel_json="$2"
    local tag
    tag=$(echo "$channel_json" | jq -r '.tag')

    local response http_code body
    response=$(curl -s -w "\n%{http_code}" \
        -X POST "${CC_BASE_URL}/rest/v1/clusters/${connection_id}/notifications" \
        -H "Authorization: Bearer ${JWT_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$channel_json" \
        2>/dev/null)

    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    case "$http_code" in
        200|201)
            log_success "Created notification channel: $tag"
            ((++NOTIFICATIONS_CREATED))
            return 0
            ;;
        409)
            log_info "Notification channel already exists: $tag"
            ((++NOTIFICATIONS_SKIPPED))
            return 1
            ;;
        *)
            log_error "Failed to create notification channel: $tag (HTTP $http_code)"
            ((++NOTIFICATIONS_FAILED))
            return 2
            ;;
    esac
}

# PATCH /rest/v1/clusters/{connectionId}/notifications/{tag}
# Request: { type, emails? (for EMAIL), url? (for WEBHOOK), phoneNumbers? (for SMS) }
# Response: 204 No Content
update_notification_channel() {
    local connection_id="$1"
    local tag="$2"
    local update_json="$3"

    local response http_code body
    response=$(curl -s -w "\n%{http_code}" \
        -X PATCH "${CC_BASE_URL}/rest/v1/clusters/${connection_id}/notifications/${tag}" \
        -H "Authorization: Bearer ${JWT_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$update_json" \
        2>/dev/null)

    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" == "204" || "$http_code" == "200" ]]; then
        log_success "Updated notification channel: $tag"
        ((++NOTIFICATIONS_UPDATED))
        return 0
    else
        log_error "Failed to update notification channel: $tag (HTTP $http_code)"
        ((++NOTIFICATIONS_FAILED))
        return 1
    fi
}

sync_notification_channels() {
    local notifications_file="${SCRIPT_DIR}/../state/notification-channels.json"

    log_section "Notification Channels"

    if [[ ! -f "$notifications_file" ]]; then
        log_warn "Notification channels state file not found: $notifications_file"
        return 0
    fi

    local notification_count
    notification_count=$(jq '.notifications | length' "$notifications_file")
    log_info "Processing notifications for $notification_count clusters..."

    local index=0
    while [[ $index -lt $notification_count ]]; do
        local cluster_tag connection_id channels_count
        cluster_tag=$(jq -r ".notifications[$index].clusterTag" "$notifications_file")
        connection_id=$(get_cluster_id_by_tag "$cluster_tag")

        if [[ -z "$connection_id" ]]; then
            log_warn "Cluster not found for notifications: $cluster_tag"
            ((++index))
            continue
        fi

        channels_count=$(jq ".notifications[$index].channels | length" "$notifications_file")

        local ch_index=0
        while [[ $ch_index -lt $channels_count ]]; do
            local channel_json
            channel_json=$(jq -c ".notifications[$index].channels[$ch_index]" "$notifications_file")

            local tag
            tag=$(echo "$channel_json" | jq -r '.tag')

            if is_dry_run; then
                log_info "[DRY-RUN] Would sync notification channel: $tag"
            else
                local create_result=0
                create_notification_channel "$connection_id" "$channel_json" || create_result=$?
                if [[ $create_result -eq 1 ]]; then
                    # Channel exists, update instead
                    update_notification_channel "$connection_id" "$tag" "$channel_json" || true
                fi
            fi

            ((++ch_index))
        done

        ((++index))
    done
}

# =============================================================================
# Alert Configuration
# =============================================================================

# POST /rest/v1/clusters/{connectionId}/alert-configurations
# Request: { tag, enabled, condition: { template, node, conditionType, thresholdValue, gracePeriod, autoClosePeriod? }, notificationChannelTags }
# Response: 201 Created | 409 Conflict
create_alert_configuration() {
    local connection_id="$1"
    local alert_json="$2"
    local tag
    tag=$(echo "$alert_json" | jq -r '.tag')

    local response http_code body
    response=$(curl -s -w "\n%{http_code}" \
        -X POST "${CC_BASE_URL}/rest/v1/clusters/${connection_id}/alert-configurations" \
        -H "Authorization: Bearer ${JWT_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$alert_json" \
        2>/dev/null)

    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    case "$http_code" in
        200|201)
            log_success "Created alert configuration: $tag"
            ((++ALERTS_CREATED))
            return 0
            ;;
        409)
            return 1  # Signal to update
            ;;
        *)
            log_error "Failed to create alert configuration: $tag (HTTP $http_code)"
            ((++ALERTS_FAILED))
            return 2
            ;;
    esac
}

# PATCH /rest/v1/clusters/{connectionId}/alert-configurations/{tag}
# Request: { tag?, enabled?, condition?, notificationChannelTags? }
# Response: 204 No Content
update_alert_configuration() {
    local connection_id="$1"
    local tag="$2"
    local update_json="$3"

    local response http_code body
    response=$(curl -s -w "\n%{http_code}" \
        -X PATCH "${CC_BASE_URL}/rest/v1/clusters/${connection_id}/alert-configurations/${tag}" \
        -H "Authorization: Bearer ${JWT_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$update_json" \
        2>/dev/null)

    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" == "204" || "$http_code" == "200" ]]; then
        log_success "Updated alert configuration: $tag"
        ((++ALERTS_UPDATED))
        return 0
    else
        log_error "Failed to update alert configuration: $tag (HTTP $http_code)"
        ((++ALERTS_FAILED))
        return 1
    fi
}

sync_alerts() {
    local alerts_file="${SCRIPT_DIR}/../state/alerts.json"

    log_section "Alert Configuration"

    if [[ ! -f "$alerts_file" ]]; then
        log_warn "Alerts state file not found: $alerts_file"
        return 0
    fi

    local alert_count
    alert_count=$(jq '.alerts | length' "$alerts_file")
    log_info "Processing alerts for $alert_count clusters..."

    local index=0
    while [[ $index -lt $alert_count ]]; do
        local cluster_tag connection_id configs_count
        cluster_tag=$(jq -r ".alerts[$index].clusterTag" "$alerts_file")
        connection_id=$(get_cluster_id_by_tag "$cluster_tag")

        if [[ -z "$connection_id" ]]; then
            log_warn "Cluster not found for alerts: $cluster_tag"
            ((++index))
            continue
        fi

        configs_count=$(jq ".alerts[$index].configurations | length" "$alerts_file")

        local cfg_index=0
        while [[ $cfg_index -lt $configs_count ]]; do
            local alert_json tag
            alert_json=$(jq -c ".alerts[$index].configurations[$cfg_index]" "$alerts_file")
            tag=$(echo "$alert_json" | jq -r '.tag')

            if is_dry_run; then
                log_info "[DRY-RUN] Would sync alert configuration: $tag"
            else
                local create_result=0
                create_alert_configuration "$connection_id" "$alert_json" || create_result=$?
                if [[ $create_result -eq 1 ]]; then
                    # Alert exists, update instead
                    update_alert_configuration "$connection_id" "$tag" "$alert_json" || true
                fi
            fi

            ((++cfg_index))
        done

        ((++index))
    done
}

# =============================================================================
# Summary
# =============================================================================

print_summary() {
    log_header "Deployment Summary"
    echo "  Users:         $USERS_CREATED created, $USERS_UPDATED updated, $USERS_FAILED failed"
    echo "  Teams:         $TEAMS_CREATED created, $TEAMS_UPDATED updated, $TEAMS_FAILED failed"
    echo "  Clusters Init: $CLUSTERS_INITIALIZED initialized, $CLUSTERS_INIT_SKIPPED skipped, $CLUSTERS_INIT_FAILED failed"
    echo "  Clusters:      $CLUSTERS_ATTACHED attached, $CLUSTERS_SKIPPED skipped, $CLUSTERS_FAILED failed"
    echo "  Notifications: $NOTIFICATIONS_CREATED created, $NOTIFICATIONS_UPDATED updated, $NOTIFICATIONS_SKIPPED skipped, $NOTIFICATIONS_FAILED failed"
    echo "  Alerts:        $ALERTS_CREATED created, $ALERTS_UPDATED updated, $ALERTS_FAILED failed"
    echo ""
    echo "  Drift Warnings: $DRIFT_WARNINGS"
    echo "========================================"

    local total_failed=$((USERS_FAILED + TEAMS_FAILED + CLUSTERS_INIT_FAILED + CLUSTERS_FAILED + NOTIFICATIONS_FAILED + ALERTS_FAILED))

    if [[ $total_failed -gt 0 ]]; then
        log_warn "Deployment completed with $total_failed failures"
        return 1
    else
        log_success "Deployment completed successfully"
        return 0
    fi
}

# =============================================================================
# Command Line Parsing
# =============================================================================

show_help() {
    cat << 'EOF'
Control Center Automated Deployment Script

Usage:
  ./deploy.sh [options]

Options:
  --dry-run       Preview changes without applying them
  --only COMPONENTS
                  Sync only specified components (comma-separated)
                  Valid: users, teams, clusters, notifications, alerts
                  Example: --only users,teams
  --help          Show this help message

Required Environment Variables:
  CC_BASE_URL        Control Center base URL (e.g., http://localhost:8008)
  CC_ADMIN_EMAIL     Admin username/email
  CC_ADMIN_PASSWORD  Admin password

Optional Environment Variables:
  CC_HEALTH_TIMEOUT     Health check timeout in seconds (default: 300)
  CC_CONNECTOR_TIMEOUT  Connector availability timeout in seconds (default: 120)

API Reference:
  See openapi/rest-api.yaml for complete OpenAPI specification

Example:
  export CC_BASE_URL=http://localhost:8008
  export CC_ADMIN_EMAIL=admin@example.com
  export CC_ADMIN_PASSWORD=secret
  ./deploy.sh
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                CC_DRY_RUN=true
                shift
                ;;
            --only)
                if [[ -z "$2" || "$2" == --* ]]; then
                    log_error "--only requires a comma-separated list of components"
                    log_info "Valid components: users, teams, clusters, notifications, alerts"
                    exit 1
                fi
                SYNC_COMPONENTS="$2"
                shift 2
                ;;
            --only=*)
                SYNC_COMPONENTS="${1#*=}"
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# =============================================================================
# Main
# =============================================================================

main() {
    parse_args "$@"

    log_header "Control Center Deployment Script"
    log_info "Starting deployment at $(date '+%Y-%m-%d %H:%M:%S')"
    log_info "CC_BASE_URL: ${CC_BASE_URL}"

    if is_dry_run; then
        log_warn "DRY-RUN MODE: No changes will be made"
    fi

    if [[ -n "$SYNC_COMPONENTS" ]]; then
        log_info "Partial sync mode: $SYNC_COMPONENTS"
    fi

    # Health check
    wait_for_cc || exit 1

    # Authenticate
    cc_login || exit 1

    # Synchronize resources (conditional based on --only flag)
    if should_sync "users"; then
        sync_users
    fi

    if should_sync "teams"; then
        warn_dependency "teams" "users"
        sync_teams
    fi

    if should_sync "clusters"; then
        sync_cluster_initialization
        sync_clusters
    fi

    if should_sync "notifications"; then
        warn_dependency "notifications" "clusters"
        sync_notification_channels
    fi

    if should_sync "alerts"; then
        warn_dependency "alerts" "clusters"
        warn_dependency "alerts" "notifications"
        sync_alerts
    fi

    # Summary
    print_summary
}

main "$@"
