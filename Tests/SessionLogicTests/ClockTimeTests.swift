import SessionLogic
import Testing

@Suite struct ClockTimeTests {
  @Test func splitsIntoWholeMinutesAndSeconds() {
    #expect(ClockTime(milliseconds: 0) == ClockTime(minutes: 0, seconds: 0))
    #expect(ClockTime(milliseconds: 999) == ClockTime(minutes: 0, seconds: 0))
    #expect(ClockTime(milliseconds: 1000) == ClockTime(minutes: 0, seconds: 1))
    #expect(ClockTime(milliseconds: 59_999) == ClockTime(minutes: 0, seconds: 59))
    #expect(ClockTime(milliseconds: 60_000) == ClockTime(minutes: 1, seconds: 0))
    #expect(ClockTime(milliseconds: 125_400) == ClockTime(minutes: 2, seconds: 5))
  }

  @Test func clampsNegativeAndLongTimes() {
    #expect(ClockTime(milliseconds: -500) == ClockTime(minutes: 0, seconds: 0))
    #expect(ClockTime(milliseconds: 100 * 60_000) == ClockTime(minutes: 99, seconds: 59))
  }
}
