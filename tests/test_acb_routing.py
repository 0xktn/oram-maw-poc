"""
Unit Tests for ACB Router

Tests sensitivity-based routing between ORAM and Standard pools.
"""

import pytest
import os
import sys

# Add enclave to path for imports
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'enclave'))

from acb.router import ACBRouter
from acb.standard_pool import StandardPool


class TestStandardPool:
    """Tests for StandardPool."""
    
    def test_store_and_retrieve(self):
        pool = StandardPool()
        
        pool.store("my_key", b"my_value")
        data, metrics = pool.retrieve("my_key")
        
        assert data == b"my_value"
        assert metrics['pool'] == 'standard'
    
    def test_delete(self):
        pool = StandardPool()
        
        pool.store("key", b"value")
        assert pool.delete("key") is True
        
        data, _ = pool.retrieve("key")
        assert data is None
    
    def test_encryption(self):
        pool = StandardPool()
        
        pool.store("key", b"plaintext_value")
        
        # Stored data should be encrypted (different from plaintext)
        encrypted = pool.storage["key"]
        assert encrypted != b"plaintext_value"
        assert len(encrypted) > len(b"plaintext_value")  # Includes nonce


class TestACBRouter:
    """Tests for ACBRouter sensitivity-based routing."""
    
    def test_route_sensitive_to_oram(self):
        router = ACBRouter()
        
        # Session keys should go to ORAM
        result = router.store("session_key:user_123", b"secret_session")
        
        assert result['routed_to'] == 'oram'
        assert result['reason'] == 'sensitive_prefix'
    
    def test_route_standard_to_standard(self):
        router = ACBRouter()
        
        # Regular keys should go to Standard pool
        result = router.store("workflow:checkpoint_1", b"state_data")
        
        assert result['routed_to'] == 'standard'
        assert result['reason'] == 'non_sensitive'
    
    def test_all_sensitive_prefixes(self):
        router = ACBRouter()
        
        sensitive_keys = [
            "session_key:test",
            "ephemeral:temp",
            "secret:password",
            "credential:user",
            "private:data",
            "token:auth"
        ]
        
        for key in sensitive_keys:
            result = router.store(key, b"value")
            assert result['routed_to'] == 'oram', f"Key {key} should route to ORAM"
    
    def test_retrieve_routed_correctly(self):
        router = ACBRouter()
        
        # Store in each pool
        router.store("secret:password", b"sensitive_value")
        router.store("config:setting", b"regular_value")
        
        # Retrieve and check routing
        data1, metrics1 = router.retrieve("secret:password")
        data2, metrics2 = router.retrieve("config:setting")
        
        assert data1 == b"sensitive_value"
        assert metrics1['routed_from'] == 'oram'
        
        assert data2 == b"regular_value"
        assert metrics2['routed_from'] == 'standard'
    
    def test_metrics(self):
        router = ACBRouter()
        
        router.store("secret:a", b"1")
        router.store("secret:b", b"2")
        router.store("data:c", b"3")
        
        metrics = router.get_metrics()
        
        assert metrics['routing']['oram_routes'] == 2
        assert metrics['routing']['standard_routes'] == 1
        assert metrics['routing']['total_routes'] == 3
    
    def test_case_insensitive_routing(self):
        router = ACBRouter()
        
        # Should recognize prefix regardless of case
        result1 = router.store("SESSION_KEY:upper", b"value")
        result2 = router.store("Session_Key:mixed", b"value")
        
        assert result1['routed_to'] == 'oram'
        assert result2['routed_to'] == 'oram'
    
    def test_security_summary(self):
        router = ACBRouter()
        
        router.store("secret:x", b"1")
        router.store("data:y", b"2")
        
        summary = router.get_security_summary()
        
        assert "ORAM-Protected Accesses: 1" in summary
        assert "Standard Accesses: 1" in summary


class TestCompartmentalization:
    """Tests that demonstrate the compartmentalization security model."""
    
    def test_mixed_workload(self):
        """Simulate a realistic mixed workload."""
        router = ACBRouter()
        
        # High-volume workflow state (should use fast Standard pool)
        for i in range(100):
            router.store(f"workflow:step_{i}", f"state_{i}".encode())
        
        # Sensitive session keys (should use secure ORAM pool)
        for i in range(10):
            router.store(f"session_key:session_{i}", f"secret_{i}".encode())
        
        metrics = router.get_metrics()
        
        # Verify routing distribution
        assert metrics['routing']['standard_routes'] == 100
        assert metrics['routing']['oram_routes'] == 10
        
        # ORAM should be ~9% of total (acceptable overhead)
        oram_pct = metrics['routing']['oram_percentage']
        assert oram_pct < 20  # Less than 20% in ORAM


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
