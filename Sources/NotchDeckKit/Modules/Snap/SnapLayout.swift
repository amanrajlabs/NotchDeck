import CoreGraphics

/// Window layouts offered by Snap Zones. Frames use AppKit coordinates
/// (origin bottom-left) within a screen's visibleFrame.
public enum SnapLayout: String, CaseIterable, Codable, Sendable {
    case leftHalf, rightHalf, maximize
    case leftThird, centerThird, rightThird
    case topLeftQuarter, topRightQuarter, bottomLeftQuarter, bottomRightQuarter

    public func frame(in v: CGRect) -> CGRect {
        let w2 = v.width / 2, h2 = v.height / 2, w3 = v.width / 3
        switch self {
        case .leftHalf: return CGRect(x: v.minX, y: v.minY, width: w2, height: v.height)
        case .rightHalf: return CGRect(x: v.minX + w2, y: v.minY, width: w2, height: v.height)
        case .maximize: return v
        case .leftThird: return CGRect(x: v.minX, y: v.minY, width: w3, height: v.height)
        case .centerThird: return CGRect(x: v.minX + w3, y: v.minY, width: w3, height: v.height)
        case .rightThird: return CGRect(x: v.minX + w3 * 2, y: v.minY, width: w3, height: v.height)
        case .topLeftQuarter: return CGRect(x: v.minX, y: v.minY + h2, width: w2, height: h2)
        case .topRightQuarter: return CGRect(x: v.minX + w2, y: v.minY + h2, width: w2, height: h2)
        case .bottomLeftQuarter: return CGRect(x: v.minX, y: v.minY, width: w2, height: h2)
        case .bottomRightQuarter: return CGRect(x: v.minX + w2, y: v.minY, width: w2, height: h2)
        }
    }

    public var title: String {
        switch self {
        case .leftHalf: "Left Half"
        case .rightHalf: "Right Half"
        case .maximize: "Maximize"
        case .leftThird: "Left Third"
        case .centerThird: "Center Third"
        case .rightThird: "Right Third"
        case .topLeftQuarter: "Top Left"
        case .topRightQuarter: "Top Right"
        case .bottomLeftQuarter: "Bottom Left"
        case .bottomRightQuarter: "Bottom Right"
        }
    }

    public var icon: String {
        switch self {
        case .leftHalf: "rectangle.lefthalf.inset.filled"
        case .rightHalf: "rectangle.righthalf.inset.filled"
        case .maximize: "rectangle.inset.filled"
        case .leftThird: "rectangle.leadingthird.inset.filled"
        case .centerThird: "rectangle.center.inset.filled"
        case .rightThird: "rectangle.trailingthird.inset.filled"
        case .topLeftQuarter: "rectangle.inset.topleading.filled"
        case .topRightQuarter: "rectangle.inset.toptrailing.filled"
        case .bottomLeftQuarter: "rectangle.inset.bottomleading.filled"
        case .bottomRightQuarter: "rectangle.inset.bottomtrailing.filled"
        }
    }
}

/// Pure geometry for the tile strip that appears under the notch.
public enum SnapZoneMath {
    public static let tileSize = CGSize(width: 64, height: 46)
    public static let tileSpacing: CGFloat = 8
    public static let stripPadding: CGFloat = 12

    /// Strip hangs from the bottom edge of the notch, horizontally centered.
    public static func stripFrame(notch: CGRect, tileCount: Int) -> CGRect {
        let width = CGFloat(tileCount) * tileSize.width
            + CGFloat(max(0, tileCount - 1)) * tileSpacing + stripPadding * 2
        let height = tileSize.height + stripPadding * 2
        return CGRect(
            x: notch.midX - width / 2,
            y: notch.minY - height,
            width: width,
            height: height
        )
    }

    public static func tileRects(strip: CGRect, count: Int) -> [CGRect] {
        (0..<count).map { i in
            CGRect(
                x: strip.minX + stripPadding + CGFloat(i) * (tileSize.width + tileSpacing),
                y: strip.minY + stripPadding,
                width: tileSize.width,
                height: tileSize.height
            )
        }
    }

    public static func tileIndex(at point: CGPoint, strip: CGRect, count: Int) -> Int? {
        tileRects(strip: strip, count: count).firstIndex { $0.contains(point) }
    }

    /// AX APIs use top-left-origin global coordinates.
    public static func axPoint(fromCocoa point: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }
}
