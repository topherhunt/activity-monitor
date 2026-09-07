import Foundation

/// A read-time rule. Every non-empty pattern must match for the rule to apply;
/// the first matching rule in list order wins.
///
/// One rule does two jobs on purpose: `category` buckets the time, and `label`
/// collapses many raw titles into one display row. That is why raw observations
/// never need cleanup before storage -- editing a pattern here reshapes history.
struct Rule: Codable {
    var category: String
    var app: String = ""       // matched against app name OR bundle id
    var title: String = ""
    var url: String = ""
    /// Display name for the collapsed row. Supports $1..$9 from the title match.
    /// Empty means "use the raw title".
    var label: String = ""
    var enabled: Bool = true
}

struct Category: Codable {
    var name: String
    var color: String
}

struct RuleSet: Codable {
    var categories: [Category]
    var rules: [Rule]

    static let uncategorized = "Uncategorized"

    static var defaults: RuleSet {
        RuleSet(
            categories: [
                Category(name: "Deep work", color: "#3b7dd8"),
                Category(name: "Browsing", color: "#e0a03c"),
                Category(name: "Notes", color: "#7d5bbe"),
                Category(name: "Media", color: "#3fa88a"),
                Category(name: "Idle", color: "#3a3f4b"),
                Category(name: "Locked", color: "#23262e"),
                Category(name: uncategorized, color: "#6b7280"),
            ],
            rules: [
                Rule(category: "Idle", app: "^__idle__$", label: "Idle"),
                Rule(category: "Locked", app: "^__locked__$", label: "Locked"),

                // Strips Claude Code's cycling spinner glyph so one task is one row.
                Rule(category: "Deep work", app: "^iTerm2$",
                     title: "^[^\\w(]*\\s*(.+)$", label: "Terminal: $1"),

                // VS Code reports "file.ext — project"; group by project.
                Rule(category: "Deep work", app: "^Code$",
                     title: "^.* — (.+)$", label: "VS Code: $1"),

                // Obsidian appends its version number, which churns on update.
                Rule(category: "Notes", app: "^Obsidian$",
                     title: "^(.*?) - .* - Obsidian", label: "Obsidian: $1"),

                Rule(category: "Media", app: "^Ludi$", label: "Ludi"),
                Rule(category: "Browsing", app: "Chrome|Safari|Firefox|Brave|Arc"),
            ]
        )
    }
}

/// What a raw tally key resolves to after rules are applied.
struct Resolved {
    var category: String
    var label: String
    var color: String
}

final class RuleEngine {
    private let ruleSet: RuleSet
    private var compiled: [(Rule, NSRegularExpression?, NSRegularExpression?, NSRegularExpression?)] = []
    private var colors: [String: String]
    private var cache: [String: Resolved] = [:]

    init(_ ruleSet: RuleSet) {
        self.ruleSet = ruleSet
        self.colors = Dictionary(ruleSet.categories.map { ($0.name, $0.color) },
                                 uniquingKeysWith: { a, _ in a })
        func re(_ p: String) -> NSRegularExpression? {
            p.isEmpty ? nil : try? NSRegularExpression(pattern: p, options: [.caseInsensitive])
        }
        // An invalid pattern compiles to nil, which would silently match everything.
        // Disable such a rule outright rather than letting it swallow the day.
        for rule in ruleSet.rules where rule.enabled {
            let a = re(rule.app), t = re(rule.title), u = re(rule.url)
            let broken = (!rule.app.isEmpty && a == nil)
                || (!rule.title.isEmpty && t == nil)
                || (!rule.url.isEmpty && u == nil)
            if broken { continue }
            compiled.append((rule, a, t, u))
        }
    }

    private func matches(_ re: NSRegularExpression?, _ s: String) -> Bool {
        guard let re else { return true }
        return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    func resolve(bundleID: String, appName: String, title: String, url: String) -> Resolved {
        let key = "\(bundleID)\u{1}\(appName)\u{1}\(title)\u{1}\(url)"
        if let hit = cache[key] { return hit }

        var result = Resolved(category: RuleSet.uncategorized,
                              label: title.isEmpty ? appName : title,
                              color: colors[RuleSet.uncategorized] ?? "#6b7280")

        for (rule, appRE, titleRE, urlRE) in compiled {
            let appOK = rule.app.isEmpty
                || matches(appRE, appName) || matches(appRE, bundleID)
            guard appOK, matches(titleRE, title), matches(urlRE, url) else { continue }

            var label = rule.label.isEmpty ? (title.isEmpty ? appName : title) : rule.label
            if !rule.label.isEmpty, let titleRE,
               let m = titleRE.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) {
                label = titleRE.replacementString(for: m, in: title, offset: 0, template: rule.label)
            }
            result = Resolved(category: rule.category,
                              label: label,
                              color: colors[rule.category] ?? "#6b7280")
            break
        }
        cache[key] = result
        return result
    }
}

enum RuleStore {
    static func load(at url: URL) -> RuleSet {
        guard let data = try? Data(contentsOf: url),
              let set = try? JSONDecoder().decode(RuleSet.self, from: data) else {
            let defaults = RuleSet.defaults
            save(defaults, to: url)
            return defaults
        }
        return set
    }

    static func save(_ set: RuleSet, to url: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? enc.encode(set).write(to: url, options: .atomic)
    }
}
