import ElementaryRouter
import ElementaryUI
import ProtocolModels
import RemoteProtocol
import SessionLogic

/// Today's finished runs, newest first. The page is fixed like every other screen; only the list
/// scrolls.
@View
struct RecordsPage {
  @Environment(AppRoutes._routeSetEnvironmentKey) var routes
  @Environment(TodayRecords.self) var records: TodayRecords

  var body: some View {
    section(.class("records")) {
      h2(.class("records-title")) { "きょうの きろく" }
      div(.class("records-list")) {
        if records.records.isEmpty {
          p(.class("records-empty")) { "まだ きろくが ないよ。さいごまで やってみよう！" }
        } else {
          for record in records.records.reversed() {
            RecordRow(record: record)
          }
        }
      }
      p(.class("records-summary")) { summary }
      div(.class("back")) {
        if let routes {
          AppRoutes.Link(to: routes.home()) { "もどる" }
        }
      }
    }
    .onAppear { records.refresh() }
  }

  private var summary: String {
    let runs = records.records.count
    let cards = records.records.reduce(0) { $0 + $1.count }
    return runs == 0 ? "" : "\(runs)かい ・ ぜんぶで \(cards)まい"
  }
}

/// Material-style list item: a leading avatar with the operator, a headline with supporting text,
/// and the elapsed time as the trailing value.
@View
struct RecordRow {
  let record: PlayRecord

  var body: some View {
    div(.class("record-row \(record.deck.colorClass)")) {
      span(.class("record-avatar")) { record.deck.symbol }
      div(.class("record-text")) {
        p(.class("record-headline")) { "\(record.deck.title)（\(record.deck.subtitle)）" }
        p(.class("record-supporting")) {
          "\(record.count)まい ・ \(record.includeZero ? "0あり" : "0なし") ・ \(record.finishedAt)"
        }
      }
      ClockDisplay(milliseconds: Double(record.milliseconds))
    }
  }
}
