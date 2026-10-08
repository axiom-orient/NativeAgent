import Foundation
import DocumentCore

func xmlLocalName(_ name: String) -> String {
  if let separatorIndex = name.lastIndex(of: ":") {
    return String(name[name.index(after: separatorIndex)...])
  }
  return name
}

struct AttributeLookup {
  private let values: [String: String]

  init(_ attributes: [String: String]) {
    var normalized: [String: String] = [:]
    for (key, value) in attributes {
      let localKey = xmlLocalName(key)
      normalized[localKey.lowercased()] = value
    }
    self.values = normalized
  }

  func string(_ keys: [String]) -> String? {
    for key in keys {
      if let value = values[key.lowercased()]?.trimmingCharacters(in: .whitespacesAndNewlines),
        !value.isEmpty
      {
        return value
      }
    }
    return nil
  }

  func int(_ keys: [String]) -> Int? {
    for key in keys {
      guard let value = string([key]) else { continue }
      if let intValue = Int(value) { return intValue }
      if let doubleValue = Double(value), doubleValue.isFinite,
        let roundedValue = Int(exactly: doubleValue.rounded())
      {
        return roundedValue
      }
    }
    return nil
  }

  func double(_ keys: [String]) -> Double? {
    for key in keys {
      guard let value = string([key]), let doubleValue = Double(value), doubleValue.isFinite else {
        continue
      }
      return doubleValue
    }
    return nil
  }

  func bool(_ keys: [String]) -> Bool? {
    guard let value = string(keys)?.lowercased() else { return nil }
    switch value {
    case "true", "1", "yes", "on": return true
    case "false", "0", "no", "off": return false
    default: return nil
    }
  }

  func hwpUnitPoint(_ keys: [String]) -> Double? {
    int(keys).map(ASKHWPPageMetrics.hwpUnitToPoint)
  }

  func pointSize(_ keys: [String]) -> Double? {
    guard let raw = double(keys) else { return nil }
    let normalized = raw > 200 ? raw / 100.0 : raw
    guard normalized.isFinite, normalized > 0 else { return nil }
    return normalized
  }
}
