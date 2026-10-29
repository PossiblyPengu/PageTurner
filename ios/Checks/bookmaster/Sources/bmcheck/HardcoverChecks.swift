import Foundation

/// Hardcover's request and answer — HardcoverCore.swift, the pure half of the source.
@MainActor
func runHardcoverChecks() {
    section("Hardcover")
    check("a pasted token keeps one Bearer", HardcoverCore.authorization("Bearer abc.def ") == "Bearer abc.def")
    check("a bare token gains Bearer", HardcoverCore.authorization(" abc ") == "Bearer abc")
    check("an empty token is none", HardcoverCore.authorization("  ") == nil && HardcoverCore.authorization("Bearer ") == nil)

    let body = HardcoverCore.body(query: "John \"Dies\" at the End")
    let sent = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    check("the query text is a variable, not spliced into the query",
          (sent?["variables"] as? [String: Any])?["q"] as? String == "John \"Dies\" at the End"
            && !((sent?["query"] as? String) ?? "").contains("Dies"))

    let answer = """
    {"data":{"search":{"results":{"hits":[
      {"document":{"title":"John Dies at the End","author_names":["David Wong"],"release_year":2007,
        "isbns":["0312555113","9780312555115"],"image":{"url":"https://assets.hardcover.app/a.jpg"},
        "description":"  A blurb. ","series_names":["John Dies at the End"]}},
      {"document":{"title":"","author_names":["Nobody"]}},
      {"nothing":true},
      {"document":{"title":"Bare","release_date":"1999-05-01"}}
    ]}}}}
    """
    let hits = HardcoverCore.parse(Data(answer.utf8))
    check("blank and malformed hits are skipped", hits.count == 2, "\(hits.count)")
    check("title, authors, year", hits.first?.title == "John Dies at the End" && hits.first?.authors == "David Wong" && hits.first?.year == "2007")
    check("the thirteen-digit ISBN is preferred", hits.first?.isbn == "9780312555115")
    check("cover, series and a trimmed blurb",
          hits.first?.coverURL?.absoluteString == "https://assets.hardcover.app/a.jpg"
            && hits.first?.series == "John Dies at the End" && hits.first?.summary == "A blurb.")
    check("a release date stands in for the year", hits.last?.year == "1999")

    let asString = #"{"data":{"search":{"results":"{\"hits\":[{\"document\":{\"title\":\"Dune\"}}]}"}}}"#
    check("results given as a string is read too", HardcoverCore.parse(Data(asString.utf8)).first?.title == "Dune")
    check("a bad token's errors-only answer is an empty list",
          HardcoverCore.parse(Data(#"{"errors":[{"message":"Unable to verify token"}]}"#.utf8)).isEmpty)
    check("garbage is an empty list", HardcoverCore.parse(Data("nope".utf8)).isEmpty)

    let seriesAnswer = """
    {"data":{"search":{"results":{"hits":[
      {"document":{"title":"Book One","series":[{"name":"The Run","position":2.5}]}},
      {"document":{"title":"Book Two","series":[{"name":"The Run","position":"3"}]}},
      {"document":{"title":"Book Three","series":[{"name":"The Run","position":"nan"}]}},
      {"document":{"title":"Book Four","series":[{"name":"The Run","position":1e999}]}}
    ]}}}}
    """
    let seriesHits = HardcoverCore.parse(Data(seriesAnswer.utf8))
    check("a series position parses, number or string",
          seriesHits.count == 4 && seriesHits[0].seriesIndex == 2.5 && seriesHits[1].seriesIndex == 3)
    check("a non-finite position is no position, not a poisoned one",
          seriesHits[2].seriesIndex == nil && seriesHits[3].seriesIndex == nil)

    section("Sweep: covers and matching")
    check("a Cyrillic title folds to its own letters, not to nothing", BookMatch.fold("Война и мир").hasSuffix("и мир") && BookMatch.fold("Война и мир").count > 6)
    check("two Cyrillic titles do not match each other", !BookMatch.titlesMatch("Война и мир", "Преступление и наказание"))
    check("a work id's jacket is a /w/ path", CoverLinks.openLibraryWork("OL45804W").first?.absoluteString.contains("/w/olid/OL45804W-L.jpg") == true)
    check("an edition id's jacket stays a /b/ path", CoverLinks.openLibraryWork("OL123M").first?.absoluteString.contains("/b/olid/OL123M-L.jpg") == true)
}

@MainActor
func runSweepReaderChecks() {
    section("Sweep: footnote marks and words")
    let spoken = SpeechText.spoken("It ended.¹ Then more.")
    check("a footnote mark is not spoken", !spoken.contains("¹"), spoken)
}
