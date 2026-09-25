import Foundation

public enum CodexTokenActivityDecoder {
  public static func decode(from data: Data) throws -> AccountTokenActivity {
    let response = try JSONDecoder().decode(Response.self, from: data)
    let summary = response.summary
    return AccountTokenActivity(
      lifetimeTokens: summary?.lifetimeTokens,
      peakDailyTokens: summary?.peakDailyTokens,
      longestRunningTurnSec: summary?.longestRunningTurnSec,
      currentStreakDays: summary?.currentStreakDays,
      longestStreakDays: summary?.longestStreakDays,
      dailyUsageBuckets: response.dailyUsageBuckets?.map {
        AccountTokenActivity.DailyBucket(startDate: $0.startDate, tokens: $0.tokens)
      }
    )
  }

  private struct Response: Decodable {
    let summary: Summary?
    let dailyUsageBuckets: [DailyBucket]?
  }

  private struct Summary: Decodable {
    let lifetimeTokens: Int?
    let peakDailyTokens: Int?
    let longestRunningTurnSec: Int?
    let currentStreakDays: Int?
    let longestStreakDays: Int?
  }

  private struct DailyBucket: Decodable {
    let startDate: String
    let tokens: Int
  }
}
