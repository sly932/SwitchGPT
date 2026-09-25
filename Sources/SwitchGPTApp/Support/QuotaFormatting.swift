import SwitchGPTAppCore

func quotaSummaryText(for account: AccountRecord) -> String {
  var values = [L10n.string("W ") + String(account.usage.weekly.remainingPercent) + "%"]
  if let fiveHour = account.usage.fiveHour {
    values.append(L10n.string("5h ") + String(fiveHour.remainingPercent) + "%")
  }
  return values.joined(separator: " │ ")
}
