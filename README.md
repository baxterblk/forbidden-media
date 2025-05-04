# forbidden-media

<div align="center">
  <img src="assets/forbidden_media_logo.png" alt="Forbidden Media logo" width="400">
</div>

# Forbidden Media

A secure, containerized solution for deploying isolated Plex Media Server instances behind VPN tunnels.

## Overview

Forbidden Media is a comprehensive toolset for deploying and managing isolated Plex Media Server instances, each running behind its own dedicated VPN tunnel. This solution provides enhanced privacy, security, and resource isolation for media server deployment.

## Key Features

- **Isolated Containers**: Each Plex instance runs in its own container with dedicated resources
- **VPN Enforcement**: All traffic is routed through a dedicated VPN tunnel using Gluetun
- **Domain & SSL Management**: Automatic domain registration and SSL certificate provisioning
- **Analytics Blocking**: Built-in blocking of Plex analytics and telemetry
- **Multi-user Support**: Easy deployment of multiple isolated instances
- **Traefik Integration**: Seamless reverse proxy integration with Traefik
- **Automated Workflow**: Built-in support for library injection and proxy configuration

## Prerequisites

- Docker and Docker Compose
- Cloudflare account with API access for DNS management
- WireGuard VPN subscription
- Traefik reverse proxy setup (optional)
- Existing Plex configuration to clone (optional)
- Hardware that supports virtualization and container technologies

## Configuration

Before using the script, you'll need to configure the following variables in the script:

```bash
# System Configuration
BASE_PLEX_CONFIG=""                          # Base configuration to clone
PLEX_CONFIG_ROOT=""                          # Root directory for all Plex configurations
SERVER_IP=""                                 # Public IP of the server

# Docker & Networking
PLEX_NETWORK=""                              # Docker network for Plex
TRAEFIK_NETWORK=""                           # Docker network for Traefik
PLEX_IMAGE="lscr.io/linuxserver/plex:latest" # Plex Docker image

# Domain & DNS
DOMAIN_SUFFIX=""                             # Domain suffix for the Plex instance
CF_ZONE_ID="YOUR_CLOUDFLARE_ZONE_ID"         # Cloudflare Zone ID
CF_API_TOKEN="YOUR_CLOUDFLARE_API_TOKEN"     # Cloudflare API Token

# WireGuard VPN Configuration
VPN_SERVICE_PROVIDER=""                      # VPN service provider
VPN_TYPE=""                                  # VPN protocol type
WIREGUARD_PRIVATE_KEY="YOUR_PRIVATE_KEY"     # WireGuard private key
WIREGUARD_ADDRESSES="0.0.0.0/32"             # WireGuard internal IP address
WIREGUARD_PUBLIC_KEY="YOUR_PUBLIC_KEY"       # WireGuard public key
WIREGUARD_ENDPOINT_IP="Endpoint IP"          # WireGuard server IP
WIREGUARD_ENDPOINT_PORT="51820"              # WireGuard server port
SERVER_CITIES="Server City"                  # Preferred server location
```

Additional configuration options include firewall settings, container configuration, storage paths, and Plex preferences.

## Usage

1. Clone this repository:
   ```bash
   git clone https://github.com/baxterblk/forbidden-media.git
   cd forbidden-media
   ```

2. Edit the configuration variables in the script:
   ```bash
   nano new-user.sh
   ```

3. Make the script executable:
   ```bash
   chmod +x new-user.sh
   ```

4. Run the script:
   ```bash
   ./new-user.sh
   ```

5. When prompted, enter your Plex claim code (obtain from https://www.plex.tv/claim/)

6. After successful deployment, you'll receive connection details including:
   - Plex Container name
   - Gluetun Container name
   - Domain name (with SSL)
   - Direct access URL
   - VPN Public IP
   - Local Docker IP
   - Configuration directory

## Deployment Process

The script performs the following steps:
1. Validates system prerequisites and connectivity
2. Generates a unique user ID and configuration
3. Creates necessary configuration directories
4. Deploys Gluetun VPN container with WireGuard configuration
5. Creates DNS records for the new instance
6. Tests VPN connectivity
7. Deploys Plex container connected to the VPN container
8. Executes automated workflows for library injection and proxy setup

## Advanced Workflows

The script includes hooks for additional automation:
- `inject_plex_libraries.sh` - Automatically adds libraries to the new Plex instance
- `create-proxy.sh` - Creates additional proxy configuration for the VPN container

## Troubleshooting

- **VPN Connection Issues**: Check the Gluetun container logs (`docker logs gluetun-XXXX`)
- **Plex Access Problems**: Verify the firewall settings and port forwarding
- **DNS Resolution Failures**: Confirm Cloudflare API settings and DNS propagation

## Security Considerations

- All sensitive configuration data (including API tokens and WireGuard keys) should be properly secured
- The script blocks Plex analytics and telemetry hosts by default
- Traffic is strictly enforced through the VPN tunnel
- Firewall rules are configured to limit inbound and outbound traffic

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the LICENSE file for details.