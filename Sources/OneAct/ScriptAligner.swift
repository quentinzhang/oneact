import Foundation
import NaturalLanguage

/// The two languages the voice-following teleprompter recognizes. The script
/// decides by default; the presenter can override it.
enum ScriptLanguage: String, CaseIterable {
    case chinese = "zh-CN"
    case english = "en-US"

    var locale: Locale { Locale(identifier: rawValue) }

    /// Same conversion as the timed teleprompter: about 1.7 Chinese characters
    /// take as long to say as one English word, so a Chinese script with a few
    /// English product names still counts as Chinese.
    static func dominant(in text: String) -> ScriptLanguage {
        var characters = 0
        var words = 0
        for token in SpeechText.tokenize(text).tokens {
            if token.isCJK { characters += 1 } else { words += 1 }
        }
        if characters == 0 && words == 0 {
            return Locale.current.language.languageCode == .chinese ? .chinese : .english
        }
        return Double(characters) / 1.7 >= Double(words) ? .chinese : .english
    }
}

/// One unit of speech: a Chinese character, or an English word.
struct SpeechToken: Equatable {
    /// Folded for comparison: lower case, half width, no diacritics or apostrophes.
    let text: String
    /// Where it sits in the source text, in UTF-16 units (what NSTextView uses).
    let range: NSRange
    let isCJK: Bool
}

/// Text normalization shared by the script and the recognizer's transcript, so
/// both sides of the comparison are cut the same way.
enum SpeechText {
    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (0x4E00...0x9FFF).contains(value)
            || (0x3400...0x4DBF).contains(value)
            || (0x20000...0x2A6DF).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0x3040...0x30FF).contains(value)
            || (0xAC00...0xD7AF).contains(value)
    }

    private static let sentenceTerminators: Set<Character> = [
        ".", "!", "?", ";", "…", "。", "！", "？", "；", "\n", "\r", "\r\n"
    ]
    private static let apostrophes: Set<Character> = ["'", "’", "ʼ"]

    /// Chinese is cut by character and everything else by word: the recognizer
    /// does not segment Chinese the way the script's author would, but it
    /// always agrees on the characters. Sentence ends are reported as token
    /// counts, so the aligner can size its look-ahead in sentences.
    static func tokenize(_ text: String) -> (tokens: [SpeechToken], sentenceEnds: [Int]) {
        var tokens: [SpeechToken] = []
        var sentenceEnds: [Int] = []
        var word = ""
        var wordStart = 0
        var offset = 0

        func flushWord() {
            guard !word.isEmpty else { return }
            tokens.append(SpeechToken(
                text: word,
                range: NSRange(location: wordStart, length: offset - wordStart),
                isCJK: false
            ))
            word = ""
        }

        for character in text {
            let length = character.utf16.count
            let folded = String(character).folding(
                options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive],
                locale: nil
            )
            let scalars = folded.unicodeScalars
            if scalars.contains(where: isCJK) {
                flushWord()
                tokens.append(SpeechToken(
                    text: folded,
                    range: NSRange(location: offset, length: length),
                    isCJK: true
                ))
            } else if !scalars.isEmpty,
                      scalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) {
                if word.isEmpty { wordStart = offset }
                word += folded
            } else if apostrophes.contains(character), !word.isEmpty {
                // "let's" and "lets" are one word to a listener.
            } else {
                flushWord()
                if folded.contains(where: sentenceTerminators.contains),
                   let last = tokens.indices.last, sentenceEnds.last != last + 1 {
                    sentenceEnds.append(last + 1)
                }
            }
            offset += length
        }
        flushWord()
        if !tokens.isEmpty, sentenceEnds.last != tokens.count {
            sentenceEnds.append(tokens.count)
        }
        return (tokens, sentenceEnds)
    }

    /// Short phrases from the script that the recognizer should expect: names,
    /// terms and longer words, which is where recognition goes wrong first. The
    /// recognizer asks for at most 100 phrases of a word or two.
    static func contextualPhrases(in text: String, language: ScriptLanguage, limit: Int = 100) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.setLanguage(language == .chinese ? .simplifiedChinese : .english)
        var seen: Set<String> = []
        var preferred: [String] = []
        var ordinary: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let word = String(text[range])
            let key = word.lowercased()
            guard !seen.contains(key) else { return true }
            let hanCount = word.unicodeScalars.filter(isCJK).count
            let isLatin = hanCount == 0
            let distinctive: Bool
            if isLatin {
                let hasCapitalInside = word.dropFirst().contains(where: \.isUppercase)
                distinctive = word.count >= 8 || hasCapitalInside
                    || word.contains(where: \.isNumber)
                    || (language == .chinese && word.count >= 2)
                    || (word.first?.isUppercase == true && word.count >= 4)
                guard word.count >= 3 || distinctive else { return true }
            } else {
                guard hanCount >= 2 else { return true }
                distinctive = hanCount >= 3
            }
            seen.insert(key)
            if distinctive { preferred.append(word) } else { ordinary.append(word) }
            return true
        }
        return Array((preferred + ordinary).prefix(limit))
    }
}

