import SwiftUI

// 续期提醒：用户给账号填"每月几号续期"（默认不填），到期前两天起在面板和小组件上提醒，到期当天结束后自动轮到下个月。
// 只是按填的日期提醒，程序不知道实际有没有续费。

/// 提前几天开始提醒
let renewalNoticeDays = 2

/// 下一个续期日（今天算在内）。那个月没有这一天（比如 2 月填了 31 号）就按月底算
func nextRenewal(day: Int, from now: Date = Date(), calendar: Calendar = .current) -> Date? {
    guard (1...31).contains(day) else { return nil }
    let today = calendar.startOfDay(for: now)
    guard let thisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: today)) else { return nil }
    for offset in 0...1 {
        guard let month = calendar.date(byAdding: .month, value: offset, to: thisMonth),
              let length = calendar.range(of: .day, in: .month, for: month)?.count,
              let date = calendar.date(byAdding: .day, value: min(day, length) - 1, to: month) else { continue }
        if date >= today { return date }
    }
    return nil
}

/// 离下一个续期日还有几天（0 = 今天）
func renewalDaysLeft(day: Int, from now: Date = Date(), calendar: Calendar = .current) -> Int? {
    nextRenewal(day: day, from: now, calendar: calendar).flatMap {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: $0).day
    }
}

struct RenewalNotice: Equatable {
    let days: Int           // 0、1、2
    let date: Date
    var text: String { days == 0 ? "今天续期" : (days == 1 ? "明天续期" : "后天续期") }
}

/// 现在要不要提醒；不用提醒返回 nil
func renewalNotice(day: Int?, from now: Date = Date(), calendar: Calendar = .current) -> RenewalNotice? {
    guard let day, let date = nextRenewal(day: day, from: now, calendar: calendar),
          let left = renewalDaysLeft(day: day, from: now, calendar: calendar), left <= renewalNoticeDays else { return nil }
    return RenewalNotice(days: left, date: date)
}

/// "12 月 5 日"
func monthDayText(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "M 月 d 日"
    return f.string(from: d)
}

extension Model {
    func renewal(_ a: Account) -> RenewalNotice? { renewalNotice(day: a.renewalDay) }
}
