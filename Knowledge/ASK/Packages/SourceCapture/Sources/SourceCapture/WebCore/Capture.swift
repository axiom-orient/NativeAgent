import Foundation
import KnowledgeCore

public enum WebCapture {
    public static func captureHTMLText(
        _ html: String,
        pageURL: String,
        sourceID: String,
        observedAt: String,
        rawRelpath: String,
        connector: String = "official-web-snapshot",
        capturedAt: String? = nil,
        tags: [String] = [],
        metadata: ASKFields = [:],
        sourceKind: SourceKind = .url,
        transport: String = "html_text"
    ) throws -> WebCaptureBundle {
        try captureHTMLData(
            Data(html.utf8),
            url: pageURL,
            finalURL: pageURL,
            contentType: "text/html",
            statusCode: 200,
            sourceID: sourceID,
            observedAt: observedAt,
            capturedAt: capturedAt ?? observedAt,
            rawRelpath: rawRelpath,
            connector: connector,
            tags: tags,
            metadata: metadata,
            sourceKind: sourceKind,
            transport: transport
        )
    }

    public static func captureHTMLFile(
        at fileURL: URL,
        pageURL: String,
        sourceID: String,
        observedAt: String,
        rawRelpath: String,
        connector: String = "official-web-snapshot",
        capturedAt: String? = nil,
        tags: [String] = [],
        metadata: ASKFields = [:]
    ) throws -> WebCaptureBundle {
        var merged = metadata
        merged["snapshot_filename"] = fileURL.lastPathComponent
        return try captureHTMLData(
            Data(contentsOf: fileURL),
            url: pageURL,
            finalURL: pageURL,
            contentType: "text/html",
            statusCode: 200,
            sourceID: sourceID,
            observedAt: observedAt,
            capturedAt: capturedAt ?? observedAt,
            rawRelpath: rawRelpath,
            connector: connector,
            tags: tags,
            metadata: merged,
            sourceKind: .url,
            transport: "file_snapshot"
        )
    }

