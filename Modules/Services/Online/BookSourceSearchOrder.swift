import Foundation

/// One search's snapshot of the user's source-list order (including its pinned region).
/// Build this derived index and sort large result lists off the main actor.
struct BookSourceSearchOrder: Sendable {
    let sourceIDs: Set<UUID>
    private let rankByID: [UUID: Int]

    init(sources: [BookSource]) {
        let ranks = SourcePerfTrace.span(
            "search.sourceOrder.index", "sources=\(sources.count) main=\(Thread.isMainThread)"
        ) {
            var ranks: [UUID: Int] = .init(minimumCapacity: sources.count)
            for source in sources where ranks[source.id] == nil {
                ranks[source.id] = ranks.count
            }
            return ranks
        }
        rankByID = ranks
        sourceIDs = Set(ranks.keys)
    }

    func includes(_ id: UUID) -> Bool { rankByID[id] != nil }

    /// Same-source channels and unknown sources retain their incoming relative order.
    func ordered(_ origins: [BookOrigin]) -> [BookOrigin] {
        orderedIndices(for: origins).map { origins[$0] }
    }

    /// Also used for the aggregator's index-aligned presentation snapshots.
    func orderedIndices(for origins: [BookOrigin]) -> [Int] {
        SourcePerfTrace.span(
            "search.sourceOrder.results", "origins=\(origins.count) main=\(Thread.isMainThread)"
        ) {
            origins.indices.sorted { lhs, rhs in
                let left = rankByID[origins[lhs].sourceId] ?? Int.max
                let right = rankByID[origins[rhs].sourceId] ?? Int.max
                return left == right ? lhs < rhs : left < right
            }
        }
    }
}