/// Tracks where a presenter is in their script from a live transcript.
///
/// The transcript is the recognizer's guess, and it is wrong in predictable
/// ways: it revises the last few words as more audio arrives, substitutes
/// homophones, drops words, and transcribes ad-libs that are not in the script
/// at all. So the aligner never trusts a single word. It keeps one position —
/// how many script tokens have been spoken — and on every update aligns the
/// most recent stretch of transcript against a window around that position: a
/// few sentences ahead, a little behind. A local alignment (Smith–Waterman,
/// with partial credit for homophones and near-spellings) finds where that
/// stretch best fits. The position moves only when the fit is good enough for
/// the kind of move it implies: continuing is cheap, jumping ahead needs more
/// evidence, going back needs the most. Anything else holds.
///
/// Because each update re-aligns the whole recent stretch, a revised partial
/// result simply replaces what came before; nothing has to be undone.
final class ScriptAligner {
    struct Tuning {
        /// Transcript tokens considered per update.
        let tailLength: Int
        /// The fit must end within this many tokens of the newest one: older
        /// matches say where the presenter was, not where they are.
        let recentSlack: Int
        /// A fit that starts within this many tokens past the position is a
        /// continuation rather than a jump.
        let continueSlack: Int
        /// A jump this short (a dropped clause, a garbled stretch) needs only a
        /// little more evidence than a continuation.
        let nearJump: Int
        let minContinueMatches: Int
        let minJumpMatches: Int
        /// Look-ahead in tokens, sized in sentences but clamped to these.
        let minimumForward: Int
        let maximumForward: Int
        let forwardSentences: Int
        /// How far behind the position the window reaches. It must cover the
        /// tail, which is mostly words already spoken.
        let backContext: Int
        /// Small backward fits are revisions, not re-reads.
        let backwardHoldTolerance: Int
        /// A match supports the position after it only if it follows the
        /// previous match within this many script tokens; a lone word after a
        /// gap is more often a misheard partial than the presenter skipping.
        let anchorStep: Int

        static func `for`(_ language: ScriptLanguage) -> Tuning {
            switch language {
            case .chinese:
                Tuning(
                    tailLength: 18, recentSlack: 4, continueSlack: 3, nearJump: 14,
                    minContinueMatches: 4, minJumpMatches: 7,
                    minimumForward: 60, maximumForward: 240, forwardSentences: 3,
                    backContext: 32, backwardHoldTolerance: 4, anchorStep: 3
                )
            case .english:
                Tuning(
                    tailLength: 12, recentSlack: 3, continueSlack: 2, nearJump: 8,
                    minContinueMatches: 3, minJumpMatches: 5,
                    minimumForward: 30, maximumForward: 130, forwardSentences: 3,
                    backContext: 20, backwardHoldTolerance: 3, anchorStep: 2
                )
            }
        }
    }

    enum Outcome: Equatable {
        case advanced
        /// A fit was found but did not justify moving (a revision, a weak fit).
        case held
        /// The presenter went back and re-read.
        case movedBack
        /// Nothing recent fits the script: an ad-lib, or the recognizer is lost.
        case offScript
    }

    struct Step {
        let outcome: Outcome
        let position: Int
        let matched: Int
        let score: Double
    }

    let language: ScriptLanguage
    let tokens: [SpeechToken]
    let tuning: Tuning
    private let sentenceEnds: [Int]
    private var vocabulary = SpeechVocabulary()
    private var scriptIDs: [Int] = []
    /// Script tokens spoken so far; the next one to be said is `tokens[position]`.
    private(set) var position = 0
    /// A backward fit seen once. Going back waits for a second update to
    /// agree, because a recognizer retracting its last words looks exactly
    /// like a re-read for one update.
    private var pendingBackEnd: Int?

    private struct Segment {
        let id: Int
        var tokenIDs: [Int]
        /// Tokens before this index were spoken before the last reset and must
        /// not pull the position back to where they were said.
        var ignoredPrefix: Int
    }
    private var segments: [Segment] = []

