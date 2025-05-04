#!/usr/bin/env python3
"""
NGINX Proxy Manager - Proxy Host Creator

This script creates a new proxy host in NGINX Proxy Manager via its API.
It follows the pattern found in existing proxy hosts.

Usage:
    python3 npm-create-proxy.py --id STRING [--username USERNAME] [--password PASSWORD] [--url URL]

Example:
    python3 npm-create-proxy.py --id 1234
    python3 npm-create-proxy.py --id test-server
"""

import argparse
import json
import logging
import sys
import requests
import urllib3

# ===== CONFIGURATION (EDIT THESE VALUES) =====
# NPM API credentials
DEFAULT_USERNAME = "admin@example.com"  # Your NGINX Proxy Manager admin username
DEFAULT_PASSWORD = "changeme"           # Your NGINX Proxy Manager admin password
DEFAULT_URL = "http://localhost:81"     # URL where your NPM API is accessible (typically port 81)

# Proxy host template
DOMAIN_SUFFIX = "your-domain.xyz"       # Your domain name without subdomain (e.g., example.com)
FORWARD_PORT = 32400                    # Port the proxy will forward to (Plex default is 32400)
CERTIFICATE_ID = 1                      # ID of the certificate to use from NPM (usually 1 for the default cert)
SSL_FORCED = True                       # Whether to force SSL/HTTPS connections
CACHING_ENABLED = True                  # Whether to enable response caching
BLOCK_EXPLOITS = True                   # Whether to enable NPM's exploit blocking feature
WEBSOCKET_UPGRADE = True                # Whether to allow WebSocket connections
HTTP2_SUPPORT = True                    # Whether to enable HTTP/2 protocol
HSTS_ENABLED = True                     # Whether to enable HTTP Strict Transport Security
HSTS_SUBDOMAINS = True                  # Whether HSTS applies to subdomains too
# ===========================================

# Disable SSL warnings for self-signed certificates
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

class NPMClient:
    """Client for interacting with NGINX Proxy Manager API"""
    
    def __init__(self, base_url=DEFAULT_URL, username=DEFAULT_USERNAME, password=DEFAULT_PASSWORD):
        """Initialize the client with credentials"""
        self.base_url = base_url
        self.username = username
        self.password = password
        self.token = None
        self.headers = {"Content-Type": "application/json"}
    
    def authenticate(self):
        """Authenticate with the API and get a token"""
        auth_url = f"{self.base_url}/api/tokens"
        payload = {
            "identity": self.username,
            "secret": self.password
        }
        
        try:
            logger.info("Authenticating with NGINX Proxy Manager...")
            response = requests.post(auth_url, json=payload, headers=self.headers, verify=False)
            response.raise_for_status()
            
            data = response.json()
            self.token = data.get("token")
            if self.token:
                logger.info("Authentication successful")
                self.headers["Authorization"] = f"Bearer {self.token}"
                return True
            else:
                logger.error("No token received in authentication response")
                return False
                
        except requests.exceptions.RequestException as e:
            logger.error(f"Authentication failed: {e}")
            return False
    
    def create_proxy_host(self, id_string):
        """Create a new proxy host with the given ID string"""
        if not self.token:
            if not self.authenticate():
                logger.error("Cannot create proxy host without authentication")
                return False
        
        proxy_url = f"{self.base_url}/api/nginx/proxy-hosts"
        
        # Template based on existing proxy hosts and config variables
        proxy_config = {
            "domain_names": [f"user-{id_string}.{DOMAIN_SUFFIX}"],
            "forward_scheme": "http",
            "forward_host": f"{id_string}",  # Use container ID directly without gluetun- prefix
            "forward_port": FORWARD_PORT,
            "certificate_id": CERTIFICATE_ID,
            "ssl_forced": SSL_FORCED,
            "caching_enabled": CACHING_ENABLED,
            "block_exploits": BLOCK_EXPLOITS,
            "allow_websocket_upgrade": WEBSOCKET_UPGRADE,
            "http2_support": HTTP2_SUPPORT,
            "hsts_enabled": HSTS_ENABLED,
            "hsts_subdomains": HSTS_SUBDOMAINS,
            "enabled": True,
            "meta": {
                "letsencrypt_agree": False,
                "dns_challenge": False,
                "nginx_online": True
            }
        }
        
        try:
            logger.info(f"Creating proxy host for ID: {id_string}...")
            response = requests.post(proxy_url, json=proxy_config, headers=self.headers, verify=False)
            response.raise_for_status()
            
            data = response.json()
            logger.info(f"Successfully created proxy host: {data.get('id')}")
            logger.info(f"Domain: user-{id_string}.{DOMAIN_SUFFIX}")
            return True
                
        except requests.exceptions.RequestException as e:
            logger.error(f"Failed to create proxy host: {e}")
            if hasattr(e, 'response') and e.response:
                logger.error(f"Response: {e.response.text}")
            return False

def main():
    """Main function to parse arguments and run the script"""
    parser = argparse.ArgumentParser(description="Create a proxy host in NGINX Proxy Manager")
    parser.add_argument("--id", required=True, help="The ID string for the proxy host (e.g., '1234' or 'test')")
    parser.add_argument("--username", default=DEFAULT_USERNAME, help="Username for NPM login")
    parser.add_argument("--password", default=DEFAULT_PASSWORD, help="Password for NPM login")
    parser.add_argument("--url", default=DEFAULT_URL, help="Base URL for NPM API")
    
    args = parser.parse_args()
    
    # Get the ID string directly - no validation needed as we accept any string
    id_string = args.id
    
    client = NPMClient(
        base_url=args.url,
        username=args.username,
        password=args.password
    )
    
    if client.create_proxy_host(id_string):
        logger.info("Proxy host creation completed successfully")
        sys.exit(0)
    else:
        logger.error("Proxy host creation failed")
        sys.exit(1)

if __name__ == "__main__":
    main()
