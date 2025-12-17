#!/usr/bin/env python3
#
# Copyright (C) GridGain Systems. All Rights Reserved.
#  _________        _____ __________________        _____
#  __  ____/___________(_)______  /__  ____/______ ____(_)_______
#  _  / __  __  ___/__  / _  __  / _  / __  _  __ `/__  / __  __ \
#  / /_/ /  _  /    _  /  / /_/ /  / /_/ /  / /_/ / _  /  _  / / /
#  \____/   /_/     /_/   \_,__/   \____/   \__,_/  /_/   /_/ /_/
#
"""
Control Center Automated Deployment Script (Python)

This script demonstrates GitOps/Infrastructure-as-Code pattern for
fully automated Control Center deployment using REST API.

Uses a lightweight httpx-based client aligned with the OpenAPI spec
(openapi/rest-api.yaml).

Usage:
    python deploy.py [options]

Options:
    --dry-run       Preview changes without applying them
    --verbose       Enable verbose/debug output
    --skip-health   Skip health check and proceed immediately
    --help          Show this help message

Required Environment Variables:
    CC_BASE_URL        Control Center base URL (e.g., http://localhost:8008)
    CC_ADMIN_EMAIL     Admin username/email
    CC_ADMIN_PASSWORD  Admin password

Optional Environment Variables:
    CC_HEALTH_TIMEOUT     Health check timeout in seconds (default: 300)
    CC_CONNECTOR_TIMEOUT  Connector availability timeout in seconds (default: 120)
"""

import argparse
import json
import os
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

import httpx

# =============================================================================
# Configuration
# =============================================================================

@dataclass
class Config:
    """Deployment configuration from environment variables."""
    base_url: str
    admin_email: str
    admin_password: str
    health_timeout: int = 300
    connector_timeout: int = 120
    cluster_init_timeout: int = 60
    dry_run: bool = False
    only_components: list = field(default_factory=list)  # Components to sync (empty = all)

    @classmethod
    def from_env(cls) -> "Config":
        """Create config from environment variables."""
        return cls(
            base_url=os.environ.get("CC_BASE_URL", "").rstrip("/"),
            admin_email=os.environ.get("CC_ADMIN_EMAIL", ""),
            admin_password=os.environ.get("CC_ADMIN_PASSWORD", ""),
            health_timeout=int(os.environ.get("CC_HEALTH_TIMEOUT", "300")),
            connector_timeout=int(os.environ.get("CC_CONNECTOR_TIMEOUT", "120")),
            cluster_init_timeout=int(os.environ.get("CC_CLUSTER_INIT_TIMEOUT", "60")),
            dry_run=os.environ.get("CC_DRY_RUN", "").lower() == "true",
        )

    def validate(self) -> None:
        """Validate required configuration."""
        if not self.base_url:
            raise ValueError("CC_BASE_URL is required")
        if not self.admin_email:
            raise ValueError("CC_ADMIN_EMAIL is required")
        if not self.admin_password:
            raise ValueError("CC_ADMIN_PASSWORD is required")


# =============================================================================
# Logging
# =============================================================================

class Colors:
    RED = "\033[0;31m"
    GREEN = "\033[0;32m"
    YELLOW = "\033[0;33m"
    BLUE = "\033[0;34m"
    CYAN = "\033[0;36m"
    NC = "\033[0m"
    BOLD = "\033[1m"


class Logger:
    def __init__(self):
        pass

    def info(self, msg: str) -> None:
        print(f"{Colors.BLUE}[INFO]{Colors.NC} {msg}")

    def success(self, msg: str) -> None:
        print(f"{Colors.GREEN}[OK]{Colors.NC} {msg}")

    def warn(self, msg: str) -> None:
        print(f"{Colors.YELLOW}[WARN]{Colors.NC} {msg}", file=sys.stderr)

    def error(self, msg: str) -> None:
        print(f"{Colors.RED}[ERROR]{Colors.NC} {msg}", file=sys.stderr)

    def section(self, msg: str) -> None:
        print(f"\n{Colors.BOLD}[INFO] === {msg} ==={Colors.NC}")

    def header(self, msg: str) -> None:
        print(f"\n{'=' * 40}\n  {msg}\n{'=' * 40}")


# =============================================================================
# Counters
# =============================================================================

