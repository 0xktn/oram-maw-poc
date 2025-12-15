# System Reference & Troubleshooting

## Component Overview

| Component | Technology | Role |
|-----------|------------|------|
| **O2RAM Engine** | Path ORAM in Python | Hides memory access patterns inside enclave |
| **ACB Router** | Python module | Routes data to ORAM or Standard pool based on sensitivity |
| **Trusted Compute** | AWS Nitro Enclaves | Isolated execution with hardware attestation |
| **Orchestrator** | Temporal | Manages workflow state and activity execution |
| **Key Management** | AWS KMS | Stores TSK, releases only to attested enclaves |

## Data Flow

```
┌─────────────┐     ┌─────────────┐     ┌─────────────────────────────┐
│   Temporal  │────▶│   Worker    │────▶│      Nitro Enclave          │
│   Server    │◀────│   (Host)    │◀────│                             │
└─────────────┘     └─────────────┘     │  ┌──────────────────────┐   │
                          │             │  │     ACB Router       │   │
                        vsock           │  └──────────┬───────────┘   │
                          │             │       ┌─────┴─────┐         │
                          ▼             │       ▼           ▼         │
                    Port 5000           │  ┌────────┐  ┌─────────┐    │
                                        │  │  ORAM  │  │Standard │    │
                                        │  │  Pool  │  │  Pool   │    │
                                        │  └────────┘  └─────────┘    │
                                        └─────────────────────────────┘
```

## Access Pattern Security

### ORAM Pool (Sensitive Data)
- Uses Path ORAM with binary tree structure
- Each access reads/writes an entire path (O(log N))
- Position remapped randomly after each access
- Observer cannot determine which block was accessed

### Standard Pool (High Volume)
- Direct key-value access (O(1))
- AES-256-GCM encryption
- Access patterns visible to host
- Appropriate for non-sensitive metadata

## Sensitivity-Based Routing

Keys are automatically routed based on prefix:

| Prefix | Pool | Rationale |
|--------|------|-----------|
| `session_key:` | ORAM | Ephemeral secrets |
| `secret:` | ORAM | General secrets |
| `token:` | ORAM | Auth tokens |
| `ephemeral:` | ORAM | Short-lived credentials |
| `credential:` | ORAM | User credentials |
| `private:` | ORAM | Private data |
| `workflow:` | Standard | State checkpoints |
| `metadata:` | Standard | Non-sensitive info |
| (other) | Standard | Default routing |

## Troubleshooting

### ORAM Stash Overflow

If stash grows too large, the ORAM may fail. Check:
```bash
./scripts/trigger.sh --verify
```

Solutions:
- Reduce concurrent access load
- Increase bucket capacity (Z parameter)
- Use larger block sizes

### vsock Connection Failed

```
{"status": "error", "msg": "vsock_error"}
```

Check enclave is running:
```bash
nitro-cli describe-enclaves
```

### KMS Decrypt Failed

Ensure PCR0 in KMS policy matches built enclave:
```bash
cat build/enclave.eif.json | jq -r '.Measurements.PCR0'
```
