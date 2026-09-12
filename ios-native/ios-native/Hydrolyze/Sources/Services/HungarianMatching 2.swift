import Foundation

/// HungarianMatching — minimum-cost bipartite matching via the
/// Kuhn-Munkres algorithm. O(n³) time, O(n²) space.
///
/// Extracted from the old `PairingService.swift` (now deleted in
/// Phase 2.6) so the new `PairingEngine` can reuse the same
/// algorithm without re-implementing it.
///
/// Auto-transposes the cost matrix so the smaller dimension becomes
/// the row count (faster, since the algorithm is O(n³)).
enum HungarianMatching {
    /// Solves the assignment problem for an N x M cost matrix.
    /// - Returns: An array of length max(N, M) where value at index i
    ///   is the assigned column index j (0-based), or -1 if unassigned.
    ///   For the smaller dimension, every row gets a column. For the
    ///   larger dimension, some values are -1 (unassigned).
    static func solve(costMatrix: [[Double]]) -> [Int] {
        let n = costMatrix.count
        guard n > 0 else { return [] }
        let m = costMatrix[0].count
        guard m > 0 else { return Array(repeating: -1, count: n) }

        // If the matrix is "wide" (more columns than rows), transpose
        // it so the row count is the smaller dimension. Hungarian is
        // O(n³) where n is the row count.
        let transposed = n > m
        let matrix: [[Double]]
        let rows: Int
        let cols: Int

        if transposed {
            rows = m
            cols = n
            var tempMatrix = Array(repeating: Array(repeating: 0.0, count: cols), count: rows)
            for i in 0..<n {
                for j in 0..<m {
                    tempMatrix[j][i] = costMatrix[i][j]
                }
            }
            matrix = tempMatrix
        } else {
            rows = n
            cols = m
            matrix = costMatrix
        }

        // Kuhn-Munkres algorithm
        var u = Array(repeating: 0.0, count: rows + 1)
        var v = Array(repeating: 0.0, count: cols + 1)
        var p = Array(repeating: 0, count: cols + 1)
        var way = Array(repeating: 0, count: cols + 1)

        for i in 1...rows {
            p[0] = i
            var j0 = 0
            var minv = Array(repeating: Double.infinity, count: cols + 1)
            var used = Array(repeating: false, count: cols + 1)

            repeat {
                used[j0] = true
                let i0 = p[j0]
                var delta = Double.infinity
                var j1 = 0

                for j in 1...cols {
                    if !used[j] {
                        let cur = matrix[i0 - 1][j - 1] - u[i0] - v[j]
                        if cur < minv[j] {
                            minv[j] = cur
                            way[j] = j0
                        }
                        if minv[j] < delta {
                            delta = minv[j]
                            j1 = j
                        }
                    }
                }

                for j in 0...cols {
                    if used[j] {
                        u[p[j]] += delta
                        v[j] -= delta
                    } else {
                        minv[j] -= delta
                    }
                }
                j0 = j1
            } while p[j0] != 0

            repeat {
                let j1 = way[j0]
                p[j0] = p[j1]
                j0 = j1
            } while j0 != 0
        }

        // Build result. result[i] = j means row i is assigned to column j.
        var result = Array(repeating: -1, count: rows)
        for j in 1...cols {
            if p[j] != 0 {
                result[p[j] - 1] = j - 1
            }
        }

        if transposed {
            // The result was for the transposed matrix; we need to
            // map back. For each (original column j, original row i)
            // where the assignment holds, result[i] = j.
            var finalResult = Array(repeating: -1, count: n)
            for i in 0..<rows {
                if result[i] != -1 {
                    finalResult[result[i]] = i
                }
            }
            return finalResult
        }

        return result
    }
}
