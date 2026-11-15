import SessionLogic
import Testing

private struct Seeded: RandomNumberGenerator {
  var state: UInt64 = 42
  mutating func next() -> UInt64 {
    state = state &* 6_364_136_223_846_793_005 &+ 1
    return state
  }
}

@Test(arguments: Deck.allCases)
func deckRangeAndDrawOrder(deck: Deck) {
  let all = deck.cards(includeZero: true)
  let without = deck.cards(includeZero: false)
  #expect(all.count == (deck == .additionNoCarry || deck == .subtractionNoBorrow ? 54 : 36))
  #expect(without.count == (all.count == 54 ? 45 : 36))
  #expect(Set(all.map(\.question)).count == all.count)
  #expect(without == all.filter { !$0.containsZero })
  for card in all {
    switch deck {
    case .additionNoCarry:
      #expect(card.op == .plus && (1...9).contains(card.lhs) && (0...9).contains(card.rhs) && card.answer <= 10)
    case .subtractionNoBorrow:
      #expect(card.op == .minus && (1...10).contains(card.lhs) && (1...9).contains(card.rhs) && card.answer >= 0)
    case .additionCarry:
      #expect(
        card.op == .plus && (2...9).contains(card.lhs) && (2...9).contains(card.rhs) && (11...18).contains(card.answer))
    case .subtractionBorrow:
      #expect(
        card.op == .minus && (11...18).contains(card.lhs) && (2...9).contains(card.rhs) && (2...9).contains(card.answer)
      )
    }
  }
  var full = Seeded()
  var subset = Seeded()
  let shuffled = deck.draw(count: 0, includeZero: false, using: &full)
  #expect(shuffled != without)
  #expect(Set(shuffled.map(\.question)) == Set(without.map(\.question)))
  #expect(deck.draw(count: 5, includeZero: false, using: &subset) == Array(shuffled.prefix(5)))
}
