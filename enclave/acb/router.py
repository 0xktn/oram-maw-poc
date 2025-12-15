"""
ACB Router - Sensitivity-based Data Routing

Routes data to either ORAM-protected pool (for sensitive data)
or Standard pool (for high-volume, less-sensitive data).
"""

from typing import Optional, Tuple, List
from .standard_pool import StandardPool

# Handle both relative and absolute imports
try:
    from ..oram import ORAMPool
except ImportError:
    from oram import ORAMPool


class ACBRouter:
    """
    Attested Confidential Blackboard Router.
    
    Routes data to appropriate pool based on sensitivity level:
    - ORAM Pool: Session keys, ephemeral credentials, secrets
    - Standard Pool: Workflow state, metadata, high-volume data
    
    This implements the compartmentalization principle where
    security overhead is proportional to data sensitivity.
    """
    
    # Prefixes that indicate sensitive data requiring ORAM protection
    SENSITIVE_PREFIXES: List[str] = [
        'session_key:',
        'ephemeral:',
        'secret:',
        'credential:',
        'private:',
        'token:',
    ]
    
    def __init__(
        self,
        oram_capacity: int = 256,
        oram_block_size: int = 256,
        encryption_key: Optional[bytes] = None
    ):
        """
        Initialize ACB Router with both pools.
        
        Args:
            oram_capacity: Max entries in ORAM pool
            oram_block_size: Block size for ORAM pool
            encryption_key: Shared encryption key (generated if not provided)
        """
        import os
        self.encryption_key = encryption_key or os.urandom(32)
        
        self.oram_pool = ORAMPool(
            capacity=oram_capacity,
            block_size=oram_block_size,
            encryption_key=self.encryption_key
        )
        
        self.standard_pool = StandardPool(
            encryption_key=self.encryption_key
        )
        
        # Routing metrics
        self.oram_routes = 0
        self.standard_routes = 0
    
    def _is_sensitive(self, key: str) -> bool:
        """Determine if a key should be routed to ORAM pool."""
        key_lower = key.lower()
        return any(key_lower.startswith(prefix) for prefix in self.SENSITIVE_PREFIXES)
    
    def store(self, key: str, value: bytes) -> dict:
        """
        Store data in the appropriate pool based on sensitivity.
        
        Args:
            key: Data key (prefix determines routing)
            value: Data to store
            
        Returns:
            Metrics dict including pool type and access info
        """
        if self._is_sensitive(key):
            self.oram_routes += 1
            result = self.oram_pool.store(key, value)
            result['routed_to'] = 'oram'
            result['reason'] = 'sensitive_prefix'
        else:
            self.standard_routes += 1
            result = self.standard_pool.store(key, value)
            result['routed_to'] = 'standard'
            result['reason'] = 'non_sensitive'
        
        return result
    
    def retrieve(self, key: str) -> Tuple[Optional[bytes], dict]:
        """
        Retrieve data from the appropriate pool.
        
        Args:
            key: Data key
            
        Returns:
            Tuple of (data, metrics)
        """
        if self._is_sensitive(key):
            data, metrics = self.oram_pool.retrieve(key)
            metrics['routed_from'] = 'oram'
        else:
            data, metrics = self.standard_pool.retrieve(key)
            metrics['routed_from'] = 'standard'
        
        return data, metrics
    
    def get_metrics(self) -> dict:
        """Get comprehensive routing and pool metrics."""
        return {
            'routing': {
                'oram_routes': self.oram_routes,
                'standard_routes': self.standard_routes,
                'total_routes': self.oram_routes + self.standard_routes,
                'oram_percentage': (
                    self.oram_routes / (self.oram_routes + self.standard_routes) * 100
                    if (self.oram_routes + self.standard_routes) > 0 else 0
                )
            },
            'oram_pool': self.oram_pool.get_metrics(),
            'standard_pool': self.standard_pool.get_metrics()
        }
    
    def get_security_summary(self) -> str:
        """Get a human-readable security summary."""
        metrics = self.get_metrics()
        return f"""
ACB Security Summary:
=====================
ORAM-Protected Accesses: {metrics['routing']['oram_routes']}
Standard Accesses: {metrics['routing']['standard_routes']}
ORAM Usage: {metrics['routing']['oram_percentage']:.1f}%

ORAM Pool Status:
- Entries: {metrics['oram_pool']['entries']}
- Stash Size: {metrics['oram_pool']['stash_size']}
- Tree Height: {metrics['oram_pool']['tree_height']}

Standard Pool Status:
- Entries: {metrics['standard_pool']['entries']}
"""
