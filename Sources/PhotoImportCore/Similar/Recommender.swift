import Foundation

public struct Recommendation: Equatable, Sendable {
    /// Index of the recommended photo.
    public let best: Int
    /// Overall score per photo, 0–1.
    public let totals: [Double]
    /// Plain-language reasons the best photo won, e.g. ["Sharpest", "Eyes open"].
    public let reasons: [String]
}

/// Picks the best photo in a group. Every signal is relative to the rest of the group, since "sharp" or
/// "good-looking" only means something compared to the alternatives.
public enum Recommender {
    static let weights = (sharpness: 0.35, eyes: 0.25, face: 0.15, level: 0.10, look: 0.15)

    public static func recommend(_ scores: [PhotoScore]) -> Recommendation? {
        guard !scores.isEmpty else { return nil }
        let maxSharp = max(scores.map(\.sharpness).max() ?? 0, 1e-9)
        let anyFaces = scores.contains { $0.faces > 0 }
        let maxFace = scores.compactMap(\.faceQuality).max()
        let looks = scores.compactMap(\.aesthetics)
        let (minLook, maxLook) = (looks.min() ?? 0, looks.max() ?? 0)

        func parts(_ s: PhotoScore) -> (sharp: Double, eyes: Double, face: Double, level: Double, look: Double) {
            let sharp = s.sharpness / maxSharp
            // In a group with people, a photo where nobody's face is found (turned away) counts as eyes closed.
            let eyes = anyFaces ? (s.faces == 0 ? 0 : Double(s.facesWithEyesOpen) / Double(s.faces)) : 1
            let face = maxFace.map { $0 > 0 ? (s.faceQuality ?? 0) / $0 : 1 } ?? 1
            let level = s.tiltDegrees.map { max(0, 1 - abs($0) / 10) } ?? 1
            let look = maxLook > minLook ? ((s.aesthetics ?? minLook) - minLook) / (maxLook - minLook) : 1
            return (sharp, eyes, face, level, look)
        }

        let w = weights
        let totals = scores.map { s -> Double in
            let p = parts(s)
            return w.sharpness * p.sharp + w.eyes * p.eyes + w.face * p.face + w.level * p.level + w.look * p.look
        }
        // Ties go to the earliest photo.
        let best = totals.indices.max { totals[$0] < totals[$1] || (totals[$0] == totals[$1] && $0 > $1) }!

        let winner = scores[best]
        var reasons: [String] = []
        if winner.sharpness >= maxSharp { reasons.append("Sharpest") }
        if anyFaces, winner.faces > 0, winner.facesWithEyesOpen == winner.faces { reasons.append("Eyes open") }
        if let tilt = winner.tiltDegrees, abs(tilt) < 1.5 { reasons.append("Level") }
        if let look = winner.aesthetics, maxLook > minLook, look >= maxLook { reasons.append("Best composition") }
        return Recommendation(best: best, totals: totals, reasons: reasons)
    }
}
