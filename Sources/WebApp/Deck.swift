import ElementaryRouter

/// One flash card: a single-digit addition or subtraction problem.
struct Card: Equatable {
  enum Operator: Equatable {
    case plus
    case minus

    var symbol: String {
      switch self {
      case .plus: "+"
      case .minus: "−"
      }
    }
  }

  let lhs: Int
  let op: Operator
  let rhs: Int

  var answer: Int {
    switch op {
    case .plus: lhs + rhs
    case .minus: lhs - rhs
    }
  }

  var question: String { "\(lhs) \(op.symbol) \(rhs)" }

  /// True when an operand or the answer is 0, e.g. `6 + 0` or `5 − 5`.
  var containsZero: Bool { lhs == 0 || rhs == 0 || answer == 0 }
}

/// The four standard 計算カード decks found in 算数セット (180 cards in total).
enum Deck: String, CaseIterable, RouteValue {
  /// あかカード: 1+0 … 9+1, sums up to 10 (54 cards).
  case additionNoCarry = "add"
  /// あおカード: 1−1 … 10−9, no borrowing (54 cards).
  case subtractionNoBorrow = "sub"
  /// きいろカード: 2+9 … 9+9, sums 11–18 (36 cards).
  case additionCarry = "add-carry"
  /// みどりカード: 11−2 … 18−9, with borrowing (36 cards).
  case subtractionBorrow = "sub-borrow"

  static var routeValueTypeName: String { "Deck" }
  static func parseRouteValue(_ rawValue: String) -> Deck? { Deck(rawValue: rawValue) }
  var routeValueString: String { rawValue }

  var title: String {
    switch self {
    case .additionNoCarry: "たしざん"
    case .subtractionNoBorrow: "ひきざん"
    case .additionCarry: "たしざん"
    case .subtractionBorrow: "ひきざん"
    }
  }

  var subtitle: String {
    switch self {
    case .additionNoCarry: "くりあがり なし"
    case .subtractionNoBorrow: "くりさがり なし"
    case .additionCarry: "くりあがり あり"
    case .subtractionBorrow: "くりさがり あり"
    }
  }

  var symbol: String {
    switch self {
    case .additionNoCarry, .additionCarry: "+"
    case .subtractionNoBorrow, .subtractionBorrow: "−"
    }
  }

  /// CSS class carrying the deck's card color.
  var colorClass: String {
    switch self {
    case .additionNoCarry: "deck-red"
    case .subtractionNoBorrow: "deck-blue"
    case .additionCarry: "deck-yellow"
    case .subtractionBorrow: "deck-green"
    }
  }

  /// The deck's cards; without zero problems the two no-carry decks drop from 54 to 45 cards.
  func cards(includeZero: Bool) -> [Card] {
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
  func draw(count: Int, includeZero: Bool) -> [Card] {
    var rng = BrowserRandom()
    let shuffled = cards(includeZero: includeZero).shuffled(using: &rng)
    guard count > 0, count < shuffled.count else { return shuffled }
    return Array(shuffled.prefix(count))
  }
}
