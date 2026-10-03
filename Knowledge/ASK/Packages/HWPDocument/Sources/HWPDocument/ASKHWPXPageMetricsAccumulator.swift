struct ASKHWPXPageMetricsAccumulator: Sendable, Hashable {
  private var widthHWPUnit: Int?
  private var heightHWPUnit: Int?
  private var marginTopHWPUnit: Int?
  private var marginRightHWPUnit: Int?
  private var marginBottomHWPUnit: Int?
  private var marginLeftHWPUnit: Int?

  mutating func capturePageProperties(_ attributes: AttributeLookup) {
    widthHWPUnit = attributes.int(["width", "w"]) ?? widthHWPUnit
    heightHWPUnit = attributes.int(["height", "h"]) ?? heightHWPUnit
    marginTopHWPUnit = attributes.int(["marginTop", "topMargin", "top"]) ?? marginTopHWPUnit
    marginRightHWPUnit =
      attributes.int(["marginRight", "rightMargin", "right"])
      ?? marginRightHWPUnit
    marginBottomHWPUnit =
      attributes.int(["marginBottom", "bottomMargin", "bottom"])
      ?? marginBottomHWPUnit
    marginLeftHWPUnit =
      attributes.int(["marginLeft", "leftMargin", "left"])
      ?? marginLeftHWPUnit
  }

  mutating func captureMargin(_ attributes: AttributeLookup) {
    marginTopHWPUnit = attributes.int(["top", "marginTop", "topMargin"]) ?? marginTopHWPUnit
    marginRightHWPUnit =
      attributes.int(["right", "marginRight", "rightMargin"])
      ?? marginRightHWPUnit
    marginBottomHWPUnit =
      attributes.int(["bottom", "marginBottom", "bottomMargin"])
      ?? marginBottomHWPUnit
    marginLeftHWPUnit =
      attributes.int(["left", "marginLeft", "leftMargin"])
      ?? marginLeftHWPUnit
  }

  func makeMetrics() -> ASKHWPPageMetrics? {
    guard let widthHWPUnit, let heightHWPUnit else { return nil }
    let defaultMargin = 5_670
    return ASKHWPPageMetrics.hwpUnits(
      width: widthHWPUnit,
      height: heightHWPUnit,
      marginTop: marginTopHWPUnit ?? defaultMargin,
      marginRight: marginRightHWPUnit ?? defaultMargin,
      marginBottom: marginBottomHWPUnit ?? defaultMargin,
      marginLeft: marginLeftHWPUnit ?? defaultMargin
    )
  }
}
