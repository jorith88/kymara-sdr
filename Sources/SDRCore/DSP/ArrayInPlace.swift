import Foundation

extension Array where Element == Float {
    /// Gives a vDSP call one pointer to use as both input and output without tripping exclusivity checks.
    @inline(__always)
    mutating func inPlace(_ body: (UnsafeMutablePointer<Float>) -> Void) {
        withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }
}
