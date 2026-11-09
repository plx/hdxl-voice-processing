"""Original amplitude recipe and exact equations for performance receipts."""
import hashlib
import struct

from native_oracle import evaluate
from shimmer_oracle import finite


def generated_amplitudes(row):
    n = row['durationMilliseconds'] * row['frequencyHz'] // 1000
    count = n + (min(64, n) if row['kind'] == 'rolling' else 0)
    return [dict(timeSeconds=(i + 1) / row['frequencyHz'],
        amplitude=4. if row['denseRejections'] and i % 17 == 7 else (.9 if i % 2 == 0 else 1.1),
        sequenceIndex=i, runID=0,
        rejections=dict(rawValue=(1 if i % 2 == 0 else 4)
            if row['denseRejections'] and i % 17 >= 10 else 0)) for i in range(count)]


def amplitude_hash(amplitudes):
    return hashlib.sha256(b''.join(struct.pack('<ddQQHB', a['timeSeconds'], a.get('amplitude', 0),
        a['sequenceIndex'], a['runID'], a['rejections']['rawValue'], int(a.get('amplitude') is not None))
        for a in amplitudes)).hexdigest()
