import CoreGraphics

/// Pure geometry for placing the notch panel. Screen coordinates are AppKit-style
/// (origin bottom-left).
public enum NotchGeometry {
    public static let simulatedNotchSize = CGSize(width: 200, height: 32)

    /// Rect of the physical notch (or a simulated one on notchless displays).
    public static func notchRect(
        screenFrame: CGRect,
        safeTopInset: CGFloat,
        auxTopLeftWidth: CGFloat?,
        auxTopRightWidth: CGFloat?,
        verticalNudge: CGFloat = 0
    ) -> CGRect {
        if let left = auxTopLeftWidth, let right = auxTopRightWidth, safeTopInset > 0 {
            let height = max(8, safeTopInset - verticalNudge)
            return CGRect(
                x: screenFrame.minX + left,
                y: screenFrame.maxY - height,
                width: screenFrame.width - left - right,
                height: height
            )
        }
        let s = simulatedNotchSize
        let height = max(8, s.height - verticalNudge)
        return CGRect(
            x: screenFrame.midX - s.width / 2,
            y: screenFrame.maxY - height,
            width: s.width,
            height: height
        )
    }

    /// Frame for the hosting panel: always big enough for expanded content,
    /// horizontally centered on the notch, flush with the top edge.
    public static func panelFrame(notch: CGRect, expandedSize: CGSize) -> CGRect {
        let width = max(expandedSize.width, notch.width)
        let height = max(expandedSize.height, notch.height)
        return CGRect(
            x: notch.midX - width / 2,
            y: notch.maxY - height,
            width: width,
            height: height
        )
    }
}