    public static func captureHTMLData(
        _ rawBytes: Data,
        url: String,
        finalURL: String,
        contentType: String?,
        statusCode: Int?,
        sourceID: String,
        observedAt: String,
        capturedAt: String,
        rawRelpath: String,
        connector: String,
        tags: [String],
        metadata: ASKFields,
        sourceKind: SourceKind,
        transport: String
    ) throws -> WebCaptureBundle {
        guard let html = String(data: rawBytes, encoding: .utf8) else {
            throw ASKError.validation("captured HTML is not valid UTF-8")
        }
        let extraction = try WebExtractor.extractPage(html: html, url: finalURL)
        let noteRelpath = ".ask/collector/web/\(sourceID)/curated_note.md"
        let domainTags = inferDomainTag(from: finalURL).map { [$0] } ?? []
        let mergedTags = Array(NSOrderedSet(array: tags + domainTags)).compactMap { $0 as? String }
        var mergedMetadata = metadata
        mergedMetadata["original_url"] = url
        mergedMetadata["final_url"] = finalURL
        mergedMetadata["canonical_url"] = extraction.canonicalURL ?? finalURL
        mergedMetadata["site_name"] = extraction.siteName ?? ""
        mergedMetadata["http_status"] = String(statusCode ?? 0)
        mergedMetadata["content_type"] = contentType ?? ""
        mergedMetadata["published_at"] = extraction.publishedAt ?? ""
        mergedMetadata["description"] = extraction.description ?? ""
        mergedMetadata["capture_transport"] = transport
        mergedMetadata["fragment_count"] = String(extraction.fragments.count)
        mergedMetadata["capture_version"] = collectedCaptureManifestVersion

        var manifestFragments: [CollectedCaptureFragment] = []
        var collectedFragments: [CollectedFragment] = []
        for fragment in extraction.fragments {
            let fragmentID = stableID(prefix: "frag", parts: [sourceID, String(fragment.ordinal), stableHash([fragment.text])])
            var fragmentMetadata: ASKFields = ["transport": transport]
            if !fragment.heading.isEmpty { fragmentMetadata["heading"] = fragment.heading }
            let manifestFragment = CollectedCaptureFragment(
                fragmentID: fragmentID,
                ordinal: fragment.ordinal,
                text: fragment.text,
                locator: fragment.locator,
                fingerprint: fragment.fingerprint,
                metadata: fragmentMetadata
            )
            manifestFragments.append(manifestFragment)
            collectedFragments.append(
                CollectedFragment(
                    fragmentID: fragmentID,
                    ordinal: fragment.ordinal,
                    locator: fragment.locator,
                    text: fragment.text,
                    fingerprint: fragment.fingerprint,
                    metadata: fragmentMetadata
                )
            )
        }

        let manifest = CollectedCaptureManifest(
            sourceID: sourceID,
            connector: connector,
            transport: transport,
            originalURL: url,
            finalURL: finalURL,
            title: extraction.title,
            observedAt: observedAt,
            capturedAt: capturedAt,
            rawRelpath: rawRelpath,
            noteRelpath: noteRelpath,
            contentHash: webSHA256Prefixed(rawBytes),
            mimeType: contentType?.split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "text/html",
            language: extraction.language,
            tags: mergedTags,
            metadata: mergedMetadata,
            fragments: manifestFragments
        )
        let collected = CollectedSource(
            sourceID: sourceID,
            connector: connector,
            sourceKind: sourceKind,
            title: extraction.title,
            observedAt: observedAt,
            capturedAt: capturedAt,
            rawRelpath: rawRelpath,
            contentHash: manifest.contentHash,
            mimeType: manifest.mimeType,
            language: extraction.language,
            tags: mergedTags,
            metadata: mergedMetadata,
            fragments: collectedFragments
        )
        let curatedNote = CuratedNoteRenderer.render(
            sourceID: sourceID,
            title: extraction.title,
            finalURL: finalURL,
            observedAt: observedAt,
            description: extraction.description,
            markdown: extraction.markdown,
            metadata: mergedMetadata
        )
        try manifest.validate()
        try collected.validate()
        return WebCaptureBundle(
            manifest: manifest,
            collectedSource: collected,
            rawBytes: rawBytes,
            curatedNoteMD: curatedNote,
            transportPayload: [
                "content_type": contentType ?? "",
                "http_status": String(statusCode ?? 0)
            ]
        )
    }

    public static func captureBrowserExport(
        payload: BrowserExportPayload,
        sourceID: String,
        observedAt: String,
        rawRelpath: String,
        connector: String = "browser-export-json",
        tags: [String] = [],
        metadata: ASKFields = [:]
    ) throws -> WebCaptureBundle {
        let url = payload.url ?? payload.canonicalURL ?? payload.finalURL ?? "https://example.invalid/"
        if let html = payload.html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try captureHTMLText(
                html,
                pageURL: url,
                sourceID: sourceID,
                observedAt: observedAt,
                rawRelpath: rawRelpath,
                connector: connector,
                tags: tags,
                metadata: metadata,
                transport: "browser_export"
            )
        }
        let title = payload.title ?? "Browser export"
        let text = payload.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let html = "<html><head><title>\(escapeHTML(title))</title></head><body><article><p>\(escapeHTML(text))</p></article></body></html>"
        return try captureHTMLText(
            html,
            pageURL: url,
            sourceID: sourceID,
            observedAt: observedAt,
            rawRelpath: rawRelpath,
            connector: connector,
            tags: tags,
            metadata: metadata,
            transport: "browser_export"
        )
    }

    public static func captureBrowserExportData(
        _ data: Data,
        sourceID: String,
        observedAt: String,
        rawRelpath: String,
        connector: String = "browser-export-json",
        tags: [String] = [],
        metadata: ASKFields = [:]
    ) throws -> WebCaptureBundle {
        let payload = try CanonicalJSON.decoder().decode(BrowserExportPayload.self, from: data)
        return try captureBrowserExport(payload: payload, sourceID: sourceID, observedAt: observedAt, rawRelpath: rawRelpath, connector: connector, tags: tags, metadata: metadata)
    }
}

private func escapeHTML(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#39;")
}
