"""Pinned external queries for interpolation and voiced-boundary stage evidence."""
import os
from pathlib import Path
import subprocess
import tempfile

from reference import (ROOT, HERE, canonical, digest, finite, integer, number,
                       encode_pitch, load_json, verify_tool)


def encode_queries(queries):
    if not isinstance(queries, list) or not 1 <= len(queries) <= 1000 or not all(finite(t) and abs(t) <= 10 for t in queries):
        raise ValueError('Invalid F0 query budget or times')
    return ''.join(repr(float(t)) + '\n' for t in queries).encode()


def parse(raw, queries):
    encode_queries(queries)
    if not isinstance(raw, str) or len(raw.encode()) > 256 * 1024:
        raise ValueError('F0 query transcript exceeds budget')
    rows = [line.split('\t') for line in raw.splitlines()]
    if len(rows) != len(queries) + 3 or rows[0] != ['begin', 'pulse-f0-boundaries-v1'] or rows[-1] != ['end', 'pulse-f0-boundaries-v1']:
        raise ValueError('Invalid F0 query boundaries/coverage')
    if rows[1] != ['count', str(len(queries))]:
        raise ValueError('Invalid F0 query count')
    values = []
    for i, (row, time) in enumerate(zip(rows[2:-1], queries), 1):
        if len(row) != 4 or row[0] != 'query' or integer(row[1]) != i or number(row[2]) != time:
            raise ValueError('F0 query identity differs')
        value = number(row[3])
        if value is not None and not 20 <= value <= 48000:
            raise ValueError('Invalid queried F0')
        values.append(value)
    return values


def evaluate(pitch, rate, count, queries):
    encoded_pitch, encoded_queries = encode_pitch(pitch, rate, count), encode_queries(queries)
    lock = load_json(ROOT / 'Tools/Reference/toolchain.json')
    binary = verify_tool(ROOT / '.build/reference-tool' / lock['version'] / lock['executablePath'], lock)
    with tempfile.TemporaryDirectory(prefix='pulse-f0-boundaries-', dir=ROOT / '.build') as temporary:
        scratch = Path(temporary)
        (scratch / 'input.Pitch').write_bytes(encoded_pitch)
        (scratch / 'queries.txt').write_bytes(encoded_queries)
        process = subprocess.run([str(binary), *lock['options'], str(HERE / 'f0_probe.praat'),
                                  str(scratch / 'input.Pitch'), str(scratch / 'queries.txt')],
                                 capture_output=True, text=True, encoding='utf-8', timeout=120,
                                 env={**os.environ, 'LC_ALL': 'C', 'LANG': 'C'})
    if process.returncode or process.stderr.strip():
        raise ValueError(f'F0 boundary probe failed ({process.returncode}): {process.stderr[:1200]}')
    data = parse(process.stdout, queries)
    identity = {'schemaVersion': 1, 'toolchain': lock, 'pitch': pitch, 'queriesSeconds': queries,
                'sampleRate': rate, 'sampleCount': count,
                'pitchSHA256': digest(encoded_pitch), 'queriesSHA256': digest(encoded_queries),
                'rawSHA256': digest(process.stdout.encode()),
                'sourceSHA256': {str(p.relative_to(ROOT)): digest(p.read_bytes()) for p in
                                 (Path(__file__), HERE / 'f0_probe.praat', HERE / 'reference.py',
                                  ROOT / 'Tools/Reference/common.py', ROOT / 'Tools/Reference/setup.py')}}
    return {'referenceIdentity': digest(canonical(identity)), **identity, 'frequenciesHz': data}, process.stdout
