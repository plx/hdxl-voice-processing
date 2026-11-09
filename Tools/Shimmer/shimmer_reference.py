"""Strict original AmplitudeTier query protocol for pinned development Praat."""
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(1, str(HERE))
sys.path.insert(1, str(ROOT / 'Tools/Reference'))
from common import canonical, digest, load_json
from setup import verify_tool
from shimmer_oracle import MEASUREMENTS, selected_indices

QUERIES = tuple((key, 'Get shimmer (' + ('local_dB' if key == 'db' else key) + ')')
                for key in MEASUREMENTS)


def script(case):
    indices = selected_indices(case)
    literal = lambda value: repr(float(value))
    lines = ['# Original query wrapper; no external implementation source.',
        f'Create AmplitudeTier: "shimmer", {literal(case["domainStartSeconds"])}, {literal(case["domainEndSeconds"])}']
    lines += [f'Add point: {literal(case["timesSeconds"][i])}, {literal(case["amplitudes"][i])}' for i in indices]
    lines += ['appendInfoLine: "begin", tab$, "shimmer-reference-v1"',
        'count = Get number of points', 'appendInfoLine: "count", tab$, count',
        'for i from 1 to count', '    time = Get time from index: i',
        '    amplitude = Get value at index: i',
        '    appendInfoLine: "amplitude", tab$, i, tab$, time, tab$, amplitude', 'endfor']
    args = ', '.join(literal(case[key]) for key in
                    ('minimumPeriodSeconds', 'maximumPeriodSeconds', 'maximumAmplitudeFactor'))
    for key, command in QUERIES:
        lines += [f'value = {command}: {args}', f'appendInfoLine: "{key}", tab$, value']
    lines += ['appendInfoLine: "end", tab$, "shimmer-reference-v1"']
    return '\n'.join(lines) + '\n'


def parse(raw, case):
    indices = selected_indices(case)
    if not isinstance(raw, str) or len(raw.encode()) > 4 * 1024 * 1024 or not raw.endswith('\n'):
        raise ValueError('Invalid shimmer reference text')
    rows = [line.split('\t') for line in raw.splitlines()]
    if len(rows) != len(indices) + len(QUERIES) + 3 or rows[0] != ['begin', 'shimmer-reference-v1'] or rows[-1] != ['end', 'shimmer-reference-v1']:
        raise ValueError('Incomplete shimmer reference protocol')
    if rows[1] != ['count', str(len(indices))]:
        raise ValueError('Shimmer amplitude count differs')
    def number(token, nullable=False):
        if nullable and token == '--undefined--': return None
        if not re.fullmatch(r'-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?', token):
            raise ValueError('Invalid shimmer decimal syntax')
        try: value = float(token)
        except (ValueError, OverflowError) as error: raise ValueError('Invalid shimmer number') from error
        if not math.isfinite(value) or value < 0: raise ValueError('Nonfinite/negative shimmer value')
        return value
    for ordinal, index in enumerate(indices, 1):
        row = rows[ordinal + 1]
        if len(row) != 4 or row[:2] != ['amplitude', str(ordinal)] or number(row[2]) != case['timesSeconds'][index] or number(row[3]) != case['amplitudes'][index]:
            raise ValueError('Injected shimmer amplitude identity differs')
    values = {}
    for row, (key, _) in zip(rows[len(indices) + 2:-1], QUERIES):
        if len(row) != 2 or row[0] != key: raise ValueError('Reordered shimmer query')
        values[key] = number(row[1], nullable=True)
    for key, minimum in (('local', 2), ('db', 2), ('apq3', 3), ('apq5', 5), ('apq11', 11), ('dda', 3)):
        if len(indices) < minimum and values[key] is not None:
            raise ValueError('Shimmer value without enough amplitude records')
    if (values['local'] is None) != (values['db'] is None) or (values['apq3'] is None) != (values['dda'] is None):
        raise ValueError('Inconsistent shimmer availability')
    if values['local'] is None and any(values[k] is not None for k in ('apq3', 'apq5', 'apq11', 'dda')):
        raise ValueError('Shimmer neighborhood without valid pairs')
    if values['apq3'] is not None and values['dda'] != 3 * values['apq3']:
        raise ValueError('Reference DDA/APQ3 relation differs')
    return values


def make_record(case, encoded, raw, lock):
    if encoded != script(case): raise ValueError('Shimmer script differs from declared inputs')
    data = parse(raw, case)
    identity = dict(schemaVersion=1, inputSHA256=digest(canonical(case)),
        scriptSHA256=digest(encoded.encode()), stdoutSHA256=digest(raw.encode()),
        toolchain=lock, command=['<verified-praat>', *lock['options'], '<saved-probe.praat>'],
        environment={'LC_ALL': 'C', 'LANG': 'C'}, data=data)
    return {'referenceIdentity': digest(canonical(identity)), **identity}


def evaluate(case, binary=None):
    encoded = script(case)
    lock = load_json(ROOT / 'Tools/Reference/toolchain.json')
    path = verify_tool(binary or ROOT / '.build/reference-tool' / lock['version'] / lock['executablePath'], lock)
    with tempfile.TemporaryDirectory(prefix='shimmer-query-', dir=ROOT / '.build') as temp:
        entry = Path(temp) / 'probe.praat'
        entry.write_text(encoded, encoding='utf-8')
        result = subprocess.run([str(path), *lock['options'], str(entry)], capture_output=True,
            text=True, encoding='utf-8', timeout=30, env={**os.environ, 'LC_ALL': 'C', 'LANG': 'C'})
    if result.returncode or result.stderr.strip():
        raise ValueError(f'Shimmer reference failed ({result.returncode}): {result.stderr[:1200]}')
    return make_record(case, encoded, result.stdout, lock), encoded, result.stdout
