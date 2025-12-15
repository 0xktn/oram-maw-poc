"""
ORAM-MAW Enclave Application

Main enclave application with O2RAM (Doubly Oblivious RAM) protection.
Combines Path ORAM with Nitro Enclave TEE for complete access pattern hiding.
"""

import json
import os
import socket
import subprocess
import base64
import sys
from datetime import datetime
from typing import Optional
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

# Import ORAM components
from acb import ACBRouter

print("[ENCLAVE] Starting ORAM-MAW Enclave Application...", flush=True)

# Global State
CREDENTIALS = {
    'ak': None,
    'sk': None,
    'token': None
}
ENCRYPTION_KEY: Optional[bytes] = None  # 32-byte TSK from KMS
ACB: Optional[ACBRouter] = None  # Compartmentalized storage


def kms_decrypt(ciphertext_b64: str) -> tuple:
    """
    Decrypt ciphertext using KMS with hardware attestation.
    
    The attestation document is automatically generated and validated
    by KMS, which only decrypts if PCR0 matches the policy.
    """
    print(f"[ENCLAVE] Decrypting ciphertext len={len(ciphertext_b64)}", flush=True)
    try:
        cmd = [
            '/usr/bin/kmstool_enclave_cli', 'decrypt',
            '--region', 'ap-southeast-1',
            '--proxy-port', '8000',
            '--aws-access-key-id', CREDENTIALS['ak'],
            '--aws-secret-access-key', CREDENTIALS['sk'],
            '--aws-session-token', CREDENTIALS['token'],
            '--ciphertext', ciphertext_b64
        ]

        env = os.environ.copy()
        env['AWS_COMMON_RUNTIME_LOG_LEVEL'] = 'Trace'

        result = subprocess.run(
            cmd, capture_output=True, text=True, check=True, env=env
        )

        stdout = result.stdout.strip()

        # Parse PLAINTEXT: <base64>
        marker = "PLAINTEXT:"
        if marker in stdout:
            payload = stdout.split(marker, 1)[1].strip()
            return (base64.b64decode(payload), None)
        return (base64.b64decode(stdout), None)

    except subprocess.CalledProcessError as e:
        err_msg = e.stderr.strip()
        print(f"[ERROR] KMS Tool Failed: {err_msg}", flush=True)
        return (None, err_msg)
    except Exception as e:
        err_msg = str(e)
        print(f"[ERROR] KMS Decrypt Exception: {err_msg}", flush=True)
        return (None, err_msg)


def handle_configure(req: dict) -> dict:
    """Handle configuration request - setup credentials and initialize ACB."""
    global CREDENTIALS, ENCRYPTION_KEY, ACB
    
    required_fields = ['aws_access_key_id', 'aws_secret_access_key', 
                       'aws_session_token', 'encrypted_tsk']
    missing = [f for f in required_fields if not req.get(f)]

    if missing:
        print(f"[ENCLAVE] ERROR: Missing required fields: {missing}", flush=True)
        return {"status": "error", "msg": "missing_fields", "details": f"Required: {missing}"}

    CREDENTIALS['ak'] = req.get('aws_access_key_id')
    CREDENTIALS['sk'] = req.get('aws_secret_access_key')
    CREDENTIALS['token'] = req.get('aws_session_token')
    tsk_b64 = req.get('encrypted_tsk')

    print(f"[ENCLAVE] Configuring with credentials (ak={CREDENTIALS['ak'][:10]}...)", flush=True)
    print("[ENCLAVE] Decrypting TSK with KMS attestation...", flush=True)

    tsk_bytes, err_details = kms_decrypt(tsk_b64)
    if tsk_bytes:
        ENCRYPTION_KEY = tsk_bytes
        
        # Initialize ACB with ORAM and Standard pools
        ACB = ACBRouter(
            oram_capacity=256,
            oram_block_size=256,
            encryption_key=ENCRYPTION_KEY
        )
        
        print(f"[ENCLAVE] ✅ TSK decrypted successfully! (len={len(ENCRYPTION_KEY)})", flush=True)
        print(f"[ENCLAVE] ✅ ACB initialized with O2RAM protection", flush=True)
        print(f"[ENCLAVE] ✅ Configured at {datetime.utcnow().isoformat()}", flush=True)

        return {
            "status": "ok",
            "msg": "configured",
            "timestamp": datetime.utcnow().isoformat(),
            "acb_enabled": True,
            "oram_enabled": True
        }
    else:
        print(f"[ENCLAVE] ❌ KMS decrypt failed: {err_details}", flush=True)
        return {"status": "error", "msg": "kms_decrypt_failed", "details": err_details}


