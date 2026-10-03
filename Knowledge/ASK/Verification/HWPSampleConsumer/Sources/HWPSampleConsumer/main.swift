import Foundation
import HWPDocument

@main
enum HWPSampleConsumer {
    static func main() {
        do {
            let paths = Array(CommandLine.arguments.dropFirst())
                .filter { !$0.hasPrefix("--") }
            guard !paths.isEmpty else {
                throw VerificationError.usage("usage: HWPSampleConsumer <document> [...]")
            }

            let parser = ASKPageHWPNativeParser()
            let compiler = ASKPageHWPNativeCompiler(parser: parser)
            let renderer = ASKHWPPageLayoutRenderer()

            for path in paths {
                let url = URL(fileURLWithPath: path)
                let document = try parser.parse(fileURL: url)
                let compiled = compiler.makeASKPageDocument(from: document, fileURL: url)
                let rendered = try renderer.render(document)
                let paragraphText = document.paragraphs.reduce(0) { $0 + $1.plainText.utf8.count }
                let hasRenderableContent = !document.plainText.isEmpty
                    || !document.tables.isEmpty
                    || !document.images.isEmpty
                    || !document.drawObjects.isEmpty
                guard !document.sections.isEmpty,
                      hasRenderableContent,
                      !compiled.sections.isEmpty,
                      !rendered.pages.isEmpty
                else {
                    throw VerificationError.invalidResult(path)
                }

                print(
                    "SAMPLE PASS path=\(path) format=\(document.format.rawValue) "
                        + "sections=\(document.sections.count) paragraphs=\(document.paragraphs.count) "
                        + "tables=\(document.tables.count) images=\(document.images.count) "
                        + "drawObjects=\(document.drawObjects.count) binaryObjects=\(document.binaryObjects.count) "
                        + "pages=\(rendered.pages.count) pageBlocks=\(compiled.blocks.count) "
                        + "textBytes=\(paragraphText) "
                        + "manifest=\(document.metadata["manifestSectionOrder"] ?? "n/a") "
                        + "styles=\(document.metadata["charStyleCount"] ?? document.metadata["docInfoCharShapeCount"] ?? "n/a")"
                )
            }
        } catch {
            print("SAMPLE FAIL error=\(error)")
            Foundation.exit(1)
        }
    }
}

private enum VerificationError: Error, CustomStringConvertible {
    case usage(String)
    case invalidResult(String)

    var description: String {
        switch self {
        case .usage(let message): return message
        case .invalidResult(let path): return "Document produced no renderable content: \(path)"
        }
    }
}