    // Scores: a match earns up to 2, everything else costs. Dropped script
    // words are cheaper than inserted transcript words because recognizers
    // drop far more often than they invent.
    private let matchReward = 2.0
    private let mismatchPenalty = 1.0
    private let transcriptGapPenalty = 0.9
    private let scriptGapPenalty = 0.7
    private let trailingPenalty = 0.6
    private let jumpCostPerToken = 0.05
    private let backCostPerToken = 0.08

    init(script: String, language: ScriptLanguage? = nil) {
        let resolved = language ?? ScriptLanguage.dominant(in: script)
        self.language = resolved
        tuning = Tuning.for(resolved)
        let parsed = SpeechText.tokenize(script)
        tokens = parsed.tokens
        sentenceEnds = parsed.sentenceEnds
        scriptIDs = tokens.map { vocabulary.id(for: $0.text, isCJK: $0.isCJK) }
    }

    var isEmpty: Bool { tokens.isEmpty }

    /// End of the last spoken token, for dimming what has been said.
    var spokenCharacterEnd: Int {
        position > 0 ? NSMaxRange(tokens[position - 1].range) : 0
    }

    /// Start of the next token to be said, which is what the reading line tracks.
    var nextCharacterLocation: Int {
        position < tokens.count ? tokens[position].range.location : spokenCharacterEnd
    }

    func reset(to newPosition: Int = 0) {
        position = min(max(0, newPosition), tokens.count)
        pendingBackEnd = nil
        clearTranscript()
    }

    /// Re-anchors after the presenter moved the script by hand: the first token
    /// at or after the offset becomes the next one to say.
    func reposition(toCharacterOffset offset: Int) {
        let index = tokens.firstIndex { $0.range.location >= offset } ?? tokens.count
        reset(to: index)
    }

    /// Speech heard so far no longer counts. Recognizer segments keep growing
    /// in place, so their current length is remembered and skipped later.
    func clearTranscript() {
        for index in segments.indices {
            segments[index].ignoredPrefix = segments[index].tokenIDs.count
        }
    }

    /// Feeds the recognizer's current text for one stream (one recognition
    /// task). Partial results replace the stream's previous text wholesale.
    @discardableResult
    func ingest(streamID: Int, text: String) -> Step {
        let ids = SpeechText.tokenize(text).tokens.map { vocabulary.id(for: $0.text, isCJK: $0.isCJK) }
        if let index = segments.firstIndex(where: { $0.id == streamID }) {
            segments[index].tokenIDs = ids
            segments[index].ignoredPrefix = min(segments[index].ignoredPrefix, ids.count)
        } else if let oldest = segments.first, streamID < oldest.id {
            // A late result for a stream already trimmed away; too old to matter.
            return Step(outcome: .held, position: position, matched: 0, score: 0)
        } else {
            // Streams are numbered in the order they started; a quiet stream
            // can still deliver its only result after its successor's first.
            let index = segments.firstIndex { $0.id > streamID } ?? segments.endIndex
            segments.insert(Segment(id: streamID, tokenIDs: ids, ignoredPrefix: 0), at: index)
        }
        trimSegments()
        return align(tail: recentTail())
    }

    private func recentTail() -> [Int] {
        var tail: [Int] = []
        for segment in segments.reversed() {
            let active = segment.tokenIDs.dropFirst(segment.ignoredPrefix)
            tail.insert(contentsOf: active.suffix(tuning.tailLength - tail.count), at: 0)
            if tail.count >= tuning.tailLength { break }
        }
        return tail
    }

    private func trimSegments() {
        var kept = 0
        var firstKept = segments.count
        for index in segments.indices.reversed() {
            firstKept = index
            kept += segments[index].tokenIDs.count - segments[index].ignoredPrefix
            if kept >= tuning.tailLength * 2 { break }
        }
        if firstKept > 0 { segments.removeFirst(firstKept) }
    }

    /// Look-ahead from `start`: a few sentences, clamped.
    private func forwardReach(from start: Int) -> Int {
        let ahead = sentenceEnds.filter { $0 > start }
        let target = ahead.count >= tuning.forwardSentences
            ? ahead[tuning.forwardSentences - 1]
            : tokens.count
        return min(max(target - start, tuning.minimumForward), tuning.maximumForward)
    }

    /// What a fit ending in one alignment cell is made of.
    private struct Path {
        var score = 0.0
        var matched = 0
        /// Matches at or past the position: the evidence for moving.
        var newMatched = 0
        /// Script index of the first match at or past the position, and
        /// where in the transcript it was heard.
        var firstNew = -1
        var firstNewHeardAt = -1
        /// Script index of the last match before the position, likewise.
        var lastOld = -1
        var lastOldHeardAt = -1
        /// Script index of the latest match, and the end of the latest match
        /// that followed its predecessor closely (see `Tuning.anchorStep`).
        var lastMatch = -1
        var anchoredEnd = -1
    }

