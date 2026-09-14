import Foundation
import UIKit

/// Small airline marks for the Live Activity. ActivityKit allows about 4 KB for
/// everything an activity carries, so each logo is a 40-pt JPEG on white kept
/// under 2 KB — fetched once per airline and kept on disk.
enum AirlineLogos {
    private static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("logos")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()
    private static let maxBytes = 2600
    @MainActor private static var inFlight: Set<String> = []

    /// The airline code from the flight number: "3U3960" → "3U".
    static func code(for flightNumber: String) -> String { String(flightNumber.prefix(2)).uppercased() }

    /// What is on disk now, or nil; when nil, a download starts and `onArrival` fires once it is saved.
    @MainActor
    static func thumbnail(for flightNumber: String, onArrival: @escaping @Sendable () -> Void) -> Data? {
        let code = code(for: flightNumber)
        let file = dir.appendingPathComponent("\(code)-mark.jpg")
        if let data = try? Data(contentsOf: file) { return data.isEmpty ? nil : data }
        guard !inFlight.contains(code) else { return nil }
        inFlight.insert(code)
        // The square mark (the symbol, no wordmark) first; the wide logo only if there is none.
        let sources = ["https://images.kiwi.com/airlines/64/\(code).png", "https://pics.avs.io/120/120/\(code).png"].compactMap(URL.init)
        Task.detached(priority: .utility) {
            var out: Data?
            var missing = true  // every source said 404: an empty file remembers that; a network failure is retried
            for url in sources {
                guard let (data, resp) = try? await URLSession.shared.data(from: url), let http = resp as? HTTPURLResponse else { missing = false; continue }
                if http.statusCode == 200, let image = UIImage(data: data), let small = shrink(image) { out = small; break }
                if http.statusCode != 404 { missing = false }
            }
            if let out { try? out.write(to: file, options: .atomic) }
            else if missing { try? Data().write(to: file, options: .atomic) }
            await MainActor.run { inFlight.remove(code) }
            if out != nil { onArrival() }
        }
        return nil
    }

    /// 56 px square on white, JPEG, quality (then size) lowered until it fits the budget.
    private static func shrink(_ image: UIImage) -> Data? {
        for side in [56.0, 44.0, 32.0] {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let drawn = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { ctx in
                UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
                image.draw(in: CGRect(x: 3, y: 3, width: side - 6, height: side - 6))
            }
            for q in [0.75, 0.55, 0.4, 0.25] {
                if let d = drawn.jpegData(compressionQuality: q), d.count <= maxBytes { return d }
            }
        }
        return nil
    }
}
