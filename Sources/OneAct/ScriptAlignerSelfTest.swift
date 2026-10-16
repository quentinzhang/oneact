import Foundation

/// Offline test of the voice-following aligner: no microphone, no recognizer.
///
/// A simulated presenter reads a Chinese and an English script while a
/// simulated recognizer turns the speech into the kind of partial results the
/// real one produces — streamed a few words at a time, revised as it goes,
/// rolled over into new streams, with homophones, split words and dropped
/// words. Each scenario asserts what the presenter would see: the position
/// only moves forward (within a small tolerance), keeps up at sentence ends,
/// holds during ad-libs, never jumps to a later copy of a repeated phrase or
/// past the look-ahead window, and ends at the end of the script.
///
/// Run with `OneAct --aligner-test`.
enum ScriptAlignerSelfTest {
    static func run() -> Int32 {
        do {
            try verifyNormalization()
            var summaries: [String] = []
            // ALIGNER_SEEDS=<n> sweeps more seeds when retuning.
            let extra = Int(ProcessInfo.processInfo.environment["ALIGNER_SEEDS"] ?? "") ?? 0
            let seeds: [UInt64] = [1, 7, 42] + (0..<max(0, extra)).map { UInt64(100 + $0) }
            for fixture in [Fixture.chinese, Fixture.english] {
                for scenario in Scenario.allCases {
                    for seed in seeds {
                        let result = try run(scenario, fixture: fixture, seed: seed)
                        if seed == 1 {
                            print("ALIGNER_CASE \(fixture.name) \(scenario) \(result)")
                        }
                    }
                    summaries.append("\(fixture.name).\(scenario)")
                }
            }
            print("ALIGNER_TEST_OK cases=\(summaries.count * seeds.count) scenarios=\(summaries.joined(separator: ","))")
            return 0
        } catch {
            fputs("ALIGNER_TEST_FAILED \(error)\n", stderr)
            return 1
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    // MARK: - Normalization

    private static func verifyNormalization() throws {
        let english = SpeechText.tokenize("Let’s try ＯｎｅＡｃｔ — it's GREAT, café!\nNext line.")
        let words = english.tokens.map(\.text)
        guard words == ["lets", "try", "oneact", "its", "great", "cafe", "next", "line"] else {
            throw Failure("english normalization: \(words)")
        }
        guard english.sentenceEnds == [6, 8] else {
            throw Failure("english sentence ends: \(english.sentenceEnds)")
        }
        let chinese = SpeechText.tokenize("你好，ＯｎｅＡｃｔ！一镜到底。")
        let characters = chinese.tokens.map(\.text)
        guard characters == ["你", "好", "oneact", "一", "镜", "到", "底"] else {
            throw Failure("chinese normalization: \(characters)")
        }
        // Ranges must point back into the original text for highlighting.
        let source = "你好，ＯｎｅＡｃｔ！一镜到底。" as NSString
        guard source.substring(with: chinese.tokens[2].range) == "ＯｎｅＡｃｔ",
              source.substring(with: chinese.tokens[3].range) == "一" else {
            throw Failure("chinese token ranges do not map back to the script")
        }
        guard ScriptLanguage.dominant(in: Fixture.chinese.script) == .chinese,
              ScriptLanguage.dominant(in: Fixture.english.script) == .english,
              ScriptLanguage.dominant(in: "今天介绍 OneAct 和 Final Cut Pro 的区别") == .chinese,
              ScriptLanguage.dominant(in: "Today we compare OneAct with 剪映") == .english else {
            throw Failure("language detection")
        }
        let phrases = SpeechText.contextualPhrases(in: Fixture.english.script, language: .english)
        guard phrases.count <= 100, phrases.contains("OneAct"), phrases.contains("teleprompter") else {
            throw Failure("english contextual phrases: \(phrases.prefix(12))")
        }
        let chinesePhrases = SpeechText.contextualPhrases(in: Fixture.chinese.script, language: .chinese)
        guard !chinesePhrases.isEmpty, chinesePhrases.count <= 100 else {
            throw Failure("chinese contextual phrases empty")
        }
    }

    // MARK: - Scenarios

    enum Scenario: CaseIterable, CustomStringConvertible {
        case exact, adLibs, skippedSentence, repeatedPhrase, recognizerErrors, partialRevisions,
             outOfWindow, rereadSentence

        var description: String {
            switch self {
            case .exact: "exact"
            case .adLibs: "ad_libs"
            case .skippedSentence: "skipped_sentence"
            case .repeatedPhrase: "repeated_phrase"
            case .recognizerErrors: "recognizer_errors"
            case .partialRevisions: "partial_revisions"
            case .outOfWindow: "out_of_window"
            case .rereadSentence: "reread_sentence"
            }
        }
    }

    struct Fixture {
        let name: String
        let script: String
        let language: ScriptLanguage
        /// A digression with plenty of words the script also uses.
        let adLib: [String]
        let shortAdLib: [String]
        /// What a recognizer writes instead: homophones, splits, near-misses.
        let confusions: [String: [String]]
        /// Every n-th word the recognizer gets wrong, where it has a confusion.
        let substitutionEvery: Int
        let backTolerance: Int
        let lagTolerance: Int
        let endTolerance: Int
        /// Index of the sentence whose opening phrase repeats two sentences later.
        let repeatedSentence: Int

        static let chinese = Fixture(
            name: "zh",
            script: """
            大家好，欢迎来到这一期的节目。今天我们来聊一聊一镜到底的录制方式。
            所见即所得，预览里看到的就是最终保存的画面。没有时间线，也没有导出和二次剪辑。
            接下来我们一起来看看提词器是怎么跟上你的声音的。语音识别完全在你的电脑上运行，声音不会离开这台设备。
            接下来我们一起来看看你临场发挥的时候会发生什么。你停下来的时候，稿子也会停下来等你。
            即使你讲了一段稿子以外的故事，它也会停在原处，等你回来。这就是全部的想法：一次录完，就此收工。
            """,
            language: .chinese,
            adLib: Array("嗯我跟大家说一下上周我试的时候家里的猫一直在键盘上走来走去特别好笑").map(String.init),
            shortAdLib: Array("这一点其实很重要啊").map(String.init),
            confusions: [
                "的": ["得"], "在": ["再"], "是": ["事"], "期": ["其"], "节": ["结"], "目": ["木"],
                "今": ["金"], "天": ["添"], "们": ["门"], "聊": ["辽"], "镜": ["境"], "录": ["路"],
                "制": ["至"], "方": ["芳"], "式": ["试"], "见": ["建"], "即": ["及"], "预": ["遇"],
                "览": ["懒"], "里": ["理"], "看": ["砍"], "到": ["道"], "就": ["旧"], "最": ["罪"],
                "终": ["中"], "保": ["宝"], "存": ["村"], "画": ["话"], "面": ["免"], "有": ["友"],
                "时": ["实"], "间": ["见"], "线": ["现"], "也": ["野"], "导": ["岛"], "出": ["初"],
                "和": ["河"], "二": ["而"], "次": ["刺"], "剪": ["简"], "辑": ["集"], "接": ["街"],
                "下": ["夏"], "提": ["题"], "词": ["辞"], "器": ["气"], "跟": ["根"], "上": ["尚"],
                "声": ["生"], "音": ["因"], "语": ["雨"], "识": ["实"], "完": ["玩"], "全": ["权"],
                "电": ["店"], "脑": ["恼"], "运": ["云"], "会": ["汇"], "台": ["抬"], "设": ["社"],
                "备": ["被"], "停": ["亭"], "稿": ["搞"], "子": ["字"], "等": ["邓"], "临": ["林"],
                "场": ["厂"], "发": ["法"], "挥": ["辉"], "使": ["始"], "讲": ["奖"], "段": ["断"],
                "故": ["顾"], "事": ["是"], "它": ["他"], "原": ["元"], "部": ["步"], "想": ["响"],
                "法": ["发"], "收": ["手"], "工": ["公"]
            ],
            substitutionEvery: 2,
            backTolerance: 3,
            lagTolerance: 4,
            endTolerance: 3,
            repeatedSentence: 4
        )

        static let english = Fixture(
            name: "en",
            script: """
            Welcome to OneAct, a recorder built for people who would rather speak than edit. \
            Everything you see in the preview is exactly what ends up in the file. \
            There is no timeline, no export step, and no second pass. \
            Today I want to show you how the teleprompter keeps up with your voice.

            Let's take a closer look at how it works. \
            The recognizer runs entirely on your Mac, so your words never leave the room. \
            Let's take a closer look at what happens when you go off script. \
            When you stop talking, the script waits for you. \
            If you wander into a story, it simply holds its place until you come back. \
            That is the whole idea: one take, and you are done.
            """,
            language: .english,
            adLib: "so yeah you know I actually tried this last week with my cat walking across the keyboard and it was honestly pretty funny"
                .split(separator: " ").map(String.init),
            shortAdLib: "and by the way this part really matters".split(separator: " ").map(String.init),
            confusions: [
                "oneact": ["one", "act"], "to": ["two"], "for": ["four"], "would": ["wood"],
                "see": ["sea"], "preview": ["pre", "view"], "exactly": ["exact"],
                "timeline": ["time", "line"], "export": ["expert"], "teleprompter": ["teleprompters"],
                "voice": ["voices"], "closer": ["close"], "recognizer": ["recognize", "her"],
                "entirely": ["entire"], "mac": ["mack"], "words": ["word"], "room": ["rum"],
                "talking": ["taking"], "script": ["scripts"], "waits": ["weights"],
                "wander": ["wonder"], "story": ["storey"], "simply": ["simple"], "holds": ["hold"],
                "place": ["plays"], "whole": ["hole"], "idea": ["i", "dear"], "done": ["dawn"],
                "their": ["there"], "your": ["you're"], "rather": ["rather"], "edit": ["edited"],
                "people": ["peoples"], "file": ["fall"], "second": ["seconds"], "pass": ["past"],
                "works": ["work"], "leave": ["live"], "happens": ["happen"], "until": ["till"]
            ],
            substitutionEvery: 3,
            backTolerance: 2,
            lagTolerance: 3,
            endTolerance: 2,
            repeatedSentence: 4
        )
    }

    private struct SpokenUnit {
        let text: String
        /// Script token this word reads, or nil for an ad-lib.
        let scriptIndex: Int?
        /// Index into `units` where a sentence ends and the presenter breathes.
        let endsSentence: Bool
        let sentence: Int?
    }

    private struct Summary: CustomStringConvertible {
        var updates = 0
        var finalPosition = 0
        var tokenCount = 0
        var largestBackStep = 0
        var largestLag = 0
        var movedBack = 0
        var maxDuringAdLib = 0

        var description: String {
            "end=\(finalPosition)/\(tokenCount) updates=\(updates) max_back=\(largestBackStep) max_sentence_lag=\(largestLag) moved_back=\(movedBack) adlib_drift=\(maxDuringAdLib)"
        }
    }

    // MARK: - Simulation

    private static func run(_ scenario: Scenario, fixture: Fixture, seed: UInt64) throws -> Summary {
        let parsed = SpeechText.tokenize(fixture.script)
        let tokens = parsed.tokens
        var sentences: [Range<Int>] = []
        var start = 0
        for end in parsed.sentenceEnds {
            sentences.append(start..<end)
            start = end
        }
        let aligner = ScriptAligner(script: fixture.script, language: fixture.language)
        guard aligner.tokens.count == tokens.count else { throw Failure("token count mismatch") }

        func read(_ sentence: Int, from offset: Int = 0, count: Int? = nil) -> [SpokenUnit] {
            let range = sentences[sentence]
            let first = range.lowerBound + offset
            let last = count.map { min(range.upperBound, first + $0) } ?? range.upperBound
            return (first..<last).map { index in
                SpokenUnit(
                    text: tokens[index].text,
                    scriptIndex: index,
                    endsSentence: index == range.upperBound - 1,
                    sentence: sentence
                )
            }
        }
        func say(_ words: [String]) -> [SpokenUnit] {
            words.enumerated().map { offset, word in
                SpokenUnit(text: word.lowercased(), scriptIndex: nil, endsSentence: offset == words.count - 1, sentence: nil)
            }
        }

        var units: [SpokenUnit] = []
        var rolloverBefore: Set<Int> = []
        var rereadStart = Int.max
        switch scenario {
        case .exact, .recognizerErrors, .partialRevisions:
            for sentence in sentences.indices { units += read(sentence) }
        case .adLibs:
            for sentence in sentences.indices {
                if sentence == 3 { units += say(fixture.adLib) }
                if sentence == 6 {
                    let half = sentences[6].count / 2
                    units += read(6, count: half) + say(fixture.shortAdLib) + read(6, from: half)
                } else {
                    units += read(sentence)
                }
            }
        case .skippedSentence:
            for sentence in sentences.indices where sentence != 3 { units += read(sentence) }
        case .repeatedPhrase:
            // An ad-lib and a stream rollover right before the first copy, so
            // the phrase arrives with no context to anchor it.
            for sentence in sentences.indices {
                if sentence == fixture.repeatedSentence {
                    units += say(fixture.shortAdLib)
                    rolloverBefore.insert(units.count)
                }
                units += read(sentence)
            }
        case .outOfWindow:
            // After two sentences the presenter reads the last one, far
            // beyond the look-ahead, then carries on from where they were.
            units += read(0) + read(1)
            units += read(sentences.count - 1).map {
                SpokenUnit(text: $0.text, scriptIndex: nil, endsSentence: $0.endsSentence, sentence: nil)
            }
            for sentence in 2..<sentences.count { units += read(sentence) }
        case .rereadSentence:
            // "Let me say that again": a finished sentence, read once more.
            // Re-reading part of a sentence needs no move at all — the
            // position simply holds until the presenter passes it again.
            for sentence in sentences.indices {
                units += read(sentence)
                if sentence == 5 {
                    rereadStart = units.count
                    units += read(5)
                }
            }
        }

        var rng = SplitMix64(seed: seed)
        var summary = Summary(tokenCount: tokens.count)
        var stream = 0
        var heard: [String] = []
        var untilRollover = rng.int(in: 25...45)
        var untilPartial = rng.int(in: 1...3)
        var highWater = 0
        var adLibStart: Int?
        let allowsBack = scenario == .rereadSentence

        func check(_ step: ScriptAligner.Step, unit: Int) throws {
            summary.updates += 1
            let position = aligner.position
            guard position >= 0, position <= tokens.count else { throw Failure("position out of range \(position)") }
            if step.outcome == .movedBack { summary.movedBack += 1 }
            if position < highWater {
                summary.largestBackStep = max(summary.largestBackStep, highWater - position)
                if !allowsBack, highWater - position > fixture.backTolerance {
                    throw Failure("\(fixture.name) \(scenario) seed \(seed): moved back \(highWater - position) at unit \(unit)")
                }
            }
            highWater = allowsBack ? position : max(highWater, position)
            if unit >= rereadStart, position < sentences[5].lowerBound - fixture.backTolerance {
                throw Failure("\(fixture.name) seed \(seed): went back past the re-read sentence to \(position)")
            }
            let current = units[unit]
            if current.scriptIndex == nil {
                let anchor = adLibStart ?? position
                adLibStart = anchor
                summary.maxDuringAdLib = max(summary.maxDuringAdLib, position - anchor)
                // A word or two of drift is the same ambiguity a human
                // operator has ("that is the…" against "there is no…").
                let tolerance = fixture.backTolerance
                if position - anchor > tolerance, scenario == .adLibs || scenario == .outOfWindow || scenario == .repeatedPhrase {
                    throw Failure("\(fixture.name) \(scenario) seed \(seed): drifted \(position - anchor) during off-script speech at unit \(unit)")
                }
            } else {
                adLibStart = nil
            }
            if scenario == .repeatedPhrase, current.sentence == fixture.repeatedSentence {
                let limit = sentences[fixture.repeatedSentence].upperBound + fixture.backTolerance
                if position > limit {
                    throw Failure("\(fixture.name) seed \(seed): jumped to the later copy of the repeated phrase (\(position) > \(limit))")
                }
            }
            if scenario == .outOfWindow, current.scriptIndex == nil, position > sentences[2].upperBound {
                throw Failure("\(fixture.name) seed \(seed): followed speech beyond the look-ahead window to \(position)")
            }
        }

        func emit(_ words: [String], final: Bool, unit: Int) throws {
            let text = join(words, fixture.language)
            let step = aligner.ingest(streamID: stream, text: text)
            if ProcessInfo.processInfo.environment["ALIGNER_DEBUG"] != nil {
                fputs("  [\(unit)] s\(stream) \(step.outcome) pos=\(step.position) m=\(step.matched) score=\(String(format: "%.1f", step.score)) \(String(text.suffix(30)))\n", stderr)
            }
            try check(step, unit: unit)
        }

        for (index, unit) in units.enumerated() {
            if rolloverBefore.contains(index), !heard.isEmpty {
                try emit(heard, final: true, unit: max(0, index - 1))
                stream += 1
                heard = []
                untilRollover = rng.int(in: 25...45)
            }
            var recognized = [unit.text]
            if scenario == .recognizerErrors, unit.scriptIndex != nil {
                if index % 9 == 4 {
                    recognized = []
                } else if index % fixture.substitutionEvery == 1, let substitute = fixture.confusions[unit.text] {
                    recognized = substitute
                }
            }
            heard += recognized
            untilPartial -= 1
            untilRollover -= 1

            if untilPartial <= 0 || unit.endsSentence {
                untilPartial = rng.int(in: 1...3)
                if scenario == .partialRevisions, heard.count > 4 {
                    let roll = rng.unit()
                    if roll < 0.35 {
                        // The newest word first comes out wrong — often as a
                        // real word from elsewhere in the script.
                        var noisy = heard
                        noisy[noisy.count - 1] = tokens[rng.int(in: 0...(tokens.count - 1))].text
                        try emit(noisy, final: false, unit: index)
                    } else if roll < 0.5 {
                        // Retracts its last two words, then restores them.
                        try emit(Array(heard.dropLast(2)), final: false, unit: index)
                    } else if roll < 0.65 {
                        // Revises a word a little further back.
                        var noisy = heard
                        noisy[noisy.count - 1 - rng.int(in: 1...3)] = "uh"
                        try emit(noisy, final: false, unit: index)
                    }
                }
                try emit(heard, final: false, unit: index)
            }
            if untilRollover <= 0 {
                try emit(heard, final: true, unit: index)
                stream += 1
                heard = []
                untilRollover = rng.int(in: 25...45)
            }

            // At each sentence end of plain reading the presenter should be
            // on the reading line, give or take a word.
            if unit.endsSentence, let scriptIndex = unit.scriptIndex,
               [.exact, .recognizerErrors, .partialRevisions, .repeatedPhrase].contains(scenario) {
                let lag = scriptIndex + 1 - aligner.position
                summary.largestLag = max(summary.largestLag, lag)
                if lag > fixture.lagTolerance {
                    throw Failure("\(fixture.name) \(scenario) seed \(seed): \(lag) tokens behind at the end of sentence \(unit.sentence ?? -1)")
                }
            }
        }
        if !heard.isEmpty { try emit(heard, final: true, unit: units.count - 1) }

        summary.finalPosition = aligner.position
        guard aligner.position >= tokens.count - fixture.endTolerance else {
            throw Failure("\(fixture.name) \(scenario) seed \(seed): ended at \(aligner.position) of \(tokens.count)")
        }
        if scenario == .rereadSentence, summary.movedBack == 0 {
            throw Failure("\(fixture.name) seed \(seed): never followed the presenter back to re-read")
        }
        return summary
    }

    private static func join(_ words: [String], _ language: ScriptLanguage) -> String {
        guard language == .chinese else { return words.joined(separator: " ") }
        var text = ""
        for word in words {
            let isLatin = word.unicodeScalars.allSatisfy { !SpeechText.isCJK($0) }
            text += isLatin ? " \(word) " : word
        }
        return text
    }
}

/// Small deterministic generator, so a failing case reproduces exactly.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }

    mutating func int(in range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }
}
