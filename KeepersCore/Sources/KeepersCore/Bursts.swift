import Foundation

/// Groups photos of the same moment: bursts, and re-takes of the same frame.
public struct BurstGrouper {
    /// Frames this close in time are one burst no matter how they look.
    public var burstGap: TimeInterval = 1.5
    /// Frames up to this far apart join a group if they look alike.
    public var similarGap: TimeInterval = 30
    /// Feature-print cosine distance under which two frames look alike.
    public var maxDistance: Double = 0.25
    /// Photos that start a new group, whatever the rules say (set by hand).
    public var breaks: Set<String> = []
    /// Photos that join the previous photo's group (set by hand).
    public var joins: Set<String> = []
    /// Photos that form a group of their own; their neighbours group as if
    /// they weren't there (set by hand).
    public var separated: Set<String> = []

    public init() {}

    public struct Item {
        public var id: String
        public var date: Date
        public var print: FeaturePrint?
        public init(id: String, date: Date, print: FeaturePrint?) {
            self.id = id; self.date = date; self.print = print
        }
    }

    /// Returns groups in capture order; each group's ids are in capture order.
    /// Each photo is compared with the one before it, so a slow pan becomes
    /// one group only while neighbouring frames stay alike.
    public func group(_ items: [Item]) -> [[String]] {
        let sorted = items.sorted { ($0.date, $0.id) < ($1.date, $1.id) }
        var groups: [[String]] = []
        var previous: Item?
        var alone: [[String]] = []
        for item in sorted {
            if separated.contains(item.id) { alone.append([item.id]); continue }
            let together = previous.map { prev in
                joins.contains(item.id) || (!breaks.contains(item.id) && belongTogether(prev, item))
            } ?? false
            if together {
                groups[groups.count - 1].append(item.id)
            } else {
                groups.append([item.id])
            }
            previous = item
        }
        // Lone shots join the list in capture order.
        let firstDate = Dictionary(uniqueKeysWithValues: sorted.map { ($0.id, $0.date) })
        return (groups + alone).sorted { firstDate[$0[0]]! < firstDate[$1[0]]! }
    }

    func belongTogether(_ a: Item, _ b: Item) -> Bool {
        let gap = abs(b.date.timeIntervalSince(a.date))
        if gap <= burstGap { return true }
        guard gap <= similarGap, let pa = a.print, let pb = b.print,
              let d = pa.distance(to: pb) else { return false }
        return d <= maxDistance
    }
}
