import Foundation
import DocumentCore

struct ASKCFBReader {
    private static let signature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
    private static let freeSector: UInt32 = 0xFFFF_FFFF
    private static let endOfChain: UInt32 = 0xFFFF_FFFE
    private static let noStream: UInt32 = 0xFFFF_FFFF

    private let bytes: [UInt8]
    private let header: Header
    private let fat: [UInt32]
    private let miniFAT: [UInt32]
    private let directoryEntries: [DirectoryEntry]
    private let pathMap: [String: Int]
    private let rootEntryIndex: Int
    private let rootMiniStream: [UInt8]
    private let maximumStreamByteCount: Int

    init(
        data: Data,
        maximumStreamByteCount: Int,
        maximumMiniStreamByteCount: Int
    ) throws {
        precondition(maximumStreamByteCount > 0, "maximumStreamByteCount must be positive.")
        precondition(maximumMiniStreamByteCount >= maximumStreamByteCount, "maximumMiniStreamByteCount must cover a stream.")
        self.bytes = Array(data)
        self.maximumStreamByteCount = maximumStreamByteCount
        guard bytes.count >= 512 else {
            throw ASKHWPError.malformedContainer("CFB file is smaller than the 512-byte header.")
        }
        guard Array(bytes[0..<8]) == Self.signature else {
            throw ASKHWPError.unsupportedFormat("Input is not a Compound File Binary container.")
        }
        let header = try Header(bytes: bytes)
        try header.validateDeclaredSectorCounts(containerByteCount: bytes.count)
        self.header = header
        let difat = try Self.readDIFAT(bytes: bytes, header: header)
        self.fat = try Self.readFAT(bytes: bytes, header: header, fatSectorIDs: difat)
        let directoryStream = try Self.readRegularStream(
            bytes: bytes,
            header: header,
            fat: fat,
            startSector: header.firstDirectorySector,
            expectedSize: nil
        )
        self.directoryEntries = try Self.readDirectoryEntries(directoryStream)
        guard let rootIndex = directoryEntries.firstIndex(where: { $0.objectType == .rootStorage }) else {
            throw ASKHWPError.malformedContainer("CFB root storage directory entry was not found.")
        }
        self.rootEntryIndex = rootIndex
        self.pathMap = Self.buildPathMap(entries: directoryEntries, rootIndex: rootIndex)
        self.miniFAT = try Self.readMiniFAT(bytes: bytes, header: header, fat: fat)
        let root = directoryEntries[rootIndex]
        if root.startingSector != Self.endOfChain, root.streamSize > 0 {
            guard root.streamSize <= UInt64(maximumMiniStreamByteCount) else {
                throw ASKHWPError.unsupportedFeature(
                    "CFB root mini stream exceeds the configured \(maximumMiniStreamByteCount)-byte limit."
                )
            }
            self.rootMiniStream = try Self.readRegularStream(
                bytes: bytes,
                header: header,
                fat: fat,
                startSector: root.startingSector,
                expectedSize: Int(root.streamSize)
            )
        } else {
            self.rootMiniStream = []
        }
    }

    func streamPaths() -> [String] {
        pathMap.keys.sorted()
    }

    func streamPaths(prefix: String) -> [String] {
        let normalizedPrefix = normalizePath(prefix)
        return pathMap.keys.filter { normalizePath($0).hasPrefix(normalizedPrefix) }.sorted()
    }

    func containsStream(named path: String) -> Bool {
        pathMap[normalizePath(path)] != nil
    }

    func stream(named path: String) throws -> Data {
        let normalized = normalizePath(path)
        guard let entryIndex = pathMap[normalized] else {
            throw ASKHWPError.resourceNotFound(path)
        }
        let entry = directoryEntries[entryIndex]
        guard entry.objectType == .stream else {
            throw ASKHWPError.malformedContainer("CFB path is not a stream: \(path)")
        }
        let bytes = try readStream(entry)
        return Data(bytes)
    }

    private func readStream(_ entry: DirectoryEntry) throws -> [UInt8] {
        guard entry.streamSize <= UInt64(maximumStreamByteCount) else {
            throw ASKHWPError.unsupportedFeature(
                "CFB stream exceeds the configured \(maximumStreamByteCount)-byte limit: \(entry.name)."
            )
        }
        let expectedSize = Int(entry.streamSize)
        if entry.streamSize < UInt64(header.miniStreamCutoffSize), entry.startingSector != Self.endOfChain {
            return try Self.readMiniStream(
                rootMiniStream: rootMiniStream,
                miniFAT: miniFAT,
                header: header,
                startMiniSector: entry.startingSector,
                expectedSize: expectedSize
            )
        }
        return try Self.readRegularStream(
            bytes: bytes,
            header: header,
            fat: fat,
            startSector: entry.startingSector,
            expectedSize: expectedSize
        )
    }

