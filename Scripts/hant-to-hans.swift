// Character-level Traditional → Simplified conversion via ICU.
//
// Reads a JSON array of strings on stdin, writes the converted JSON array on
// stdout. Intentionally does *only* the glyph conversion — mainland vocabulary
// differences (介面 → 界面, 檔案 → 文件) are a separate concern handled by the
// terminology map in inject-translations.py, because they are editorial choices
// rather than a mechanical mapping.
//
// ASCII is untouched, so format specifiers like %1$lld survive intact.

import Foundation

let input = FileHandle.standardInput.readDataToEndOfFile()

guard let strings = try? JSONDecoder().decode([String].self, from: input) else {
    FileHandle.standardError.write(Data("error: stdin was not a JSON array of strings\n".utf8))
    exit(1)
}

let transform = StringTransform("Hant-Hans")

let converted: [String] = strings.map { source in
    // A nil result means ICU could not apply the transform; passing the original
    // through keeps the pipeline lossless rather than substituting an empty
    // string, which would silently ship a blank label.
    source.applyingTransform(transform, reverse: false) ?? source
}

guard let output = try? JSONSerialization.data(
    withJSONObject: converted,
    options: [.withoutEscapingSlashes]
) else {
    FileHandle.standardError.write(Data("error: could not encode output\n".utf8))
    exit(1)
}

FileHandle.standardOutput.write(output)
