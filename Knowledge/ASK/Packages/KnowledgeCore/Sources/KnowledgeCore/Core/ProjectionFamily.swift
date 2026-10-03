public enum ProjectionFamily: String, Codable, CaseIterable, Sendable {
    case source
    case entity
    case topic
    case current
    case playbook
    case casebook
    case query
    case other
}
