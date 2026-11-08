import Foundation
import CoreGraphics

struct TreemapTile: Identifiable {
    let id: UUID
    let rect: CGRect
}

// Squarified treemap (Bruls, Huijsen, van Wijk, 2000).
enum Treemap {
    static func layout(values: [(id: UUID, value: Double)], in bounds: CGRect) -> [TreemapTile] {
        let positives = values.filter { $0.value > 0 }
        guard !positives.isEmpty, bounds.width > 0, bounds.height > 0 else { return [] }

        let totalValue = positives.reduce(0.0) { $0 + $1.value }
        let totalArea = Double(bounds.width * bounds.height)
        let scale = totalArea / totalValue

        // Sort descending by value
        let sorted = positives.sorted { $0.value > $1.value }
        let scaled = sorted.map { Item(id: $0.id, area: $0.value * scale) }

        var tiles: [TreemapTile] = []
        squarify(items: scaled, current: [], rect: bounds, output: &tiles)
        // Never hand SwiftUI a NaN/infinite or empty rect: CALayer throws on NaN bounds.
        return tiles.compactMap { t in
            let r = t.rect
            guard r.origin.x.isFinite, r.origin.y.isFinite, r.width.isFinite, r.height.isFinite,
                  r.width >= 0.5, r.height >= 0.5 else { return nil }
            return t
        }
    }

    private struct Item {
        let id: UUID
        let area: Double
    }

    private static func squarify(
        items: [Item],
        current: [Item],
        rect: CGRect,
        output: inout [TreemapTile]
    ) {
        guard let next = items.first else {
            placeRow(current, in: rect, output: &output)
            return
        }
        guard rect.width > 0.5, rect.height > 0.5 else { return }
        let shorter = Double(min(rect.width, rect.height))
        let candidate = current + [next]
        if current.isEmpty || worstAspectRatio(candidate, side: shorter) <= worstAspectRatio(current, side: shorter) {
            squarify(items: Array(items.dropFirst()), current: candidate, rect: rect, output: &output)
        } else {
            let remaining = placeRow(current, in: rect, output: &output)
            squarify(items: items, current: [], rect: remaining, output: &output)
        }
    }

    @discardableResult
    private static func placeRow(_ row: [Item], in rect: CGRect, output: inout [TreemapTile]) -> CGRect {
        guard !row.isEmpty, rect.width > 0.5, rect.height > 0.5 else { return rect }
        let totalArea = row.reduce(0.0) { $0 + $1.area }
        let horizontal = rect.width >= rect.height
        if horizontal {
            // Stack vertically along left side, width determined by area/height
            let width = min(rect.width, CGFloat(totalArea) / rect.height)
            var y = rect.minY
            for item in row {
                let h = CGFloat(item.area) / max(width, 0.0001)
                let r = CGRect(x: rect.minX, y: y, width: width, height: h)
                output.append(TreemapTile(id: item.id, rect: r))
                y += h
            }
            return CGRect(x: rect.minX + width, y: rect.minY, width: rect.width - width, height: rect.height)
        } else {
            // Stack horizontally along top, height determined by area/width
            let height = min(rect.height, CGFloat(totalArea) / rect.width)
            var x = rect.minX
            for item in row {
                let w = CGFloat(item.area) / max(height, 0.0001)
                let r = CGRect(x: x, y: rect.minY, width: w, height: height)
                output.append(TreemapTile(id: item.id, rect: r))
                x += w
            }
            return CGRect(x: rect.minX, y: rect.minY + height, width: rect.width, height: rect.height - height)
        }
    }

    private static func worstAspectRatio(_ row: [Item], side: Double) -> Double {
        guard !row.isEmpty else { return .infinity }
        let sum = row.reduce(0.0) { $0 + $1.area }
        let minItem = max(row.map(\.area).min()!, 1e-9)
        let maxItem = row.map(\.area).max()!
        let s2 = max(side * side, 1e-9)
        let sum2 = max(sum * sum, 1e-9)
        return max((s2 * maxItem) / sum2, sum2 / (s2 * minItem))
    }
}
