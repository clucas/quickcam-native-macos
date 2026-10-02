import AppKit
import SystemExtensions

private final class AppDelegate: NSObject, NSApplicationDelegate, OSSystemExtensionRequestDelegate {
    private var window: NSWindow!
    private let status = NSTextField(wrappingLabelWithString:
        "Install camera support to use the QuickCam Pro 4000 and Communicate STX in camera apps.")
    private var activeRequest: OSSystemExtensionRequest?
    private var extensionIdentifier: String {
        Bundle.main.object(forInfoDictionaryKey: "QuickCamExtensionIdentifier") as! String
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let appMenu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "Quit QuickCam Native", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        appMenu.addItem(applicationItem)
        NSApp.mainMenu = appMenu

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 280),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "QuickCam Native"
        let title = NSTextField(labelWithString: "Legacy QuickCam camera support")
        title.font = .boldSystemFont(ofSize: 20)
        status.maximumNumberOfLines = 0
        status.preferredMaxLayoutWidth = 500
        let install = NSButton(title: "Install Camera Support", target: self, action: #selector(activate))
        install.bezelStyle = .rounded
        let uninstall = NSButton(title: "Remove Camera Support", target: self, action: #selector(deactivate))
        uninstall.bezelStyle = .rounded
        if Bundle.main.object(forInfoDictionaryKey: "QuickCamHasSigningIdentity") as? Bool != true {
            install.isEnabled = false
            uninstall.isEnabled = false
            status.stringValue = "This development build needs an Apple signing identity and provisioning before macOS can install its camera extension."
        }
        let buttons = NSStackView(views: [install, uninstall])
        buttons.orientation = .horizontal
        let content = NSStackView(views: [title, status, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 22
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28),
            content.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28),
            content.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 28)
        ])
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--activate") { activate() }
        if CommandLine.arguments.contains("--deactivate") { deactivate() }
    }

    @objc private func activate() {
        guard activeRequest == nil else { return }
        guard Bundle.main.object(forInfoDictionaryKey: "QuickCamHasSigningIdentity") as? Bool == true else { return }
        guard Bundle.main.bundleURL.path.hasPrefix("/Applications/") else {
            status.stringValue = "Move QuickCam Native.app to /Applications before installing camera support."
            return
        }
        submit(OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: extensionIdentifier, queue: .main))
    }

    @objc private func deactivate() {
        guard activeRequest == nil else { return }
        submit(OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: extensionIdentifier, queue: .main))
    }

    private func submit(_ request: OSSystemExtensionRequest) {
        request.delegate = self
        activeRequest = request
        status.stringValue = "macOS is processing the camera extension request."
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        status.stringValue = "Approve QuickCam Native in System Settings → General → Login Items & Extensions → Camera Extensions, then return here."
    }

    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        activeRequest = nil
        switch result {
        case .completed:
            status.stringValue = "The request completed. Reopen your camera app to update its camera list."
        case .willCompleteAfterReboot:
            status.stringValue = "macOS will complete this request after the next restart."
        @unknown default:
            status.stringValue = "macOS returned an unrecognized result: \(result.rawValue)."
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        activeRequest = nil
        let details = error as NSError
        status.stringValue = "Camera support could not be installed: \(details.localizedDescription) (\(details.domain) \(details.code))."
        NSLog("QuickCam system-extension request failed: %@", details)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

private let delegate = AppDelegate()
NSApplication.shared.setActivationPolicy(.regular)
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