    private struct Candidate {
        let end: Int
        let path: Path
        let adjusted: Double
    }

    private func align(tail: [Int]) -> Step {
        let m = tail.count
        let lo = max(0, position - tuning.backContext)
        let hi = min(tokens.count, position + forwardReach(from: position))
        let n = hi - lo
        guard m > 0, n > 0 else {
            return Step(outcome: .offScript, position: position, matched: 0, score: 0)
        }

        let width = n + 1
        var cells = [Path](repeating: Path(), count: (m + 1) * width)
        var best: Candidate?

        for i in 1...m {
            let spoken = tail[i - 1]
            for j in 1...n {
                let cell = i * width + j
                let scriptIndex = lo + j - 1
                let similarity = vocabulary.similarity(spoken, scriptIDs[scriptIndex])
                let diagonal = cells[cell - width - 1]
                let up = cells[cell - width]
                let left = cells[cell - 1]

                var path = Path()
                var endsInMatch = false
                let diagonalScore = diagonal.score
                    + (similarity > 0 ? matchReward * similarity : -mismatchPenalty)
                if diagonalScore > 0 {
                    path = diagonal.score > 0 ? diagonal : Path()
                    path.score = diagonalScore
                    if similarity > 0 {
                        endsInMatch = true
                        path.matched += 1
                        if path.lastMatch >= 0, scriptIndex - path.lastMatch <= tuning.anchorStep {
                            path.anchoredEnd = scriptIndex + 1
                        }
                        path.lastMatch = scriptIndex
                        if scriptIndex >= position {
                            path.newMatched += 1
                            if path.firstNew < 0 {
                                path.firstNew = scriptIndex
                                path.firstNewHeardAt = i
                            }
                        } else {
                            path.lastOld = scriptIndex
                            path.lastOldHeardAt = i
                        }
                    }
                }
                if up.score - transcriptGapPenalty > path.score {
                    path = up
                    path.score -= transcriptGapPenalty
                    endsInMatch = false
                }
                if left.score - scriptGapPenalty > path.score {
                    path = left
                    path.score -= scriptGapPenalty
                    endsInMatch = false
                }
                cells[cell] = path

                // Only fits that end on a match, among the newest words.
                let trailing = m - i
                guard endsInMatch, trailing <= tuning.recentSlack else { continue }
                let end = scriptIndex + 1
                let jump = path.firstNew >= 0
                    ? max(0, path.firstNew - (position + tuning.continueSlack))
                    : 0
                let back = max(0, position - end)
                let adjusted = path.score
                    - trailingPenalty * Double(trailing)
                    - jumpCostPerToken * Double(jump)
                    - backCostPerToken * Double(back)
                if best == nil || adjusted > best!.adjusted + 1e-9 {
                    best = Candidate(end: end, path: path, adjusted: adjusted)
                }
            }
        }

        guard let best else {
            return Step(outcome: .offScript, position: position, matched: 0, score: 0)
        }
        return decide(best)
    }

    private func decide(_ candidate: Candidate) -> Step {
        let path = candidate.path
        func step(_ outcome: Outcome) -> Step {
            Step(outcome: outcome, position: position, matched: path.matched, score: path.score)
        }
        let end = path.anchoredEnd
        guard end >= 0 else {
            pendingBackEnd = nil
            return step(.offScript)
        }

        if end > position {
            pendingBackEnd = nil
            // A fit that runs straight through the position — adjacent in the
            // script and in what was heard — is one reading continuing, and
            // all of it counts. Anything else (a fit that starts ahead, or
            // bridges an ad-lib to get there) is judged only on what it
            // matched ahead, and the further ahead, the more it needs.
            let gap = path.firstNew - position
            let contiguous = path.lastOld >= 0
                && gap <= tuning.continueSlack
                && position - path.lastOld <= tuning.continueSlack + 1
                && path.firstNewHeardAt - path.lastOldHeardAt <= 2
            let evidence: Int
            let required: Int
            if contiguous {
                evidence = path.matched
                required = tuning.minContinueMatches
            } else {
                evidence = path.newMatched
                if gap <= tuning.continueSlack {
                    required = tuning.minContinueMatches
                } else if gap <= tuning.nearJump {
                    required = tuning.minContinueMatches + 1
                } else {
                    required = tuning.minJumpMatches
                }
            }
            let span = end - path.firstNew
            let dense = contiguous || Double(path.newMatched) >= 0.6 * Double(span)
            guard evidence >= required, dense,
                  path.score >= matchReward * Double(required) * 0.7 else {
                return step(.offScript)
            }
            position = end
            return step(.advanced)
        }

        // Going back is only believed for a clear re-read: well behind the
        // position, as well supported as a jump, and still there on the next
        // update. Anything closer is the recognizer revising its last words.
        if position - end > tuning.backwardHoldTolerance,
           path.matched >= tuning.minJumpMatches,
           path.score >= matchReward * Double(tuning.minJumpMatches) * 0.8 {
            if let pending = pendingBackEnd, end >= pending - tuning.backwardHoldTolerance {
                pendingBackEnd = nil
                position = end
                return step(.movedBack)
            }
            pendingBackEnd = end
            return step(.held)
        }
        pendingBackEnd = nil
        return step(path.matched >= tuning.minContinueMatches ? .held : .offScript)
    }
}

