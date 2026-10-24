from lowlat_place import cpu_counts


def test_usable_cpus_do_not_exceed_system_cpus() -> None:
    counts = cpu_counts()
    assert counts["cpu_count"] is not None
    assert counts["process_cpu_count"] is not None
    assert 1 <= counts["process_cpu_count"] <= counts["cpu_count"]