    private func normalizePath(_ path: String) -> String {
        path
            .split(separator: "/")
            .filter { !$0.isEmpty }
            .joined(separator: "/")
            .lowercased()
    }

    private static func sectorOffset(_ sectorID: UInt32, sectorSize: Int) throws -> Int {
        guard sectorID < 0xFFFF_FFF0 else {
            throw ASKHWPError.malformedContainer("Invalid CFB sector id \(sectorID).")
        }
        let sectorIndex = Int(sectorID)
        return (sectorIndex + 1) * sectorSize
    }

    private static func readSector(bytes: [UInt8], sectorID: UInt32, sectorSize: Int) throws -> [UInt8] {
        let offset = try sectorOffset(sectorID, sectorSize: sectorSize)
        guard offset >= 0, offset + sectorSize <= bytes.count else {
            throw ASKHWPError.malformedContainer("CFB sector \(sectorID) escapes file bounds.")
        }
        return Array(bytes[offset..<(offset + sectorSize)])
    }

    private static func readDIFAT(bytes: [UInt8], header: Header) throws -> [UInt32] {
        var difat = header.difatEntries.filter { $0 != Self.freeSector }
        var nextSector = header.firstDIFATSector
        var remaining = header.numberOfDIFATSectors
        let entriesPerDIFATSector = header.sectorSize / 4 - 1
        var visited = Set<UInt32>()

        while remaining > 0 {
            guard nextSector != Self.endOfChain, nextSector != Self.freeSector else {
                throw ASKHWPError.malformedContainer("CFB DIFAT chain ended before its declared sector count.")
            }
            guard visited.insert(nextSector).inserted else {
                throw ASKHWPError.malformedContainer("CFB DIFAT chain contains a cycle at sector \(nextSector).")
            }
            let sector = try readSector(bytes: bytes, sectorID: nextSector, sectorSize: header.sectorSize)
            for entryIndex in 0..<entriesPerDIFATSector {
                let value = try ASKByteCursor.uint32LE(sector, at: entryIndex * 4)
                if value != Self.freeSector { difat.append(value) }
            }
            nextSector = try ASKByteCursor.uint32LE(sector, at: entriesPerDIFATSector * 4)
            remaining -= 1
        }
        if difat.count > Int(header.numberOfFATSectors) {
            difat = Array(difat.prefix(Int(header.numberOfFATSectors)))
        }
        return difat
    }

    private static func readFAT(bytes: [UInt8], header: Header, fatSectorIDs: [UInt32]) throws -> [UInt32] {
        guard fatSectorIDs.count >= Int(header.numberOfFATSectors) else {
            throw ASKHWPError.malformedContainer("CFB FAT sector count is smaller than declared.")
        }
        var fat: [UInt32] = []
        fat.reserveCapacity(Int(header.numberOfFATSectors) * header.sectorSize / 4)
        for sectorID in fatSectorIDs.prefix(Int(header.numberOfFATSectors)) {
            let sector = try readSector(bytes: bytes, sectorID: sectorID, sectorSize: header.sectorSize)
            for offset in stride(from: 0, to: header.sectorSize, by: 4) {
                fat.append(try ASKByteCursor.uint32LE(sector, at: offset))
            }
        }
        return fat
    }

    private static func readRegularStream(
        bytes: [UInt8],
        header: Header,
        fat: [UInt32],
        startSector: UInt32,
        expectedSize: Int?
    ) throws -> [UInt8] {
        if expectedSize == 0 {
            return []
        }
        guard startSector != Self.endOfChain, startSector != Self.freeSector else {
            if expectedSize == nil {
                return []
            }
            throw ASKHWPError.malformedContainer("CFB stream ended before its declared size.")
        }
        var result: [UInt8] = []
        var sectorID = startSector
        var visited = Set<UInt32>()
        while sectorID != Self.endOfChain {
            guard sectorID < UInt32(fat.count) else {
                throw ASKHWPError.malformedContainer("CFB FAT chain references out-of-range sector \(sectorID).")
            }
            guard visited.insert(sectorID).inserted else {
                throw ASKHWPError.malformedContainer("CFB FAT chain contains a cycle at sector \(sectorID).")
            }
            result.append(contentsOf: try readSector(bytes: bytes, sectorID: sectorID, sectorSize: header.sectorSize))
            sectorID = fat[Int(sectorID)]
            if let expectedSize, result.count >= expectedSize { break }
        }
        if let expectedSize, result.count > expectedSize {
            result = Array(result.prefix(expectedSize))
        }
        if let expectedSize, result.count < expectedSize {
            throw ASKHWPError.malformedContainer("CFB stream ended before its declared size.")
        }
        return result
    }

