/// Round-robin selection for the collapsed strip's trailing slot.
public enum LiveRotation {
    public static func pick(count: Int, tick: Int) -> Int? {
        guard count > 0 else { return nil }
        return tick % count
    }
}
