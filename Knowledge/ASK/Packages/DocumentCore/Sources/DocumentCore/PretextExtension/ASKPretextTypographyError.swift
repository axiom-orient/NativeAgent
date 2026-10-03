
public enum ASKPretextTypographyError: Error, Sendable, Hashable {
    case unknownHandle(ASKPreparedTextHandle)
    case invalidPointSize(Double)
    case invalidLineHeight(Double)
}
