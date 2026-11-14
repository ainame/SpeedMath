import ElementaryRouter
import SessionLogic

extension Deck: RouteValue {
  public static var routeValueTypeName: String { "Deck" }
  public static func parseRouteValue(_ rawValue: String) -> Deck? { Deck(rawValue: rawValue) }
  public var routeValueString: String { rawValue }
}
