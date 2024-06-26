/*
MIT License

Copyright 2023 - Present, Shopify Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
*/

import UIKit
import WebKit

protocol CheckoutWebViewDelegate: AnyObject {
	func checkoutViewDidStartNavigation()
	func checkoutViewDidCompleteCheckout(event: CheckoutCompletedEvent)
	func checkoutViewDidFinishNavigation()
	func checkoutViewDidClickLink(url: URL)
	func checkoutViewDidFailWithError(error: CheckoutError)
	func checkoutViewDidToggleModal(modalVisible: Bool)
	func checkoutViewDidEmitWebPixelEvent(event: PixelEvent)
}

class CheckoutWebView: WKWebView {
	private static var cache: CacheEntry?

	static var preloadingActivatedByClient: Bool = false

	/// A reference to the view is needed when preload is deactivated in order to detatch the bridge
	static weak var uncacheableViewRef: CheckoutWebView?

	var isBridgeAttached = false
    
    let fadeLock = NSLock()

	static func `for`(checkout url: URL) -> CheckoutWebView {
		let cacheKey = url.absoluteString

		guard ShopifyCheckoutSheetKit.configuration.preloading.enabled else {
			return uncacheableView()
		}

		guard let cache = cache, cacheKey == cache.key, !cache.isStale else {
			let view = CheckoutWebView()
			CheckoutWebView.cache = CacheEntry(key: cacheKey, view: view)
			return view
		}

		return cache.view
	}

	static func uncacheableView() -> CheckoutWebView {
		uncacheableViewRef?.detachBridge()
		let view = CheckoutWebView()
		uncacheableViewRef = view
		return view
	}

	static func invalidate() {
		preloadingActivatedByClient = false
		cache?.view.detachBridge()
		cache = nil
	}

	// MARK: Properties

	weak var viewDelegate: CheckoutWebViewDelegate?
	var presentedEventDidDispatch = false
	var checkoutDidPresent: Bool = false {
		didSet {
			dispatchPresentedMessage(checkoutDidLoad, checkoutDidPresent)
		}
	}
	var checkoutDidLoad: Bool = false {
		didSet {
			dispatchPresentedMessage(checkoutDidLoad, checkoutDidPresent)
		}
	}

	// MARK: Initializers

	override init(frame: CGRect, configuration: WKWebViewConfiguration) {
		configuration.applicationNameForUserAgent = CheckoutBridge.applicationName

		super.init(frame: frame, configuration: configuration)

		#if DEBUG
			if #available(iOS 16.4, *) {
				isInspectable = true
			}
		#endif

		navigationDelegate = self

		configuration.userContentController
			.add(MessageHandler(delegate: self), name: CheckoutBridge.messageHandler)
		isBridgeAttached = true

		isOpaque = false
		backgroundColor = ShopifyCheckoutSheetKit.configuration.backgroundColor

		if #available(iOS 15.0, *) {
			underPageBackgroundColor = ShopifyCheckoutSheetKit.configuration.backgroundColor
		}
	}

	deinit {
		detachBridge()
	}

	public func detachBridge() {
		configuration.userContentController
			.removeScriptMessageHandler(forName: CheckoutBridge.messageHandler)
		isBridgeAttached = false
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	// MARK: -

	func load(checkout url: URL, isPreload: Bool = false) {
		var request = URLRequest(url: url)
		if isPreload {
			request.setValue("prefetch", forHTTPHeaderField: "Sec-Purpose")
		}
		load(request)
	}

	private func dispatchPresentedMessage(_ checkoutDidLoad: Bool, _ checkoutDidPresent: Bool) {
		if checkoutDidLoad && checkoutDidPresent {
			CheckoutBridge.sendMessage(self, messageName: "presented", messageBody: nil)
			presentedEventDidDispatch = true
		}
	}
}

extension CheckoutWebView: WKScriptMessageHandler {
	func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
		do {
			switch try CheckoutBridge.decode(message) {
			case let .checkoutComplete(checkoutCompletedEvent):
				CheckoutWebView.cache = nil
				viewDelegate?.checkoutViewDidCompleteCheckout(event: checkoutCompletedEvent)
			case .checkoutUnavailable:
				CheckoutWebView.cache = nil
				viewDelegate?.checkoutViewDidFailWithError(error: .checkoutUnavailable(message: "Checkout unavailable."))
			case let .checkoutModalToggled(modalVisible):
				viewDelegate?.checkoutViewDidToggleModal(modalVisible: modalVisible)
			case let .webPixels(event):
				if let nonOptionalEvent = event {
					viewDelegate?.checkoutViewDidEmitWebPixelEvent(event: nonOptionalEvent)
				}
			default:
				()
			}
		} catch {
            viewDelegate?.checkoutViewDidFailWithError(error: .sdkError(underlying: error))
		}
	}
}