/// Interned tokens with precomputed phonetic keys, so the alignment's inner
/// loop compares integers and looks up cached similarities.
private struct SpeechVocabulary {
    private struct Entry {
        let text: String
        let isCJK: Bool
        /// Toneless pinyin; the recognizer's commonest Chinese error is the
        /// right sound written with the wrong character (在/再, 的/得).
        let pinyin: String?
        /// Pinyin with the distinctions accents and recognizers blur (zh/z,
        /// ch/c, sh/s, -ng/-n) folded away.
        let loosePinyin: String?
        /// English consonant skeleton: their/there, to/two.
        let skeleton: String?
    }

    private var ids: [String: Int] = [:]
    private var entries: [Entry] = []
    private var cache: [Int: Double] = [:]

    mutating func id(for text: String, isCJK: Bool) -> Int {
        if let existing = ids[text] { return existing }
        let pinyin = isCJK ? Self.pinyin(of: text) : nil
        let entry = Entry(
            text: text,
            isCJK: isCJK,
            pinyin: pinyin,
            loosePinyin: pinyin.map(Self.loosen),
            skeleton: isCJK ? nil : Self.skeleton(of: text)
        )
        let id = entries.count
        entries.append(entry)
        ids[text] = id
        return id
    }

    mutating func similarity(_ a: Int, _ b: Int) -> Double {
        if a == b { return 1 }
        let key = a < b ? (a << 32) | b : (b << 32) | a
        if let cached = cache[key] { return cached }
        let value = Self.similarity(entries[a], entries[b])
        cache[key] = value
        return value
    }

    private static func similarity(_ a: Entry, _ b: Entry) -> Double {
        guard a.isCJK == b.isCJK else { return 0 }
        if a.isCJK {
            if let pa = a.pinyin, pa == b.pinyin { return 0.8 }
            if let la = a.loosePinyin, la == b.loosePinyin { return 0.6 }
            return 0
        }
        let x = Array(a.text)
        let y = Array(b.text)
        if min(x.count, y.count) >= 5, abs(x.count - y.count) <= 1, editDistance(x, y) <= 1 {
            return 0.7
        }
        if let sa = a.skeleton, sa.count >= 2, sa == b.skeleton {
            return 0.6
        }
        // Inflections: record / recording / recorded.
        if min(x.count, y.count) >= 5, x.prefix(4) == y.prefix(4), abs(x.count - y.count) <= 3 {
            return 0.6
        }
        return 0
    }

    private static func pinyin(of text: String) -> String? {
        let mutable = NSMutableString(string: text)
        guard CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false),
              CFStringTransform(mutable, nil, kCFStringTransformStripCombiningMarks, false) else {
            return nil
        }
        let result = (mutable as String).lowercased().trimmingCharacters(in: .whitespaces)
        return result.isEmpty || result == text ? nil : result
    }

    private static func loosen(_ pinyin: String) -> String {
        var syllable = pinyin
        for (from, to) in [("zh", "z"), ("ch", "c"), ("sh", "s")] where syllable.hasPrefix(from) {
            syllable = to + syllable.dropFirst(2)
        }
        if syllable.hasSuffix("ng") { syllable.removeLast() }
        return syllable
    }

    private static func skeleton(of word: String) -> String? {
        guard let first = word.first, first.isLetter else { return nil }
        var result = String(first)
        for character in word.dropFirst() where !"aeiouyhw".contains(character) {
            if result.last != character { result.append(character) }
        }
        return result
    }

    private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + [Int](repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                )
            }
            previous = current
        }
        return previous[b.count]
    }
}
