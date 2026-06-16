import Foundation

/// Lightweight subsequence-based fuzzy match (think VSCode / fzf-lite).
/// Returns nil if not a match, else a score where higher = better.
///
/// Scoring rules:
/// - All chars of `query` must appear in `candidate` in order (case-insensitive)
/// - +10 per matched char
/// - +5 bonus if match is adjacent to previous match (consecutive run)
/// - +15 bonus if match is at start of word (after `_`, space, or at index 0)
/// - +5 bonus for matching the very first character of candidate
enum FuzzyMatch {
    static func score(query: String, in candidate: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        let q = Array(query.lowercased())
        let c = Array(candidate.lowercased())
        guard q.count <= c.count else { return nil }

        var qi = 0
        var total = 0
        var lastMatchedIdx: Int = -2

        for (i, ch) in c.enumerated() {
            guard qi < q.count else { break }
            if ch == q[qi] {
                total += 10
                if i == lastMatchedIdx + 1 { total += 5 }
                if i == 0 || c[i - 1] == "_" || c[i - 1] == " " || c[i - 1] == "-" { total += 15 }
                if i == 0 { total += 5 }
                lastMatchedIdx = i
                qi += 1
            }
        }
        return qi == q.count ? total : nil
    }
}
