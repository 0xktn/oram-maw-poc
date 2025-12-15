"""
Path ORAM Implementation for TEE Environment

This module implements Path ORAM, which provides oblivious memory access
by organizing data in a binary tree structure. Each access reads an entire
path from root to leaf, hiding which block was actually accessed.

References:
- Path ORAM Paper: https://eprint.iacr.org/2013/280.pdf
"""

import os
import secrets
from math import ceil, log2
from typing import Dict, List, Optional, Tuple
from dataclasses import dataclass, field
from cryptography.hazmat.primitives.ciphers.aead import AESGCM


@dataclass
class Block:
    """A single data block in the ORAM."""
    block_id: int
    data: bytes
    is_dummy: bool = False
    
    @classmethod
    def dummy(cls, block_size: int) -> 'Block':
        """Create a dummy block for padding."""
        return cls(block_id=-1, data=os.urandom(block_size), is_dummy=True)


@dataclass 
class Bucket:
    """A bucket in the ORAM tree containing multiple blocks."""
    blocks: List[Block] = field(default_factory=list)
    capacity: int = 4  # Z parameter
    
    def add(self, block: Block) -> bool:
        """Add a block if bucket has space."""
        if len(self.blocks) < self.capacity:
            self.blocks.append(block)
            return True
        return False
    
    def remove(self, block_id: int) -> Optional[Block]:
        """Remove and return a block by ID."""
        for i, block in enumerate(self.blocks):
            if block.block_id == block_id:
                return self.blocks.pop(i)
        return None
    
    def get_real_blocks(self) -> List[Block]:
        """Get all non-dummy blocks."""
        return [b for b in self.blocks if not b.is_dummy]
    
    def pad_to_capacity(self, block_size: int):
        """Pad bucket with dummy blocks to hide occupancy."""
        while len(self.blocks) < self.capacity:
            self.blocks.append(Block.dummy(block_size))


class PathORAM:
    """
    Path ORAM implementation optimized for TEE environment.
    
    Key Properties:
    - Access pattern is independent of which block is accessed
    - Each access reads/writes one path (root to leaf)
    - Position map tracks which leaf each block maps to
    - Stash holds overflow blocks client-side
    
    Parameters:
    - num_blocks: Maximum number of data blocks (N)
    - block_size: Size of each block in bytes
    - bucket_capacity: Blocks per bucket (Z, default=4)
    """
    
    def __init__(
        self, 
        num_blocks: int, 
        block_size: int = 256,
        bucket_capacity: int = 4,
        encryption_key: Optional[bytes] = None
    ):
        self.num_blocks = num_blocks
        self.block_size = block_size
        self.bucket_capacity = bucket_capacity
        
        # Tree parameters
        self.height = max(1, ceil(log2(num_blocks))) if num_blocks > 1 else 1
        self.num_leaves = 2 ** self.height
        self.num_buckets = 2 ** (self.height + 1) - 1
        
        # Initialize tree (array representation: index 0 = root)
        self.tree: List[Bucket] = [
            Bucket(capacity=bucket_capacity) 
            for _ in range(self.num_buckets)
        ]
        
        # Client-side state
        self.position_map: Dict[int, int] = {}  # block_id -> leaf
        self.stash: List[Block] = []
        
        # Encryption
        self.encryption_key = encryption_key or os.urandom(32)
        self.aesgcm = AESGCM(self.encryption_key)
        
        # Metrics
        self.access_count = 0
        self.stash_peak = 0
    
    def _get_path_indices(self, leaf: int) -> List[int]:
        """Get bucket indices from root to the given leaf."""
        # Leaf index in tree array (leaves start at 2^height - 1)
        leaf_idx = (2 ** self.height - 1) + leaf
        
        path = []
        current = leaf_idx
        while current >= 0:
            path.append(current)
            if current == 0:
                break
            current = (current - 1) // 2
        
        return list(reversed(path))  # Root to leaf order
    
    def _can_place_on_path(self, block_id: int, bucket_idx: int) -> bool:
        """Check if a block can be placed in a bucket on its assigned path."""
        if block_id not in self.position_map:
            return False
        
        assigned_leaf = self.position_map[block_id]
        path_indices = self._get_path_indices(assigned_leaf)
        return bucket_idx in path_indices
    
    def _encrypt_block(self, block: Block) -> bytes:
        """Encrypt a block with authenticated encryption."""
        nonce = os.urandom(12)
        plaintext = block.block_id.to_bytes(8, 'big') + block.data
        ciphertext = self.aesgcm.encrypt(nonce, plaintext, None)
        return nonce + ciphertext
    
    def _decrypt_block(self, encrypted: bytes) -> Block:
        """Decrypt an encrypted block."""
        nonce = encrypted[:12]
        ciphertext = encrypted[12:]
        plaintext = self.aesgcm.decrypt(nonce, ciphertext, None)
        block_id = int.from_bytes(plaintext[:8], 'big')
        data = plaintext[8:]
        return Block(block_id=block_id, data=data, is_dummy=(block_id == -1))
    
    def access(self, op: str, block_id: int, new_data: Optional[bytes] = None) -> Optional[bytes]:
        """
        Perform an oblivious access (read or write).
        
        This is the core ORAM operation that ensures access patterns
        are independent of which block is being accessed.
        
        Args:
            op: 'read' or 'write'
            block_id: ID of the block to access
            new_data: Data to write (required for write operations)
            
        Returns:
            Block data for read operations, None for writes
        """
        self.access_count += 1
        
        # Step 1: Lookup position (or assign new random position)
        if block_id in self.position_map:
            old_leaf = self.position_map[block_id]
        else:
            old_leaf = secrets.randbelow(self.num_leaves)
            self.position_map[block_id] = old_leaf
        
        # Step 2: Remap to new random leaf (for next access)
        new_leaf = secrets.randbelow(self.num_leaves)
        self.position_map[block_id] = new_leaf
        
        # Step 3: Read entire path from root to old_leaf
        path_indices = self._get_path_indices(old_leaf)
        for bucket_idx in path_indices:
            bucket = self.tree[bucket_idx]
            # Move all real blocks to stash
            for block in bucket.get_real_blocks():
                self.stash.append(block)
            bucket.blocks.clear()
        
        # Step 4: Find and update the target block in stash
        result_data = None
        target_found = False
        
        for i, block in enumerate(self.stash):
            if block.block_id == block_id:
                target_found = True
                if op == 'read':
                    result_data = block.data
                elif op == 'write' and new_data is not None:
                    self.stash[i] = Block(block_id=block_id, data=new_data)
                break
        
        # If block not found for write, create new block
        if not target_found and op == 'write' and new_data is not None:
            self.stash.append(Block(block_id=block_id, data=new_data))
        
        # Step 5: Write path back with eviction
        # Place as many stash blocks as possible onto the path
        for bucket_idx in reversed(path_indices):  # Leaf to root (greedy)
            bucket = self.tree[bucket_idx]
            
            # Find blocks that can be placed in this bucket
            remaining_stash = []
            for block in self.stash:
                if not block.is_dummy and self._can_place_on_path(block.block_id, bucket_idx):
                    if bucket.add(block):
                        continue  # Block added to bucket
                remaining_stash.append(block)
            self.stash = remaining_stash
            
            # Pad bucket with dummies
            bucket.pad_to_capacity(self.block_size)
        
        # Track stash size (should stay small)
        self.stash_peak = max(self.stash_peak, len(self.stash))
        
        return result_data
    
    def read(self, block_id: int) -> Optional[bytes]:
        """Read a block obliviously."""
        return self.access('read', block_id)
    
    def write(self, block_id: int, data: bytes) -> None:
        """Write a block obliviously."""
        # Pad/truncate data to block size
        if len(data) < self.block_size:
            data = data + b'\x00' * (self.block_size - len(data))
        elif len(data) > self.block_size:
            data = data[:self.block_size]
        
        self.access('write', block_id, data)
    
    def get_metrics(self) -> dict:
        """Get ORAM performance metrics."""
        return {
            'access_count': self.access_count,
            'stash_size': len(self.stash),
            'stash_peak': self.stash_peak,
            'tree_height': self.height,
            'num_buckets': self.num_buckets,
            'path_length': self.height + 1
        }


