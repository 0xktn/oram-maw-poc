# ORAM Concepts

## What is Oblivious RAM (ORAM)?

ORAM is a cryptographic technique that hides **access patterns** from an adversary who can observe memory operations. Even if data is encrypted, an observer might learn sensitive information by watching *which* locations are accessed and *how often*.

### Example Attack: Access Pattern Leak

```
Without ORAM:
  Access[1] → Block A
  Access[2] → Block B
  Access[3] → Block A  ← Observer sees "A accessed twice"
  
With ORAM:
  Access[1] → Read path to leaf 7, evict
  Access[2] → Read path to leaf 3, evict  
  Access[3] → Read path to leaf 5, evict  ← All accesses look similar
```

## Path ORAM

This POC uses **Path ORAM**, which organizes data in a binary tree:

```
                    [Root Bucket]
                    /          \
            [Bucket]          [Bucket]
            /      \          /      \
       [Leaf 0] [Leaf 1] [Leaf 2] [Leaf 3]
```

### Key Properties

1. **Position Map**: Each block is mapped to a random leaf
2. **Path Invariant**: Block is stored somewhere on path from root to its leaf
3. **Access Protocol**: Read entire path → update stash → write back
4. **Remapping**: Assign new random leaf after each access

### Complexity

- **Access**: O(log N) - must read one tree path
- **Storage**: O(N) - tree nodes plus stash
- **Stash**: O(log N) expected size

## Doubly Oblivious RAM (O2RAM)

When ORAM runs inside a TEE (Trusted Execution Environment), we get **doubly oblivious** protection:

- **First layer**: TEE hides computation from host OS
- **Second layer**: ORAM hides access patterns within the TEE

This protects against:
- Malicious cloud providers
- Compromised hypervisors
- Side-channel attacks on memory access

## Compartmentalization

Not all data needs ORAM protection. This POC uses **compartmentalized** storage:

| Data Type | Pool | Access Time | Security |
|-----------|------|-------------|----------|
| Session keys | ORAM | O(log N) | Access pattern hidden |
| Ephemeral tokens | ORAM | O(log N) | Access pattern hidden |
| Workflow state | Standard | O(1) | Encrypted only |
| Metadata | Standard | O(1) | Encrypted only |

### Why Compartmentalize?

ORAM has overhead. Using it universally would make the system too slow. By routing only sensitive data to ORAM, we achieve:

- **Acceptable latency** for high-volume state
- **Strong protection** for critical secrets
- **Practical real-world deployment**

## References

- [Path ORAM Paper (Stefanov et al.)](https://eprint.iacr.org/2013/280.pdf)
- [Oblix: Oblivious Search Index](https://eprint.iacr.org/2019/1089.pdf)
- [H2O2RAM (USENIX Security '24)](https://www.usenix.org/conference/usenixsecurity24/presentation/dauterman-h2o2ram)
