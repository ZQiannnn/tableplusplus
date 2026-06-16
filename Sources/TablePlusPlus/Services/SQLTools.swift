import Foundation

/// Statement-level SQL text utilities: split on top-level `;`, locate the statement under the
/// cursor, and a conservative whitespace/keyword formatter. All scanning is quote- and
/// comment-aware ('…', "…", `…`, -- …, # …, /* … */).
enum SQLTools {
    struct Statement {
        let sql: String
        let range: NSRange   // UTF-16 range in the source text
    }

    static func statements(in text: String) -> [Statement] {
        let ns = text as NSString
        var out: [Statement] = []
        var start = 0
        scan(text) { kind, loc in
            guard kind == .terminator else { return }
            append(ns, from: start, to: loc, into: &out)
            start = loc + 1
        }
        append(ns, from: start, to: ns.length, into: &out)
        return out
    }

    /// The statement containing `location` (UTF-16 offset), else the last one before it.
    static func statement(in text: String, at location: Int) -> Statement? {
        let all = statements(in: text)
        if let hit = all.first(where: { location >= $0.range.location && location <= $0.range.location + $0.range.length }) {
            return hit
        }
        return all.last { $0.range.location < location } ?? all.first
    }

    /// A `SELECT <list> FROM <table> [WHERE <cond>]` that's safe to split by primary-key range
    /// across parallel connections. nil for anything with JOIN / UNION / GROUP / ORDER / LIMIT /
    /// DISTINCT / aggregates / subqueries / multiple tables / comments — i.e. anything where range
    /// sharding would change results.
    struct SimpleSelect {
        let selectList: String   // verbatim, between SELECT and FROM
        let table: String        // verbatim table ref (may be `db`.`tbl`)
        let bareTable: String    // unquoted, db-stripped — for schema lookup
        let whereClause: String? // verbatim condition after WHERE, nil if none
    }

    private static let forbiddenParallel: Set<String> = [
        "JOIN", "UNION", "GROUP", "ORDER", "LIMIT", "HAVING", "DISTINCT", "OFFSET",
        "COUNT", "SUM", "AVG", "MIN", "MAX", "GROUP_CONCAT", "SELECT",
    ]

