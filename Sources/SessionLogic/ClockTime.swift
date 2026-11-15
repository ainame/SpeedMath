/// Elapsed time as whole minutes and seconds, shown as 「x ふん y びょう」.
public struct ClockTime: Equatable, Sendable {
  public let minutes: Int
  public let seconds: Int

  /// The longest time shown: 99 ふん 59 びょう.
  public static let maxMilliseconds = (99 * 60 + 59) * 1000

  public init(minutes: Int, seconds: Int) {
    self.minutes = minutes
    self.seconds = seconds
  }

  /// Rounds down to the whole second, so a running clock ticks over exactly on each second.
  public init(milliseconds: Double) {
    let clamped = min(max(0, milliseconds), Double(Self.maxMilliseconds))
    let total = Int(clamped) / 1000
    minutes = total / 60
    seconds = total % 60
  }
}
