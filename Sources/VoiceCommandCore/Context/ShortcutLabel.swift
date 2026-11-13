import Foundation

/// Keyboard shortcuts that controls show in their own names: YouTube's "Previous (SHIFT+p)",
/// "Pause (k)", "Next keyboard shortcut SHIFT+n". When the control itself is gone (YouTube
/// hides Previous; 9 Nov), its shortcut still works.
public enum ShortcutLabel {
    /// The name without the shortcut, and the shortcut as `KeyCombo` text ("shift+p").
    public static func parse(_ label: String) -> (name: String, keys: String)? {
        let text = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [
            #"^(.+?)\s*\(([A-Za-z0-9⌘⇧⌥⌃+\- ]{1,20})\)$"#,          // "Previous (SHIFT+p)"
            #"^(.+?)\s+keyboard shortcut\s+([A-Za-z0-9⌘⇧⌥⌃+\-]{1,20})$"#,  // "Next keyboard shortcut SHIFT+n"
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let n = Range(m.range(at: 1), in: text), let k = Range(m.range(at: 2), in: text) else { continue }
            let keys = text[k].lowercased().replacingOccurrences(of: " ", with: "")
            // A single letter or a combination; "(2)" and "(13)" are counts, not keys.
            guard keys.contains("+") || (keys.count == 1 && keys.first!.isLetter) else { continue }
            // A plain Return could send something; never press that as a fallback.
            guard let combo = KeyCombo.parse(keys), !combo.isPlainReturn else { continue }
            return (String(text[n]).trimmingCharacters(in: .whitespaces), keys)
        }
        return nil
    }
}