@dataclass
class Counters:
    users_created: int = 0
    users_updated: int = 0
    users_failed: int = 0
    teams_created: int = 0
    teams_updated: int = 0
    teams_failed: int = 0
    clusters_initialized: int = 0
    clusters_init_skipped: int = 0
    clusters_init_failed: int = 0
    clusters_attached: int = 0
    clusters_skipped: int = 0
    clusters_failed: int = 0
    notifications_created: int = 0
    notifications_updated: int = 0
    notifications_skipped: int = 0
    notifications_failed: int = 0
    alerts_created: int = 0
    alerts_updated: int = 0
    alerts_failed: int = 0
    drift_warnings: int = 0


# =============================================================================
# API Client
# =============================================================================

class ControlCenterClient:
    """
    Control Center REST API client.

    This client uses httpx to make direct API calls. Each method corresponds
    to an endpoint in the OpenAPI specification (openapi/rest-api.yaml).
    """

    def __init__(self, config: Config, logger: Logger):
        self.config = config
        self.logger = logger
        self.token: Optional[str] = None
        self.client = httpx.Client(timeout=30.0)

    def _headers(self) -> dict:
        """Get headers with authorization."""
        headers = {"Content-Type": "application/json"}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        return headers

    # -------------------------------------------------------------------------
    # Authentication
    # POST /rest/v1/authentication/login
    # -------------------------------------------------------------------------
    def login(self) -> bool:
        """Authenticate and obtain JWT token."""
        self.logger.info(f"Authenticating as: {self.config.admin_email}")

        if self.config.dry_run:
            self.logger.info("[DRY-RUN] Would authenticate")
            self.token = "dry-run-token"
            return True

        try:
            response = self.client.post(
                f"{self.config.base_url}/rest/v1/authentication/login",
                json={
                    "username": self.config.admin_email,
                    "password": self.config.admin_password,
                },
            )

            if response.status_code == 200:
                self.token = response.text
                self.logger.success("Authentication successful")
                return True
            else:
                self.logger.error(f"Authentication failed (HTTP {response.status_code})")
                return False

        except Exception as e:
            self.logger.error(f"Authentication error: {e}")
            return False

    # -------------------------------------------------------------------------
    # Health Check
    # GET /actuator/health
    # -------------------------------------------------------------------------
    def wait_for_health(self) -> bool:
        """Wait for Control Center to be healthy."""
        timeout = self.config.health_timeout
        interval = 5
        elapsed = 0

        self.logger.info("Waiting for Control Center to be healthy...")

        while elapsed < timeout:
            try:
                response = self.client.get(f"{self.config.base_url}/actuator/health")
                if response.status_code == 200:
                    data = response.json()
                    if data.get("status") == "UP":
                        self.logger.success("Control Center is healthy")
                        return True
            except Exception:
                pass

            time.sleep(interval)
            elapsed += interval

        self.logger.error(f"Control Center did not become healthy within {timeout}s")
        return False

    # -------------------------------------------------------------------------
    # Connectors
    # GET /rest/v1/connectors
    # -------------------------------------------------------------------------
    def wait_for_connector(self, connector_name: str) -> bool:
        """Wait for a connector to be available."""
        timeout = self.config.connector_timeout
        interval = 5
        elapsed = 0

        self.logger.info(f"Waiting for connector '{connector_name}' to be available...")

        if self.config.dry_run:
            self.logger.info(f"[DRY-RUN] Would wait for connector: {connector_name}")
            return True

        while elapsed < timeout:
            try:
                response = self.client.get(
                    f"{self.config.base_url}/rest/v1/connectors",
                    headers=self._headers(),
                )
                if response.status_code == 200:
                    connectors = response.json()
                    if connector_name in connectors:
                        self.logger.success(f"Connector '{connector_name}' is available")
                        return True
            except Exception:
                pass

            time.sleep(interval)
            elapsed += interval

        self.logger.error(f"Connector '{connector_name}' did not become available within {timeout}s")
        return False

    # -------------------------------------------------------------------------
    # Users
    # GET /rest/v1/users
    # POST /rest/v1/users
    # PATCH /rest/v1/users/{username}
    # -------------------------------------------------------------------------
    def list_users(self) -> list:
        """Get all registered users."""
        response = self.client.get(
            f"{self.config.base_url}/rest/v1/users",
            headers=self._headers(),
        )
        return response.json() if response.status_code == 200 else []

    def create_user(self, user_data: dict) -> tuple[bool, int]:
        """Create a new user. Returns (success, status_code).

        Note: admin field is stripped on create (API restriction) and must be
        applied via PATCH after user creation.
        """
        # Strip admin field - can only be set via PATCH after user creation
        create_data = {k: v for k, v in user_data.items() if k != "admin"}
        response = self.client.post(
            f"{self.config.base_url}/rest/v1/users",
            headers=self._headers(),
            json=create_data,
        )
        return response.status_code in (200, 201), response.status_code

    def update_user(self, username: str, update_data: dict) -> bool:
        """Update an existing user."""
        response = self.client.patch(
            f"{self.config.base_url}/rest/v1/users/{username}",
            headers=self._headers(),
            json=update_data,
        )
        return response.status_code in (200, 204)

    # -------------------------------------------------------------------------
    # Teams
    # GET /rest/v1/teams
    # POST /rest/v1/teams
    # POST /rest/v1/teams/{name}/members
    # -------------------------------------------------------------------------
    def list_teams(self) -> list:
        """Get all teams."""
        response = self.client.get(
            f"{self.config.base_url}/rest/v1/teams",
            headers=self._headers(),
        )
        return response.json() if response.status_code == 200 else []

    def create_team(self, name: str) -> tuple[bool, int]:
        """Create a new team. Returns (success, status_code)."""
        response = self.client.post(
            f"{self.config.base_url}/rest/v1/teams",
            headers=self._headers(),
            json={"name": name},
        )
        return response.status_code in (200, 201), response.status_code

    def get_team_members(self, team_name: str) -> list:
        """Get members of a team."""
        response = self.client.get(
            f"{self.config.base_url}/rest/v1/teams/{team_name}/members",
            headers=self._headers(),
        )
        return response.json() if response.status_code == 200 else []

    def add_team_members(self, team_name: str, members: list) -> bool:
        """Add members to a team."""
        response = self.client.post(
            f"{self.config.base_url}/rest/v1/teams/{team_name}/members",
            headers=self._headers(),
            json=members,
        )
        return response.status_code in (200, 201)

    def delete_team_members(self, team_name: str, members: list) -> bool:
        """Remove members from a team."""
        response = self.client.request(
            "DELETE",
            f"{self.config.base_url}/rest/v1/teams/{team_name}/members",
            headers=self._headers(),
            json=members,
        )
        return response.status_code in (200, 204)

    # -------------------------------------------------------------------------
    # Clusters
    # GET /rest/v1/clusters
    # POST /rest/v1/clusters
    # POST /rest/v1/clusters/{connectionId}/actions/share
    # -------------------------------------------------------------------------
    def list_clusters(self) -> list:
        """Get all clusters."""
        response = self.client.get(
            f"{self.config.base_url}/rest/v1/clusters",
            headers=self._headers(),
        )
        return response.json() if response.status_code == 200 else []

    def attach_cluster(self, cluster_data: dict) -> tuple[Optional[dict], int]:
        """Attach a cluster. Returns (response_data, status_code)."""
        response = self.client.post(
            f"{self.config.base_url}/rest/v1/clusters",
            headers=self._headers(),
            json=cluster_data,
        )
        if response.status_code in (200, 201):
            return response.json(), response.status_code
        return None, response.status_code

    def share_cluster(self, connection_id: str, share_with: list) -> bool:
        """Share a cluster with teams/users."""
        response = self.client.post(
            f"{self.config.base_url}/rest/v1/clusters/{connection_id}/actions/share",
            headers=self._headers(),
            json=share_with,
        )
        return response.status_code in (200, 201)

    def get_cluster_id_by_tag(self, tag: str) -> Optional[str]:
        """Find cluster connection ID by tag."""
        clusters = self.list_clusters()
        for cluster in clusters:
            if cluster.get("tag") == tag:
                return cluster.get("id")
        return None

    # -------------------------------------------------------------------------
    # Ignite Cluster Initialization (Direct to Ignite REST API)
    # GET /management/v1/cluster/state
    # POST /management/v1/cluster/init
    # -------------------------------------------------------------------------
    def wait_for_ignite_rest(self, init_url: str) -> bool:
        """Wait for Ignite REST API to be available."""
        timeout = self.config.cluster_init_timeout
        interval = 5
        elapsed = 0

        self.logger.info(f"Waiting for Ignite REST API at '{init_url}'...")

        if self.config.dry_run:
            self.logger.info(f"[DRY-RUN] Would wait for Ignite REST API: {init_url}")
            return True

        while elapsed < timeout:
            try:
                response = self.client.get(f"{init_url}/management/v1/cluster/state")
                if response.status_code in (200, 409):
                    self.logger.success(f"Ignite REST API is available at '{init_url}'")
                    return True
            except Exception:
                pass

            time.sleep(interval)
            elapsed += interval

        self.logger.error(f"Ignite REST API at '{init_url}' did not become available within {timeout}s")
        return False

    def get_cluster_state(self, init_url: str) -> Optional[dict]:
        """Get Ignite cluster initialization state."""
        try:
            response = self.client.get(f"{init_url}/management/v1/cluster/state")
            if response.status_code == 200:
                return response.json()
        except Exception:
            pass
        return None

    def wait_for_cluster_ready(self, init_url: str, timeout: int = 30) -> bool:
        """Wait for Ignite cluster to be initialized (cluster/state returns 200)."""
        interval = 2
        elapsed = 0

        while elapsed < timeout:
            try:
                response = self.client.get(f"{init_url}/management/v1/cluster/state")
                if response.status_code == 200:
                    return True
            except Exception:
                pass

            time.sleep(interval)
            elapsed += interval

        return False

    def init_ignite_cluster(self, init_url: str, cluster_name: str, meta_storage_node: str) -> tuple[bool, int, str]:
        """
        Initialize an Ignite cluster.
        Returns (success, status_code, message).
        """
        try:
            response = self.client.post(
                f"{init_url}/management/v1/cluster/init",
                json={
                    "metaStorageNodes": [meta_storage_node],
                    "cmgNodes": [meta_storage_node],
                    "clusterName": cluster_name,
                    "clusterConfiguration": "",
                },
            )

            if response.status_code == 200:
                # Wait for cluster to be ready
                self.wait_for_cluster_ready(init_url)
                return True, 200, "initialized"
            elif response.status_code == 400:
                # Check if already initialized with correct name
                state = self.get_cluster_state(init_url)
                if state:
                    current_name = state.get("clusterTag") or state.get("name", "")
                    if current_name == cluster_name:
                        return True, 400, "already_initialized"
                    else:
                        return False, 400, f"name_mismatch:{current_name}"
                return False, 400, "bad_config"
            else:
                return False, response.status_code, response.text

        except Exception as e:
            return False, 0, str(e)

    # -------------------------------------------------------------------------
    # Notification Channels
    # POST /rest/v1/clusters/{connectionId}/notifications
    # PATCH /rest/v1/clusters/{connectionId}/notifications/{tag}
    # -------------------------------------------------------------------------
    def create_notification_channel(self, connection_id: str, channel_data: dict) -> tuple[bool, int]:
        """Create a notification channel. Returns (success, status_code)."""
        response = self.client.post(
            f"{self.config.base_url}/rest/v1/clusters/{connection_id}/notifications",
            headers=self._headers(),
            json=channel_data,
        )
        return response.status_code in (200, 201), response.status_code

    def update_notification_channel(self, connection_id: str, tag: str, update_data: dict) -> bool:
        """Update a notification channel."""
        response = self.client.patch(
            f"{self.config.base_url}/rest/v1/clusters/{connection_id}/notifications/{tag}",
            headers=self._headers(),
            json=update_data,
        )
        return response.status_code in (200, 204)

    # -------------------------------------------------------------------------
    # Alert Configurations
    # POST /rest/v1/clusters/{connectionId}/alert-configurations
    # PATCH /rest/v1/clusters/{connectionId}/alert-configurations/{tag}
    # -------------------------------------------------------------------------
    def create_alert_configuration(self, connection_id: str, alert_data: dict) -> tuple[bool, int]:
        """Create an alert configuration. Returns (success, status_code)."""
        response = self.client.post(
            f"{self.config.base_url}/rest/v1/clusters/{connection_id}/alert-configurations",
            headers=self._headers(),
            json=alert_data,
        )
        return response.status_code in (200, 201), response.status_code

    def update_alert_configuration(self, connection_id: str, tag: str, update_data: dict) -> bool:
        """Update an alert configuration."""
        response = self.client.patch(
            f"{self.config.base_url}/rest/v1/clusters/{connection_id}/alert-configurations/{tag}",
            headers=self._headers(),
            json=update_data,
        )
        return response.status_code in (200, 204)


