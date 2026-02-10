import Cocoa
import UserNotifications
import ServiceManagement

// MARK: - Debug Logging
#if DEBUG
func debugLog(_ message: String) {
    print("[OpenClawWatcher] \(message)")
}
#else
func debugLog(_ message: String) {}
#endif

// MARK: - Model Info Structure
struct ModelInfo {
    let id: String
    let name: String
    let provider: String

    var fullId: String {
        return "\(provider)/\(id)"
    }
}

@main
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
    var statusItem: NSStatusItem!
    var timer: Timer?
    var lastStatus: Bool = false
    var isFirstCheck = true

    // Custom LM Studio base URL
    let lmStudioBaseUrl = "192.168.50.10:1234"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request notification permissions
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            debugLog("Notifications \(granted ? "enabled" : "denied")")
        }

        // Create menu bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        updateStatusIcon(running: false)
        setupMenu()

        // Check status every 5 seconds
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.checkStatus()
        }
        checkStatus()
    }

    deinit {
        timer?.invalidate()
        timer = nil
    }

    func setupMenu() {
        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "OpenClaw Monitor", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        let statusItem = NSMenuItem(title: "Status: Checking...", action: nil, keyEquivalent: "")
        statusItem.tag = 100
        menu.addItem(statusItem)

        menu.addItem(NSMenuItem.separator())

        let startItem = NSMenuItem(title: "Start Gateway", action: #selector(startGateway), keyEquivalent: "s")
        startItem.target = self
        menu.addItem(startItem)

        let stopItem = NSMenuItem(title: "Stop Gateway", action: #selector(stopGateway), keyEquivalent: "x")
        stopItem.target = self
        menu.addItem(stopItem)

        let restartItem = NSMenuItem(title: "Restart Gateway", action: #selector(restartGateway), keyEquivalent: "r")
        restartItem.target = self
        menu.addItem(restartItem)

        let killItem = NSMenuItem(title: "Kill All OpenClaw", action: #selector(killAllOpenClaw), keyEquivalent: "k")
        killItem.target = self
        menu.addItem(killItem)

        menu.addItem(NSMenuItem.separator())

        let dashboardItem = NSMenuItem(title: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: "d")
        dashboardItem.target = self
        menu.addItem(dashboardItem)

        let gatewayItem = NSMenuItem(title: "Open Gateway (no auth)", action: #selector(openGateway), keyEquivalent: "g")
        gatewayItem.target = self
        menu.addItem(gatewayItem)

        let logsItem = NSMenuItem(title: "View Logs", action: #selector(viewLogs), keyEquivalent: "l")
        logsItem.target = self
        menu.addItem(logsItem)

        menu.addItem(NSMenuItem.separator())

        // Model selection submenu
        let modelSubmenu = NSMenu()
        let modelItem = NSMenuItem(title: "Model: Loading...", action: nil, keyEquivalent: "")
        modelItem.tag = 300
        modelItem.submenu = modelSubmenu
        menu.addItem(modelItem)

        menu.addItem(NSMenuItem.separator())

        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.target = self
        launchItem.tag = 200
        launchItem.state = isLaunchAtLoginEnabled() ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        self.statusItem.menu = menu

        // Populate model menu after setup
        updateModelMenu()
    }

    func updateStatusIcon(running: Bool) {
        DispatchQueue.main.async {
            if running {
                self.statusItem.button?.title = "🦞"
            } else {
                self.statusItem.button?.title = "💀"
            }

            // Update status menu item
            if let menu = self.statusItem.menu,
               let item = menu.item(withTag: 100) {
                item.title = running ? "Status: Running" : "Status: Stopped"
            }
        }
    }

    func checkStatus() {
        DispatchQueue.global(qos: .background).async { [weak self] in
            let running = self?.isOpenClawRunning() ?? false

            DispatchQueue.main.async {
                self?.updateStatusIcon(running: running)

                // Send notification on status change (skip first check)
                if let self = self, !self.isFirstCheck && running != self.lastStatus {
                    self.sendNotification(running: running)
                }
                self?.lastStatus = running
                self?.isFirstCheck = false
            }
        }
    }

    // MARK: - Process Management (Safe: no shell interpretation needed)

    func isOpenClawRunning() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", "openclaw-gateway"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            debugLog("Error checking status: \(error.localizedDescription)")
            return false
        }
    }

    func sendNotification(running: Bool) {
        let content = UNMutableNotificationContent()
        content.title = "OpenClaw"
        content.body = running ? "Gateway is now running" : "Gateway has stopped"
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    @objc func startGateway() {
        // Source ~/.zshrc to get env vars (API keys), then start gateway
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-c", "source ~/.zshrc && nohup /opt/homebrew/bin/openclaw gateway > /tmp/openclaw-gateway.log 2>&1 &"]

        do {
            try task.run()
            debugLog("Gateway start command executed")
        } catch {
            debugLog("Error starting gateway: \(error.localizedDescription)")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.checkStatus()
        }
    }

    @objc func stopGateway() {
        // Direct process execution - no shell needed
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-f", "openclaw-gateway"]

        do {
            try task.run()
            task.waitUntilExit()
            debugLog("Gateway stop command executed")
        } catch {
            debugLog("Error stopping gateway: \(error.localizedDescription)")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.checkStatus()
        }
    }

    @objc func restartGateway() {
        stopGateway()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.startGateway()
        }
    }

    @objc func killAllOpenClaw() {
        // Kill all openclaw processes (gateway, agents, channels, etc.)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-9", "-f", "openclaw"]

        do {
            try task.run()
            task.waitUntilExit()
            debugLog("Killed all OpenClaw processes")
            sendNotification(running: false)
        } catch {
            debugLog("Error killing OpenClaw: \(error.localizedDescription)")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.checkStatus()
        }
    }

    @objc func openDashboard() {
        guard let token = getGatewayToken(), !token.isEmpty else {
            sendErrorNotification("Could not read gateway token")
            return
        }

        // Using URL fragment (#) instead of query string (?) for security
        // Fragments are not sent in HTTP requests or logged in server logs
        let urlString = "http://127.0.0.1:18789/#token=\(token)"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func openGateway() {
        if let url = URL(string: "http://127.0.0.1:18789") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func viewLogs() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", "Console", "/tmp/openclaw-gateway.log"]

        do {
            try task.run()
        } catch {
            debugLog("Error opening logs: \(error.localizedDescription)")
        }
    }

    @objc func toggleLaunchAtLogin() {
        let enabled = !isLaunchAtLoginEnabled()
        setLaunchAtLogin(enabled: enabled)

        if let menu = statusItem.menu,
           let item = menu.item(withTag: 200) {
            item.state = enabled ? .on : .off
        }
    }

    func isLaunchAtLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    func setLaunchAtLogin(enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                debugLog("Failed to set launch at login: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Model Selection

    func getAvailableModels() -> [ModelInfo] {
        var models: [ModelInfo] = []

        guard let config = readOpenClawConfig() else {
            debugLog("Could not read config for models")
            return models
        }

        guard let modelsSection = config["models"] as? [String: Any],
              let providers = modelsSection["providers"] as? [String: Any] else {
            debugLog("Could not find models.providers in config")
            return models
        }

        for (providerName, providerData) in providers {
            guard let providerDict = providerData as? [String: Any],
                  let providerModels = providerDict["models"] as? [[String: Any]] else {
                continue
            }

            for modelData in providerModels {
                guard let id = modelData["id"] as? String,
                      let name = modelData["name"] as? String else {
                    continue
                }

                let modelInfo = ModelInfo(id: id, name: name, provider: providerName)
                models.append(modelInfo)
            }
        }

        return models
    }

    func getCurrentModel() -> String? {
        guard let config = readOpenClawConfig() else {
            return nil
        }

        guard let agents = config["agents"] as? [String: Any],
              let defaults = agents["defaults"] as? [String: Any],
              let model = defaults["model"] as? [String: Any],
              let primary = model["primary"] as? String else {
            return nil
        }

        return primary
    }

    func updateModelMenu() {
        guard let menu = statusItem.menu,
              let modelMenuItem = menu.item(withTag: 300),
              let modelSubmenu = modelMenuItem.submenu else {
            debugLog("Could not find model submenu")
            return
        }

        // Clear existing items
        modelSubmenu.removeAllItems()

        // Get current model and available models
        let currentModel = getCurrentModel()
        let availableModels = getAvailableModels()

        // Update parent menu title
        if let currentModel = currentModel {
            // Extract display name from current model
            let displayName = getModelDisplayName(fullId: currentModel, availableModels: availableModels)
            modelMenuItem.title = "Model: \(displayName)"
        } else {
            modelMenuItem.title = "Model: Unknown"
        }

        // Group models by provider
        var modelsByProvider: [String: [ModelInfo]] = [:]
        for model in availableModels {
            if modelsByProvider[model.provider] == nil {
                modelsByProvider[model.provider] = []
            }
            modelsByProvider[model.provider]?.append(model)
        }

        // Sort providers for consistent ordering
        let sortedProviders = modelsByProvider.keys.sorted { a, b in
            // Put anthropic first, then gemini, then others alphabetically
            let order = ["anthropic": 0, "gemini": 1, "openrouter": 2, "lmstudio": 3, "koboldcpp": 4]
            let orderA = order[a] ?? 5
            let orderB = order[b] ?? 5
            if orderA != orderB {
                return orderA < orderB
            }
            return a < b
        }

        // Add models grouped by provider
        var isFirst = true
        for provider in sortedProviders {
            guard let models = modelsByProvider[provider] else { continue }

            if !isFirst {
                modelSubmenu.addItem(NSMenuItem.separator())
            }
            isFirst = false

            // Provider header
            let headerItem = NSMenuItem(title: provider.capitalized, action: nil, keyEquivalent: "")
            headerItem.isEnabled = false
            modelSubmenu.addItem(headerItem)

            // Add models for this provider
            for model in models {
                let item = NSMenuItem(title: "  \(model.name)", action: #selector(selectModel(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = model.fullId

                // Check if this is the current model
                if let currentModel = currentModel, currentModel == model.fullId {
                    item.state = .on
                }

                modelSubmenu.addItem(item)
            }
        }

        // Add separator before custom option
        if !availableModels.isEmpty {
            modelSubmenu.addItem(NSMenuItem.separator())
        }

        // Add custom LM Studio option
        let customHeader = NSMenuItem(title: "Custom", action: nil, keyEquivalent: "")
        customHeader.isEnabled = false
        modelSubmenu.addItem(customHeader)

        // Show last used model and address if available
        let lastModelName = getLastCustomModelName()
        let lastAddress = getLastCustomAddress() ?? lmStudioBaseUrl
        let customTitle = lastModelName != nil
            ? "  \(lastModelName!) @ \(lastAddress)"
            : "  Custom LM Studio..."
        let customItem = NSMenuItem(title: customTitle, action: #selector(selectCustomModel(_:)), keyEquivalent: "")
        customItem.target = self
        customItem.representedObject = lastModelName != nil ? "lmstudio/\(lastModelName!)@\(lastAddress)" : "lmstudio:custom"

        // Check if current model is a custom LM Studio model
        if let currentModel = currentModel, currentModel.hasPrefix("lmstudio/") || currentModel == "lmstudio:custom" {
            customItem.state = .on
        }

        modelSubmenu.addItem(customItem)

        // Add refresh option
        modelSubmenu.addItem(NSMenuItem.separator())
        let refreshItem = NSMenuItem(title: "Refresh Models", action: #selector(refreshModels), keyEquivalent: "")
        refreshItem.target = self
        modelSubmenu.addItem(refreshItem)
    }

    func getModelDisplayName(fullId: String, availableModels: [ModelInfo]) -> String {
        // Check if it's a custom LM Studio model (format: lmstudio/model@address)
        if fullId.hasPrefix("lmstudio/") {
            let remainder = String(fullId.dropFirst("lmstudio/".count))
            if remainder.contains("@") {
                let parts = remainder.split(separator: "@", maxSplits: 1)
                if parts.count == 2 {
                    return "\(parts[0]) @ \(parts[1])"
                }
            }
            return "LM Studio: \(remainder)"
        }
        if fullId == "lmstudio:custom" {
            return "Custom LM Studio"
        }

        // Find in available models
        if let model = availableModels.first(where: { $0.fullId == fullId }) {
            return model.name
        }

        // Fallback: extract from fullId
        if fullId.contains("/") {
            let parts = fullId.split(separator: "/", maxSplits: 1)
            if parts.count == 2 {
                return String(parts[1])
            }
        }

        return fullId
    }

    @objc func selectModel(_ sender: NSMenuItem) {
        guard let modelId = sender.representedObject as? String else {
            debugLog("No model ID in menu item")
            return
        }

        let modelName = sender.title.trimmingCharacters(in: .whitespaces)
        setActiveModel(modelId) { [weak self] success in
            if success {
                self?.updateModelMenu()
                self?.promptGatewayRestart(modelName: modelName)
            }
        }
    }

    @objc func selectCustomModel(_ sender: NSMenuItem) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Create alert with text inputs for address and model name
            let alert = NSAlert()
            alert.messageText = "Custom LM Studio Model"
            alert.informativeText = "Enter the server address and model name:"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Set Model")
            alert.addButton(withTitle: "Cancel")

            // Create container view for two labeled fields
            let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 70))

            // Address label and field
            let addressLabel = NSTextField(labelWithString: "Address:")
            addressLabel.frame = NSRect(x: 0, y: 46, width: 60, height: 17)
            containerView.addSubview(addressLabel)

            let addressField = NSTextField(frame: NSRect(x: 65, y: 44, width: 255, height: 24))
            addressField.placeholderString = "192.168.50.10:1234"
            addressField.stringValue = self.getLastCustomAddress() ?? self.lmStudioBaseUrl
            containerView.addSubview(addressField)

            // Model label and field
            let modelLabel = NSTextField(labelWithString: "Model:")
            modelLabel.frame = NSRect(x: 0, y: 10, width: 60, height: 17)
            containerView.addSubview(modelLabel)

            let modelField = NSTextField(frame: NSRect(x: 65, y: 8, width: 255, height: 24))
            modelField.placeholderString = "llama-3.2-8b, qwen2.5-coder, etc."
            modelField.stringValue = self.getLastCustomModelName() ?? ""
            containerView.addSubview(modelField)

            alert.accessoryView = containerView
            alert.window.initialFirstResponder = addressField

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                let address = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                let modelName = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

                guard !address.isEmpty else {
                    self.sendErrorNotification("Address cannot be empty")
                    return
                }
                guard !modelName.isEmpty else {
                    self.sendErrorNotification("Model name cannot be empty")
                    return
                }

                // Save for next time
                self.saveLastCustomAddress(address)
                self.saveLastCustomModelName(modelName)

                // Set the model as lmstudio/modelname@address
                let fullModelId = "lmstudio/\(modelName)@\(address)"
                self.setActiveModel(fullModelId) { success in
                    if success {
                        self.updateModelMenu()
                        self.promptGatewayRestart(modelName: "\(modelName) @ \(address)")
                    }
                }
            }
        }
    }

    func getLastCustomAddress() -> String? {
        return UserDefaults.standard.string(forKey: "lastCustomAddress")
    }

    func saveLastCustomAddress(_ address: String) {
        UserDefaults.standard.set(address, forKey: "lastCustomAddress")
    }

    func getLastCustomModelName() -> String? {
        return UserDefaults.standard.string(forKey: "lastCustomModelName")
    }

    func saveLastCustomModelName(_ name: String) {
        UserDefaults.standard.set(name, forKey: "lastCustomModelName")
    }

    @objc func refreshModels() {
        updateModelMenu()
        debugLog("Model menu refreshed")
    }

    func promptGatewayRestart(modelName: String) {
        DispatchQueue.main.async { [weak self] in
            let alert = NSAlert()
            alert.messageText = "Model Changed"
            alert.informativeText = "Model set to \(modelName).\n\nRestart the gateway to apply the change?"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Restart Gateway")
            alert.addButton(withTitle: "Later")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                self?.restartGateway()
            }
        }
    }

    func setActiveModel(_ modelId: String, completion: @escaping (Bool) -> Void) {
        // Validate model ID format (basic security check)
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_/:./"))
        guard modelId.unicodeScalars.allSatisfy({ allowedCharacters.contains($0) }),
              modelId.count <= 256 else {
            debugLog("Invalid model ID format")
            sendErrorNotification("Invalid model ID")
            completion(false)
            return
        }

        // Call external script to set model (avoids shell escaping issues)
        let scriptPath = NSString(string: "~/.openclaw/scripts/set-model.sh").expandingTildeInPath

        let task = Process()
        task.executableURL = URL(fileURLWithPath: scriptPath)
        task.arguments = [modelId]

        let errorPipe = Pipe()
        task.standardError = errorPipe

        do {
            try task.run()
            task.waitUntilExit()

            if task.terminationStatus == 0 {
                debugLog("Model set to: \(modelId)")
                completion(true)
            } else {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorOutput = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                debugLog("Failed to set model: \(errorOutput)")
                sendErrorNotification("Failed to save config")
                completion(false)
            }
        } catch {
            debugLog("Error setting model: \(error.localizedDescription)")
            sendErrorNotification("Error: \(error.localizedDescription)")
            completion(false)
        }
    }

    func sendNotification(message: String) {
        let content = UNMutableNotificationContent()
        content.title = "OpenClaw"
        content.body = message
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Configuration Reading

    func readOpenClawConfig() -> [String: Any]? {
        let configPath = NSString(string: "~/.openclaw/openclaw.json").expandingTildeInPath
        let fileManager = FileManager.default

        // Security: Check file exists and is not a symlink pointing outside home
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: configPath, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            debugLog("Config file not found")
            return nil
        }

        // Resolve symlinks and verify path is within home directory
        let resolvedPath = (configPath as NSString).resolvingSymlinksInPath
        guard resolvedPath.hasPrefix(NSHomeDirectory()) else {
            debugLog("Security: Config path resolves outside home directory")
            return nil
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return json
            }
        } catch {
            debugLog("Error reading config: \(error.localizedDescription)")
        }

        return nil
    }

    func getGatewayToken() -> String? {
        guard let config = readOpenClawConfig() else {
            return nil
        }

        guard let gateway = config["gateway"] as? [String: Any],
              let auth = gateway["auth"] as? [String: Any],
              let token = auth["token"] as? String else {
            debugLog("Could not find gateway token in config")
            return nil
        }

        // Basic token validation
        guard token.count >= 10, token.count <= 1024 else {
            debugLog("Token has invalid length")
            return nil
        }

        return token
    }

    func sendErrorNotification(_ message: String) {
        let content = UNMutableNotificationContent()
        content.title = "OpenClaw Monitor"
        content.body = message
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
