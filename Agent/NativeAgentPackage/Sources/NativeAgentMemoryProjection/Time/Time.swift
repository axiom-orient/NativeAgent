import Foundation

func nowMS() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1_000)
}
