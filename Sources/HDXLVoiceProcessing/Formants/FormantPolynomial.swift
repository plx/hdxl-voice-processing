import Foundation

struct FormantRoot: Sendable, Hashable {
    var real: Double
    var imaginary: Double
    init(_ real: Double, _ imaginary: Double = 0) {
        self.real = real
        self.imaginary = imaginary
    }
    var magnitude: Double { hypot(real, imaginary) }
    static func + (a: Self, b: Self) -> Self { Self(a.real + b.real, a.imaginary + b.imaginary) }
    static func - (a: Self, b: Self) -> Self { Self(a.real - b.real, a.imaginary - b.imaginary) }
    static func * (a: Self, b: Self) -> Self {
        Self(
            (a.real * b.real).addingProduct(-a.imaginary, b.imaginary),
            (a.real * b.imaginary).addingProduct(a.imaginary, b.real))
    }
    static func / (a: Self, b: Self) -> Self {
        if abs(b.real) >= abs(b.imaginary) {
            let ratio = b.imaginary / b.real
            let d = b.real + b.imaginary * ratio
            return Self((a.real + a.imaginary * ratio) / d, (a.imaginary - a.real * ratio) / d)
        }
        let ratio = b.real / b.imaginary
        let d = b.imaginary + b.real * ratio
        return Self((a.real * ratio + a.imaginary) / d, (a.imaginary * ratio - a.real) / d)
    }
}

struct FormantRootSolution {
    let roots: [FormantRoot]
    let sweeps: Int
    let triedSecondStart: Bool
    let maximumRelativeResidual: Double?
    var converged: Bool { maximumRelativeResidual != nil }
}

/// Ehrlich–Aberth on a real monic polynomial. The normal start is just outside the stable-pole disk.
/// A rotated interior start and a fixed sweep limit bound work even for coincident or difficult poles.
struct FormantPolynomial {
    static let sweepLimit = 64
    let coefficients: [Double]

    func evaluate(at z: FormantRoot) -> (value: FormantRoot, derivative: FormantRoot, scale: Double)
    {
        var value = FormantRoot(coefficients[0])
        var derivative = FormantRoot(0)
        var scale = abs(coefficients[0])
        let radius = z.magnitude
        for a in coefficients.dropFirst() {
            derivative = derivative * z + value
            value = value * z + FormantRoot(a)
            scale = scale * radius + abs(a)
        }
        return (value, derivative, scale)
    }

    func solve(sweepLimit: Int = Self.sweepLimit) -> FormantRootSolution {
        let failed = FormantRootSolution(
            roots: [], sweeps: 0, triedSecondStart: false, maximumRelativeResidual: nil)
        guard (2...17).contains(coefficients.count), coefficients[0] == 1,
            coefficients.allSatisfy(\.isFinite), (1...Self.sweepLimit).contains(sweepLimit)
        else { return failed }
        // Remove exact factors of z. Their multiplicity cannot be recovered from pairwise repulsion.
        if coefficients.last == 0 {
            let end = coefficients.lastIndex(where: { $0 != 0 })!
            let zeroes = Array(repeating: FormantRoot(0), count: coefficients.count - 1 - end)
            if end == 0 {
                return .init(
                    roots: zeroes, sweeps: 0, triedSecondStart: false, maximumRelativeResidual: 0)
            }
            let part = Self(coefficients: Array(coefficients[...end])).solve(sweepLimit: sweepLimit)
            guard part.converged else { return part }
            return .init(
                roots: part.roots + zeroes, sweeps: part.sweeps,
                triedSecondStart: part.triedSecondStart,
                maximumRelativeResidual: part.maximumRelativeResidual)
        }
        let order = coefficients.count - 1
        if order == 1 {
            return .init(
                roots: [FormantRoot(-coefficients[1])], sweeps: 0, triedSecondStart: false,
                maximumRelativeResidual: 0)
        }
        var sweeps = 0
        for attempt in 0..<2 {
            let radius = attempt == 0 ? 1.04 : 0.78
            var roots = (0..<order).map { j in
                let angle =
                    2 * Double.pi * (Double(j) + (attempt == 0 ? 0.27 : 0.71)) / Double(order)
                return FormantRoot(radius * cos(angle), radius * sin(angle))
            }
            for _ in 0..<sweepLimit {
                sweeps += 1
                var settled = true
                var finite = true
                for j in roots.indices {
                    let z = roots[j]
                    let p = evaluate(at: z)
                    if p.value.real == 0 && p.value.imaginary == 0 { continue }
                    var separation = FormantRoot(0)
                    for k in roots.indices where k != j {
                        separation = separation + FormantRoot(1) / (z - roots[k])
                    }
                    let correction = p.value / (p.derivative - p.value * separation)
                    guard correction.magnitude.isFinite else {
                        finite = false
                        break
                    }
                    roots[j] = z - correction
                    if correction.magnitude > 2e-12 * (1 + z.magnitude) { settled = false }
                }
                if !finite { break }
                if settled, let residual = verifiedResidual(roots) {
                    return .init(
                        roots: roots, sweeps: sweeps, triedSecondStart: attempt != 0,
                        maximumRelativeResidual: residual)
                }
            }
        }
        return .init(
            roots: [], sweeps: sweeps, triedSecondStart: true, maximumRelativeResidual: nil)
    }

    private func verifiedResidual(_ roots: [FormantRoot]) -> Double? {
        var reconstructed = Array(repeating: FormantRoot(0), count: coefficients.count)
        reconstructed[0] = FormantRoot(1)
        var maximum = 0.0
        for (index, root) in roots.enumerated() {
            let p = evaluate(at: root)
            let residual = p.value.magnitude / p.scale
            guard residual.isFinite, residual <= 1e-10 else { return nil }
            maximum = max(maximum, residual)
            // Verify the multiset too: a small point residual alone cannot detect duplicate roots.
            for k in stride(from: index + 1, through: 1, by: -1) {
                reconstructed[k] = reconstructed[k] - root * reconstructed[k - 1]
            }
        }
        let scale = coefficients.reduce(0) { max($0, abs($1)) }
        guard
            coefficients.indices.allSatisfy({
                (reconstructed[$0] - FormantRoot(coefficients[$0])).magnitude <= 1e-7 * scale
            })
        else { return nil }
        return maximum
    }
}
