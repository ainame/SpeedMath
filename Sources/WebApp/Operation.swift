import ElementaryRouter

/// The four arithmetic operations a drill can practice.
enum Operation: String, CaseIterable, RouteValue {
  case addition
  case subtraction
  case multiplication
  case division

  static var routeValueTypeName: String { "Operation" }

  static func parseRouteValue(_ rawValue: String) -> Operation? {
    Operation(rawValue: rawValue)
  }

  var routeValueString: String { rawValue }

  var title: String {
    switch self {
    case .addition: "たしざん"
    case .subtraction: "ひきざん"
    case .multiplication: "かけざん"
    case .division: "わりざん"
    }
  }

  var symbol: String {
    switch self {
    case .addition: "+"
    case .subtraction: "−"
    case .multiplication: "×"
    case .division: "÷"
    }
  }
}