# =============================================================================
# Deployer
# =============================================================================

class Deployer:
    """Main deployment orchestrator."""

    def __init__(self, config: Config):
        self.config = config
        self.logger = Logger()
        self.client = ControlCenterClient(config, self.logger)
        self.counters = Counters()
        self.state_dir = Path(__file__).parent.parent / "state"

    def should_sync(self, component: str) -> bool:
        """Check if a component should be synced based on --only flag."""
        if not self.config.only_components:
            return True  # Sync all if no --only specified
        return component in self.config.only_components

    def warn_dependency(self, component: str, depends_on: str) -> None:
        """Warn if running partial sync without a dependency."""
        if self.config.only_components and depends_on not in self.config.only_components:
            self.logger.warn(f"{component} depends on {depends_on} - ensure it was synced previously")

    def run(self) -> int:
        """Run the deployment. Returns exit code."""
        self.logger.header("Control Center Deployment Script")
        self.logger.info(f"Starting deployment at {time.strftime('%Y-%m-%d %H:%M:%S')}")
        self.logger.info(f"CC_BASE_URL: {self.config.base_url}")

        if self.config.dry_run:
            self.logger.warn("DRY-RUN MODE: No changes will be made")

        if self.config.only_components:
            self.logger.info(f"Partial sync mode: {', '.join(self.config.only_components)}")

        # Health check
        if not self.client.wait_for_health():
            return 1

        # Authenticate
        if not self.client.login():
            return 1

        # Synchronize resources (conditional based on --only flag)
        if self.should_sync("users"):
            self.sync_users()

        if self.should_sync("teams"):
            self.warn_dependency("teams", "users")
            self.sync_teams()

        if self.should_sync("clusters"):
            self.sync_cluster_initialization()
            self.sync_clusters()

        if self.should_sync("notifications"):
            self.warn_dependency("notifications", "clusters")
            self.sync_notification_channels()

        if self.should_sync("alerts"):
            self.warn_dependency("alerts", "clusters")
            self.warn_dependency("alerts", "notifications")
            self.sync_alerts()

        # Summary
        return self.print_summary()

    # -------------------------------------------------------------------------
    # User Synchronization
    # -------------------------------------------------------------------------
    def sync_users(self) -> None:
        self.logger.section("User Synchronization")

        users_file = self.state_dir / "users.json"
        if not users_file.exists():
            self.logger.warn(f"Users state file not found: {users_file}")
            return

        data = json.loads(users_file.read_text())
        users = data.get("users", [])
        self.logger.info(f"Processing {len(users)} users...")

        for user_data in users:
            username = user_data.get("username")
            is_admin = user_data.get("admin", False)

            if self.config.dry_run:
                self.logger.info(f"[DRY-RUN] Would sync user: {username}")
                continue

            success, status = self.client.create_user(user_data)
            if success:
                self.logger.success(f"Created user: {username}")
                self.counters.users_created += 1
                # Apply admin flag if set (can't be set on POST)
                if is_admin:
                    if self.client.update_user(username, {"admin": True}):
                        self.logger.success(f"Updated user: {username}")
                    else:
                        self.logger.warn(f"Failed to set admin flag for user: {username}")
            elif status == 409:
                # User exists, update
                update_data = {k: v for k, v in user_data.items() if k != "username"}
                if self.client.update_user(username, update_data):
                    self.logger.success(f"Updated user: {username}")
                    self.counters.users_updated += 1
                else:
                    self.logger.error(f"Failed to update user: {username}")
                    self.counters.users_failed += 1
            else:
                self.logger.error(f"Failed to create user: {username} (HTTP {status})")
                self.counters.users_failed += 1

        # Detect drift
        if not self.config.dry_run:
            self._detect_user_drift(users)

    def _detect_user_drift(self, managed_users: list) -> None:
        managed_usernames = {u["username"] for u in managed_users}
        actual_users = self.client.list_users()

        for user in actual_users:
            username = user.get("username")
            if username == self.config.admin_email:
                continue
            if username not in managed_usernames:
                self.logger.warn(f"DRIFT: User '{username}' exists but is not managed")
                self.counters.drift_warnings += 1

    # -------------------------------------------------------------------------
    # Team Synchronization
    # -------------------------------------------------------------------------
    def sync_teams(self) -> None:
        self.logger.section("Team Synchronization")

        teams_file = self.state_dir / "teams.json"
        if not teams_file.exists():
            self.logger.warn(f"Teams state file not found: {teams_file}")
            return

        data = json.loads(teams_file.read_text())
        teams = data.get("teams", [])
        self.logger.info(f"Processing {len(teams)} teams...")

        for team_data in teams:
            name = team_data.get("name")
            desired_members = set(team_data.get("members", []))

            if self.config.dry_run:
                self.logger.info(f"[DRY-RUN] Would sync team: {name}")
                continue

            success, status = self.client.create_team(name)
            if success:
                self.logger.success(f"Created team: {name}")
                self.counters.teams_created += 1

            # Sync members (add missing, remove extra)
            self._sync_team_members(name, desired_members)

        # Detect drift
        if not self.config.dry_run:
            self._detect_team_drift(teams)

    def _sync_team_members(self, team_name: str, desired_members: set) -> None:
        """Sync team members - add missing and remove extra members."""
        # Get current members
        current_members_data = self.client.get_team_members(team_name)
        current_members = {m.get("username") for m in current_members_data}

        # Find members to add (in desired but not in current)
        to_add = desired_members - current_members

        # Find members to remove (in current but not in desired)
        # Skip the script user as they may be the owner
        to_remove = current_members - desired_members - {self.config.admin_email}

        changes_made = False

        # Add missing members
        if to_add:
            if self.client.add_team_members(team_name, list(to_add)):
                changes_made = True

        # Remove extra members
        if to_remove:
            if self.client.delete_team_members(team_name, list(to_remove)):
                changes_made = True

        # Report changes
        if changes_made:
            self.logger.success(f"Updated team members: {team_name}")
            self.counters.teams_updated += 1

    def _detect_team_drift(self, managed_teams: list) -> None:
        managed_names = {t["name"] for t in managed_teams}
        actual_teams = self.client.list_teams()

        for team in actual_teams:
            name = team.get("name")
            if name not in managed_names:
                self.logger.warn(f"DRIFT: Team '{name}' exists but is not managed")
                self.counters.drift_warnings += 1

    # -------------------------------------------------------------------------
    # Ignite Cluster Initialization
    # -------------------------------------------------------------------------
    def sync_cluster_initialization(self) -> None:
        """Initialize Ignite clusters before attaching to Control Center."""
        self.logger.section("Ignite Cluster Initialization")

        clusters_file = self.state_dir / "clusters.json"
        if not clusters_file.exists():
            self.logger.warn(f"Clusters state file not found: {clusters_file}")
            return

        data = json.loads(clusters_file.read_text())
        clusters = data.get("clusters", [])
        self.logger.info(f"Processing {len(clusters)} clusters for initialization...")

        for cluster_data in clusters:
            cluster_name = cluster_data.get("clusterName") or cluster_data.get("tag")
            init_url = cluster_data.get("initUrl") or cluster_data.get("restUrl")
            meta_storage_node = cluster_data.get("metaStorageNode")

            if not meta_storage_node:
                self.logger.warn(f"No metaStorageNode specified for cluster: {cluster_name}, skipping initialization")
                continue

            if self.config.dry_run:
                self.logger.info(f"[DRY-RUN] Would initialize Ignite cluster: {cluster_name}")
                continue

            # Wait for Ignite REST API
            if not self.client.wait_for_ignite_rest(init_url):
                self.logger.error(f"Cannot initialize cluster '{cluster_name}': REST API not available")
                self.counters.clusters_init_failed += 1
                continue

            success, status, message = self.client.init_ignite_cluster(init_url, cluster_name, meta_storage_node)

            if success:
                if message == "initialized":
                    self.logger.success(f"Initialized Ignite cluster: {cluster_name}")
                    self.counters.clusters_initialized += 1
                else:  # already_initialized
                    self.logger.info(f"Ignite cluster already initialized: {cluster_name}")
                    self.counters.clusters_init_skipped += 1
            else:
                if message.startswith("name_mismatch:"):
                    current_name = message.split(":", 1)[1]
                    self.logger.error(f"Ignite cluster initialized with different name: '{current_name}' (expected '{cluster_name}')")
                else:
                    self.logger.error(f"Failed to initialize Ignite cluster: {cluster_name} (HTTP {status})")
                self.counters.clusters_init_failed += 1

    # -------------------------------------------------------------------------
    # Cluster Synchronization
    # -------------------------------------------------------------------------
    def sync_clusters(self) -> None:
        self.logger.section("Cluster Attachment")

        clusters_file = self.state_dir / "clusters.json"
        if not clusters_file.exists():
            self.logger.warn(f"Clusters state file not found: {clusters_file}")
            return

        data = json.loads(clusters_file.read_text())
        clusters = data.get("clusters", [])

        # Wait for connector if any cluster uses one
        connector_names = [c.get("connectorName") for c in clusters if c.get("connectorName")]
        if connector_names:
            if not self.client.wait_for_connector(connector_names[0]):
                return

        self.logger.info(f"Processing {len(clusters)} clusters...")

        for cluster_data in clusters:
            tag = cluster_data.get("tag")
            share_with = cluster_data.get("shareWith", [])

            if self.config.dry_run:
                self.logger.info(f"[DRY-RUN] Would attach cluster: {tag}")
                continue

            # Prepare attach request - include connectorName only if specified
            attach_data = {"restUrl": cluster_data.get("restUrl")}
            if cluster_data.get("connectorName"):
                attach_data["connectorName"] = cluster_data.get("connectorName")

            response_data, status = self.client.attach_cluster(attach_data)
            if response_data:
                self.logger.success(f"Attached cluster: {tag}")
                self.counters.clusters_attached += 1
                connection_id = response_data.get("id")
            elif status == 409:
                self.logger.info(f"Cluster already attached: {tag}")
                self.counters.clusters_skipped += 1
                connection_id = self.client.get_cluster_id_by_tag(tag)
            else:
                self.logger.error(f"Failed to attach cluster: {tag} (HTTP {status})")
                self.counters.clusters_failed += 1
                continue

            # Share with teams/users
            if connection_id and share_with:
                if self.client.share_cluster(connection_id, share_with):
                    self.logger.success("Shared cluster with teams/users")
                else:
                    self.logger.warn("Failed to share cluster - may already be shared")

        # Detect drift
        if not self.config.dry_run:
            self._detect_cluster_drift(clusters)

    def _detect_cluster_drift(self, managed_clusters: list) -> None:
        managed_tags = {c["tag"] for c in managed_clusters}
        actual_clusters = self.client.list_clusters()

        for cluster in actual_clusters:
            tag = cluster.get("tag")
            if tag not in managed_tags:
                self.logger.warn(f"DRIFT: Cluster '{tag}' exists but is not managed")
                self.counters.drift_warnings += 1

    # -------------------------------------------------------------------------
    # Notification Channel Synchronization
    # -------------------------------------------------------------------------
    def sync_notification_channels(self) -> None:
        self.logger.section("Notification Channels")

        notifications_file = self.state_dir / "notification-channels.json"
        if not notifications_file.exists():
            self.logger.warn(f"Notification channels state file not found: {notifications_file}")
            return

        data = json.loads(notifications_file.read_text())
        notifications = data.get("notifications", [])
        self.logger.info(f"Processing notifications for {len(notifications)} clusters...")

        for notification_data in notifications:
            cluster_tag = notification_data.get("clusterTag")
            connection_id = self.client.get_cluster_id_by_tag(cluster_tag)

            if not connection_id:
                self.logger.warn(f"Cluster not found for notifications: {cluster_tag}")
                continue

            channels = notification_data.get("channels", [])
            for channel_data in channels:
                tag = channel_data.get("tag")

                if self.config.dry_run:
                    self.logger.info(f"[DRY-RUN] Would sync notification channel: {tag}")
                    continue

                success, status = self.client.create_notification_channel(connection_id, channel_data)
                if success:
                    self.logger.success(f"Created notification channel: {tag}")
                    self.counters.notifications_created += 1
                elif status == 409:
                    # Channel exists, update
                    if self.client.update_notification_channel(connection_id, tag, channel_data):
                        self.logger.success(f"Updated notification channel: {tag}")
                        self.counters.notifications_updated += 1
                    else:
                        self.logger.error(f"Failed to update notification channel: {tag}")
                        self.counters.notifications_failed += 1
                else:
                    self.logger.error(f"Failed to create notification channel: {tag} (HTTP {status})")
                    self.counters.notifications_failed += 1

    # -------------------------------------------------------------------------
    # Alert Configuration Synchronization
    # -------------------------------------------------------------------------
    def sync_alerts(self) -> None:
        self.logger.section("Alert Configuration")

        alerts_file = self.state_dir / "alerts.json"
        if not alerts_file.exists():
            self.logger.warn(f"Alerts state file not found: {alerts_file}")
            return

        data = json.loads(alerts_file.read_text())
        alerts = data.get("alerts", [])
        self.logger.info(f"Processing alerts for {len(alerts)} clusters...")

        for alert_data in alerts:
            cluster_tag = alert_data.get("clusterTag")
            connection_id = self.client.get_cluster_id_by_tag(cluster_tag)

            if not connection_id:
                self.logger.warn(f"Cluster not found for alerts: {cluster_tag}")
                continue

            configurations = alert_data.get("configurations", [])
            for config in configurations:
                tag = config.get("tag")

                if self.config.dry_run:
                    self.logger.info(f"[DRY-RUN] Would sync alert configuration: {tag}")
                    continue

                success, status = self.client.create_alert_configuration(connection_id, config)
                if success:
                    self.logger.success(f"Created alert configuration: {tag}")
                    self.counters.alerts_created += 1
                elif status == 409:
                    # Alert exists, update
                    if self.client.update_alert_configuration(connection_id, tag, config):
                        self.logger.success(f"Updated alert configuration: {tag}")
                        self.counters.alerts_updated += 1
                    else:
                        self.logger.error(f"Failed to update alert configuration: {tag}")
                        self.counters.alerts_failed += 1
                else:
                    self.logger.error(f"Failed to create alert configuration: {tag} (HTTP {status})")
                    self.counters.alerts_failed += 1

    # -------------------------------------------------------------------------
    # Summary
    # -------------------------------------------------------------------------
    def print_summary(self) -> int:
        self.logger.header("Deployment Summary")
        c = self.counters
        print(f"  Users:         {c.users_created} created, {c.users_updated} updated, {c.users_failed} failed")
        print(f"  Teams:         {c.teams_created} created, {c.teams_updated} updated, {c.teams_failed} failed")
        print(f"  Clusters Init: {c.clusters_initialized} initialized, {c.clusters_init_skipped} skipped, {c.clusters_init_failed} failed")
        print(f"  Clusters:      {c.clusters_attached} attached, {c.clusters_skipped} skipped, {c.clusters_failed} failed")
        print(f"  Notifications: {c.notifications_created} created, {c.notifications_updated} updated, {c.notifications_skipped} skipped, {c.notifications_failed} failed")
        print(f"  Alerts:        {c.alerts_created} created, {c.alerts_updated} updated, {c.alerts_failed} failed")
        print()
        print(f"  Drift Warnings: {c.drift_warnings}")
        print("=" * 40)

        total_failed = c.users_failed + c.teams_failed + c.clusters_init_failed + c.clusters_failed + c.notifications_failed + c.alerts_failed

        if total_failed > 0:
            self.logger.warn(f"Deployment completed with {total_failed} failures")
            return 1
        else:
            self.logger.success("Deployment completed successfully")
            return 0


# =============================================================================
# Main
# =============================================================================

def main() -> int:
    parser = argparse.ArgumentParser(
        description="Control Center Automated Deployment Script",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
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
  python deploy.py
        """,
    )
    parser.add_argument("--dry-run", action="store_true", help="Preview changes without applying them")
    parser.add_argument(
        "--only",
        type=str,
        help="Sync only specified components (comma-separated). Valid: users, teams, clusters, notifications, alerts",
        metavar="COMPONENTS",
    )

    args = parser.parse_args()

    # Load configuration
    try:
        config = Config.from_env()
        config.dry_run = config.dry_run or args.dry_run
        if args.only:
            config.only_components = [c.strip() for c in args.only.split(",")]
        config.validate()
    except ValueError as e:
        print(f"Configuration error: {e}", file=sys.stderr)
        return 1

    # Run deployment
    deployer = Deployer(config)
    return deployer.run()


if __name__ == "__main__":
    sys.exit(main())
