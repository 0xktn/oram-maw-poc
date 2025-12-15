"""
Temporal Activities for ORAM-MAW POC

Activities that communicate with the ORAM-enabled enclave
via vsock to demonstrate compartmentalized state protection.
"""

import json
import socket
import os
import time
from dataclasses import dataclass
from typing import Optional
from temporalio import activity

# Enclave connection settings
ENCLAVE_CID = 16  # Default parent CID for Nitro Enclaves
ENCLAVE_PORT = 5000


@dataclass
class EnclaveConfig:
    """Configuration for enclave initialization."""
    aws_access_key_id: str
    aws_secret_access_key: str
    aws_session_token: str
    encrypted_tsk: str


def send_to_enclave(request: dict, timeout: int = 30) -> dict:
    """
    Send a request to the enclave and receive response.
    
    Args:
        request: JSON-serializable request dict
        timeout: Socket timeout in seconds
        
    Returns:
        Response dict from enclave
    """
    try:
        sock = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        sock.connect((ENCLAVE_CID, ENCLAVE_PORT))
        
        # Send request
        request_bytes = json.dumps(request).encode('utf-8')
        sock.sendall(request_bytes)
        
        # Receive response
        response_bytes = sock.recv(16384)
        sock.close()
        
        return json.loads(response_bytes.decode('utf-8'))
        
    except socket.error as e:
        return {"status": "error", "msg": "vsock_error", "details": str(e)}
    except json.JSONDecodeError as e:
        return {"status": "error", "msg": "json_error", "details": str(e)}


# Global configuration state
_enclave_configured = False


@activity.defn
async def configure_enclave(config: dict) -> dict:
    """
    Configure the enclave with credentials and TSK.
    
    This must be called before any ORAM operations.
    The enclave will use hardware attestation to decrypt the TSK from KMS.
    """
    global _enclave_configured
    
    activity.logger.info("Configuring enclave with O2RAM support...")
    
    response = send_to_enclave({
        "type": "configure",
        "aws_access_key_id": config["aws_access_key_id"],
        "aws_secret_access_key": config["aws_secret_access_key"],
        "aws_session_token": config["aws_session_token"],
        "encrypted_tsk": config["encrypted_tsk"]
    })
    
    if response.get("status") == "ok":
        _enclave_configured = True
        activity.logger.info(f"Enclave configured with O2RAM at {response.get('timestamp')}")
    else:
        activity.logger.error(f"Enclave configuration failed: {response}")
    
    return response


@activity.defn
async def store_sensitive_data(key: str, value: str) -> dict:
    """
    Store sensitive data in the ORAM-protected pool.
    
    Keys with sensitive prefixes (session_key:, secret:, token:, etc.)
    are automatically routed to the ORAM pool for access pattern hiding.
    
    Args:
        key: Data key (prefix determines pool routing)
        value: Data value to store
        
    Returns:
        Storage result with routing metrics
    """
    activity.logger.info(f"Storing data with key: {key}")
    
    response = send_to_enclave({
        "type": "store",
        "key": key,
        "value": value
    })
    
    routed_to = response.get("routed_to", "unknown")
    activity.logger.info(f"Data stored via {routed_to} pool")
    
    return response


@activity.defn
async def retrieve_sensitive_data(key: str) -> dict:
    """
    Retrieve data from the appropriate pool.
    
    ORAM pool retrieval hides access patterns even from the host.
    
    Args:
        key: Data key to retrieve
        
    Returns:
        Retrieved data with access metrics
    """
    activity.logger.info(f"Retrieving data with key: {key}")
    
    response = send_to_enclave({
        "type": "retrieve",
        "key": key
    })
    
    routed_from = response.get("routed_from", "unknown")
    activity.logger.info(f"Data retrieved from {routed_from} pool")
    
    return response


@activity.defn
async def get_acb_metrics() -> dict:
    """
    Get ACB (Attested Confidential Blackboard) metrics.
    
    Returns metrics showing ORAM vs Standard pool usage,
    demonstrating the compartmentalization in action.
    """
    activity.logger.info("Fetching ACB metrics...")
    
    response = send_to_enclave({"type": "metrics"})
    
    if response.get("status") == "ok":
        routing = response.get("routing", {})
        activity.logger.info(
            f"ACB Metrics - ORAM: {routing.get('oram_routes', 0)}, "
            f"Standard: {routing.get('standard_routes', 0)}"
        )
    
    return response


@activity.defn
async def ping_enclave() -> dict:
    """Ping the enclave to check if it's responsive."""
    activity.logger.info("Pinging enclave...")
    
    response = send_to_enclave({"type": "ping"})
    
    if response.get("status") == "ok":
        activity.logger.info("Enclave responded with pong")
    else:
        activity.logger.error(f"Enclave ping failed: {response}")
    
    return response


@activity.defn  
async def health_check() -> dict:
    """Check enclave health status including O2RAM state."""
    activity.logger.info("Checking enclave health...")
    
    response = send_to_enclave({"type": "health"})
    
    configured = response.get("configured", False)
    acb_enabled = response.get("acb_enabled", False)
    
    activity.logger.info(
        f"Health: configured={configured}, acb_enabled={acb_enabled}"
    )
    
    return response
