"""Compatibility alias: the replay lives in geometry_replay.py (shared byte-identically
with LWIP). This module IS that module, so callers and tests that patch
geometry_ops.cv2 / _cv2_unavailable_logged still hit the live code."""

import sys

from app.services import geometry_replay

sys.modules[__name__] = geometry_replay
