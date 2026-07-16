/// A small, self-contained collection of quotes shown in the Dashboard's Quote widget.
public enum QuoteBook {
    public static let quotes: [String] = [
        "Simplicity is the ultimate sophistication. — Leonardo da Vinci",
        "The best way to predict the future is to invent it. — Alan Kay",
        "Make it work, make it right, make it fast. — Kent Beck",
        "Focus is saying no to a thousand things. — Steve Jobs",
        "Amateurs sit and wait for inspiration; the rest of us get up and go to work. — Stephen King",
        "What gets measured gets managed. — Peter Drucker",
        "Deep work is the superpower of the 21st century. — Cal Newport",
        "Perfection is achieved when there is nothing left to take away. — Antoine de Saint-Exupéry",
        "You do not rise to the level of your goals; you fall to the level of your systems. — James Clear",
        "The impediment to action advances action. — Marcus Aurelius",
        "Little by little, one travels far. — J.R.R. Tolkien",
        "Well begun is half done. — Aristotle",
    ]

    /// Deterministic per-day quote; wraps around once `dayOfYear` exceeds the list length.
    public static func quote(dayOfYear: Int) -> String {
        quotes[((dayOfYear % quotes.count) + quotes.count) % quotes.count]
    }
}
