import Foundation
import StillMotionsPipeline

/// Fits `SizeModel` to real exports and scores it (issue #31).
struct Evaluation {
    typealias Sample = EstimateAccuracy.Sample

    struct Group: Codable {
        let name: String
        let count: Int
        let within25: Double          // share of exports estimated within +-25% of actual
        let medianRatio: Double       // estimate / actual
        let worstRatio: Double        // the ratio furthest from 1
    }
    struct Worst: Codable {
        let clip: String, format: String, mode: String, preset: String, rate: String?
        let actualBytes: Int, estimatedBytes: Int, ratio: Double
        let detail: Double, edgeDensity: Double, change: Double, cropRetention: Double, sourceFrameRate: Double
    }
    struct Summary: Codable {
        let exports: Int, clips: Int
        /// The headline: models fitted on four fifths of the clips, scored on the other fifth, five times.
        let crossValidatedWithin25: Double
        let crossValidatedGifWithin25: Double
        let crossValidatedMp4Within25: Double
        /// The final model scored on the clips it was fitted on. Optimistic; shown for reference.
        let fittedWithin25: Double
        let fittedClipsAllWithin25: Double
        let frameCountMismatches: Int
        let groups: [Group]
        let worst: [Worst]
        let fittedModel: SizeModel
        let ratioPercentiles: [String: Double]
    }

    let summary: Summary
    let markdown: String

    static let tolerance = 0.25
    static let folds = 5
    /// The terms the GIF model uses.
    static let terms = SizeTerm.allCases

    static func input(_ s: Sample) -> SizeInput {
        SizeInput(
            format: ExportFormat(rawValue: s.format) ?? .gif, width: s.width, height: s.height, frameCount: s.plannedFrames,
            gifRate: s.rate.flatMap(GifFrameRate.init(rawValue:)) ?? .fps20, sourceFrameRate: s.sourceFrameRate,
            cropRetention: s.cropRetention, isBounce: s.mode == "bounce", content: s.content
        )
    }

    static func ratio(_ s: Sample, _ model: SizeModel) -> Double {
        Double(SizeEstimator(model: model).estimate(input(s))) / Double(max(1, s.bytes))
    }
    static func within(_ ratio: Double) -> Bool { abs(ratio - 1) <= tolerance }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    // MARK: - Fitting

    /// Ordinary least squares by the normal equations, with a tiny ridge so collinear terms cannot make
    /// the system singular. `rows` are the term values, `y` the targets. Returns intercept + weights.
    static func leastSquares(rows: [[Double]], y: [Double]) -> [Double]? {
        guard let first = rows.first else { return nil }
        let p = first.count + 1
        var a = [[Double]](repeating: [Double](repeating: 0, count: p + 1), count: p)
        for (row, target) in zip(rows, y) {
            let x = [1.0] + row
            for i in 0..<p {
                for j in 0..<p { a[i][j] += x[i] * x[j] }
                a[i][p] += x[i] * target
            }
        }
        for i in 1..<p { a[i][i] += 1e-6 * Double(rows.count) }
        // Gaussian elimination with partial pivoting.
        for col in 0..<p {
            guard let pivot = (col..<p).max(by: { abs(a[$0][col]) < abs(a[$1][col]) }), abs(a[pivot][col]) > 1e-12 else { return nil }
            a.swapAt(col, pivot)
            for r in 0..<p where r != col {
                let factor = a[r][col] / a[col][col]
                if factor != 0 { for c in col...p { a[r][c] -= factor * a[col][c] } }
            }
        }
        return (0..<p).map { a[$0][p] / a[$0][$0] }
    }

