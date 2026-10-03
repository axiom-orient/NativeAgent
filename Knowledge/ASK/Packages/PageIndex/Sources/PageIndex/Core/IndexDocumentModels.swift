import Foundation

public struct DocumentPage: Codable, Equatable, Sendable {
    public var page: Int
    public var content: String

    public init(page: Int, content: String) {
        self.page = page
        self.content = content
    }
}

public struct DocumentNode: Codable, Equatable, Sendable {
    public var title: String
    public var nodeID: String?
    public var startIndex: Int?
    public var endIndex: Int?
    public var lineNumber: Int?
    public var summary: String?
    public var prefixSummary: String?
    public var text: String?
    public var nodes: [DocumentNode]?

    public init(
        title: String,
        nodeID: String? = nil,
        startIndex: Int? = nil,
        endIndex: Int? = nil,
        lineNumber: Int? = nil,
        summary: String? = nil,
        prefixSummary: String? = nil,
        text: String? = nil,
        nodes: [DocumentNode]? = nil
    ) {
        self.title = title
        self.nodeID = nodeID
        self.startIndex = startIndex
        self.endIndex = endIndex
        self.lineNumber = lineNumber
        self.summary = summary
        self.prefixSummary = prefixSummary
        self.text = text
        self.nodes = nodes
    }

    public var isLeaf: Bool {
        (nodes ?? []).isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case title
        case nodeID = "node_id"
        case startIndex = "start_index"
        case endIndex = "end_index"
        case lineNumber = "line_num"
        case summary
        case prefixSummary = "prefix_summary"
        case text
        case nodes
    }
}

public struct IndexedDocument: Codable, Equatable, Sendable {
    public var id: String?
    public var type: DocumentType?
    public var path: String?
    public var docName: String
    public var docDescription: String?
    public var pageCount: Int?
    public var lineCount: Int?
    public var structure: [DocumentNode]?
    public var pages: [DocumentPage]?

    public init(
        id: String? = nil,
        type: DocumentType? = nil,
        path: String? = nil,
        docName: String,
        docDescription: String? = nil,
        pageCount: Int? = nil,
        lineCount: Int? = nil,
        structure: [DocumentNode]? = nil,
        pages: [DocumentPage]? = nil
    ) {
        self.id = id
        self.type = type
        self.path = path
        self.docName = docName
        self.docDescription = docDescription
        self.pageCount = pageCount
        self.lineCount = lineCount
        self.structure = structure
        self.pages = pages
    }

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case path
        case docName = "doc_name"
        case docDescription = "doc_description"
        case pageCount = "page_count"
        case lineCount = "line_count"
        case structure
        case pages
    }
}

public struct WorkspaceMetaEntry: Codable, Equatable, Sendable {
    public var type: DocumentType
    public var docName: String
    public var docDescription: String?
    public var pageCount: Int?
    public var lineCount: Int?
    public var path: String?

    public init(
        type: DocumentType,
        docName: String,
        docDescription: String? = nil,
        pageCount: Int? = nil,
        lineCount: Int? = nil,
        path: String? = nil
    ) {
        self.type = type
        self.docName = docName
        self.docDescription = docDescription
        self.pageCount = pageCount
        self.lineCount = lineCount
        self.path = path
    }

    enum CodingKeys: String, CodingKey {
        case type
        case docName = "doc_name"
        case docDescription = "doc_description"
        case pageCount = "page_count"
        case lineCount = "line_count"
        case path
    }
}

public struct DocumentMetadataResponse: Codable, Equatable, Sendable {
    public var docID: String
    public var docName: String
    public var docDescription: String
    public var type: String
    public var status: String
    public var pageCount: Int?
    public var lineCount: Int?

    public init(
        docID: String,
        docName: String,
        docDescription: String,
        type: String,
        status: String,
        pageCount: Int? = nil,
        lineCount: Int? = nil
    ) {
        self.docID = docID
        self.docName = docName
        self.docDescription = docDescription
        self.type = type
        self.status = status
        self.pageCount = pageCount
        self.lineCount = lineCount
    }

    enum CodingKeys: String, CodingKey {
        case docID = "doc_id"
        case docName = "doc_name"
        case docDescription = "doc_description"
        case type
        case status
        case pageCount = "page_count"
        case lineCount = "line_count"
    }
}

public struct ErrorResponse: Codable, Equatable, Sendable {
    public var error: String

    public init(error: String) {
        self.error = error
    }
}