private var timer: Date?
import os.log
extension CheckoutWebView: WKNavigationDelegate {
	func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {

		guard let url = action.request.url else {
			decisionHandler(.allow)
			return
		}

		if isExternalLink(action) || isMailOrTelLink(url) {
			viewDelegate?.checkoutViewDidClickLink(url: removeExternalParam(url))
			decisionHandler(.cancel)
			return
		}

		decisionHandler(.allow)
	}

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let response = navigationResponse.response as? HTTPURLResponse {
            decisionHandler(handleResponse(response))
            return
        }
        decisionHandler(.allow)
    }

    func handleResponse(_ response: HTTPURLResponse) -> WKNavigationResponsePolicy {
		if isCheckout(url: response.url) && response.statusCode >= 400 {
			CheckoutWebView.cache = nil
			switch response.statusCode {
			case 410:
				viewDelegate?.checkoutViewDidFailWithError(error: .checkoutExpired(message: "Checkout has expired"))
			case 404:
				viewDelegate?.checkoutViewDidFailWithError(error: .checkoutLiquidNotMigrated(message: "The checkout url provided has resulted in an error. The store is still using checkout.liquid, whereas the checkout SDK only supports checkout with extensibility."))
			case 500:
				viewDelegate?.checkoutViewDidFailWithError(error: .checkoutUnavailable(message: "Checkout unavailable due to error"))
			default:
				()
			}

			return .cancel
		}

		return .allow
	}

	func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
		timer = Date()
		viewDelegate?.checkoutViewDidStartNavigation()
	}

	func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
		timer = nil
	}
    
//    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
//        fadeCheckoutView(alpha: 0)
//    }

	func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
		viewDelegate?.checkoutViewDidFinishNavigation()

		if let startTime = timer {
			let endTime = Date()
			let diff = endTime.timeIntervalSince(startTime)
			let preloading = String(ShopifyCheckoutSheetKit.Configuration().preloading.enabled)
			let message = "Preloaded checkout in \(String(format: "%.2f", diff))s"
			ShopifyCheckoutSheetKit.configuration.logger.log(message)
			CheckoutBridge.instrument(self, InstrumentationPayload(name: "checkout_finished_loading", value: Int(diff * 1000), type: .histogram, tags: ["preloading": preloading]))
		}
		checkoutDidLoad = true
		timer = nil
        
        applyStylingAndFadeIn()
	}
    
    func applyStylingAndFadeIn() {
        
        // Prepare CSS to inject
        let cssString = checkoutStyling.build().css
        let escapedCSSString = cssString
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\'", with: "\\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")

        // JavaScript to inject CSS
        let jsToInject = """
            document.querySelectorAll('button').forEach(function(button) {
              if (button.textContent.trim().toLowerCase() === 'pay now'.toLowerCase()) {
                button.classList.add('pay-now-button');
              }
            });
            
            
            var style = document.createElement('style');
            style.type = 'text/css';
            style.innerHTML = '\(escapedCSSString)';
            document.head.appendChild(style);
            console.log('CSS Injected Successfully.');
            """

        // Evaluate JavaScript in the current web view context
        self.evaluateJavaScript(jsToInject) { [weak self] result, error in
            guard let self = self else { return }
            if let error = error {
                if #available(iOS 14.0, *) {
                    os_log(.fault, "Error injecting CSS: \(String(describing: error))")
                }
                self.fadeCheckoutView()
                return
            }

            // Fade in the web view only after CSS has been applied
            // wait 0.3 seconds before fading in the web view
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.fadeCheckoutView()
            }
        }
    }
    func fadeCheckoutView(alpha: Double = 1.0) {
        fadeLock.lock()
        DispatchQueue.main.async {
            if #available(iOS 14.0, *) {
                os_log(.debug, "Fading checkout view to alpha \(String(format: "%f", alpha))")
            }
            UIView.animate(withDuration: 0.3, animations: {
                self.alpha = alpha
            }, completion: { _ in
                self.fadeLock.unlock()
            })
        }
        
    }
    
	func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
		timer = nil
		CheckoutWebView.cache = nil
		viewDelegate?.checkoutViewDidFailWithError(error: .sdkError(underlying: error))
	}

	private func isExternalLink(_ action: WKNavigationAction) -> Bool {
		if action.navigationType == .linkActivated && action.targetFrame == nil { return true }

		guard let url = action.request.url else { return false }
		guard let url = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }

		guard let openExternally = url.queryItems?.first(where: { $0.name == "open_externally" })?.value else { return false }

		return openExternally.lowercased() == "true" || openExternally == "1"
	}

	private func removeExternalParam(_ url: URL) -> URL {
		guard var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
			return url
		}
		urlComponents.queryItems = urlComponents.queryItems?.filter { !($0.name == "open_externally") }
		return urlComponents.url ?? url
    }

	private func isMailOrTelLink(_ url: URL) -> Bool {
		return ["mailto", "tel"].contains(url.scheme)
	}

	private func isCheckout(url: URL?) -> Bool {
		return self.url == url
	}

}

extension CheckoutWebView {
	fileprivate struct CacheEntry {
		let key: String

		let view: CheckoutWebView

		private let timestamp = Date()

		private let timeout = TimeInterval(60 * 5)

		var isStale: Bool {
			abs(timestamp.timeIntervalSinceNow) >= timeout
		}
	}
}