    /// The model that best fits `samples`: GIF by least squares on ln(bytes per pixel per frame),
    /// MP4 as the median fraction of the encoder's bitrate target the files reach.
    static func fit(_ samples: [Sample]) -> SizeModel {
        let gif = samples.filter { $0.format == "gif" && $0.content != nil }
        let contents = samples.compactMap(\.content)
        func mean(_ key: KeyPath<ContentFeatures, Double>) -> Double { contents.isEmpty ? 0 : contents.map { $0[keyPath: key] }.reduce(0, +) / Double(contents.count) }
        let typical = ContentFeatures(
            detail: mean(\.detail), edgeDensity: mean(\.edgeDensity), change: mean(\.change),
            changeFraction: mean(\.changeFraction), colorEntropy: mean(\.colorEntropy)
        )

        var model = SizeModel(gifIntercept: 0, gifWeights: [:], typicalContent: typical, mp4FractionOfTarget: 1)
        let rows = gif.map { s in terms.map { model.value(of: $0, for: input(s)) } }
        let targets = gif.map { log(Double($0.bytes) / Double($0.width * $0.height * $0.plannedFrames)) }
        if let beta = leastSquares(rows: rows, y: targets) {
            model.gifIntercept = beta[0]
            for (i, term) in terms.enumerated() { model.gifWeights[term] = beta[i + 1] }
        }

        let unit = SizeEstimator(model: model)
        let mp4 = samples.filter { $0.format == "mp4" }.map { Double($0.bytes) / Double(max(1, unit.estimate(input($0)))) }
        model.mp4FractionOfTarget = mp4.isEmpty ? 1 : median(mp4)
        return model
    }

    // MARK: - Report

