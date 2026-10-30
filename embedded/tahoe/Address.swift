import Foundation

enum TahoeAddress {
    static func url(for input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil { return url }
        if text.contains("://") || text.lowercased().hasPrefix("javascript:") || text.lowercased().hasPrefix("file:") { return nil }
        if !text.contains(where: { $0.isWhitespace }), text.contains("."),
           let url = URL(string: "https://" + text), url.host != nil { return url }
        var search = URLComponents(string: "https://www.google.com/search")!
        search.queryItems = [URLQueryItem(name: "q", value: text)]
        return search.url
    }
}
