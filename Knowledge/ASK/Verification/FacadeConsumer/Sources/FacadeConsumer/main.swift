import ASK
import Foundation

@main
enum FacadeConsumer {
    static func main() async {
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ask-facade-consumer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let client = ASKClient(configuration: ASKConfiguration(workspaceURL: workspace))
        do {
            let outcome = try await client.apply(try client.plan(.quickStart(ASKQuickStartCommand(
                requestedAt: "2026-07-26T00:00:00Z",
                resetExistingWorkspace: true
            ))))
            guard case .workspaceApplied(let applied) = outcome else {
                throw ASKDiagnostic(
                    code: .integrityViolation,
                    operation: .apply,
                    message: "quickStart did not produce a workspace result"
                )
            }
            let slug = applied.projectionSlug
            let reads: [(String, ASKQuery)] = [
                ("evidenceSearch", .searchEvidence(ASKEvidenceSearchQuery(text: "onboarding quick-start"))),
                ("knowledgeSearch", .searchKnowledge(ASKKnowledgeSearchQuery(text: "onboarding quick-start"))),
                ("projection", .projection(ASKProjectionQuery(slug: slug))),
                ("markdownPage", .markdownPage(ASKMarkdownPageQuery(markdown: "# Consumer\n\nMarkdown route."))),
                ("readingContext", .readingContext(ASKReadingContextQuery(projectionSlug: slug))),
                ("storageHealth", .storageHealth(ASKStorageHealthQuery())),
            ]
            print("WRITE quickStart PASS indexed=\(applied.indexedCount) slug=\(slug)")
            for (name, query) in reads {
                let result = try await client.query(query)
                print("READ \(name) PASS result=\(result)")
            }
        } catch {
            print("FACADE FAIL error=\(error)")
            Foundation.exit(1)
        }
    }
}
