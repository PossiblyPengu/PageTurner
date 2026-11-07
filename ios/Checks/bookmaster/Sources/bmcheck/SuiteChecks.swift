import Foundation

// The suite-presence and level words the Together tab shares with the web —
// whereabouts picks, "last seen" spans and the level titles, no servers needed.

private func beat(_ online: Bool, _ place: String? = nil, _ seen: Double = 0) -> BMAppBeat {
    BMAppBeat(online: online, place: place, lastSeenAt: seen)
}

@MainActor
func runSuiteChecks() {
    section("Suite presence")

    let now = Date()
    let t = now.timeIntervalSince1970 * 1000

    // an app they are in right now beats one they left
    let w1 = BMSuite.whereabouts([
        "kindred": beat(false, "notes", t - 60_000),
        "pageturner": beat(true, "reader", t - 30_000),
    ])
    check("online beats offline", w1?.app == "pageturner" && w1?.online == true)
    check("the screen is named in the suite's words", w1?.place == "a book")

    // two online — the freshest heartbeat wins
    let w2 = BMSuite.whereabouts([
        "quest-log": beat(true, "map", t - 120_000),
        "pageturner": beat(true, "library", t - 10_000),
    ])
    check("the freshest online app wins", w2?.app == "pageturner")

    // both quiet — the most recently seen one
    let w3 = BMSuite.whereabouts([
        "quest-log": beat(false, "chat", t - 60_000),
        "kindred": beat(false, "us", t - 300_000),
    ])
    check("all quiet: the last seen app", w3?.app == "quest-log" && w3?.online == false)

    // apps the suite does not know are skipped entirely
    check("unknown apps are ignored",
          BMSuite.whereabouts(["mastodon": beat(true, nil, t)]) == nil)
    check("no beats, no whereabouts", BMSuite.whereabouts([:]) == nil)

    check("the online line names the place",
          BMSuite.whereaboutsLine(["pageturner": beat(true, "reader", t)], now: now)
            == "In Pageturner · a book")
    check("an unknown screen is still a visit",
          BMSuite.whereaboutsLine(["kindred": beat(true, "somewhere-new", t)], now: now)
            == "In Kindred · looking around")
    check("the away line says when and where",
          BMSuite.whereaboutsLine(["quest-log": beat(false, "map", t - 5 * 60_000)], now: now)
            == "Last seen 5m ago in Quest Log")

    check("lastSeen just now", BMSuite.lastSeen(t - 5_000, now: now) == "just now")
    check("lastSeen minutes", BMSuite.lastSeen(t - 42 * 60_000, now: now) == "42m ago")
    check("lastSeen hours", BMSuite.lastSeen(t - 5 * 3_600_000, now: now) == "5h ago")
    check("lastSeen days", BMSuite.lastSeen(t - 3 * 86_400_000, now: now) == "3d ago")

    // shelf dates come back as SQLite's UTC text
    let justNow = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: now)
    }()
    check("a beat today says today", BMSuite.timeAgo(justNow, now: now) == "today")
    let weekAgo = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        // one second deeper than 4d: whether the formatter truncates or rounds
        // the sub-second part, the parsed date still reads as four days back
        return f.string(from: now.addingTimeInterval(-4 * 86_400 - 1))
    }()
    check("four days back says 4d ago", BMSuite.timeAgo(weekAgo, now: now) == "4d ago")
    let plainDay = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: now.addingTimeInterval(-20 * 86_400))
    }()
    check("a bare date reads too", BMSuite.timeAgo(plainDay, now: now) == "2w ago")
    check("nothing is nothing", BMSuite.timeAgo(nil, now: now) == nil)
    check("gibberish is nothing", BMSuite.timeAgo("not a date", now: now) == nil)

    check("level titles keep the web's bands",
          [bmLevelTitle(1), bmLevelTitle(9), bmLevelTitle(40), bmLevelTitle(100)]
            == ["Novice Reader", "Casual Reader", "Bibliophile", "Legendary Reader"])
}
