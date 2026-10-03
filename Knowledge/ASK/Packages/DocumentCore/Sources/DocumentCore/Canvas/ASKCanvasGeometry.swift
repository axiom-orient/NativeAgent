public struct ASKCanvasPoint: Sendable, Hashable, Codable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct ASKCanvasSize: Sendable, Hashable, Codable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct ASKCanvasRect: Sendable, Hashable, Codable {
    public let origin: ASKCanvasPoint
    public let size: ASKCanvasSize

    public init(origin: ASKCanvasPoint, size: ASKCanvasSize) {
        self.origin = origin
        self.size = size
    }

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.init(
            origin: .init(x: x, y: y),
            size: .init(width: width, height: height)
        )
    }
}

public struct ASKCanvasObstacle: Sendable, Hashable, Codable {
    public let frame: ASKCanvasRect

    public init(frame: ASKCanvasRect) {
        self.frame = frame
    }

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.init(frame: .init(x: x, y: y, width: width, height: height))
    }

    public var x: Double { frame.origin.x }
    public var y: Double { frame.origin.y }
    public var width: Double { frame.size.width }
    public var height: Double { frame.size.height }
}
