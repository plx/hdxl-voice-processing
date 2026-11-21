"""Fail closed on missing, duplicated, or corrupted native SWIPE evidence."""
import copy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'SWIPE'))
import audit_native as native


class SWIPENativeEvidenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.expected = native.expected_rows(native.ROOT / 'Tests/HDXLVoiceProcessingTests/Fixtures/SWIPE')
        # These are synthetic audit inputs, not claimed native measurements.
        cls.rows = [dict(row, preparedBufferBytes=1, **dict.fromkeys(native.FRACTIONS, 0.0))
                    for row in cls.expected.values()]

    def test_all_independently_derived_denominators_are_required(self):
        result = native.audit(self.rows, self.expected)
        self.assertEqual((result['cases'], result['directFrames'], result['streamedFrames']), (74, 374, 748))
        self.assertEqual(result['intermediateCells'], dict(kernelCells=317853, loudnessCells=645585,
                                                        magnitudeCells=1655517, strengthCells=347268))

    def test_adversarial_evidence_is_rejected(self):
        self.assertEqual(native.corruption_controls(self.rows, self.expected), 42)

    def test_field_inventory_is_closed(self):
        for field in ('maximumStrengthBudgetFraction', 'unexpected'):
            changed = copy.deepcopy(self.rows)
            if field == 'unexpected':
                changed[0][field] = 0
            else:
                del changed[0][field]
            with self.assertRaisesRegex(ValueError, 'fields'):
                native.audit(changed, self.expected)


if __name__ == '__main__':
    unittest.main()
