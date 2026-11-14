import Foundation

extension Double {
    /// The nearest whole number as an Int, for any input: not-a-number gives 0 and huge values are clamped, so
    /// reading a number out of a program can never crash the app (`Int(x)` traps on those).
    var clampedInt: Int {
        if isNaN { return 0 }
        let r = rounded()
        if r >= 1e15 { return 1_000_000_000_000_000 }
        if r <= -1e15 { return -1_000_000_000_000_000 }
        return Int(r)
    }
}