def handle_store(req: dict) -> dict:
    """Handle store request - route to appropriate pool based on sensitivity."""
    global ACB
    
    if not ACB:
        return {"status": "error", "msg": "not_configured", "details": "Call configure first"}
    
    key = req.get('key')
    value = req.get('value')
    
    if not key or value is None:
        return {"status": "error", "msg": "missing_params", "details": "key and value required"}
    
    # Convert value to bytes if string
    if isinstance(value, str):
        value = value.encode('utf-8')
    elif isinstance(value, dict):
        value = json.dumps(value).encode('utf-8')
    
    metrics = ACB.store(key, value)
    
    print(f"[ENCLAVE] Stored '{key}' via {metrics['routed_to']} pool", flush=True)
    
    return {
        "status": "ok",
        "msg": "stored",
        "key": key,
        **metrics
    }


def handle_retrieve(req: dict) -> dict:
    """Handle retrieve request - access via appropriate pool."""
    global ACB
    
    if not ACB:
        return {"status": "error", "msg": "not_configured", "details": "Call configure first"}
    
    key = req.get('key')
    if not key:
        return {"status": "error", "msg": "missing_params", "details": "key required"}
    
    data, metrics = ACB.retrieve(key)
    
    if data is None:
        print(f"[ENCLAVE] Key '{key}' not found", flush=True)
        return {
            "status": "ok",
            "msg": "not_found",
            "key": key,
            **metrics
        }
    
    print(f"[ENCLAVE] Retrieved '{key}' via {metrics['routed_from']} pool", flush=True)
    
    # Try to decode as string or JSON
    try:
        value = data.decode('utf-8')
        try:
            value = json.loads(value)
        except json.JSONDecodeError:
            pass
    except UnicodeDecodeError:
        value = base64.b64encode(data).decode('ascii')
    
    return {
        "status": "ok",
        "msg": "retrieved",
        "key": key,
        "value": value,
        **metrics
    }


def handle_metrics(req: dict) -> dict:
    """Handle metrics request - return ACB performance metrics."""
    global ACB
    
    if not ACB:
        return {"status": "error", "msg": "not_configured"}
    
    metrics = ACB.get_metrics()
    return {
        "status": "ok",
        "msg": "metrics",
        **metrics
    }


def run_server():
    """Main vsock server loop."""
    global ENCRYPTION_KEY
    cid = socket.VMADDR_CID_ANY
    port = 5000

    try:
        s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
        s.bind((cid, port))
        s.listen(5)
        print(f"[ENCLAVE] Listening on {cid}:{port}", flush=True)
        print("[ENCLAVE] O2RAM Protection: ENABLED", flush=True)
    except Exception as e:
        print(f"[FATAL] Bind failed: {e}", flush=True)
        return

    while True:
        try:
            conn, addr = s.accept()
            print(f"[ENCLAVE] Connect from {addr}", flush=True)

            data = conn.recv(16384)
            if not data:
                conn.close()
                continue

            try:
                msg = data.decode('utf-8')
                req = json.loads(msg)
                msg_type = req.get('type')

                response = {"status": "error", "msg": "unknown_type"}

                if msg_type == 'ping':
                    response = {"status": "ok", "msg": "pong", "oram_enabled": True}

                elif msg_type == 'configure':
                    response = handle_configure(req)

                elif msg_type == 'store':
                    response = handle_store(req)

                elif msg_type == 'retrieve':
                    response = handle_retrieve(req)

                elif msg_type == 'metrics':
                    response = handle_metrics(req)

                elif msg_type == 'health':
                    response = {
                        "status": "healthy",
                        "configured": bool(ENCRYPTION_KEY),
                        "acb_enabled": bool(ACB),
                        "timestamp": datetime.utcnow().isoformat()
                    }

                conn.sendall(json.dumps(response).encode('utf-8'))

            except json.JSONDecodeError:
                conn.sendall(b'{"status": "error", "msg": "invalid_json"}')
            except Exception as e:
                print(f"[ERROR] Handler failed: {e}", flush=True)
                conn.sendall(b'{"status": "error", "msg": "internal_error"}')

            conn.close()

        except Exception as e:
            print(f"[FATAL] Loop error: {e}", flush=True)


if __name__ == "__main__":
    run_server()