    init(samples: [Sample]) {
        // Cross-validation: five folds of clips. Each fold is scored by a model that never saw its clips.
        let clips = Array(Set(samples.map(\.clip))).sorted()
        var hits = 0, total = 0, gifHits = 0, gifTotal = 0, mp4Hits = 0, mp4Total = 0
        for fold in 0..<Self.folds {
            let held = Set(clips.enumerated().filter { $0.offset % Self.folds == fold }.map(\.element))
            let train = samples.filter { !held.contains($0.clip) }
            let model = Self.fit(train)
            for s in samples where held.contains(s.clip) && (s.format == "mp4" || s.content != nil) {
                let ok = Self.within(Self.ratio(s, model))
                total += 1; hits += ok ? 1 : 0
                if s.format == "gif" { gifTotal += 1; gifHits += ok ? 1 : 0 } else { mp4Total += 1; mp4Hits += ok ? 1 : 0 }
            }
        }

        let fitted = Self.fit(samples)
        let scored = samples.filter { $0.format == "mp4" || $0.content != nil }
        let ratios = scored.map { Self.ratio($0, fitted) }.sorted()
        func percentile(_ p: Double) -> Double { ratios.isEmpty ? 0 : ratios[min(ratios.count - 1, Int(p * Double(ratios.count)))] }

        func group(_ name: String, _ items: [Sample]) -> Group {
            let r = items.map { Self.ratio($0, fitted) }
            return Group(
                name: name, count: items.count, within25: Double(r.filter(Self.within).count) / Double(max(1, r.count)),
                medianRatio: Self.median(r), worstRatio: r.max { abs($0 - 1) < abs($1 - 1) } ?? 1
            )
        }
        var groups: [Group] = []
        for format in ["gif", "mp4"] {
            for preset in SizePreset.allCases {
                let mine = scored.filter { $0.format == format && $0.preset == preset.rawValue }
                if !mine.isEmpty { groups.append(group("\(format) \(preset.rawValue)", mine)) }
            }
        }
        for rate in GifFrameRate.allCases {
            let mine = scored.filter { $0.format == "gif" && $0.rate == rate.rawValue }
            if !mine.isEmpty { groups.append(group("gif \(rate.rawValue)", mine)) }
        }
        for mode in ["loop", "bounce", "once"] {
            let mine = scored.filter { $0.mode == mode }
            if !mine.isEmpty { groups.append(group("mode \(mode)", mine)) }
        }

        let byClip = Dictionary(grouping: scored, by: \.clip)
        let worst = scored.sorted { abs(Self.ratio($0, fitted) - 1) > abs(Self.ratio($1, fitted) - 1) }.prefix(8).map { s in
            Worst(
                clip: s.clip, format: s.format, mode: s.mode, preset: s.preset, rate: s.rate, actualBytes: s.bytes,
                estimatedBytes: SizeEstimator(model: fitted).estimate(Self.input(s)), ratio: Self.ratio(s, fitted),
                detail: s.content?.detail ?? 0, edgeDensity: s.content?.edgeDensity ?? 0, change: s.content?.change ?? 0,
                cropRetention: s.cropRetention, sourceFrameRate: s.sourceFrameRate
            )
        }
        let summary = Summary(
            exports: scored.count, clips: byClip.count,
            crossValidatedWithin25: Double(hits) / Double(max(1, total)),
            crossValidatedGifWithin25: Double(gifHits) / Double(max(1, gifTotal)),
            crossValidatedMp4Within25: Double(mp4Hits) / Double(max(1, mp4Total)),
            fittedWithin25: Double(ratios.filter(Self.within).count) / Double(max(1, ratios.count)),
            fittedClipsAllWithin25: Double(byClip.values.filter { $0.allSatisfy { Self.within(Self.ratio($0, fitted)) } }.count) / Double(max(1, byClip.count)),
            frameCountMismatches: samples.filter { $0.frames != $0.plannedFrames }.count,
            groups: groups, worst: Array(worst), fittedModel: fitted,
            ratioPercentiles: ["p5": percentile(0.05), "p25": percentile(0.25), "p50": percentile(0.5), "p75": percentile(0.75), "p95": percentile(0.95)]
        )
        self.summary = summary

        var md = "# Size estimate accuracy\n\n"
        md += String(
            format: "%d exports from %d clips.\n\n**On clips the model was not fitted on (5-fold cross-validation): %.1f%% of exports within ±25%%** (bar: 80%%). GIF %.1f%%, MP4 %.1f%%.\n\nThe final model on the clips it was fitted on: %.1f%% of exports; %.1f%% of clips have every export within ±25%%. Frame-count mismatches (planned vs written): %d.\n\n",
            summary.exports, summary.clips, summary.crossValidatedWithin25 * 100, summary.crossValidatedGifWithin25 * 100,
            summary.crossValidatedMp4Within25 * 100, summary.fittedWithin25 * 100, summary.fittedClipsAllWithin25 * 100, summary.frameCountMismatches
        )
        md += String(format: "estimate / actual percentiles (fitted model): p5 %.2f, p25 %.2f, p50 %.2f, p75 %.2f, p95 %.2f\n\n", percentile(0.05), percentile(0.25), percentile(0.5), percentile(0.75), percentile(0.95))
        md += "| group | exports | within ±25% | median est/actual | worst est/actual |\n| --- | ---: | ---: | ---: | ---: |\n"
        for g in groups { md += String(format: "| %@ | %d | %.1f%% | %.2f | %.2f |\n", g.name, g.count, g.within25 * 100, g.medianRatio, g.worstRatio) }
        md += "\n## Worst cases (fitted model)\n\n| clip | export | actual | estimate | est/actual | detail | edges | change | crop kept | src fps |\n| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |\n"
        for w in worst {
            md += String(format: "| %@ | %@ %@ %@%@ | %d | %d | %.2f | %.1f | %.2f | %.1f | %.0f%% | %.0f |\n", w.clip, w.format, w.mode, w.preset, w.rate.map { " " + $0 } ?? "", w.actualBytes, w.estimatedBytes, w.ratio, w.detail, w.edgeDensity, w.change, w.cropRetention * 100, w.sourceFrameRate)
        }
        md += "\n## Fitted coefficients (paste into `SizeModel.shipped`)\n\n```swift\n"
        md += String(format: "gifIntercept: %.6f,\ngifWeights: [\n", fitted.gifIntercept)
        for term in Self.terms { md += String(format: "    .%@: %.6f,\n", term.rawValue, fitted.gifWeights[term] ?? 0) }
        let c = fitted.typicalContent
        md += String(format: "],\ntypicalContent: ContentFeatures(detail: %.4f, edgeDensity: %.4f, change: %.4f, changeFraction: %.4f, colorEntropy: %.4f),\nmp4FractionOfTarget: %.4f\n```\n", c.detail, c.edgeDensity, c.change, c.changeFraction, c.colorEntropy, fitted.mp4FractionOfTarget)
        markdown = md
    }
}
