enum ASKHWPXSectionEvent: Sendable, Hashable {
  case startElement(name: String, attributes: [String: String])
  case characters(String)
  case endElement(name: String)
}
