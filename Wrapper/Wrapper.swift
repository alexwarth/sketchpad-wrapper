import SwiftUI
import WebKit

// Put your mDNS, IP address, or web URL here.
// (Note: You can use a local web server with a self-signed cert, and https as the protocol, to (eg) get more accuracy from performance.now())
let url = URL(string: "https://alexwarth.github.io/projects/sutherland/?tablet=true")!
//let url = URL(string: "http://awarth.local:5173/?tablet=true")!

@main
struct WrapperApp: App {
    var body: some Scene {
        WindowGroup {
            AppView()
        }
    }
}

struct AppView: View {
    @State private var error: Error?
    @State private var loading = true
    
    var body: some View {
        VStack {
            if let error = error {
                // In the event of an error, show the error message and a handy quit button (so you don't have to force-quit)
                Text(error.localizedDescription)
                    .foregroundColor(.pink)
                    .font(.headline)
                Button("Quit") { exit(EXIT_FAILURE) }
                    .buttonStyle(.bordered)
                    .foregroundColor(.primary)
            } else {
                // Load the WebView, and show a spinner while it's loading
                ZStack {
                    WrapperWebView(error: $error, loading: $loading)
                        .opacity(loading ? 0 : 1) // The WebView is opaque white while loading, which sucks in dark mode
                    if loading {
                        VStack(spacing: 20) {
                            Text("Attempting to load \(url)")
                                .foregroundColor(.gray)
                                .font(.headline)
                            ProgressView()
                        }
                    }
                }
            }
        }
        .ignoresSafeArea() // Allow views to stretch right to the edges
        .statusBarHidden() // Hide the status bar at the top
        .persistentSystemOverlays(.hidden) // Hide the home indicator at the bottom
        .defersSystemGestures(on:.all) // Block the first swipe from the top (todo: doesn't seem to block the bottom)
        // We also have fullScreenRequired set in the Project settings, so we're opted-out from multitasking
    }
}

// This struct wraps WKWebView so that we can use it in SwiftUI.
// Hopefully it won't be long before this can all be removed.
struct WrapperWebView: UIViewRepresentable {
    @Binding var error: Error?
    @Binding var loading: Bool
    
    // This coordinator is created first, right at the beginning of setting up our view.
    // A "coordinator" is a delegate that handles a bunch of UIKit events and other stuff on behalf of the WKWebView instance.
    // This delegate pattern is just how UIKit classes are made extensible.
    // We give it a reference to this struct so that it can communicate with SwiftUI (eg: by changing the $error and $loading bindings).
    func makeCoordinator() -> WebViewCoordinator { WebViewCoordinator(self) }
    
    // Next, we need to initialize the UIKit view that'll be added to SwiftUI (a WKWebView, in our case).
    func makeUIView(context: Context) -> WKWebView {
        // It's idiomatic that the coordinator do all the fanciness on behalf of the UIKit, and this UIViewRepresentable struct just manage lifecycle.
        // So, for conveinence, we have the coordinator create the webView instance and do a bunch of configuration before giving it back to us.
        let webView = context.coordinator.setupWebView();

        // Never use the cache
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData))
        
        return webView
    }
    
    // Required by UIViewRepresentable
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

class WebViewCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let parent: WrapperWebView
    var webView: WKWebView?
    var feedback: UICanvasFeedbackGenerator? // for haptic feedback
    var touchRecognizer: TouchesToJS?
    var triedOffline = false

    init(_ webView: WrapperWebView) { self.parent = webView }
    
    func setupWebView() -> WKWebView {
        // Content controller for sending messages from JS to the Wrapper
        let contentController = WKUserContentController()
        messageNames.forEach { contentController.add(self, name: $0) }
        
        // Content controllers must be added to a Configuration instance.
        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        
        // Initialize our WKWebView instance, into which we'll load the JS app from the user-selected server
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isInspectable = true
        
        // The coordinator is the view's delegate, handling various events associated with the view (because that's idiomatic).
        webView.navigationDelegate = self
        
        self.webView = webView

        // For haptic feedback
        self.feedback = UICanvasFeedbackGenerator(view: webView)

        // For forwarding touch data to the webapp
        self.touchRecognizer = TouchesToJS(webView)
        webView.addGestureRecognizer(touchRecognizer!)
        
        return webView
    }

    // This will travel all the way up to SwiftUI and unhide the webview.
    func webView(_ wv: WKWebView, didFinish nav: WKNavigation) { parent.loading = false; }

    // If loading fails, return to the Select A Server view and show an error message
    func webView(_ wv: WKWebView, didFail nav: WKNavigation, withError error: Error) { parent.error = error }
    func webView(_ wv: WKWebView, didFailProvisionalNavigation nav: WKNavigation, withError error: Error) { parent.error = error }

    // This makes the webview ignore certificate errors, so you can use a self-signed cert for https, so that the browser context is trusted, which enables additional APIs
    func webView(_ wv: WKWebView, respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        (.useCredential, URLCredential(trust: challenge.protectionSpace.serverTrust!))
    }
    
    // These are all the messages we handle, listed here so we can add handlers for them in a loop
    let messageNames = [
        "prepareHaptics",
        "hapticImpact",
    ]
    
    // This allows the Sketchpad webapp to send messages to the Wrapper.
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        print(message.name)
        
        if let feedback, message.name == "prepareHaptics" {
            feedback.prepare()
        }
        
        if let feedback, message.name == "hapticImpact" {
            print("wham!")
            feedback.pathCompleted(at: .zero)
        }
    }
}


// This class captures all the touch events triggered on a given WKWebView, and re-triggeres them inside the JS context.
// This allows JS to receive pencil and touch simultaneously.
class TouchesToJS: UIGestureRecognizer {
    let webView: WKWebView
    
    init(_ webView: WKWebView) {
        self.webView = webView
        super.init(target:nil, action:nil)
        requiresExclusiveTouchType = false // Allow simultaneous pen and touch events
    }
    
    typealias TouchJSON = [String: AnyHashable]
    
    private func makeTouchJSON(id: Int, phase: String, touch: UITouch) -> TouchJSON {
        let location = touch.preciseLocation(in: view)
        return [
            "id": id,
            "type": touch.type == .pencil ? "pencil" : "finger",
            "phase": phase,
            "position": [
                "x": location.x,
                "y": location.y,
            ],
            "pressure": touch.force,
            "altitude": touch.altitudeAngle,
            "azimuth": touch.azimuthAngle(in: view),
            "rollAngle": touch.rollAngle,
            "radius": touch.majorRadius,
            "timestamp": touch.timestamp
        ]
    }
    
    func sendTouches(_ phase: String, _ touches: Set<UITouch>, _ event: UIEvent) {
        for touch in touches {
            let id = touch.hashValue // These ids *should be* stable until the touch ends (ie: finger or pencil is lifted)
            let jsonArr = event.coalescedTouches(for: touch)!.map({ makeTouchJSON(id: id, phase: phase, touch: $0) })
            if let json = try? JSONSerialization.data(withJSONObject: jsonArr),
               let jsonString = String(data: json, encoding: .utf8) {
                webView.evaluateJavaScript("if ('wrapperEvents' in window) wrapperEvents(\(jsonString))")
            }
        }
    }
    
    override func touchesBegan    (_ touches: Set<UITouch>, with event: UIEvent) { sendTouches("began", touches, event) }
    override func touchesMoved    (_ touches: Set<UITouch>, with event: UIEvent) { sendTouches("moved", touches, event) }
    override func touchesEnded    (_ touches: Set<UITouch>, with event: UIEvent) { sendTouches("ended", touches, event) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { sendTouches("ended", touches, event) } // "ended" because we don't differentiate between ended and cancelled in the web app
}
