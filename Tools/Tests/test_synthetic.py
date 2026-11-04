"""Independent hand anchors and algebraic checks for developer-only synthetic sources."""
import copy
from fractions import Fraction
import cmath
import math
from pathlib import Path
import sys
import unittest

SYNTHETIC = Path(__file__).resolve().parents[1] / "Synthetic"
sys.path.insert(0, str(SYNTHETIC))
from synthetic import (Renderer, SplitMix64, SyntheticError, canonical, mix_noise, pole_section,
                       render, selection, sine_phase, transfer, validate_recipe, wave)
from sequences import statistics


def recipe(source, count=16, rate=16000, **changes):
    return {"schemaVersion": 1, "identifier": {"name": "test-source", "version": 1},
            "sampleRate": rate, "sampleCount": count, "source": source, "gain": 1, "clip": False,
            "formants": [], "initialFilterState": [], "missingIntervals": [], **changes}


def tone(frequency=4000, amplitude=0.5, phase=0):
    return {"kind": "harmonics", "components": [{"frequencyHz": frequency, "amplitude": amplitude, "phaseTurns": phase}]}


def exact(result, metric):
    record = result["statistics"][metric]["exactRational"]
    return Fraction(int(record["numerator"]), int(record["denominator"]))


class SyntheticTests(unittest.TestCase):
    def test_oscillator_hand_values_and_dense_independent_error_bound(self):
        self.assertEqual([sine_phase(i, 4) for i in range(8)], [0, 1, 0, -1] * 2)
        self.assertAlmostEqual(sine_phase(1, 12), 0.5, delta=5e-15)
        self.assertAlmostEqual(sine_phase(1, 8), math.sqrt(0.5), delta=5e-15)
        for i in range(-4096, 4097):
            self.assertAlmostEqual(sine_phase(i, 4097), math.sin(2 * math.pi * i / 4097), delta=5e-15)

    def test_tone_dc_impulse_and_energy_hand_arrays(self):
        values, _ = render(recipe(tone(), count=8))
        self.assertEqual(values, [0, 0.5, 0, -0.5] * 2)
        self.assertEqual(sum(v*v for v in values) / 8, 0.125)
        self.assertEqual(render(recipe({"kind": "dc", "value": 0.25}, count=3))[0], [0.25] * 3)
        self.assertEqual(render(recipe({"kind": "impulse", "index": 2, "amplitude": 0.5}, count=4))[0], [0, 0, 0.5, 0])
        for k in range(8):
            dft = sum(v * cmath.exp(-2j * math.pi * k * i / 8) for i, v in enumerate(values))
            self.assertAlmostEqual(dft.real, 0, delta=1e-14)
            self.assertAlmostEqual(dft.imag, -2 if k == 2 else 2 if k == 6 else 0, delta=1e-14)

    def test_polarity_gain_rate_and_time_scaling(self):
        base = recipe(tone(1000), count=32)
        values = render(base)[0]
        self.assertEqual(render({**base, "gain": -1})[0], [-v for v in values])
        self.assertEqual(render({**base, "gain": 0.5})[0], [v/2 for v in values])
        faster_rate = render({**base, "sampleRate": 32000, "sampleCount": 64})[0]
        self.assertEqual(faster_rate[::2], values)
        slowed = recipe(tone(500), count=64)
        self.assertEqual(render(slowed)[0][::2], values)
        self.assertAlmostEqual(20*math.log10(2), 6.020599913279624, delta=1e-14)

    def test_noise_known_integer_outputs_and_chunk_identity(self):
        random = SplitMix64(0)
        self.assertEqual([random.next_word() for _ in range(3)],
                         [0xE220A8397B1DCDAF, 0x6E789E6AA1B965F4, 0x06C45D188009454F])
        source = recipe({"kind": "noise", "seed": 0, "amplitude": 0.25}, count=4097)
        self.assertEqual(render(source, 1)[0], render(source, 1024)[0])
        for value in render(source)[0]:
            self.assertTrue(-0.25 <= value < 0.25)

    def test_poles_roots_response_and_filter_chunk_state(self):
        section = pole_section(4000, "3530.1696024424255", 16000)
        _, a1, a2 = section["denominator"]
        roots = [(-a1 + sign * cmath.sqrt(a1*a1 - 4*a2))/2 for sign in (-1, 1)]
        for pole in roots:
            self.assertAlmostEqual(abs(pole), 0.5, delta=1e-15)
            self.assertAlmostEqual(abs(cmath.phase(pole)), math.pi/2, delta=1e-14)
        self.assertAlmostEqual(abs(transfer([section], 0, 16000)), 1, delta=1e-14)
        source = recipe({"kind": "impulse", "index": 0, "amplitude": 0.5}, count=8,
                        formants=[{"frequencyHz": 4000, "bandwidthHz": "3530.1696024424255"}], initialFilterState=[[0, 0]])
        values, renderer = render(source, 1)
        self.assertEqual(values, render(source, 7)[0])
        for v, expected in zip(values, [0.625, 0, -0.15625, 0, 0.0390625, 0, -0.009765625, 0]):
            self.assertAlmostEqual(v, expected, delta=1e-14)
        snapshot = renderer.snapshot()
        snapshot["filterState"][0][0] = 99
        self.assertNotEqual(renderer.snapshot()["filterState"][0][0], 99)

    def test_period_and_amplitude_exact_hand_statistics(self):
        periods = statistics(["1/100", "11/1000", "1/100"], "period")
        self.assertEqual(exact(periods, "jitterAbsolute"), Fraction(1, 1000))
        self.assertEqual(exact(periods, "jitterLocal"), Fraction(3, 31))
        self.assertEqual(exact(periods, "jitterRAP"), Fraction(2, 31))
        self.assertEqual(exact(periods, "jitterDDP"), Fraction(6, 31))
        amplitudes = statistics(["1/2", "11/20", "1/2"], "amplitude")
        self.assertEqual(exact(amplitudes, "shimmerLocal"), Fraction(3, 31))
        self.assertEqual(exact(amplitudes, "shimmerAPQ3"), Fraction(2, 31))
        db = amplitudes["statistics"]["shimmerDB"]["outcome"]["estimate"]["value"]
        self.assertAlmostEqual(db, 20*math.log10(1.1), delta=1e-14)
        long = ["1/2"] * 13
        long[6] = "11/20"
        stats = statistics(long, "amplitude")
        for metric, expected in {"shimmerLocal": Fraction(13, 786), "shimmerAPQ3": Fraction(52, 4323),
                                 "shimmerAPQ5": Fraction(104, 5895), "shimmerAPQ11": Fraction(52, 1441)}.items():
            self.assertEqual(exact(stats, metric), expected)

    def test_missing_intervals_do_not_stitch_and_zero_is_distinct(self):
        mask = [True] * 13
        mask[6] = False
        result = statistics(["1/100"]*13, "period", mask)
        self.assertEqual(result["statistics"]["jitterLocal"]["eligibleWindowCount"], 10)
        self.assertEqual(result["statistics"]["jitterRAP"]["eligibleWindowCount"], 8)
        self.assertEqual(result["statistics"]["jitterPPQ5"]["eligibleWindowCount"], 4)
        self.assertEqual(exact(result, "jitterLocal"), 0)
        self.assertEqual(result["statistics"]["jitterLocal"]["outcome"]["estimate"]["warnings"], ["partialCoverage"])
        for values, family, reason in (([], "period", "insufficientData"), ([0, 0], "amplitude", "silence"), ([0, 1], "period", "invalidInput")):
            self.assertEqual(statistics(values, family)["statistics"]["jitterLocal" if family == "period" else "shimmerLocal"]["outcome"],
                             {"status": "unavailable", "reason": reason})
        spans = selection(10, [{"startSample": 3, "sampleCount": 2}])
        self.assertEqual([(s["startSample"],s["sampleCount"],s["included"]) for s in spans], [(0,3,True),(3,2,False),(5,5,True)])

    def test_pulse_rounding_and_collision_are_explicit(self):
        source = {"kind": "pulses", "startSeconds": "1/32000", "periodsSeconds": ["3/32000", "3/32000"], "amplitudes": [0.25,0.5,0.25]}
        values, renderer = render(recipe(source, count=8))
        self.assertEqual(renderer.pulse_metadata["renderedSampleIndices"], [0, 2, 4])
        self.assertEqual(values, [0.25,0,0.5,0,0.25,0,0,0])
        source["periodsSeconds"] = ["1/1000000", "1/1000000"]
        with self.assertRaises(SyntheticError):
            Renderer(recipe(source))

    def test_clipping_nonfinite_and_profile_types(self):
        source = recipe({"kind": "dc", "value": 0.75}, count=3, gain=2, clip=True)
        values, renderer = render(source)
        self.assertEqual(values, [1]*3)
        self.assertEqual(renderer.clipped, 3)
        source["clip"] = False
        with self.assertRaises(SyntheticError): render(source)
        for key, value in (("sampleRate",True),("schemaVersion",True),("gain",float("nan")),("clip",1)):
            with self.assertRaises(SyntheticError):
                validate_recipe({**recipe(tone()), key:value})
        with self.assertRaises(SyntheticError): wave([float("inf")],16000)

    def test_snr_component_energy_and_fixed_seed_ensemble_bounds(self):
        signal = render(recipe(tone(1000,0.05),count=4096))[0]
        scales=[]
        for seed in range(8):
            noise=render(recipe({"kind":"noise","seed":seed,"amplitude":1},count=4096))[0]
            mean=sum(noise)/len(noise)
            variance=sum(v*v for v in noise)/len(noise)
            self.assertLess(abs(mean),0.05)
            self.assertTrue(0.30 < variance < 0.37)
            mixture, metadata=mix_noise(signal,noise,20)
            self.assertAlmostEqual(10*math.log10(metadata["sourceEnergy"]/metadata["noiseEnergyAfterScaling"]),20,delta=1e-12)
            self.assertAlmostEqual(sum(v*v for v in mixture),metadata["sourceEnergy"]+metadata["noiseEnergyAfterScaling"]+metadata["crossTerm"],delta=1e-10)
            scales.append(metadata["noiseScale"])
        self.assertEqual(len(set(scales)),8)
        with self.assertRaises(SyntheticError): mix_noise([0],[1],20)
        with self.assertRaises(SyntheticError): mix_noise([1],[0],20)

    def test_renderer_owns_recipe_and_empty_support(self):
        source=recipe(tone(),count=4)
        renderer=Renderer(source)
        source["source"]["components"][0]["amplitude"]=99
        self.assertEqual(renderer.read(4),[0,0.5,0,-0.5])
        self.assertEqual(render(recipe({"kind":"dc","value":0},count=0))[0],[])

    def test_catalog_reproduction_and_metadata(self):
        from generate import artifacts
        import json
        first = artifacts()
        self.assertEqual(first, artifacts())
        self.assertLess(sum(map(len, first.values())), 1000000)
        catalog = json.loads(first['catalog.json'])
        self.assertEqual(len(catalog['cases']), 34)
        self.assertEqual({r['planningID'] for r in catalog['coverage']}, {f'A{i:02}' for i in range(1, 19)})
        for entry in catalog['cases']:
            m = json.loads(first[entry['manifest']])
            self.assertEqual(m['fixtureIdentity'], entry['fixtureIdentity'])
            self.assertEqual(m['timing']['source']['sampleCount'] * 8 + 56, len(first[m['artifact']['file']]))
            if m['directPulseStatistics']:
                self.assertEqual(m['directPulseStatistics']['periods']['sourceCount'] + 1,
                                 len(m['renderDiagnostics']['pulses']['renderedSampleIndices']))

    def test_catalog_filter_transfer_after_declared_warmup(self):
        from catalog import recipes
        from generate import materialize
        r = next(r for r in recipes() if r['identifier']['name'] == 'filtered-harmonics')
        samples, _, diagnostics = materialize(r)
        kept = samples[4000:]
        for component in r['source']['components']:
            frequency = component['frequencyHz']
            projected = 2/len(kept) * sum(x * cmath.exp(-2j*math.pi*frequency*(n+4000)/r['sampleRate']) for n,x in enumerate(kept))
            response = transfer(diagnostics['sections'], frequency, r['sampleRate']) * r['gain']
            # Sine's positive-frequency coefficient is -i*A, with integer periods in retained support.
            self.assertAlmostEqual(abs(projected + 1j*component['amplitude']*response), 0, delta=1e-14)

    def test_recipe_and_mixture_reject_ambiguous_support(self):
        from catalog import recipes, harmonics
        from generate import materialize
        with self.assertRaises(SyntheticError): harmonics(100, (1,2), [0.1])
        m = next(r for r in recipes() if 'mixture' in r)
        for mutation in ('rate','mask','identifier','schema'):
            changed = copy.deepcopy(m)
            if mutation == 'rate': changed['mixture']['noise']['sampleRate'] = 8000
            if mutation == 'mask': changed['mixture']['noise']['missingIntervals'] = [{'startSample':0,'sampleCount':1}]
            if mutation == 'identifier': changed['identifier']['version'] = True
            if mutation == 'schema': changed['schemaVersion'] = True
            with self.assertRaises(SyntheticError): materialize(changed)
        with self.assertRaises(SyntheticError): mix_noise([1e300], [1], 0)
        for fields in ({'formants':[{'frequencyHz':8000,'bandwidthHz':100}], 'initialFilterState':[[0,0]]},
                       {'sampleRate':True}, {'sampleCount':-1}, {'clip':1},
                       {'missingIntervals':[{'startSample':15,'sampleCount':2}]}):
            with self.assertRaises(SyntheticError): Renderer(recipe(tone(), **fields))

    def test_all_catalog_chunk_boundaries_preserve_state(self):
        from catalog import recipes
        for r in recipes():
            if 'mixture' in r: continue
            baseline, original = render(r)
            renderer = Renderer(r)
            pieces = []
            while renderer.position < renderer.count:
                pieces.extend(renderer.read(7))
            self.assertEqual(baseline, pieces, r['identifier'])
            self.assertEqual(original.snapshot(), renderer.snapshot())

    def test_benchmark_registration_and_prepared_pcm(self):
        import importlib.util
        import tempfile
        spec = importlib.util.spec_from_file_location('synthetic_benchmark', SYNTHETIC / 'benchmark.py')
        benchmark = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(benchmark)
        matrix = benchmark.workloads()
        self.assertEqual(len(matrix), 24)
        self.assertEqual({w['durationSeconds'] for w in matrix}, {1,10,60,300})
        self.assertEqual({w['sampleRate'] for w in matrix}, {16000,44100,48000})
        self.assertEqual({w['sourceF0Hz'] for w in matrix}, {50,600})
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/'prepared.wav'
            a, b = benchmark.trial(matrix[0],path), benchmark.trial(matrix[0])
            from synthetic import sha256
            self.assertEqual(a['normalizedFloat64LESHA256'], b['normalizedFloat64LESHA256'])
            self.assertEqual(a['artifactSHA256'], sha256(path.read_bytes()))
            self.assertEqual(path.stat().st_size, 56+8*16000)
            self.assertEqual(a['fullBlockLatencySeconds']['count'], 3)
            self.assertEqual(a['partialBlockLatencySeconds']['count'], 1)
            self.assertGreater(a['fileWriteSeconds'], 0)
            self.assertEqual(b['fileWriteSeconds'], 0)


    def test_poles_reject_rounded_marginal_denominators(self):
        for frequency in ("1/1000000000000", "7999999999999999/1000000000000"):
            with self.assertRaises(SyntheticError): pole_section(frequency, "1/1000000", 16000)
