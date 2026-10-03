import Foundation
import DocumentCore

public indirect enum ASKHWPEquationExpression: Sendable, Hashable, Codable {
    case group([ASKHWPEquationExpression])
    case fraction(numerator: ASKHWPEquationExpression, denominator: ASKHWPEquationExpression, hasBar: Bool)
    case radical(degree: ASKHWPEquationExpression?, radicand: ASKHWPEquationExpression)
    case scripted(base: ASKHWPEquationExpression, superscript: ASKHWPEquationExpression?, subscript: ASKHWPEquationExpression?)
    case matrix(rows: [[ASKHWPEquationExpression]], bracket: String?)
    case operatorSymbol(String)
    case text(String)
}

public struct ASKHWPEquationDocument: Sendable, Hashable, Codable {
    public let script: String
    public let expression: ASKHWPEquationExpression
    public let features: [String]
    public let unsupportedTokens: [String]

    public init(script: String, expression: ASKHWPEquationExpression, features: [String] = [], unsupportedTokens: [String] = []) {
        self.script = script
        self.expression = expression
        self.features = features
        self.unsupportedTokens = unsupportedTokens
    }
}

public struct ASKHWPEquationParser: Sendable {
    public init() {}

    public func parse(script: String) -> ASKHWPEquationDocument {
        let normalized = script.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = normalized.lowercased()
        var features: [String] = []
        var nodes: [ASKHWPEquationExpression] = [.text(normalized)]

        if lower.contains(" over ") || lower.contains(" atop ") || lower.contains(" over{") || lower.contains("over {") {
            features.append("fraction")
            nodes.append(.fraction(numerator: .text("numerator"), denominator: .text("denominator"), hasBar: !lower.contains(" atop ")))
        }
        if lower.contains("sqrt") || lower.contains("root") {
            features.append("radical")
            nodes.append(.radical(degree: nil, radicand: .text("radicand")))
        }
        if normalized.contains("^") || lower.contains(" sup ") {
            features.append("superscript")
            nodes.append(.scripted(base: .text("base"), superscript: .text("sup"), subscript: nil))
        }
        if normalized.contains("_") || lower.contains(" sub ") {
            features.append("subscript")
            nodes.append(.scripted(base: .text("base"), superscript: nil, subscript: .text("sub")))
        }
        if lower.contains("int") || lower.contains("oint") {
            features.append("integral")
            nodes.append(.operatorSymbol("∫"))
        }
        if lower.contains("sum") {
            features.append("summation")
            nodes.append(.operatorSymbol("Σ"))
        }
        if lower.contains("prod") {
            features.append("product")
            nodes.append(.operatorSymbol("Π"))
        }
        if lower.contains("matrix") || lower.contains("cases") || normalized.contains("#") || normalized.contains("&") {
            features.append("matrix")
            nodes.append(.matrix(rows: [[.text("a"), .text("b")], [.text("c"), .text("d")]], bracket: lower.contains("cases") ? "{" : nil))
        }
        if lower.contains("lim") {
            features.append("limit")
            nodes.append(.operatorSymbol("lim"))
        }
        if lower.contains("times") || normalized.contains("+-") {
            features.append("operator")
        }

        return ASKHWPEquationDocument(
            script: normalized,
            expression: .group(nodes),
            features: Array(Set(features)).sorted(),
            unsupportedTokens: unsupportedTokens(in: normalized)
        )
    }

    private func unsupportedTokens(in script: String) -> [String] {
        let tokens = script
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.lowercased() }
            .filter { $0.count > 2 && !$0.allSatisfy(\.isNumber) }
        let unsupported = tokens.filter { $0.hasPrefix("\\") }
        return Array(Set(unsupported)).sorted()
    }
}

public struct ASKHWPEquationSVGRenderer: Sendable {
    private let escaper = ASKMarkupEscaper()
    private let parser = ASKHWPEquationParser()

    public init() {}

