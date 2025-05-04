#!/bin/bash
# FIXED VERSION - Fixed WireGuard endpoint IP and improved error handling
# new-user.sh - Using Custom WireGuard Configuration with Enhanced Setup
# Purpose: Deploy a new isolated Plex container behind Gluetun VPN with enforced VPN-only routing

# ====== FUNCTIONS ======

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

cleanup() {
  local user_num=$1; local error_msg=$2
  log "ERROR: $error_msg"
  # Capture the last container logs for diagnostics
  if [[ -n "$GLUETUN_ID" ]]; then
    log "Gluetun logs before failure:"
    docker logs "$GLUETUN_ID" | tail -n 20 || true
  fi
  docker rm -f "gluetun-${user_num}" "user${user_num}_1_1" >/dev/null 2>&1 || true
  exit 1
}

validate_ip() {
  local ip=$1
  [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.'; for o in $ip; do ((o>=0 && o<=255)) || return 1; done
  return 0
}

create_dns_record() {
  local sub=$1 ip=$2
  log "Creating DNS A-record for ${sub}.${DOMAIN_SUFFIX} → $ip (DNS-only)"
  curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" \
    --data "{\"type\":\"A\",\"name\":\"$sub\",\"content\":\"$ip\",\"ttl\":120,\"proxied\":false}" \
  | grep -q '"success":true' || log "WARNING: Cloudflare API call failed"
  sleep 2
}

random_port() {
  USED=$(docker ps -q | xargs docker port 2>/dev/null | grep -oE ':[0-9]+' | tr -d ':' | sort -n | uniq)
  while :; do
    C=$((32401 + RANDOM % 10000))
    [[ ! " $USED " =~ " $C " ]] && { echo "$C"; break; }
  done
}

test_connectivity() {
  log "Testing basic internet connectivity..."
  if ! ping -c 3 1.1.1.1 &>/dev/null; then
    log "WARNING: Host cannot ping 1.1.1.1."
    return 1
  fi
  log "Testing host DNS resolution..."
  if ! host plex.tv &>/dev/null; then
    log "WARNING: Host cannot resolve plex.tv."
    return 1
  fi
  log "Testing Traefik access..."
  if ! curl -s -o /dev/null -w "%{http_code}" http://localhost:80 | grep -qE "200|301|302"; then
    log "WARNING: Traefik not responding on port 80!"
    return 1
  fi
  return 0
}

install_debugging_tools() {
  local container_id=$1
  log "Installing debugging tools in container..."
  docker exec "$container_id" apk add --no-cache curl bind-tools iputils net-tools &>/dev/null
}

check_vpn_connectivity() {
  local container_id=$1 attempts=3 success=0
  log "Checking VPN connectivity (may take a moment)..."
  install_debugging_tools "$container_id"
  for i in $(seq 1 $attempts); do
    log "DNS test attempt $i/$attempts..."
    if docker exec "$container_id" nslookup plex.tv &>/dev/null; then
      ((success++))
    else
      log "DNS resolution failed:"; docker exec "$container_id" cat /etc/resolv.conf || true
    fi
    sleep 1
  done
  for i in $(seq 1 $attempts); do
    log "HTTP test attempt $i/$attempts..."
    if docker exec "$container_id" curl -s -m5 https://plex.tv &>/dev/null; then
      ((success++))
    fi
    sleep 1
  done
  (( success > attempts )) && return 0 || return 1
}

# ====== CONFIGURATION ======
set -euo pipefail

# ---- System Configuration ----
BASE_PLEX_CONFIG=""                                          # Base configuration to clone
PLEX_CONFIG_ROOT=""                                          # Root directory for all Plex configurations
SERVER_IP=""                                                 # Public IP of the server

# ---- Docker & Networking ----
PLEX_NETWORK=""                                              # Docker network for Plex
TRAEFIK_NETWORK=""                                           # Docker network for Traefik
PLEX_IMAGE="lscr.io/linuxserver/plex:latest"                 # Plex Docker image to use

# ---- Domain & DNS ----
DOMAIN_SUFFIX=""                                # Domain suffix for the Plex instance
CF_ZONE_ID="YOUR_CLOUDFLARE_ZONE_ID"                         # Cloudflare Zone ID
CF_API_TOKEN="YOUR_CLOUDFLARE_API_TOKEN"                     # Cloudflare API Token (redacted)

# ---- Wireguard VPN Configuration ----
VPN_SERVICE_PROVIDER=""                               # VPN service provider
VPN_TYPE=""                                         # VPN protocol type
WIREGUARD_PRIVATE_KEY="YOUR_WIREGUARD_PRIVATE_KEY"           # WireGuard private key (redacted)
WIREGUARD_ADDRESSES="0.0.0.0/32"                             # WireGuard internal IP address
WIREGUARD_PUBLIC_KEY="YOUR_WIREGUARD_PUBLIC_KEY"             # WireGuard public key (redacted)
WIREGUARD_ENDPOINT_IP="Wireguard Endpoint IP"                # WireGuard server IP (check wg0.conf)
WIREGUARD_ENDPOINT_PORT="51820"                              # WireGuard server port
SERVER_CITIES="Wireguard Server City"                        # Preferred server location
WIREGUARD_DNS="1.1.1.1,8.8.8.8"                              # DNS servers to use inside VPN
WIREGUARD_MTU=1280                                           # WireGuard MTU setting

# ---- Firewall Settings ----
FIREWALL_ENABLED="on"                                        # Enable the firewall
FIREWALL_VPN_INPUT_PORTS=32400                               # Ports to allow inbound through VPN
FIREWALL_OUTBOUND_SUBNETS="0.0.0.0/16"                   # Allowed outbound subnets
FIREWALL_INPUT_SUBNETS="0.0.0.0/16,0.0.0.0/16"        # Allowed inbound subnets
HTTP_PROXY_ENABLED="on"                                      # Enable HTTP proxy

# ---- Docker Container Settings ----
GLUETUN_IMAGE="qmcgaw/gluetun:latest"                        # Gluetun Docker image
DOCKER_USER="0:0"                                            # User:Group for Docker containers
PLEX_CONTAINER_PORT=32400                                    # Plex server port inside container
BLOCK_ANALYTICS_HOSTS="metric.plex.tv metrics.plex.tv analytics.plex.tv"  # Hosts to block in Plex

# ---- Storage & Device Settings ----
PLEX_MEDIA_PATH=""                           # Path to media files on host
HARDWARE_ACCELERATION_DEVICE=""            # Device for hardware acceleration

# ---- Plex Settings ----
# These are default Plex settings that can be customized
PLEX_PREFERENCE_ENABLE_IPV6=0                               # Disable IPv6
PLEX_PREFERENCE_DISABLE_TLSV1_0=0                           # Don't disable TLSv1.0
PLEX_PREFERENCE_ENABLE_STREAM_LOOPING=1                     # Enable stream looping
PLEX_PREFERENCE_DLNA_MS_MEDIA_RECEIVER_UDN=""               # Empty DLNA media receiver UDN
PLEX_PREFERENCE_ACCEPTED_EULA=1                             # Accept EULA automatically
PLEX_PREFERENCE_TRANSCODER_THROTTLE_BUFFER=600              # Transcoder throttle buffer
PLEX_PREFERENCE_LAN_NETWORKS_BANDWIDTH="10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"  # LAN networks for bandwidth
PLEX_PREFERENCE_ALLOWED_NETWORKS="10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,0.0.0.0/0"  # Allowed networks

# ====== INITIAL VALIDATION ======
log "Performing pre-deployment system checks..."
if ! test_connectivity; then
  log "ERROR: System prerequisites not met."
  exit 1
fi

USER_NUM=$(shuf -i1000-9999 -n1)
USER_ID="user${USER_NUM}_1_1"
GLUETUN_ID="gluetun-${USER_NUM}"
SUBDOMAIN="$USER_NUM"
DOMAIN="$SUBDOMAIN.$DOMAIN_SUFFIX"
CONFIG_PATH="$PLEX_CONFIG_ROOT/$USER_ID"
HOST_PORT=$(random_port)

log "Using container IDs:"
log "- Gluetun: $GLUETUN_ID"
log "- Plex:   $USER_ID"
log "- Domain: $DOMAIN"
log "- Port:   $HOST_PORT"

# ====== PREPARE CONFIG ======
log "Creating Plex config at $CONFIG_PATH"
mkdir -p "$CONFIG_PATH"/{Cache,Logs,Media,Metadata,Transcode,"Plug-in Support"/{Databases,Data,Caches,Preferences,"Metadata Combination"}}
cp -a "$BASE_PLEX_CONFIG/Metadata/." "$CONFIG_PATH/Metadata/"
cp -a "$BASE_PLEX_CONFIG/Plug-in Support/Databases/." "$CONFIG_PATH/Plug-in Support/Databases/"
sed -e 's@<MachineIdentifier>.*</MachineIdentifier>@<MachineIdentifier></MachineIdentifier>@' \
    -e 's@<ProcessedMachineIdentifier>.*</ProcessedMachineIdentifier>@<ProcessedMachineIdentifier></ProcessedMachineIdentifier>@' \
    -e 's@<AnonymousMachineIdentifier>.*</AnonymousMachineIdentifier>@<AnonymousMachineIdentifier></AnonymousMachineIdentifier>@' \
    "$BASE_PLEX_CONFIG/Preferences.xml" > "$CONFIG_PATH/Preferences.xml"

docker network inspect "$PLEX_NETWORK"   &>/dev/null || docker network create "$PLEX_NETWORK"
docker network inspect "$TRAEFIK_NETWORK" &>/dev/null || docker network create "$TRAEFIK_NETWORK"

# ====== DEPLOY GLUETUN ======
log "Starting Gluetun container ($GLUETUN_ID)"
docker rm -f "$GLUETUN_ID" &>/dev/null || true

SHORT_ID=$(head /dev/urandom | tr -dc 'a-f0-9' | head -c12)

log "Launching with WireGuard endpoint ${WIREGUARD_ENDPOINT_IP}:${WIREGUARD_ENDPOINT_PORT}"
docker run -d \
  --name="$GLUETUN_ID" \
  --hostname="$SHORT_ID" \
  --user="$DOCKER_USER" \
  --cap-add=NET_ADMIN \
  --device=/dev/net/tun:/dev/net/tun \
  --network="$PLEX_NETWORK" \
  -e VPN_SERVICE_PROVIDER="$VPN_SERVICE_PROVIDER" \
  -e VPN_TYPE="$VPN_TYPE" \
  -e WIREGUARD_PRIVATE_KEY="$WIREGUARD_PRIVATE_KEY" \
  -e WIREGUARD_ADDRESSES="$WIREGUARD_ADDRESSES" \
  -e WIREGUARD_PUBLIC_KEY="$WIREGUARD_PUBLIC_KEY" \
  -e WIREGUARD_ENDPOINT_IP="$WIREGUARD_ENDPOINT_IP" \
  -e WIREGUARD_ENDPOINT_PORT="$WIREGUARD_ENDPOINT_PORT" \
  -e SERVER_CITIES="$SERVER_CITIES" \
  -e WIREGUARD_DNS="$WIREGUARD_DNS" \
  -e WIREGUARD_MTU="$WIREGUARD_MTU" \
  -e FIREWALL_ENABLED="$FIREWALL_ENABLED" \
  -e FIREWALL_VPN_INPUT_PORTS="$FIREWALL_VPN_INPUT_PORTS" \
  -e FIREWALL_OUTBOUND_SUBNETS="$FIREWALL_OUTBOUND_SUBNETS" \
  -e FIREWALL_INPUT_SUBNETS="$FIREWALL_INPUT_SUBNETS" \
  -e HTTP_PROXY_ENABLED="$HTTP_PROXY_ENABLED" \
  -p "$HOST_PORT:$PLEX_CONTAINER_PORT" \
  --expose=8000 \
  --expose=8388 \
  --expose=8388/udp \
  --expose=8888 \
  $(for host in $BLOCK_ANALYTICS_HOSTS; do echo "--add-host=$host:127.0.0.1"; done) \
  --label="traefik.enable=true" \
  --label="traefik.http.routers.${SUBDOMAIN}.rule=Host(\`${DOMAIN}\`)" \
  --label="traefik.http.routers.${SUBDOMAIN}.tls=true" \
  --label="traefik.http.services.${SUBDOMAIN}.loadbalancer.server.port=$PLEX_CONTAINER_PORT" \
  --label="traefik.http.routers.${SUBDOMAIN}.entrypoints=websecure" \
  --label="traefik.http.routers.${SUBDOMAIN}.tls.certresolver=letsEncrypt" \
  --label="traefik.http.routers.${SUBDOMAIN}.priority=20" \
  --label="traefik.http.routers.${SUBDOMAIN}-http.rule=Host(\`${DOMAIN}\`)" \
  --label="traefik.http.routers.${SUBDOMAIN}-http.entrypoints=web" \
  --label="traefik.http.routers.${SUBDOMAIN}-http.middlewares=${SUBDOMAIN}-redirect" \
  --label="traefik.http.middlewares.${SUBDOMAIN}-redirect.redirectscheme.scheme=https" \
  --restart=unless-stopped \
  "$GLUETUN_IMAGE"

if [ $? -ne 0 ]; then
  cleanup "$USER_NUM" "Failed to launch Gluetun container"
fi

log "Waiting for container to initialize..."
sleep 5

log "Connecting Gluetun to $TRAEFIK_NETWORK"
docker network connect "$TRAEFIK_NETWORK" "$GLUETUN_ID" || {
  log "ERROR: Failed to connect to $TRAEFIK_NETWORK"
  log "Continuing without Traefik integration"
}

create_dns_record "$SUBDOMAIN" "$SERVER_IP" || log "WARNING: DNS record failed"

log "Checking Gluetun status"
docker logs "$GLUETUN_ID" | tail -n 10

# Increased wait time to 30 seconds for better stability
log "Waiting for VPN stabilization (30 seconds)..."
sleep 30

if ! docker ps | grep -q "$GLUETUN_ID"; then
  log "Container stopped unexpectedly, capturing final logs:"
  docker logs "$GLUETUN_ID" 2>&1 || true
  cleanup "$USER_NUM" "Gluetun container stopped unexpectedly"
fi

VPN_IP=$(docker exec "$GLUETUN_ID" curl -s ifconfig.me || echo "unknown")
if [[ "$VPN_IP" == "unknown" ]]; then
  log "⚠️ Could not get VPN IP—continuing anyway"
else
  log "✅ VPN IP: $VPN_IP"
fi

log "Ensuring iptables allows $PLEX_CONTAINER_PORT"
docker exec "$GLUETUN_ID" iptables -I INPUT -p tcp --dport $PLEX_CONTAINER_PORT -j ACCEPT || true

if ! check_vpn_connectivity "$GLUETUN_ID"; then
  log "⚠️ VPN connectivity tests failed—continuing at your discretion"
fi

# ====== REQUEST CLAIM & DEPLOY PLEX ======
read -p "Enter Plex claim code: " PLEX_CLAIM_CODE
[[ -z "$PLEX_CLAIM_CODE" ]] && { log "Claim code required."; exit 1; }

docker rm -f "$USER_ID" &>/dev/null || true
GLUETUN_ID_FULL=$(docker inspect -f '{{.Id}}' "$GLUETUN_ID" || echo "")
if [[ -z "$GLUETUN_ID_FULL" ]]; then
  cleanup "$USER_NUM" "Cannot find Gluetun container ID"
fi

log "Launching Plex container ($USER_ID)"
docker run -d \
  --name="$USER_ID" \
  --env="ADVERTISE_IP=https://${DOMAIN},http://${DOMAIN},http://${SERVER_IP}:${HOST_PORT},http://localhost:${PLEX_CONTAINER_PORT},https://localhost:${PLEX_CONTAINER_PORT}" \
  --env="PUID=$(echo $DOCKER_USER | cut -d: -f1)" \
  --env="PGID=$(echo $DOCKER_USER | cut -d: -f2)" \
  --env="PLEX_CLAIM=$PLEX_CLAIM_CODE" \
  --env="CHANGE_CONFIG_DIR_OWNERSHIP=false" \
  --env="VERSION=latest" \
  --env="PLEX_PREFERENCE_1=FriendlyName=$USER_ID" \
  --env="PLEX_PREFERENCE_2=EnableIPv6=$PLEX_PREFERENCE_ENABLE_IPV6" \
  --env="PLEX_PREFERENCE_3=DisableTLSv1_0=$PLEX_PREFERENCE_DISABLE_TLSV1_0" \
  --env="PLEX_PREFERENCE_4=EnableStreamLooping=$PLEX_PREFERENCE_ENABLE_STREAM_LOOPING" \
  --env="PLEX_PREFERENCE_5=DlnaMSMediaReceiverUDN=$PLEX_PREFERENCE_DLNA_MS_MEDIA_RECEIVER_UDN" \
  --env="PLEX_PREFERENCE_6=AcceptedEULA=$PLEX_PREFERENCE_ACCEPTED_EULA" \
  --env="PLEX_PREFERENCE_7=TranscoderThrottleBuffer=$PLEX_PREFERENCE_TRANSCODER_THROTTLE_BUFFER" \
  --env="PLEX_PREFERENCE_8=LanNetworksBandwidth=$PLEX_PREFERENCE_LAN_NETWORKS_BANDWIDTH" \
  --env="PLEX_PREFERENCE_9=AllowedNetworks=$PLEX_PREFERENCE_ALLOWED_NETWORKS" \
  -v "$CONFIG_PATH:/config" \
  -v "$CONFIG_PATH/Transcode:/transcode" \
  -v "$PLEX_MEDIA_PATH:/data:rw" \
  --network="container:$GLUETUN_ID_FULL" \
  --device $HARDWARE_ACCELERATION_DEVICE \
  --restart unless-stopped \
  "$PLEX_IMAGE"

if [ $? -ne 0 ]; then
  cleanup "$USER_NUM" "Failed to create Plex container"
fi

log "Waiting for Plex to initialize (30 seconds)..."
sleep 30

log "Testing Plex via VPN"
if docker exec "$GLUETUN_ID" curl -sf "http://localhost:$PLEX_CONTAINER_PORT/web" &>/dev/null; then
  log "✅ Plex accessible through VPN"
else
  log "⚠️ Plex may not be accessible—check logs:"
  docker logs "$USER_ID" | tail -n20
fi

# ====== SUMMARY ======
LOCAL_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$GLUETUN_ID")
cat <<EOF

======================================================================
              PLEX INSTANCE DEPLOYED SUCCESSFULLY
======================================================================
• Plex Container:     $USER_ID
• Gluetun Container:  $GLUETUN_ID
• Domain (SSL):       https://${DOMAIN}
• Direct Access:      http://${SERVER_IP}:${HOST_PORT}
• VPN Public IP:      $VPN_IP
• Local Docker IP:    $LOCAL_IP
• Config Directory:   $CONFIG_PATH
======================================================================
EOF

LOG_FILE="$CONFIG_PATH/deployment_info.log"
{
  echo "Deployment completed: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "Plex:     $USER_ID"
  echo "Gluetun:  $GLUETUN_ID"
  echo "Domain:   https://${DOMAIN}"
  echo "Direct:   http://${SERVER_IP}:${HOST_PORT}"
  echo "VPN IP:   $VPN_IP"
  echo "Local IP: $LOCAL_IP"
  echo "Config:   $CONFIG_PATH"
} > "$LOG_FILE"

# ====== AUTOMATED WORKFLOW ======
log "Starting automated workflow..."

# Step 1: Pass new user to inject_plex_libraries.sh
if [ -f "/root/Desktop/inject_plex_libraries.sh" ]; then
  log "Running library injection via inject_plex_libraries.sh..."
  /root/Desktop/inject_plex_libraries.sh -t "$USER_ID"
else
  log "Warning: inject_plex_libraries.sh not found, skipping library injection"
fi

# Step 2: Pass gluetun container ID to create-proxy.sh
if [ -f "/root/Desktop/create-proxy.sh" ]; then
  log "Creating proxy via create-proxy.sh..."
  /root/Desktop/create-proxy.sh "$USER_NUM"
else
  log "Warning: create-proxy.sh not found, skipping proxy creation"
fi

log "Workflow complete!"
