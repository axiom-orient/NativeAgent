import Foundation
import KnowledgeCore

package struct SQLiteSearchCandidate: Sendable, Equatable {
    package var row: SearchDocRow
    package var snippet: String
    package var ftsRank: Double

    package init(row: SearchDocRow, snippet: String, ftsRank: Double) {
        self.row = row
        self.snippet = snippet
        self.ftsRank = ftsRank
    }
}
