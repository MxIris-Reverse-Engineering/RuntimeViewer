import RuntimeViewerAppCore

/// Xcode's twelve find patterns as AppKitPlus's `NSFindPattern.standardPatternGroups` defines them, for tests that
/// make terms without AppKitPlus. `FindPatternParityTests` holds them equal to AppKitPlus's.
extension FindPattern {
    // Characters

    package static func tab(identifier: String? = nil) -> FindPattern {
        FindPattern(regularExpression: "\t", title: "Tab", tokenTitle: "→", allowsBackreferences: false, replacementString: "\t", identifier: identifier)
    }

    package static func lineBreak(identifier: String? = nil) -> FindPattern {
        FindPattern(regularExpression: #"[\n\r]"#, title: "Line Break", tokenTitle: "↵", replacementString: "\n", identifier: identifier)
    }

    // Basic

    package static func anyCharacters(identifier: String? = nil) -> FindPattern {
        FindPattern(regularExpression: ".+?", title: "Any Characters", tokenTitle: "Any", identifier: identifier)
    }

    package static func anyWordCharacters(identifier: String? = nil) -> FindPattern {
        FindPattern(regularExpression: #"\w+"#, title: "Any Word Characters", tokenTitle: "Word", identifier: identifier)
    }

    package static func nonASCIICharacters(identifier: String? = nil) -> FindPattern {
        FindPattern(regularExpression: #"[^\00-\x7E]+"#, title: "Non-ASCII Characters", tokenTitle: "ASCII", isNegation: true, identifier: identifier)
    }

    package static func wordBreak(identifier: String? = nil) -> FindPattern {
        FindPattern(regularExpression: #"\b"#, title: "Word Break", tokenTitle: "Break", allowsBackreferences: false, identifier: identifier)
    }

    package static func whiteSpace(identifier: String? = nil) -> FindPattern {
        FindPattern(regularExpression: #"\s+"#, title: "White Space", tokenTitle: " ", identifier: identifier)
    }

    package static func digits(identifier: String? = nil) -> FindPattern {
        FindPattern(regularExpression: #"\d+"#, title: "Digits", tokenTitle: "#", identifier: identifier)
    }

    package static func hexadecimalDigits(identifier: String? = nil) -> FindPattern {
        FindPattern(regularExpression: "[:xdigit:]+", title: "Hexadecimal Digits", tokenTitle: "Hex", identifier: identifier)
    }

    // Advanced

    package static func emailAddress(identifier: String? = nil) -> FindPattern {
        FindPattern(regularExpression: #"\b[A-Za-z0-9._%-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,4}\b"#, title: "Email Address", tokenTitle: "Email Address", identifier: identifier)
    }

    package static func webAddress(identifier: String? = nil) -> FindPattern {
        FindPattern(
            regularExpression: #"(?:[A-Za-z][A-Za-z0-9+.-]{1,120}:[A-Za-z0-9/](?:(?:[A-Za-z0-9$_.+!*,;/?:@&~=-])|%[A-Fa-f0-9]{2}){1,333}(?:#(?:[a-zA-Z0-9][a-zA-Z0-9$_.+!*,;/?:@&~=%-]{0,1000}))?)"#,
            title: "Web Address",
            tokenTitle: "URL",
            identifier: identifier
        )
    }

    package static func ipAddress(identifier: String? = nil) -> FindPattern {
        FindPattern(regularExpression: #"(?:\d{1,3}(?:\.\d{1,3}){3}|[:xdigit:]{1,4}(?::[:xdigit:]{1,4}){7})"#, title: "IP Address", tokenTitle: "IP Address", identifier: identifier)
    }

    /// The twelve in the order of AppKitPlus's pattern menu: the Characters, Basic and Advanced groups.
    package static let standardPatterns: [FindPattern] = [
        tab(), lineBreak(),
        anyCharacters(), anyWordCharacters(), nonASCIICharacters(), wordBreak(), whiteSpace(), digits(), hexadecimalDigits(),
        emailAddress(), webAddress(), ipAddress(),
    ]
}
