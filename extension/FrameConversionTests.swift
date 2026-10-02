@main
struct FrameConversionTests {
    static func main() {
        let source: [UInt8] = [255,0,0, 0,255,0, 0xA5,0xA5,0xA5,
                                0,0,255, 255,255,255, 0xA5,0xA5,0xA5]
        var result = [UInt8](repeating: 0xCC, count: 24)
        source.withUnsafeBufferPointer { input in
            result.withUnsafeMutableBufferPointer { output in
                copyRGB24ToBGRA(input.baseAddress!, sourceStride: 9,
                    destination: output.baseAddress!, destinationStride: 12, width: 2, height: 2)
            }
        }
        let expected: [UInt8] = [0,0,255,255, 0,255,0,255, 0xCC,0xCC,0xCC,0xCC,
                                255,0,0,255, 255,255,255,255, 0xCC,0xCC,0xCC,0xCC]
        precondition(result == expected, "BGRA conversion must preserve row padding and RGB channels.")
        print("RGB24/BGRA channel order, alpha, and row-stride tests passed.")
    }
}
