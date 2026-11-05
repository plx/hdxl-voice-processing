/// Independent deterministic order-statistic selection. Three-way partitions
/// collapse ties. A finite partition budget falls back to in-place heapsort,
/// bounding worst-case work by O(n log n) and requiring no allocation or RNG.
enum CPPSelection {
    static func median(_ data: UnsafeMutableBufferPointer<Double>, count: Int) -> Double {
        precondition(count > 0 && count <= data.count)
        let middle = count / 2
        let upper = select(data, count: count, rank: middle)
        if count % 2 == 1 { return upper }
        var lower = data[0]
        if middle > 1 {
            for i in 1..<middle { lower = max(lower, data[i]) }
        }
        return lower + (upper - lower) * 0.5
    }

    private static func select(_ data: UnsafeMutableBufferPointer<Double>, count: Int, rank: Int)
        -> Double
    {
        var left = 0
        var right = count
        var budget = 2 * (Int.bitWidth - count.leadingZeroBitCount)
        while right - left > 1 {
            if budget == 0 {
                heapSort(data, start: left, count: right - left)
                return data[rank]
            }
            budget -= 1
            let a = data[left]
            let b = data[left + (right - left) / 2]
            let c = data[right - 1]
            let pivot = max(min(a, b), min(max(a, b), c))
            var lower = left
            var cursor = left
            var upper = right
            while cursor < upper {
                if data[cursor] < pivot {
                    data.swapAt(cursor, lower)
                    cursor += 1
                    lower += 1
                } else if data[cursor] > pivot {
                    upper -= 1
                    data.swapAt(cursor, upper)
                } else {
                    cursor += 1
                }
            }
            if rank < lower {
                right = lower
            } else if rank >= upper {
                left = upper
            } else {
                return pivot
            }
        }
        return data[rank]
    }

    private static func heapSort(_ data: UnsafeMutableBufferPointer<Double>, start: Int, count: Int)
    {
        func sift(_ root: Int, _ end: Int) {
            var parent = root
            while parent < end / 2 {
                var child = 2 * parent + 1
                if child + 1 < end && data[start + child] < data[start + child + 1] { child += 1 }
                if data[start + parent] >= data[start + child] { return }
                data.swapAt(start + parent, start + child)
                parent = child
            }
        }
        for root in stride(from: count / 2 - 1, through: 0, by: -1) { sift(root, count) }
        for end in stride(from: count - 1, through: 1, by: -1) {
            data.swapAt(start, start + end)
            sift(0, end)
        }
    }
}
