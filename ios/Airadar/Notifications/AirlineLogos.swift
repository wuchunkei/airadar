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
    private static let maxBytes = 2000
    @MainActor private static var inFlight: Set<String> = []

    /// The airline code from the flight number: "3U3960" → "3U".
    static func code(for flightNumber: String) -> String { String(flightNumber.prefix(2)).uppercased() }

    /// What is on disk now, or nil; when nil, a download starts and `onArrival` fires once it is saved.
    @MainActor
    static func thumbnail(for flightNumber: String, onArrival: @escaping @Sendable () -> Void) -> Data? {
        let code = code(for: flightNumber)
        let file = dir.appendingPathComponent("\(code).jpg")
        if let data = try? Data(contentsOf: file) { return data.isEmpty ? nil : data }
        guard !inFlight.contains(code), let url = URL(string: "https://pics.avs.io/120/120/\(code).png") else { return nil }
        inFlight.insert(code)
        Task.detached(priority: .utility) {
            var out = Data()  // an empty file remembers a miss, so it is not asked for every sync
            if let (data, resp) = try? await URLSession.shared.data(from: url), (resp as? HTTPURLResponse)?.statusCode == 200,
               let image = UIImage(data: data), let small = shrink(image) {
                out = small
            }
            try? out.write(to: file, options: .atomic)
            await MainActor.run { inFlight.remove(code) }
            if !out.isEmpty { onArrival() }
        }
        return nil
    }

    /// 40×40 on white, JPEG, quality lowered until it fits the budget.
    private static func shrink(_ image: UIImage) -> Data? {
        let side: CGFloat = 40
        let format = UIGraphicsImageRendererFormat(); format.scale = 2
        let drawn = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            image.draw(in: CGRect(x: 4, y: 4, width: side - 8, height: side - 8))
        }
        for q in [0.7, 0.5, 0.35, 0.2] {
            if let d = drawn.jpegData(compressionQuality: q), d.count <= maxBytes { return d }
        }
        return nil
    }
}