    private static func readMiniFAT(bytes: [UInt8], header: Header, fat: [UInt32]) throws -> [UInt32] {
        guard header.numberOfMiniFATSectors > 0, header.firstMiniFATSector != Self.endOfChain else {
            return []
        }
        let miniFATBytes = try readRegularStream(
            bytes: bytes,
            header: header,
            fat: fat,
            startSector: header.firstMiniFATSector,
            expectedSize: Int(header.numberOfMiniFATSectors) * header.sectorSize
        )
        var result: [UInt32] = []
        for offset in stride(from: 0, to: miniFATBytes.count - (miniFATBytes.count % 4), by: 4) {
            result.append(try ASKByteCursor.uint32LE(miniFATBytes, at: offset))
        }
        return result
    }

    private static func readMiniStream(
        rootMiniStream: [UInt8],
        miniFAT: [UInt32],
        header: Header,
        startMiniSector: UInt32,
        expectedSize: Int
    ) throws -> [UInt8] {
        if expectedSize == 0 {
            return []
        }
        guard !rootMiniStream.isEmpty else {
            return []
        }
        var result: [UInt8] = []
        var sectorID = startMiniSector
        var visited = Set<UInt32>()
        while sectorID != Self.endOfChain {
            guard sectorID < UInt32(miniFAT.count) else {
                throw ASKHWPError.malformedContainer("CFB mini FAT chain references out-of-range mini sector \(sectorID).")
            }
            guard visited.insert(sectorID).inserted else {
                throw ASKHWPError.malformedContainer("CFB mini FAT chain contains a cycle at sector \(sectorID).")
            }
            let offset = Int(sectorID) * header.miniSectorSize
            guard offset >= 0, offset + header.miniSectorSize <= rootMiniStream.count else {
                throw ASKHWPError.malformedContainer("CFB mini sector \(sectorID) escapes root mini stream.")
            }
            result.append(contentsOf: rootMiniStream[offset..<(offset + header.miniSectorSize)])
            sectorID = miniFAT[Int(sectorID)]
            if result.count >= expectedSize { break }
        }
        if result.count > expectedSize {
            result = Array(result.prefix(expectedSize))
        }
        guard result.count == expectedSize else {
            throw ASKHWPError.malformedContainer("CFB mini stream ended before its declared size.")
        }
        return result
    }

    private static func readDirectoryEntries(_ bytes: [UInt8]) throws -> [DirectoryEntry] {
        guard bytes.count >= 128 else {
            throw ASKHWPError.malformedContainer("CFB directory stream is empty.")
        }
        var entries: [DirectoryEntry] = []
        for offset in stride(from: 0, to: bytes.count - (bytes.count % 128), by: 128) {
            entries.append(try DirectoryEntry(bytes: bytes, offset: offset, index: entries.count))
        }
        return entries
    }

    private static func buildPathMap(entries: [DirectoryEntry], rootIndex: Int) -> [String: Int] {
        var result: [String: Int] = [:]
        var visited = Set<Int>()

        func normalize(_ path: String) -> String {
            path
                .split(separator: "/")
                .filter { !$0.isEmpty }
                .joined(separator: "/")
                .lowercased()
        }

        func visitSiblingTree(_ id: UInt32, parentPath: String) {
            guard id != Self.noStream, id < UInt32(entries.count) else { return }
            let index = Int(id)
            guard visited.insert(index).inserted else { return }
            let entry = entries[index]
            visitSiblingTree(entry.leftSiblingID, parentPath: parentPath)
            let path = parentPath.isEmpty ? entry.name : parentPath + "/" + entry.name
            switch entry.objectType {
            case .stream:
                result[normalize(path)] = index
            case .storage:
                visitSiblingTree(entry.childID, parentPath: path)
            case .rootStorage:
                visitSiblingTree(entry.childID, parentPath: "")
            case .unknown:
                break
            }
            visitSiblingTree(entry.rightSiblingID, parentPath: parentPath)
        }

        visitSiblingTree(entries[rootIndex].childID, parentPath: "")
        return result
    }
}

private extension ASKCFBReader {
    struct Header {
        let majorVersion: UInt16
        let sectorSize: Int
        let miniSectorSize: Int
        let numberOfFATSectors: UInt32
        let firstDirectorySector: UInt32
        let miniStreamCutoffSize: UInt32
        let firstMiniFATSector: UInt32
        let numberOfMiniFATSectors: UInt32
        let firstDIFATSector: UInt32
        let numberOfDIFATSectors: UInt32
        let difatEntries: [UInt32]

