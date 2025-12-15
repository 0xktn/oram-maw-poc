"""
Unit Tests for Path ORAM Implementation

Tests the core ORAM functionality without requiring an enclave.
"""

import pytest
import os
import sys

# Add enclave to path for imports
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'enclave'))

from oram.path_oram import PathORAM, ORAMPool, Block, Bucket


class TestBlock:
    """Tests for Block dataclass."""
    
    def test_create_block(self):
        block = Block(block_id=1, data=b"test data")
        assert block.block_id == 1
        assert block.data == b"test data"
        assert block.is_dummy is False
    
    def test_create_dummy_block(self):
        dummy = Block.dummy(32)
        assert dummy.block_id == -1
        assert len(dummy.data) == 32
        assert dummy.is_dummy is True


class TestBucket:
    """Tests for Bucket class."""
    
    def test_bucket_add(self):
        bucket = Bucket(capacity=4)
        block = Block(block_id=1, data=b"data")
        assert bucket.add(block) is True
        assert len(bucket.blocks) == 1
    
    def test_bucket_capacity(self):
        bucket = Bucket(capacity=2)
        bucket.add(Block(block_id=1, data=b"a"))
        bucket.add(Block(block_id=2, data=b"b"))
        assert bucket.add(Block(block_id=3, data=b"c")) is False
    
    def test_bucket_remove(self):
        bucket = Bucket(capacity=4)
        bucket.add(Block(block_id=1, data=b"data"))
        removed = bucket.remove(1)
        assert removed is not None
        assert removed.block_id == 1
        assert len(bucket.blocks) == 0
    
    def test_bucket_pad(self):
        bucket = Bucket(capacity=4)
        bucket.add(Block(block_id=1, data=b"data"))
        bucket.pad_to_capacity(32)
        assert len(bucket.blocks) == 4
        assert sum(1 for b in bucket.blocks if b.is_dummy) == 3


class TestPathORAM:
    """Tests for Path ORAM implementation."""
    
    def test_initialization(self):
        oram = PathORAM(num_blocks=16, block_size=64)
        assert oram.num_blocks == 16
        assert oram.block_size == 64
        assert oram.height == 4
        assert len(oram.stash) == 0
    
    def test_write_and_read(self):
        oram = PathORAM(num_blocks=16, block_size=64)
        
        # Write a block
        oram.write(block_id=5, data=b"hello world")
        
        # Read it back
        result = oram.read(block_id=5)
        
        assert result is not None
        assert b"hello world" in result
    
    def test_multiple_writes(self):
        oram = PathORAM(num_blocks=32, block_size=64)
        
        # Write multiple blocks
        for i in range(10):
            oram.write(block_id=i, data=f"data_{i}".encode())
        
        # Verify all can be read
        for i in range(10):
            result = oram.read(block_id=i)
            assert f"data_{i}".encode() in result
    
    def test_overwrite(self):
        oram = PathORAM(num_blocks=16, block_size=64)
        
        oram.write(block_id=1, data=b"original")
        oram.write(block_id=1, data=b"updated")
        
        result = oram.read(block_id=1)
        assert b"updated" in result
    
    def test_position_remapping(self):
        oram = PathORAM(num_blocks=16, block_size=64)
        
        oram.write(block_id=1, data=b"test")
        pos1 = oram.position_map[1]
        
        oram.read(block_id=1)
        pos2 = oram.position_map[1]
        
        # Position should change after access (probabilistically)
        # May be same by chance, so we do multiple accesses
        positions = {pos1, pos2}
        for _ in range(10):
            oram.read(block_id=1)
            positions.add(oram.position_map[1])
        
        # Should have seen multiple different positions
        assert len(positions) > 1
    
    def test_metrics(self):
        oram = PathORAM(num_blocks=16, block_size=64)
        
        oram.write(block_id=1, data=b"test")
        oram.read(block_id=1)
        
        metrics = oram.get_metrics()
        assert metrics['access_count'] == 2
        assert 'stash_size' in metrics
        assert 'tree_height' in metrics


class TestORAMPool:
    """Tests for ORAMPool wrapper."""
    
    def test_store_and_retrieve(self):
        pool = ORAMPool(capacity=64, block_size=128)
        
        pool.store("my_key", b"my_value")
        data, metrics = pool.retrieve("my_key")
        
        assert data == b"my_value"
        assert metrics['pool'] == 'oram'
        assert metrics['found'] is True
    
    def test_retrieve_nonexistent(self):
        pool = ORAMPool(capacity=64)
        
        data, metrics = pool.retrieve("nonexistent")
        
        assert data is None
        assert metrics['found'] is False
    
    def test_multiple_keys(self):
        pool = ORAMPool(capacity=64, block_size=128)
        
        pool.store("key1", b"value1")
        pool.store("key2", b"value2")
        pool.store("key3", b"value3")
        
        data1, _ = pool.retrieve("key1")
        data2, _ = pool.retrieve("key2")
        data3, _ = pool.retrieve("key3")
        
        assert data1 == b"value1"
        assert data2 == b"value2"
        assert data3 == b"value3"
    
    def test_metrics(self):
        pool = ORAMPool(capacity=64)
        
        pool.store("key", b"value")
        metrics = pool.get_metrics()
        
        assert metrics['pool_type'] == 'oram'
        assert metrics['entries'] == 1


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
