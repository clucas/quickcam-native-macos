func copyRGB24ToBGRA(_ source: UnsafePointer<UInt8>, sourceStride: Int,
                     destination: UnsafeMutablePointer<UInt8>, destinationStride: Int,
                     width: Int, height: Int) {
    for row in 0..<height {
        let sourceRow = source.advanced(by: row * sourceStride)
        let output = destination.advanced(by: row * destinationStride)
        for column in 0..<width {
            output[column * 4] = sourceRow[column * 3 + 2]
            output[column * 4 + 1] = sourceRow[column * 3 + 1]
            output[column * 4 + 2] = sourceRow[column * 3]
            output[column * 4 + 3] = 255
        }
    }
}
