import Foundation

/// One credit per person on a book's author line (`AuthorNames`).
func runAuthorNamesChecks() {
    section("Authors credited once")
    check("the same name twice, cased two ways, is one: the name-cased one kept",
          AuthorNames.joined(["John doe", "John Doe"]) == "John Doe", AuthorNames.joined(["John doe", "John Doe"]))
    check("capitals and lower case lose to a name's own casing",
          AuthorNames.joined(["JOHN DOE", "john doe", "John Doe"]) == "John Doe")
    check("\"Last, First\" beside \"First Last\" is one person, shown First Last",
          AuthorNames.joined(["Doe, John", "John Doe"]) == "John Doe")
    check("…in either order", AuthorNames.joined(["John Doe", "Doe, John"]) == "John Doe")
    check("accents and stops do not make two people",
          AuthorNames.joined(["Gabriel García Márquez", "Gabriel Garcia Marquez"]) == "Gabriel García Márquez")
    check("initials however they are spaced", AuthorNames.joined(["J. R. R. Tolkien", "J.R.R. Tolkien"]) == "J. R. R. Tolkien")
    check("two people stay two, in order", AuthorNames.joined(["Neil Gaiman", "Terry Pratchett"]) == "Neil Gaiman & Terry Pratchett")
    check("a suffix is not a first name", AuthorNames.key("Martin Luther King, Jr.") != AuthorNames.key("Jr. Martin Luther King"))
    check("empty names and spaces go", AuthorNames.joined(["", "  ", " Jane   Roe "]) == "Jane Roe")
    check("nothing is nothing", AuthorNames.joined([]) == "")
    // a line already joined (books added before this)
    check("a doubled line is cleaned", AuthorNames.cleaned("John doe & John Doe") == "John Doe")
    check("a line of one name is left exactly as it is", AuthorNames.cleaned("Doe, John") == "Doe, John")
    check("a name with an ampersand of its own survives", AuthorNames.cleaned("Simon & Schuster") == "Simon & Schuster")
    check("three credits, one twice", AuthorNames.cleaned("Neil Gaiman & Terry Pratchett & neil gaiman") == "Neil Gaiman & Terry Pratchett")
}
