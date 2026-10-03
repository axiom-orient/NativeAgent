protocol Database: AnyObject {
    func close() throws
    func execScript(_ sql: String) throws
    func exec(_ sql: String, _ params: [SQLValue]) throws
    func query(_ sql: String, _ params: [SQLValue]) throws -> [SQLRow]
    func changes() -> Int
}

extension Database {
    func exec(_ sql: String) throws {
        try exec(sql, [])
    }

    func query(_ sql: String) throws -> [SQLRow] {
        try query(sql, [])
    }
}