    static func parseSimpleSelect(_ sql: String) -> SimpleSelect? {
        let s = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        // Conservative: bail on comments (could hide forbidden clauses) and trailing ';'.
        if s.contains("--") || s.contains("/*") || s.contains("#") { return nil }
        let body = s.hasSuffix(";") ? String(s.dropLast()) : s
        let pattern = #"(?is)^SELECT\s+(.+?)\s+FROM\s+(`?[\w$]+`?(?:\.`?[\w$]+`?)?)\s*(?:WHERE\s+(.+))?$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)) else { return nil }
        let ns = body as NSString
        func group(_ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        guard let selectList = group(1)?.trimmingCharacters(in: .whitespaces),
              let tableRef = group(2) else { return nil }
        let whereClause = group(3)?.trimmingCharacters(in: .whitespaces)

        // Reject forbidden keywords anywhere in the select list or where condition (ORDER/LIMIT/…
        // captured inside the greedy WHERE group, aggregates / subqueries in the list).
        let scan = selectList + " " + (whereClause ?? "")
        var hit = false
        word(in: scan) { if forbiddenParallel.contains($0) { hit = true } }
        if hit { return nil }
        if selectList.contains("(") { return nil }   // functions / subqueries

        let bare = tableRef.split(separator: ".").last.map(String.init)?
            .replacingOccurrences(of: "`", with: "") ?? tableRef
        return SimpleSelect(selectList: selectList, table: tableRef, bareTable: bare, whereClause: whereClause)
    }

    /// The single base table a result can be safely edited against: `SELECT … FROM <one table> …`,
    /// allowing trailing WHERE / ORDER BY / LIMIT but rejecting JOIN / UNION / GROUP / aggregates /
    /// subqueries / multiple tables. Looser than `parseSimpleSelect` (which also bans ORDER/LIMIT).
    static func editableSelect(_ sql: String) -> (table: String, bareTable: String)? {
        let s = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.contains("--") || s.contains("/*") || s.contains("#") { return nil }
        let body = s.hasSuffix(";") ? String(s.dropLast()) : s
        let pattern = #"(?is)^SELECT\s+(.+?)\s+FROM\s+(`?[\w$]+`?(?:\.`?[\w$]+`?)?)(\s+(?:WHERE|ORDER|LIMIT|GROUP|HAVING)\b.*)?$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)) else { return nil }
        let ns = body as NSString
        func group(_ i: Int) -> String? {
            let r = m.range(at: i); return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        guard let selectList = group(1), let tableRef = group(2) else { return nil }
        let tail = group(3) ?? ""
        var bad = false
        word(in: selectList + " " + tail) { w in
            if ["JOIN", "UNION", "GROUP", "HAVING", "DISTINCT", "COUNT", "SUM", "AVG",
                "MIN", "MAX", "GROUP_CONCAT", "SELECT"].contains(w) { bad = true }
        }
        if bad || selectList.contains("(") || tableRef.contains(",") { return nil }
        let bare = tableRef.split(separator: ".").last.map(String.init)?
            .replacingOccurrences(of: "`", with: "") ?? tableRef
        return (tableRef, bare)
    }

    /// Uppercased first keyword of a statement (SELECT / INSERT / UPDATE / SHOW / …), "" if none.
    static func firstKeyword(_ sql: String) -> String {
        var first = ""
        word(in: sql) { w in if first.isEmpty { first = w } }
        return first
    }

    /// Statements that produce a result set (stream them); everything else reports affected rows.
    static func producesRows(_ sql: String) -> Bool {
        ["SELECT", "SHOW", "DESCRIBE", "DESC", "EXPLAIN", "WITH", "TABLE", "CALL", "VALUES"].contains(firstKeyword(sql))
    }

    /// True when the statement is a SELECT without its own top-level LIMIT.
    static func wantsLimit(_ sql: String) -> Bool {
        var firstWord: String?
        var hasLimit = false
        word(in: sql) { w in
            if firstWord == nil { firstWord = w }
            if w == "LIMIT" { hasLimit = true }
        }
        return firstWord == "SELECT" && !hasLimit
    }

    // MARK: - Beautify

    private static let newlineBefore: Set<String> = [
        "FROM", "WHERE", "GROUP", "ORDER", "HAVING", "LIMIT", "UNION",
        "LEFT", "RIGHT", "INNER", "OUTER", "CROSS", "JOIN", "SET", "VALUES",
    ]
    private static let indented: Set<String> = ["AND", "OR", "ON"]
    private static let keywords: Set<String> = newlineBefore.union(indented).union([
        "SELECT", "INSERT", "UPDATE", "DELETE", "INTO", "AS", "BY", "ASC", "DESC",
        "DISTINCT", "IN", "IS", "NOT", "NULL", "LIKE", "BETWEEN", "EXISTS", "CASE",
        "WHEN", "THEN", "ELSE", "END", "COUNT", "SUM", "MIN", "MAX", "AVG", "OFFSET",
    ])

    /// Reflows whitespace and uppercases keywords; line comments keep their own line.
    static func beautify(_ text: String) -> String {
        statements(in: text).map { beautifyOne($0.sql) }.joined(separator: ";\n\n") + (text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(";") ? ";" : "")
    }

    private static func beautifyOne(_ sql: String) -> String {
        var out = ""
        var prevJoinish = false
        token(in: sql) { tok, isWord in
            if isWord {
                let upper = tok.uppercased()
                let isKw = keywords.contains(upper)
                let word = isKw ? upper : tok
                if !out.isEmpty {
                    if newlineBefore.contains(upper) && !prevJoinish {
                        out += "\n"
                    } else if indented.contains(upper) && upper != "ON" {
                        out += "\n  "
                    } else {
                        out += " "
                    }
                }
                prevJoinish = ["LEFT", "RIGHT", "INNER", "OUTER", "CROSS"].contains(upper)
                out += word
            } else {
                if tok.hasPrefix("--") || tok.hasPrefix("#") {
                    out += (out.isEmpty ? "" : "\n") + tok + "\n"
                } else if tok == "," {
                    out += tok
                } else if tok == "(" || tok == ")" || tok == "." {
                    if tok == "(" && out.last == " " { }
                    out += tok
                } else {
                    if !out.isEmpty && out.last != "\n" && out.last != "(" && tok.first != ")" { out += " " }
                    out += tok
                }
                if !["--", "#"].contains(where: { tok.hasPrefix($0) }) { prevJoinish = false }
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Scanner core

    private enum Event { case terminator }

    /// Walks UTF-16 code units; reports each top-level `;` location.
    private static func scan(_ text: String, _ onEvent: (Event, Int) -> Void) {
        let u = Array(text.utf16)
        var i = 0
        while i < u.count {
            let c = u[i]
            switch c {
            case 0x27, 0x22, 0x60:   // ' " `
                let quote = c
                i += 1
                while i < u.count {
                    if u[i] == 0x5C { i += 2; continue }   // backslash escape
                    if u[i] == quote { break }
                    i += 1
                }
            case 0x2D where i + 1 < u.count && u[i + 1] == 0x2D,   // --
                 0x23:                                              // #
                while i < u.count && u[i] != 0x0A { i += 1 }
                continue
            case 0x2F where i + 1 < u.count && u[i + 1] == 0x2A:   // /*
                i += 2
                while i + 1 < u.count && !(u[i] == 0x2A && u[i + 1] == 0x2F) { i += 1 }
                i += 1
            case 0x3B:   // ;
                onEvent(.terminator, i)
            default:
                break
            }
            i += 1
        }
    }

    private static func append(_ ns: NSString, from: Int, to: Int, into out: inout [Statement]) {
        guard to > from else { return }
        let range = NSRange(location: from, length: to - from)
        let sql = ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sql.isEmpty else { return }
        out.append(Statement(sql: sql, range: range))
    }

    /// Uppercased bare words outside quotes/comments.
    private static func word(in sql: String, _ visit: (String) -> Void) {
        token(in: sql) { tok, isWord in
            if isWord { visit(tok.uppercased()) }
        }
    }

    /// Tokens outside quotes/comments: words (`isWord` true) and everything else (quoted strings,
    /// comments, punctuation) verbatim.
    private static func token(in sql: String, _ visit: (String, Bool) -> Void) {
        let s = Array(sql)
        var i = 0
        func isWordChar(_ ch: Character) -> Bool { ch.isLetter || ch.isNumber || ch == "_" }
        while i < s.count {
            let ch = s[i]
            if ch == "'" || ch == "\"" || ch == "`" {
                var j = i + 1
                while j < s.count {
                    if s[j] == "\\" { j += 2; continue }
                    if s[j] == ch { break }
                    j += 1
                }
                let end = min(j + 1, s.count)
                visit(String(s[i..<end]), false)
                i = end
            } else if ch == "-" && i + 1 < s.count && s[i + 1] == "-" || ch == "#" {
                var j = i
                while j < s.count && s[j] != "\n" { j += 1 }
                visit(String(s[i..<j]), false)
                i = j
            } else if ch == "/" && i + 1 < s.count && s[i + 1] == "*" {
                var j = i + 2
                while j + 1 < s.count && !(s[j] == "*" && s[j + 1] == "/") { j += 1 }
                let end = min(j + 2, s.count)
                visit(String(s[i..<end]), false)
                i = end
            } else if isWordChar(ch) {
                var j = i
                while j < s.count && isWordChar(s[j]) { j += 1 }
                visit(String(s[i..<j]), true)
                i = j
            } else if ch.isWhitespace {
                i += 1
            } else {
                visit(String(ch), false)
                i += 1
            }
        }
    }
}
