import pytest

try:
    import lowlat_proto  # noqa: F401
except ModuleNotFoundError as exc:  # generated code not built yet
    pytest.exit(f"{exc}; run scripts/gen-python-proto.sh first", returncode=2)
