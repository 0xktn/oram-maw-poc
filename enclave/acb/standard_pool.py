"""
Standard Memory Pool with AES-256-GCM Encryption

This module provides a standard encrypted memory pool for
high-volume, less-sensitive data that doesn't require ORAM protection.
"""

import os
from typing import Dict, Optional, Tuple
from cryptography.hazmat.primitives.ciphers.aead import AESGCM


class StandardPool:
    """
    Standard encrypted memory pool (non-ORAM).
    
    Uses AES-256-GCM for encryption but does NOT hide access patterns.
    Suitable for high-volume data where access pattern leakage is acceptable.
    
    Performance: O(1) access time
    Security: Confidentiality only (no access pattern hiding)
    """
    
    def __init__(self, encryption_key: Optional[bytes] = None):
        """
        Initialize standard pool.
        
        Args:
            encryption_key: 32-byte AES key (generated if not provided)
        """
        self.encryption_key = encryption_key or os.urandom(32)
        self.aesgcm = AESGCM(self.encryption_key)
        self.storage: Dict[str, bytes] = {}  # key -> encrypted_value
        self.access_count = 0
    
    def _encrypt(self, plaintext: bytes) -> bytes:
        """Encrypt data with AES-256-GCM."""
        nonce = os.urandom(12)
        ciphertext = self.aesgcm.encrypt(nonce, plaintext, None)
        return nonce + ciphertext
    
    def _decrypt(self, encrypted: bytes) -> bytes:
        """Decrypt data."""
        nonce = encrypted[:12]
        ciphertext = encrypted[12:]
        return self.aesgcm.decrypt(nonce, ciphertext, None)
    
    def store(self, key: str, value: bytes) -> dict:
        """Store a value with encryption (O(1) access)."""
        self.access_count += 1
        encrypted = self._encrypt(value)
        self.storage[key] = encrypted
        return {
            'pool': 'standard',
            'access_count': self.access_count,
            'overhead': 'O(1)'
        }
    
    def retrieve(self, key: str) -> Tuple[Optional[bytes], dict]:
        """Retrieve a value (O(1) access)."""
        self.access_count += 1
        
        if key not in self.storage:
            return None, {'pool': 'standard', 'found': False}
        
        encrypted = self.storage[key]
        plaintext = self._decrypt(encrypted)
        
        return plaintext, {
            'pool': 'standard',
            'found': True,
            'access_count': self.access_count
        }
    
    def delete(self, key: str) -> bool:
        """Delete a key from storage."""
        if key in self.storage:
            del self.storage[key]
            return True
        return False
    
    def get_metrics(self) -> dict:
        """Get pool metrics."""
        return {
            'pool_type': 'standard',
            'entries': len(self.storage),
            'access_count': self.access_count,
            'overhead': 'O(1)'
        }
