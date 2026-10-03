
public struct ASKCanvasPage: Sendable, Hashable, Codable {
    public let id: ASKPageCanvasSceneID
    public let elements: [ASKCanvasElement]

    public init(id: ASKPageCanvasSceneID, elements: [ASKCanvasElement]) {
        self.id = id
        self.elements = elements
    }
}
