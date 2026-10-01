import Foundation

/// `grep -m N <marker> <file>`, in process: the first lines of a JSONL transcript containing a
/// marker, found by searching the memory-mapped file. The scanner used to spawn two `grep`s per
/// transcript, and a process launch costs ~80 ms here — 59 transcripts took 9 s to list, on
/// every rescan. A mapped search reads only as far as it must (the whole file only when the
/// marker is absent) and never copies the file.
public enum TranscriptLines {
    public static func first(_ limit: Int, containing marker: String, in file: URL) -> [String] {
        guard limit > 0,
              let data = try? Data(contentsOf: file, options: .alwaysMapped), !data.isEmpty else { return [] }
        let needle = Data(marker.utf8)
        var out: [String] = []
        var from = data.startIndex
        while out.count < limit, from < data.endIndex,
              let hit = data.range(of: needle, options: [], in: from..<data.endIndex) {
            let start = data[from..<hit.lowerBound].lastIndex(of: 0x0A).map { $0 + 1 } ?? from
            let end = data[hit.upperBound...].firstIndex(of: 0x0A) ?? data.endIndex
            if let line = String(data: data[start..<end], encoding: .utf8) { out.append(line) }
            from = end < data.endIndex ? end + 1 : data.endIndex
        }
        return out
    }
}
