/// One flash card: a single-digit addition or subtraction problem.
public struct Card: Equatable {
  public enum Operator: Equatable {
    case plus
    case minus

    public var symbol: String {
      switch self {
      case .plus: "+"
      case .minus: "−"
      }
    }
  }

  public let lhs: Int
  public let op: Operator
  public let rhs: Int

  public var answer: Int {
    switch op {
    case .plus: lhs + rhs
    case .minus: lhs - rhs
    }
  }

  public var question: String { "\(lhs) \(op.symbol) \(rhs)" }

  /// True when an operand or the answer is 0, e.g. `6 + 0` or `5 − 5`.
  public var containsZero: Bool { lhs == 0 || rhs == 0 || answer == 0 }
}

/// The four standard 計算カード decks found in 算数セット (180 cards in total).
public enum Deck: String, CaseIterable, Sendable {
  /// あかカード: 1+0 … 9+1, sums up to 10 (54 cards).
  case additionNoCarry = "add"
  /// あおカード: 1−1 … 10−9, no borrowing (54 cards).
  case subtractionNoBorrow = "sub"
  /// きいろカード: 2+9 … 9+9, sums 11–18 (36 cards).
  case additionCarry = "add-carry"
  /// みどりカード: 11−2 … 18−9, with borrowing (36 cards).
  case subtractionBorrow = "sub-borrow"

  public var title: String {
    switch self {
    case .additionNoCarry: "たしざん"
    case .subtractionNoBorrow: "ひきざん"
    case .additionCarry: "たしざん"
    case .subtractionBorrow: "ひきざん"
    }
  }

  public var subtitle: String {
    switch self {
    case .additionNoCarry: "くりあがり なし"
    case .subtractionNoBorrow: "くりさがり なし"
    case .additionCarry: "くりあがり あり"
    case .subtractionBorrow: "くりさがり あり"
    }
  }

  public var symbol: String {
    switch self {
    case .additionNoCarry, .additionCarry: "+"
    case .subtractionNoBorrow, .subtractionBorrow: "−"
    }
  }

  /// CSS class carrying the deck's card color.
  public var colorClass: String {
    switch self {
    case .additionNoCarry: "deck-red"
    case .subtractionNoBorrow: "deck-blue"
    case .additionCarry: "deck-yellow"
    case .subtractionBorrow: "deck-green"
    }
  }

  /// The deck's cards; without zero problems the two no-carry decks drop from 54 to 45 cards.
  public func cards(includeZero: Bool) -> [Card] {
    includeZero ? allCards : allCards.filter { !$0.containsZero }
  }

  private var allCards: [Card] {
    var cards: [Card] = []
    switch self {
    case .additionNoCarry:
      for lhs in 1...9 {
        for rhs in 0...(10 - lhs) {
          cards.append(Card(lhs: lhs, op: .plus, rhs: rhs))
        }
      }
    case .subtractionNoBorrow:
      for lhs in 1...10 {
        for rhs in 1...min(lhs, 9) {
          cards.append(Card(lhs: lhs, op: .minus, rhs: rhs))
        }
      }
    case .additionCarry:
      for lhs in 2...9 {
        for rhs in (11 - lhs)...9 {
          cards.append(Card(lhs: lhs, op: .plus, rhs: rhs))
        }
      }
    case .subtractionBorrow:
      for lhs in 11...18 {
        for rhs in (lhs - 9)...9 {
          cards.append(Card(lhs: lhs, op: .minus, rhs: rhs))
        }
      }
    }
    return cards
  }

  /// Draws `count` cards in shuffled order; `count <= 0` or more than the deck size means all.
  public func draw(count: Int, includeZero: Bool, using rng: inout some RandomNumberGenerator) -> [Card] {
    let shuffled = cards(includeZero: includeZero).shuffled(using: &rng)
    guard count > 0, count < shuffled.count else { return shuffled }
    return Array(shuffled.prefix(count))
  }
}
