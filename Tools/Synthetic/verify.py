#!/usr/bin/env python3
"""Offline exact regeneration gate; never bless drift in committed fixtures."""
import argparse
from pathlib import Path
from generate import artifacts, FIXTURES
from synthetic import require, sha256


def verify(directory=FIXTURES):
    directory = Path(directory)
    expected = artifacts()
    actual = {p.name for p in directory.iterdir() if p.is_file()}
    require(actual == set(expected), "Synthetic artifact inventory differs")
    for name, data in expected.items():
        require((directory / name).read_bytes() == data, f"Synthetic regeneration differs: {name}; expected SHA256 {sha256(data)}")
    print(f"Synthetic fixtures verified offline: {len(expected)} artifacts")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, default=FIXTURES)
    verify(parser.parse_args().directory)
