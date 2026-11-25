import Foundation
import SwitchGPTAppCore
import SwitchGPTDesktopIntegration

enum RealSwitchWorkflowError: Error, LocalizedError {
  case targetUnavailable
  case quotaRefreshFailed

  var errorDescription: String? {
    switch self {
    case .targetUnavailable:
      return L10n.string("The selected account is no longer configured.")
    case .quotaRefreshFailed:
      return L10n.string("The selected account could not be refreshed before switching.")
    }
  }
}

@MainActor
enum RealSwitchWorkflow {
  static func prepare(targetID: AccountID, store: SwitchGPTAppStore) async throws
    -> RealSwitchPlan
  {
    guard await store.refreshAccount(targetID, recoveringExpiredSwitchTarget: true) else {
      throw RealSwitchWorkflowError.quotaRefreshFailed
    }
    guard let target = store.accounts.first(where: { $0.id == targetID }) else {
      throw RealSwitchWorkflowError.targetUnavailable
    }
    let accounts = store.accounts
    return try await Task.detached(priority: .userInitiated) {
      try ExperimentalRealSwitchCoordinator.preflight(
        target: target,
        accounts: accounts
      )
    }.value
  }

  static func run(_ plan: RealSwitchPlan, store: SwitchGPTAppStore) async {
    guard store.beginRealSwitch(to: plan.targetAccount.id) else { return }
    ExperimentalRealSwitchCoordinator.projectStateMonitor.pauseAndWait()
    defer { ExperimentalRealSwitchCoordinator.projectStateMonitor.resume() }
    let accounts = store.accounts
    do {
      let result = try await Task.detached(priority: .userInitiated) {
        try ExperimentalRealSwitchCoordinator.perform(plan, accounts: accounts)
      }.value
      switch result.receipt.outcome {
      case .committed:
        store.completeRealSwitch(
          to: plan.targetAccount.id,
          receiptRecorded: result.receiptRecorded
        )
        await store.refresh()
        store.completeRealSwitch(
          to: plan.targetAccount.id,
          receiptRecorded: result.receiptRecorded
        )
      case .rolledBack, .manualRecoveryRequired:
        store.failRealSwitch(
          message: failureMessage(result.receipt)
            + receiptSuffix(recorded: result.receiptRecorded)
        )
      }
    } catch {
      store.failRealSwitch(message: userMessage(for: error))
    }
  }

  static func userMessage(for error: Error) -> String {
    if let error = error as? LocalProjectStateSynchronizationError {
      if error == .unsupportedProjectLayout {
        return L10n.string("SwitchGPT could not verify the local project layout. The switch was blocked before quitting ChatGPT.")
      }
      return L10n.string("Local project synchronization or verification failed. The account switch was blocked.")
    }
    if let error = error as? ExperimentalRealSwitchError,
      let message = error.errorDescription
    {
      return message
    }
    if let error = error as? RealSwitchWorkflowError,
      let message = error.errorDescription
    {
      return message
    }
    return L10n.string("The experimental switch was blocked by a safety check; ChatGPT was not changed.")
  }

  private static func failureMessage(_ receipt: RealSwitchReceipt) -> String {
    let switchMessage = switch (receipt.failureReason, receipt.targetFailurePhase) {
    case (.targetApplicationChanged, _):
      L10n.string("ChatGPT changed during the switch. Review and confirm the switch again.")
    case (_, .stoppingForTarget):
      L10n.string("The switch stopped while waiting for ChatGPT to quit.")
    case (_, .installingTarget):
      L10n.string("The switch stopped while preparing the target account.")
    case (_, .startingTarget):
      L10n.string("The switch stopped while starting ChatGPT for the target account.")
    case (_, .verifyingTarget):
      L10n.string("The switch stopped while verifying the target account.")
    case (_, .committed):
      L10n.string("The switch stopped while saving its result.")
    default:
      L10n.string("The account switch stopped.")
    }

    if receipt.outcome == .rolledBack {
      return switchMessage + L10n.string(" The original account was restored.")
    }
    if receipt.failureReason == .recoveryLaunchBudgetExhausted, receipt.rollbackLaunchAttempts == 1 {
      return switchMessage + " "
        + L10n.string("Automatic recovery stopped after its single launch budget. Manual recovery is required.")
    }

    let recoveryMessage = switch receipt.recoveryFailurePhase {
    case .rollbackStopping:
      L10n.string(" Recovery stopped while waiting for ChatGPT to quit.")
    case .rollbackRestoring:
      L10n.string(" Recovery stopped while restoring the original account.")
    case .rollbackStarting:
      L10n.string(" Recovery stopped while reopening ChatGPT.")
    case .rollbackVerifying:
      L10n.string(" Recovery stopped while verifying the original account.")
    case .rolledBack:
      L10n.string(" Recovery stopped while saving its result.")
    default:
      ""
    }
    return switchMessage + recoveryMessage + L10n.string(" Manual recovery is required.")
  }

  private static func receiptSuffix(recorded: Bool) -> String {
    recorded
      ? L10n.string(" A private metadata-only verification receipt was saved.")
      : L10n.string(" The local verification receipt could not be saved.")
  }
}
