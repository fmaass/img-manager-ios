import SafariServices
import UIKit

/// The browser view as the sign-in needs it: something that can be put on screen, taken down,
/// and asked whether it actually made it.
///
/// A protocol so the interleaving bugs a real browser session can produce — a view closing
/// after its attempt was already cancelled, a second tap arriving mid-flight — are a few
/// deterministic test lines behind this seam instead of undriveable through a live
/// `SFSafariViewController`. Ported from memos-ng-ios's `MemosFeatures/LoginBrowser.swift`.
@MainActor
protocol LoginBrowser: AnyObject {
  /// Called when the PERSON closed the view. Never called for a dismissal the app asked for
  /// (`SignInCoordinator` clears this before it calls `dismiss()`).
  var onClose: (() -> Void)? { get set }

  func present(from host: UIViewController)
  func dismiss()
  var isOnScreen: Bool { get }
}

/// The real one: `SFSafariViewController`, which runs out of process — the app cannot read the
/// page it shows or reach into its fields, and it reuses the household sign-on's existing
/// cookies instead of asking for the password again.
///
/// This is memos-ng-ios's own choice, made and documented after `ASWebAuthenticationSession`
/// presented nothing at all on one household phone — no sheet, no error, `start()` returning
/// true, every piece of instrumentation agreeing a sign-in had begun — because that phone holds
/// no domain association for the server's host and the session reports that refusal with the
/// same code it uses for the person closing the sheet
/// (memos-ng-ios `SafariLoginPresenter.swift`, `NativeLoginSession.swift`). This app's Adjudication
/// A deployment has the identical property — internal-only DNS, no public AASA — so the same
/// failure mode applies here and `SFSafariViewController` is used from the start rather than
/// discovered the hard way twice.
@MainActor
final class SafariLoginBrowser: NSObject, LoginBrowser, SFSafariViewControllerDelegate {
  var onClose: (() -> Void)?

  /// Held strongly: a local would belong to a scope that ends the moment this function
  /// returns, and a deallocated view controller presents nothing while reporting nothing.
  private let controller: SFSafariViewController

  init(url: URL) {
    controller = SFSafariViewController(url: url)
    super.init()
    controller.delegate = self
    controller.dismissButtonStyle = .cancel
  }

  func present(from host: UIViewController) {
    host.present(controller, animated: true)
  }

  func dismiss() {
    controller.presentingViewController?.dismiss(animated: true)
  }

  var isOnScreen: Bool { controller.viewIfLoaded?.window != nil }

  nonisolated func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
    MainActor.assumeIsolated { onClose?() }
  }
}
