import Foundation
import KeepersCore

// keepers-eval <folder> [--preset strict|balanced|lenient] [--fresh] [--signals]
//
// Analyzes a folder like the app does (sharing its cache), prints the folder
// decisions, and, when the folder has hand-made placements from the app,
// how often the engine agrees with them. Doesn't touch the output folders.

let args = Array(CommandLine.arguments.dropFirst())
guard let path = args.first(where: { !$0.hasPrefix("--") }) else {
    FileHandle.standardError.write("usage: keepers-eval <folder> [--preset strict|balanced|lenient] [--fresh] [--signals]\n".data(using: .utf8)!)
    exit(2)
}
let presetArg = args.firstIndex(of: "--preset").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
let preset = presetArg.flatMap(Preset.init(rawValue:)) ?? .balanced
let fresh = args.contains("--fresh")
let showSignals = args.contains("--signals")

let folder = URL(fileURLWithPath: path).standardizedFileURL
let session = try CullSession(inputDirectory: folder)
let start = Date()
try await session.analyze(fresh: fresh) { p in
    if let name = p.current { FileHandle.standardError.write("\r[\(p.done)/\(p.total)] \(name)        ".data(using: .utf8)!) }
}
FileHandle.standardError.write("\n".data(using: .utf8)!)
let elapsed = Date().timeIntervalSince(start)

let result = Culler.cull(session.analyses, preset: preset)
func f(_ x: Double?) -> String { x.map { String(format: "%.2f", $0) } ?? "  - " }

if showSignals {
    print("name\tquality\tsharp\tfocusE\tglobalE\texpo\thiClip\tloClip\taesth\tfaces\tface\tsmile\tblink\tgroup\tfolder\treasons")
}
for (g, ids) in result.groups.enumerated() {
    for name in ids {
        let a = session.analyses[name]!, s = result.scores[name]!, d = result.decisions[name]!
        if showSignals {
            let p = a.primaryFace
            print([name, f(s.quality), f(s.sharpness), f(a.subjectFocus), f(a.globalFocus), f(s.exposure),
                   f(a.exposure.highlightClip), f(a.exposure.shadowClip), f(s.aesthetics),
                   "\(a.subjectFaces.count)/\(a.faces.count)", f(s.face),
                   p?.smiling.map { $0 ? "y" : "n" } ?? "-", p?.eyesClosed.map { $0 ? "y" : "n" } ?? "-",
                   "\(g)", d.folder.rawValue, d.reasons.joined(separator: "; ")].joined(separator: "\t"))
        }
    }
}
let trashed = result.decisions.filter { $0.value.group < 0 }.keys.sorted()
if showSignals {
    for name in trashed {
        let a = session.analyses[name]!, s = result.scores[name]!
        print([name, f(s.quality), f(s.sharpness), f(a.subjectFocus), f(a.globalFocus), f(s.exposure),
               f(a.exposure.highlightClip), f(a.exposure.shadowClip), f(s.aesthetics),
               "\(a.subjectFaces.count)/\(a.faces.count)", f(s.face), "-", "-", "-", "Trash",
               result.decisions[name]!.reasons.joined(separator: "; ")].joined(separator: "\t"))
    }
}

var counts: [Folder: Int] = [:]
for d in result.decisions.values { counts[d.folder, default: 0] += 1 }
print("\n\(session.photos.count) photos, \(session.failures.count) unreadable, \(result.groups.count) groups, analysis \(String(format: "%.1f", elapsed))s, preset \(preset.rawValue)")
print(Folder.allCases.map { "\($0.rawValue): \(counts[$0] ?? 0)" }.joined(separator: "  "))
for (name, error) in session.failures.sorted(by: { $0.key < $1.key }) { print("unreadable: \(name): \(error)") }

let manual = session.store.placements
if !manual.isEmpty {
    var agree = 0
    var confusion: [String: Int] = [:]
    for (name, chosen) in manual {
        guard let engine = result.decisions[name]?.folder else { continue }
        if engine == chosen { agree += 1 }
        confusion["\(engine.rawValue) -> \(chosen.rawValue)", default: 0] += 1
    }
    print("\nAgreement with \(manual.count) hand placements: \(agree)/\(manual.count)")
    for (k, v) in confusion.sorted(by: { $0.key < $1.key }) { print("  engine \(k): \(v)") }
}