        init(bytes: [UInt8]) throws {
            self.majorVersion = try ASKByteCursor.uint16LE(bytes, at: 0x1A)
            guard majorVersion == 3 || majorVersion == 4 else {
                throw ASKHWPError.unsupportedFeature("CFB major version \(majorVersion) is not supported.")
            }
            let byteOrder = try ASKByteCursor.uint16LE(bytes, at: 0x1C)
            guard byteOrder == 0xFFFE else {
                throw ASKHWPError.malformedContainer("CFB byte order marker is invalid.")
            }
            let sectorShift = try ASKByteCursor.uint16LE(bytes, at: 0x1E)
            let miniSectorShift = try ASKByteCursor.uint16LE(bytes, at: 0x20)
            let expectedSectorShift: UInt16 = majorVersion == 3 ? 9 : 12
            guard sectorShift == expectedSectorShift else {
                throw ASKHWPError.unsupportedFeature("CFB sector shift \(sectorShift) is not supported.")
            }
            guard miniSectorShift == 6 else {
                throw ASKHWPError.malformedContainer("CFB mini sector shift must be 6, got \(miniSectorShift).")
            }
            self.sectorSize = 1 << Int(sectorShift)
            self.miniSectorSize = 1 << Int(miniSectorShift)
            self.numberOfFATSectors = try ASKByteCursor.uint32LE(bytes, at: 0x2C)
            self.firstDirectorySector = try ASKByteCursor.uint32LE(bytes, at: 0x30)
            self.miniStreamCutoffSize = try ASKByteCursor.uint32LE(bytes, at: 0x38)
            self.firstMiniFATSector = try ASKByteCursor.uint32LE(bytes, at: 0x3C)
            self.numberOfMiniFATSectors = try ASKByteCursor.uint32LE(bytes, at: 0x40)
            self.firstDIFATSector = try ASKByteCursor.uint32LE(bytes, at: 0x44)
            self.numberOfDIFATSectors = try ASKByteCursor.uint32LE(bytes, at: 0x48)
            var difat: [UInt32] = []
            for offset in stride(from: 0x4C, to: 0x4C + 109 * 4, by: 4) {
                difat.append(try ASKByteCursor.uint32LE(bytes, at: offset))
            }
            self.difatEntries = difat
        }

        func validateDeclaredSectorCounts(containerByteCount: Int) throws {
            let availableSectorCount = max(containerByteCount / sectorSize - 1, 0)
            let maximumDeclaredCount = UInt64(availableSectorCount)
            guard UInt64(numberOfFATSectors) <= maximumDeclaredCount else {
                throw ASKHWPError.malformedContainer(
                    "CFB declares \(numberOfFATSectors) FAT sectors but only \(availableSectorCount) sectors are present."
                )
            }
            guard UInt64(numberOfMiniFATSectors) <= maximumDeclaredCount else {
                throw ASKHWPError.malformedContainer(
                    "CFB declares \(numberOfMiniFATSectors) mini FAT sectors but only \(availableSectorCount) sectors are present."
                )
            }
            guard UInt64(numberOfDIFATSectors) <= maximumDeclaredCount else {
                throw ASKHWPError.malformedContainer(
                    "CFB declares \(numberOfDIFATSectors) DIFAT sectors but only \(availableSectorCount) sectors are present."
                )
            }
        }
    }

    enum ObjectType: UInt8 {
        case unknown = 0
        case storage = 1
        case stream = 2
        case rootStorage = 5
    }

    struct DirectoryEntry {
        let index: Int
        let name: String
        let objectType: ObjectType
        let leftSiblingID: UInt32
        let rightSiblingID: UInt32
        let childID: UInt32
        let startingSector: UInt32
        let streamSize: UInt64

        init(bytes: [UInt8], offset: Int, index: Int) throws {
            self.index = index
            let rawNameLength = Int(try ASKByteCursor.uint16LE(bytes, at: offset + 64))
            let nameLength = max(min(rawNameLength, 64) - 2, 0)
            let nameBytes = Array(bytes[offset..<(offset + nameLength)])
            self.name = ASKByteCursor.utf16LittleEndianString(nameBytes)
            let typeByte = bytes[offset + 66]
            self.objectType = ObjectType(rawValue: typeByte) ?? .unknown
            self.leftSiblingID = try ASKByteCursor.uint32LE(bytes, at: offset + 68)
            self.rightSiblingID = try ASKByteCursor.uint32LE(bytes, at: offset + 72)
            self.childID = try ASKByteCursor.uint32LE(bytes, at: offset + 76)
            self.startingSector = try ASKByteCursor.uint32LE(bytes, at: offset + 116)
            self.streamSize = try ASKByteCursor.uint64LE(bytes, at: offset + 120)
        }
    }
}
