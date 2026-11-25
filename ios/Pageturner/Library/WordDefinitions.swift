import Foundation

/// A saved word's short definition, from Wiktionary (`WordStudy.definition` reads the answer). Only the word is
/// sent. The answer is kept with the word, so it is there offline after; a word that has none is marked so ("")
/// and not asked about again, and a failed request (offline) leaves it to be tried next time.
enum WordDefinitions {
    /// The definition, "" when Wiktionary has none, nil when it could not be asked.
    static func lookUp(_ word: String) async -> String? {
        var forms = [word]
        let lower = word.lowercased()
        // a word saved from the start of a sentence is in the dictionary in lower case
        if lower != word { forms.append(lower) }
        var answered = false
        for form in forms {
            guard let path = WordStudy.wiktionaryPath(for: form),
                  let url = URL(string: "https://en.wiktionary.org/api/rest_v1/page/definition/\(path)")
            else { continue }
            var request = URLRequest(url: url, timeoutInterval: 15)
            // Wikimedia asks every client to name itself
            request.setValue("Pageturner/1.0 (iOS e-reader; saved-word definitions)", forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let status = (response as? HTTPURLResponse)?.statusCode
            else { continue }
            if status == 404 { answered = true; continue }
            guard status == 200, let text = WordStudy.definition(fromWiktionary: data) else { continue }
            answered = true
            if !text.isEmpty { return text }
        }
        return answered ? "" : nil
    }

    /// Look up every word in `library` that has never been looked up, a few at a time, and keep what comes back.
    @MainActor
    static func fillMissing(in library: LibraryStore, limit: Int = 12) async {
        let wanted = library.books.flatMap { book in
            book.words.filter { $0.definition == nil }.map { (book: book.id, word: $0) }
        }.prefix(limit)
        for item in wanted {
            guard !Task.isCancelled else { return }
            guard let definition = await lookUp(item.word.word) else { return }   // offline: try another time
            library.mutate(item.book) { book in
                guard let i = book.words.firstIndex(where: { $0.id == item.word.id }) else { return }
                book.words[i].definition = definition
            }
        }
    }
}