class ORAMPool:
    """
    ORAM-protected memory pool for sensitive data.
    
    Uses Path ORAM to hide access patterns for critical secrets
    like session keys and ephemeral credentials.
    """
    
    def __init__(self, capacity: int = 1024, block_size: int = 256, encryption_key: Optional[bytes] = None):
        """
        Initialize ORAM pool.
        
        Args:
            capacity: Maximum number of entries
            block_size: Size of each entry in bytes
            encryption_key: 32-byte AES key (generated if not provided)
        """
        self.oram = PathORAM(
            num_blocks=capacity,
            block_size=block_size,
            encryption_key=encryption_key
        )
        self.key_to_id: Dict[str, int] = {}
        self.next_id = 0
    
    def _get_block_id(self, key: str) -> int:
        """Get or assign a block ID for a key."""
        if key not in self.key_to_id:
            self.key_to_id[key] = self.next_id
            self.next_id += 1
        return self.key_to_id[key]
    
    def store(self, key: str, value: bytes) -> dict:
        """Store a value with ORAM protection."""
        block_id = self._get_block_id(key)
        self.oram.write(block_id, value)
        return {
            'pool': 'oram',
            'access_count': self.oram.access_count,
            'path_length': self.oram.height + 1
        }
    
    def retrieve(self, key: str) -> Tuple[Optional[bytes], dict]:
        """Retrieve a value with ORAM protection."""
        if key not in self.key_to_id:
            return None, {'pool': 'oram', 'found': False}
        
        block_id = self.key_to_id[key]
        data = self.oram.read(block_id)
        
        # Strip padding
        if data:
            data = data.rstrip(b'\x00')
        
        return data, {
            'pool': 'oram',
            'found': True,
            'access_count': self.oram.access_count
        }
    
    def get_metrics(self) -> dict:
        """Get pool metrics."""
        return {
            'pool_type': 'oram',
            'entries': len(self.key_to_id),
            **self.oram.get_metrics()
        }
