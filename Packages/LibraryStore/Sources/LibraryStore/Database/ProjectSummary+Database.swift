import CoreModel
import Foundation
import GRDB

extension ProjectSummary {
    static func fetchAll(_ db: Database, limit: Int) throws -> [ProjectSummary] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM project
                ORDER BY modified_at DESC, id ASC
                LIMIT ?
                """,
            arguments: [limit]
        )
        return rows.map { row in
            ProjectSummary(
                id: ProjectID(rawValue: row["id"]),
                name: row["name"],
                packagePath: row["package_path"],
                modifiedAt: Date(timeIntervalSince1970: row["modified_at"]),
                duration: RationalTime(
                    value: row["duration_value"],
                    timescale: row["duration_scale"]
                ),
                itemCount: row["item_count"]
            )
        }
    }
}
