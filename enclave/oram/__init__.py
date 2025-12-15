"""
ORAM Module for TEE-based Oblivious Memory Access

This module provides Path ORAM implementation optimized for
Trusted Execution Environments (TEEs) like AWS Nitro Enclaves.
"""

from .path_oram import PathORAM, ORAMPool, Block, Bucket

__all__ = ['PathORAM', 'ORAMPool', 'Block', 'Bucket']
