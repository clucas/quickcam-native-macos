import CoreMediaIO
import Foundation

let source = QuickCamProvider()
CMIOExtensionProvider.startService(provider: source.provider)
CFRunLoopRun()