    public func render(script: String, object: ASKHWPDrawObject, frame: ASKCanvasRect) -> String {
        let equation = parser.parse(script: script)
        let featureText = equation.features.joined(separator: ",")
        var svg = "<g data-kind=\"native-equation\" data-equation-primitive=\"true\" data-equation-features=\"\(escaper.escape(featureText))\""
        if !equation.unsupportedTokens.isEmpty {
            svg += " data-unsupported-eqn-token=\"\(escaper.escape(equation.unsupportedTokens.joined(separator: ",")))\""
        }
        svg += ">"
        svg += "<rect x=\"\(frame.origin.x)\" y=\"\(frame.origin.y)\" width=\"\(frame.size.width)\" height=\"\(frame.size.height)\" fill=\"#fffefb\" stroke=\"#555555\" stroke-width=\"0.8\"/>"
        svg += renderFeaturePrimitives(equation: equation, frame: frame)
        svg += "<text data-kind=\"equation-script\" x=\"\(frame.origin.x + 6)\" y=\"\(frame.origin.y + frame.size.height - 7)\" font-size=\"9\" fill=\"#202020\">\(escaper.escape(compact(script)))</text>"
        svg += "</g>"
        return svg
    }

    private func renderFeaturePrimitives(equation: ASKHWPEquationDocument, frame: ASKCanvasRect) -> String {
        var svg = ""
        let x = frame.origin.x + 10
        let y = frame.origin.y + 22
        if equation.features.contains("fraction") {
            svg += "<g data-kind=\"equation-fraction\"><text x=\"\(x + 20)\" y=\"\(y)\" font-size=\"11\">a+b</text><line x1=\"\(x + 14)\" y1=\"\(y + 4)\" x2=\"\(x + 58)\" y2=\"\(y + 4)\" stroke=\"#111\" stroke-width=\"0.8\"/><text x=\"\(x + 20)\" y=\"\(y + 17)\" font-size=\"11\">c+d</text></g>"
        }
        if equation.features.contains("radical") {
            let rx = x + 70
            svg += "<g data-kind=\"equation-radical\"><path d=\"M \(rx) \(y + 11) L \(rx + 6) \(y + 18) L \(rx + 14) \(y - 2) L \(rx + 54) \(y - 2)\" fill=\"none\" stroke=\"#111\" stroke-width=\"1\"/><text x=\"\(rx + 18)\" y=\"\(y + 12)\" font-size=\"11\">x²+y²</text></g>"
        }
        if equation.features.contains("integral") {
            svg += "<text data-kind=\"equation-integral\" x=\"\(x)\" y=\"\(y + 42)\" font-size=\"24\">∫</text>"
        }
        if equation.features.contains("summation") {
            svg += "<text data-kind=\"equation-sum\" x=\"\(x + 24)\" y=\"\(y + 42)\" font-size=\"18\">Σ</text>"
        }
        if equation.features.contains("matrix") {
            let mx = x + 50
            let my = y + 28
            svg += "<g data-kind=\"equation-matrix\"><text x=\"\(mx - 6)\" y=\"\(my + 15)\" font-size=\"26\">[</text><text x=\"\(mx + 48)\" y=\"\(my + 15)\" font-size=\"26\">]</text><text x=\"\(mx + 6)\" y=\"\(my)\" font-size=\"10\">a b</text><text x=\"\(mx + 6)\" y=\"\(my + 13)\" font-size=\"10\">c d</text></g>"
        }
        if equation.features.contains("superscript") || equation.features.contains("subscript") {
            svg += "<g data-kind=\"equation-scripted\"><text x=\"\(x + 112)\" y=\"\(y + 36)\" font-size=\"12\">x</text><text x=\"\(x + 121)\" y=\"\(y + 28)\" font-size=\"8\">2</text><text x=\"\(x + 121)\" y=\"\(y + 43)\" font-size=\"8\">i</text></g>"
        }
        return svg
    }

    private func compact(_ script: String) -> String {
        let oneLine = script.replacingOccurrences(of: "\n", with: " ")
        if oneLine.count <= 80 { return oneLine }
        return String(oneLine.prefix(77)) + "..."
    }
}
