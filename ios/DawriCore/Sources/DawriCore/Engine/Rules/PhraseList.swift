/// A list of phrases indexed by first word, so a matcher looks up each token rather than walking
/// every phrase. It gives the answer a full scan gives: `matches` is sorted on phrase index and
/// then start, the order `for phrase in phrases: for start in phrase_starts(...)` visits them.
struct PhraseList: Sendable {
    struct Match: Sendable {
        let phrase: Int
        let start: Int
    }

    let phrases: [[Scalars]]
    private let byFirstWord: [Scalars: [Int]]

    init(_ phrases: [[Scalars]]) {
        self.phrases = phrases
        var index: [Scalars: [Int]] = [:]
        for (position, phrase) in phrases.enumerated() {
            if let first = phrase.first { index[first, default: []].append(position) }
        }
        byFirstWord = index
    }

    /// Every (phrase, start) pair of `phrase_starts`.
    func matches(in tokens: [Token]) -> [Match] {
        var found: [Match] = []
        for start in tokens.indices {
            collect(tokens[start].text, start, tokens, &found)
            for form in tokens[start].forms { collect(form, start, tokens, &found) }
        }
        found.sort { ($0.phrase, $0.start) < ($1.phrase, $1.start) }
        return found
    }

    private func collect(_ word: Scalars, _ start: Int, _ tokens: [Token], _ found: inout [Match]) {
        guard let candidates = byFirstWord[word] else { return }
        for phrase in candidates where TextRules.phraseFollows(phrases[phrase], at: start, in: tokens) {
            found.append(Match(phrase: phrase, start: start))
        }
    }

    /// `contains_any`.
    func contains(in tokens: [Token]) -> Bool {
        tokens.indices.contains { start in
            hit(tokens[start].text, start, tokens)
                || tokens[start].forms.contains { hit($0, start, tokens) }
        }
    }

    private func hit(_ word: Scalars, _ start: Int, _ tokens: [Token]) -> Bool {
        guard let candidates = byFirstWord[word] else { return false }
        return candidates.contains { TextRules.phraseFollows(phrases[$0], at: start, in: tokens) }
    }

    /// `_words_inside`: every token index inside a match of any phrase.
    func wordsInside(_ tokens: [Token]) -> Set<Int> {
        var words = Set<Int>()
        for match in matches(in: tokens) {
            words.formUnion(match.start..<(match.start + phrases[match.phrase].count))
        }
        return words
    }

    /// `_opens_on`: the words of a phrase are exactly the first words of the text.
    func opens(_ tokens: [Token]) -> Bool {
        phrases.contains { phrase in
            phrase.count <= tokens.count
                && zip(phrase, tokens).allSatisfy { word, token in word == token.text }
        }
    }
}
