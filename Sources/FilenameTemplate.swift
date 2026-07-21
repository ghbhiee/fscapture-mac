import Foundation

/// FastStone filename templates: `$Y $M $D $H $N $S` = date/time fields,
/// a run of `#` = zero-padded auto-increment sequence number.
/// Example: `$Y-$M-$D_$H$N$S` -> `2026-07-20_193045`.
enum FilenameTemplate {

    /// Expands `template`; consumes (increments) the shared sequence counter
    /// only when the template actually contains `#`.
    static func expand(_ template: String, date: Date = Date()) -> String {
        let cal = Calendar.current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func pad(_ v: Int?, _ w: Int) -> String { String(format: "%0\(w)d", v ?? 0) }

        var out = template
        out = out.replacingOccurrences(of: "$Y", with: pad(c.year, 4))
        out = out.replacingOccurrences(of: "$M", with: pad(c.month, 2))
        out = out.replacingOccurrences(of: "$D", with: pad(c.day, 2))
        out = out.replacingOccurrences(of: "$H", with: pad(c.hour, 2))
        out = out.replacingOccurrences(of: "$N", with: pad(c.minute, 2))
        out = out.replacingOccurrences(of: "$S", with: pad(c.second, 2))

        if out.contains("#") {
            let counter = Settings.shared.sequenceCounter
            Settings.shared.sequenceCounter = counter + 1
            var result = ""
            var i = out.startIndex
            while i < out.endIndex {
                if out[i] == "#" {
                    var width = 0
                    while i < out.endIndex && out[i] == "#" {
                        width += 1
                        i = out.index(after: i)
                    }
                    result += String(format: "%0\(width)d", counter)
                } else {
                    result.append(out[i])
                    i = out.index(after: i)
                }
            }
            out = result
        }

        // Strip anything not filesystem-friendly.
        out = out.replacingOccurrences(of: "/", with: "-")
        out = out.replacingOccurrences(of: ":", with: "-")
        return out.isEmpty ? "capture" : out
    }

    /// A collision-free URL for the expanded name in `folder` (appends -1, -2, …).
    static func uniqueURL(in folder: URL, baseName: String, ext: String) -> URL {
        var url = folder.appendingPathComponent(baseName).appendingPathExtension(ext)
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(baseName)-\(n)").appendingPathExtension(ext)
            n += 1
        }
        return url
    }
}
