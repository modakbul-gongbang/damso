import Foundation

/// Page scripts executed inside the user's meeting tab via
/// `chromux run --page-file`, plus the selector strategies they use.
///
/// Every selector lives in this one file so the T9 live probe (real Meet
/// call) can confirm or replace them in a single place; the JSON envelope
/// each script returns is what the parsing layer and its fixtures test, so a
/// selector change never ripples further than this file.
enum MeetingDOMScripts {
    /// Extracts participant display names from a Meet tab. Tries the video
    /// tiles first (present without opening any panel), then the people side
    /// panel when the user has it open.
    static let meetParticipants = """
    (() => {
      const names = new Set();
      const clean = (t) => (t || "").replace(/\\s+/g, " ").trim();
      // Google icon fonts render the glyph name as text ("devices",
      // "frame_person") and can carry the same notranslate class as the
      // name plates (confirmed on a live call, 2026-07-17), so icon
      // elements are skipped explicitly.
      const isIconElement = (el) => {
        if (!el) return true;
        if (el.closest("i")) return true;
        const cls = ((el.className || "") + "").toLowerCase();
        return cls.includes("material-icons") || cls.includes("material-symbols") || cls.includes("google-symbols");
      };
      for (const tile of document.querySelectorAll("[data-participant-id]")) {
        const selfName = tile.getAttribute("data-self-name");
        if (selfName) { names.add(clean(selfName)); continue; }
        const plate = tile.querySelector("[data-self-name]");
        if (plate) { names.add(clean(plate.getAttribute("data-self-name"))); continue; }
        const text = [...tile.querySelectorAll(".notranslate")].find((el) => !isIconElement(el) && clean(el.textContent));
        if (text) names.add(clean(text.textContent));
      }
      for (const item of document.querySelectorAll('[role="list"] [role="listitem"][aria-label]')) {
        names.add(clean(item.getAttribute("aria-label")));
      }
      return JSON.stringify({ kind: "participants", participants: [...names].filter(Boolean) });
    })()
    """

    /// Extracts the names of currently speaking participants from a Meet tab
    /// (active-speaker indicator on the tile).
    static let meetActiveSpeakers = """
    (() => {
      const names = new Set();
      const clean = (t) => (t || "").replace(/\\s+/g, " ").trim();
      const isIconElement = (el) => {
        if (!el) return true;
        if (el.closest("i")) return true;
        const cls = ((el.className || "") + "").toLowerCase();
        return cls.includes("material-icons") || cls.includes("material-symbols") || cls.includes("google-symbols");
      };
      for (const tile of document.querySelectorAll("[data-participant-id]")) {
        const speaking = tile.querySelector('[data-speaking="true"], [class*="speaking" i]');
        if (!speaking) continue;
        const label = tile.getAttribute("data-self-name")
          || tile.querySelector("[data-self-name]")?.getAttribute("data-self-name")
          || [...tile.querySelectorAll(".notranslate")].find((el) => !isIconElement(el) && clean(el.textContent))?.textContent;
        if (label) names.add(clean(label));
      }
      return JSON.stringify({ kind: "activeSpeakers", activeSpeakers: [...names].filter(Boolean) });
    })()
    """

    /// Extracts participant display names from a Zoom web client tab. Names
    /// are only present while the participants panel is open; the footer
    /// count alone never yields names, so an empty result is normal.
    static let zoomWebParticipants = """
    (() => {
      const names = new Set();
      const clean = (t) => (t || "").replace(/\\s+/g, " ").trim();
      for (const item of document.querySelectorAll(".participants-item__display-name, [class*='participants-item'] [class*='display-name']")) {
        names.add(clean(item.textContent));
      }
      return JSON.stringify({ kind: "participants", participants: [...names].filter(Boolean) });
    })()
    """
}

/// Parses the JSON envelope a capture script returned through chromux stdout.
/// chromux may wrap the result in its own logging, so the parser scans for
/// the script's envelope instead of assuming clean output.
enum MeetingDOMScriptOutput {
    static func participantNames(from data: Data) -> [String]? {
        envelope(from: data)?.participants.map { $0.filter { !isLikelyIconGlyphName($0) } }
    }

    static func activeSpeakerNames(from data: Data) -> [String]? {
        envelope(from: data)?.activeSpeakers.map { $0.filter { !isLikelyIconGlyphName($0) } }
    }

    /// Google icon fonts leak their glyph name as scraped text ("devices",
    /// "frame_person" — seen on a live Meet call). Second line of defense
    /// behind the page script's icon-element skip: snake_case lowercase
    /// tokens are never display names, plus the single-word glyphs Meet's
    /// in-call UI actually shows. Exact lowercase match only, so real names
    /// like "Devices Kim" or lowercase handles like "gggg" pass through.
    static func isLikelyIconGlyphName(_ name: String) -> Bool {
        if name.contains("_"), name.range(of: "^[a-z0-9]+(_[a-z0-9]+)+$", options: .regularExpression) != nil {
            return true
        }
        return meetUIGlyphNames.contains(name)
    }

    private static let meetUIGlyphNames: Set<String> = [
        "devices", "mic", "videocam", "mood", "chat", "info", "keep",
        "fullscreen", "group", "groups", "settings", "close", "search",
        "send", "lock", "feedback", "help", "warning",
    ]

    private struct Envelope: Decodable {
        var participants: [String]?
        var activeSpeakers: [String]?
    }

    private static func envelope(from data: Data) -> Envelope? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let decoder = JSONDecoder()
        // The result may appear as a raw object, an object nested in chromux's
        // own response, or a JSON-encoded string. Scan candidate ranges.
        for candidate in jsonCandidates(in: text) {
            guard let candidateData = candidate.data(using: .utf8) else { continue }
            if let envelope = try? decoder.decode(Envelope.self, from: candidateData),
               envelope.participants != nil || envelope.activeSpeakers != nil {
                return envelope
            }
            if let unescaped = try? decoder.decode(String.self, from: candidateData),
               let unescapedData = unescaped.data(using: .utf8),
               let envelope = try? decoder.decode(Envelope.self, from: unescapedData),
               envelope.participants != nil || envelope.activeSpeakers != nil {
                return envelope
            }
        }
        return nil
    }

    /// Balanced-brace object candidates plus quoted-string candidates that
    /// may hold a JSON.stringify'd envelope.
    private static func jsonCandidates(in text: String) -> [String] {
        var candidates: [String] = []
        var depth = 0
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "{" {
                if depth == 0 { start = index }
                depth += 1
            } else if character == "}" , depth > 0 {
                depth -= 1
                if depth == 0, let openIndex = start {
                    candidates.append(String(text[openIndex...index]))
                    start = nil
                }
            }
            index = text.index(after: index)
        }
        // Quoted candidates: "{\\"kind\\":...}"
        var searchRange = text.startIndex..<text.endIndex
        while let quoteRange = text.range(of: "\"{", range: searchRange) {
            if let closing = text.range(of: "}\"", range: quoteRange.upperBound..<text.endIndex) {
                candidates.append(String(text[quoteRange.lowerBound..<closing.upperBound]))
                searchRange = closing.upperBound..<text.endIndex
            } else {
                break
            }
        }
        return candidates
    }
}
