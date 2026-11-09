"""Strict direct PointProcess query protocol for the pinned development executable."""
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
from jitter_oracle import MEASUREMENTS, validate

QUERIES = (('periodCount', 'Get number of periods'), ('meanPeriod', 'Get mean period'),
           ('local', 'Get jitter (local)'), ('absolute', 'Get jitter (local, absolute)'),
           ('rap', 'Get jitter (rap)'), ('ppq5', 'Get jitter (ppq5)'), ('ddp', 'Get jitter (ddp)'))


def script(case):
    validate(case)
    def literal(value):
        return repr(float(value))
    lines = ['# Original numerical query wrapper; no external implementation code.',
             f'Create empty PointProcess: "jitter", {literal(case["domainStartSeconds"])}, {literal(case["domainEndSeconds"])}']
    lines += [f'Add point: {literal(t)}' for t in case['pointsSeconds']]
    lines += ['appendInfoLine: "begin", tab$, "jitter-reference-v1"',
              'count = Get number of points', 'appendInfoLine: "count", tab$, count',
              'for i from 1 to count', '    time = Get time from index: i',
              '    appendInfoLine: "point", tab$, i, tab$, time', 'endfor']
    args = ', '.join(literal(case[k]) for k in ('queryStartSeconds', 'queryEndSeconds',
                    'minimumPeriodSeconds', 'maximumPeriodSeconds', 'maximumAdjacentFactor'))
    for key, command in QUERIES:
        lines += [f'value = {command}: {args}', f'appendInfoLine: "{key}", tab$, value']
    lines += ['appendInfoLine: "end", tab$, "jitter-reference-v1"']
    return '\n'.join(lines) + '\n'


def parse(raw, case):
    validate(case)
    if not isinstance(raw, str) or len(raw) > 2_000_000 or not raw.endswith('\n'):
        raise ValueError('Invalid jitter reference text')
    rows = [line.split('\t') for line in raw.splitlines()]
    expected = len(case['pointsSeconds']) + len(QUERIES) + 3
    if len(rows) != expected or rows[0] != ['begin', 'jitter-reference-v1'] or rows[-1] != ['end', 'jitter-reference-v1']:
        raise ValueError('Incomplete jitter reference protocol')
    if rows[1] != ['count', str(len(case['pointsSeconds']))]:
        raise ValueError('Jitter point count differs')
    def number(text, nullable=False):
        if nullable and text == '--undefined--': return None
        if not re.fullmatch(r'(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?', text):
            raise ValueError('Invalid jitter decimal syntax')
        try: value = float(text)
        except (ValueError, OverflowError) as error: raise ValueError('Invalid jitter number') from error
        if not math.isfinite(value) or value < 0:
            raise ValueError('Nonfinite/negative jitter number')
        return value
    for i, point in enumerate(case['pointsSeconds']):
        row = rows[i + 2]
        if len(row) != 3 or row[:2] != ['point', str(i + 1)] or number(row[2]) != point:
            raise ValueError('Injected jitter point differs')
    values = {}
    for row, (key, _) in zip(rows[2 + len(case['pointsSeconds']):-1], QUERIES):
        if len(row) != 2 or row[0] != key: raise ValueError('Reordered jitter query')
        if key == 'periodCount':
            if not row[1].isascii() or not row[1].isdigit() or str(int(row[1])) != row[1]:
                raise ValueError('Invalid jitter period count')
            value = int(row[1])
            if value > max(0, len(case['pointsSeconds']) - 1): raise ValueError('Excess jitter periods')
        else:
            value = number(row[1], nullable=True)
        values[key] = value
    if (values['periodCount'] == 0) != (values['meanPeriod'] is None) or values['meanPeriod'] == 0:
        raise ValueError('Inconsistent jitter denominator')
    if (values['local'] is None) != (values['absolute'] is None) or (values['rap'] is None) != (values['ddp'] is None):
        raise ValueError('Inconsistent jitter availability')
    if values['meanPeriod'] is None and any(values[k] is not None for k in MEASUREMENTS):
        raise ValueError('Jitter without a mean period')
    if values['local'] is None and any(values[k] is not None for k in ('rap', 'ppq5', 'ddp')):
        raise ValueError('Higher-order jitter without valid pairs')
    return values


def make_record(case, encoded, raw, lock):
    if encoded != script(case):
        raise ValueError('Jitter script differs from declared inputs')
    data = parse(raw, case)
    identity = {'schemaVersion': 1, 'inputSHA256': digest(canonical(case)),
                'scriptSHA256': digest(encoded.encode()), 'stdoutSHA256': digest(raw.encode()),
                'toolchain': lock, 'command': ['<verified-praat>', *lock['options'], '<saved-probe.praat>'],
                'environment': {'LC_ALL': 'C', 'LANG': 'C'}, 'data': data}
    return {'referenceIdentity': digest(canonical(identity)), **identity}


def evaluate(case, binary=None):
    encoded = script(case)
    lock = load_json(ROOT / 'Tools/Reference/toolchain.json')
    path = binary or ROOT / '.build/reference-tool' / lock['version'] / lock['executablePath']
    path = verify_tool(path, lock)
    with tempfile.TemporaryDirectory(prefix='jitter-query-', dir=ROOT / '.build') as temp:
        entry = Path(temp) / 'probe.praat'
        entry.write_text(encoded, encoding='utf-8')
        command = [str(path), *lock['options'], str(entry)]
        result = subprocess.run(command, capture_output=True, text=True, encoding='utf-8', timeout=30,
                                env={**os.environ, 'LC_ALL': 'C', 'LANG': 'C'})
    if result.returncode or result.stderr.strip():
        raise ValueError(f'Jitter reference failed ({result.returncode}): {result.stderr[:1200]}')
    return make_record(case, encoded, result.stdout, lock), encoded, result.stdout
