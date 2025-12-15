"""
ACB (Attested Confidential Blackboard) Module

Provides compartmentalized memory pools with sensitivity-based routing:
- ORAMPool: For secrets requiring access pattern hiding
- StandardPool: For high-volume data with O(1) access
- ACBRouter: Automatic routing based on key prefixes
"""

from .router import ACBRouter
from .standard_pool import StandardPool

# Import ORAMPool - handle both relative and absolute imports
try:
    from ..oram import ORAMPool
except ImportError:
    from oram import ORAMPool

__all__ = ['ACBRouter', 'StandardPool', 'ORAMPool']
