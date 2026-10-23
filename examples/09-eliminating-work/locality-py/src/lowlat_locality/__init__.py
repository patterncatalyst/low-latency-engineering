"""Ch9: eliminating work, Python lane.

The divergence from C++ and Java is the point: Python cannot place an object or pad a field, so
the lever is fewer objects. ``records`` and ``tracker`` hold the parcel tracker, ``footprint``
counts the bytes a tracked parcel costs per record shape, ``sweep`` times the due sweep over a
list of objects against array columns, and ``counters`` runs five camera counters in shared
memory (processes) and in threads.
"""
