import Foundation

/// Local deny-list for shell commands. The router labels risk too; the stricter of the two
/// wins and neither is trusted alone.
public enum CommandRiskChecker {
    public struct Finding: Equatable {
        public let rule: String
        public let forbidden: Bool   // never allowed in the MVP (sudo)
    }

    /// Patterns are matched against each sub-command (split on ; && || |) separately.
    static let rules: [(name: String, pattern: String, forbidden: Bool)] = [
        ("sudo", #"^\s*(sudo|su|doas)\b"#, true),
        ("rm", #"^\s*(rm|rmdir|unlink|shred|srm)\b"#, false),
        ("find -delete", #"^\s*find\b.*\s-(delete|exec)\b"#, false),
        ("dd/mkfs", #"^\s*(dd|mkfs\S*|diskutil|fdisk)\b"#, false),
        ("chmod/chown -R", #"^\s*(chmod|chown|chgrp)\b.*\s-R\b"#, false),
        ("git push", #"^\s*git\b.*\bpush\b"#, false),
        ("git reset --hard", #"^\s*git\b.*\breset\b.*--hard"#, false),
        ("git clean", #"^\s*git\b.*\bclean\b"#, false),
        ("git checkout/restore discard", #"^\s*git\b.*\b(checkout|restore)\b.*(\s--\s|\s\.$|--staged|--worktree)"#, false),
        ("git branch -D", #"^\s*git\b.*\bbranch\b.*\s-D\b"#, false),
        ("git rebase/filter", #"^\s*git\b.*\b(rebase|filter-branch|filter-repo)\b"#, false),
        ("drop/truncate", #"\b(drop|truncate)\s+(table|database|schema|index)\b"#, false),
        ("delete from", #"\bdelete\s+from\b"#, false),
        ("kubectl", #"^\s*kubectl\b.*\b(delete|apply|replace|scale|drain|rollout)\b"#, false),
        ("helm", #"^\s*helm\b.*\b(install|upgrade|uninstall|delete|rollback)\b"#, false),
        ("terraform", #"^\s*(terraform|tofu|pulumi)\b.*\b(apply|destroy|up)\b"#, false),
        ("docker rm/prune", #"^\s*docker\b.*\b(rm|rmi|prune|kill|stop)\b"#, false),
        ("publish/deploy", #"\b(npm|pnpm|yarn|cargo|gem|twine)\s+publish\b|\bdeploy\b|\bvercel\b.*--prod|\bfly\s+deploy\b|\bheroku\b"#, false),
        ("shutdown", #"^\s*(shutdown|reboot|halt|killall|pkill|launchctl)\b"#, false),
        ("kill -9", #"^\s*kill\b"#, false),
        ("pipe to shell", #"\|\s*(sh|bash|zsh|python\d?|node|ruby|perl)\b"#, false),
        ("curl/wget", #"^\s*(curl|wget)\b"#, false),
        ("overwrite redirect", #"(^|[^>])>\s*[^&\s>]"#, false),
        ("mv/cp overwrite", #"^\s*(mv|cp)\b"#, false),
        ("eval/exec", #"^\s*(eval|exec|xargs)\b"#, false),
        ("defaults/security", #"^\s*(defaults\s+(write|delete)|security\b|csrutil|spctl|tccutil)"#, false),
    ]

    static let compiled: [(String, NSRegularExpression, Bool)] = rules.compactMap { r in
        (try? NSRegularExpression(pattern: r.pattern, options: [.caseInsensitive])).map { (r.name, $0, r.forbidden) }
    }

    static func subcommands(_ command: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var chars = Array(command)
        var i = 0
        chars.append(" ")
        while i < chars.count - 1 {
            let c = chars[i], n = chars[i + 1]
            if (c == "&" && n == "&") || (c == "|" && n == "|") {
                parts.append(current); current = ""; i += 2; continue
            }
            if c == ";" || c == "\n" || c == "`" || (c == "$" && n == "(") {
                parts.append(current); current = ""; i += (c == "$" ? 2 : 1); continue
            }
            current.append(c)
            i += 1
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public static func findings(_ command: String) -> [Finding] {
        var out: [Finding] = []
        // Whole-command rules that need the pipe context.
        let whole = command as NSString
        for (name, re, forbidden) in compiled where name == "pipe to shell" || name == "drop/truncate" || name == "delete from" || name == "publish/deploy" {
            if re.firstMatch(in: command, range: NSRange(location: 0, length: whole.length)) != nil {
                out.append(Finding(rule: name, forbidden: forbidden))
            }
        }
        for sub in subcommands(command) {
            // A pipe stage is its own command for the leading-word rules.
            for stage in sub.split(separator: "|").map({ String($0).trimmingCharacters(in: .whitespaces) }) {
                let ns = stage as NSString
                for (name, re, forbidden) in compiled where re.firstMatch(in: stage, range: NSRange(location: 0, length: ns.length)) != nil {
                    if !out.contains(where: { $0.rule == name }) { out.append(Finding(rule: name, forbidden: forbidden)) }
                }
            }
        }
        return out
    }

    public static func isRisky(_ command: String) -> Bool { !findings(command).isEmpty }
    public static func isForbidden(_ command: String) -> Bool { findings(command).contains { $0.forbidden } }
}
