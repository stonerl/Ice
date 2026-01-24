//
//  AppState.swift
//  Ice
//

import Combine
import OSLog
import SwiftUI

/// The model for app-wide state.
@MainActor
final class AppState: ObservableObject {
    /// Information for the active space.
    @Published private(set) var activeSpace = SpaceInfo.activeSpace()

    /// A Boolean value that indicates whether the user is dragging a menu bar item.
    @Published private(set) var isDraggingMenuBarItem = false

    /// Model for the app's settings.
    let settings = AppSettings()

    /// Model for the app's permissions.
    let permissions = AppPermissions()

    /// Model for app-wide navigation.
    let navigationState = AppNavigationState()

    /// Manager for the state of the menu bar.
    let menuBarManager = MenuBarManager()

    /// Manager for the menu bar's appearance.
    let appearanceManager = MenuBarAppearanceManager()

    /// Manager for menu bar item spacing.
    let spacingManager = MenuBarItemSpacingManager()

    /// Manager for menu bar items.
    let itemManager = MenuBarItemManager()

    /// Global cache for menu bar item images.
    let imageCache = MenuBarItemImageCache()

    /// Manager for input events received by the app.
    let hidEventManager = HIDEventManager()

    /// Manager for app updates.
    let updatesManager = UpdatesManager()

    /// Manager for user notifications.
    let userNotificationManager = UserNotificationManager()

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// Track open windows to prevent duplicates
    private var openWindows = Set<IceWindowIdentifier>()

    /// Logger for the app state.
    let logger = Logger(category: "AppState")

    /// Async setup actions, run once on first access.
    private lazy var setupTask = Task {
        permissions.stopAllChecks()

        settings.performSetup(with: self)
        menuBarManager.performSetup(with: self)

        if #available(macOS 26.0, *) {
            await MenuBarItemService.Connection.shared.start()
        }

        appearanceManager.performSetup(with: self)
        hidEventManager.performSetup(with: self)
        await itemManager.performSetup(with: self)
        imageCache.performSetup(with: self)
        updatesManager.performSetup(with: self)
        userNotificationManager.performSetup(with: self)

        configureCancellables()

        // Start memory monitoring
        startMemoryMonitoring()
    }

    /// Starts periodic memory monitoring to track potential leaks
    private func startMemoryMonitoring() {
        Task {
            while !Task.isCancelled {
                let memoryInfo = getMemoryInfo()
                if memoryInfo.used > 100 * 1024 * 1024 { // 100MB threshold
                    let timestamp = ISO8601DateFormatter().string(from: Date())
                    logger.warning("High memory usage detected at \(timestamp): \(memoryInfo.used / 1024 / 1024)MB")

                    // Log component sizes for debugging
                    await MainActor.run {
                        let imageCount = imageCache.images.count
                        let windowCount = openWindows.count

                        if imageCount > 20 {
                            logger.warning("Large image cache: \(imageCount) items")
                        }
                        if windowCount > 5 {
                            logger.warning("Many open windows: \(windowCount)")
                        }
                    }
                }

                try? await Task.sleep(for: .seconds(300)) // Check every 5 minutes
            }
        }
    }

    /// Dismisses the window with the given identifier.
    func dismissWindow(_ id: IceWindowIdentifier) {
        // Async prevents conflicts with SwiftUI.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.openWindows.remove(id)
            self.logger.debug("Dismissing window with id: \(id, privacy: .public)")
            EnvironmentValues().dismissWindow(id: id)
        }
    }

    /// Gets current memory usage information
    private func getMemoryInfo() -> (used: Int64, available: Int64) {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4

        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }

        if kerr == KERN_SUCCESS {
            return (used: Int64(info.resident_size), available: 0)
        } else {
            return (used: 0, available: 0)
        }
    }

    /// Performs app state setup.
    ///
    /// - Parameter hasPermissions: If `true`, continues with setup normally.
    ///   If `false`, prompts the user to grant permissions.
    func performSetup(hasPermissions: Bool) {
        if hasPermissions {
            Task {
                logger.debug("Setting up app state")
                await setupTask.value

                // Warm up the activation policy system.
                NSApp.setActivationPolicy(.regular)
                try? await Task.sleep(for: .milliseconds(50))
                NSApp.setActivationPolicy(.accessory)

                logger.debug("Finished setting up app state")
            }
        } else {
            Task {
                // Delay to prevent conflicts with the app delegate.
                try? await Task.sleep(for: .milliseconds(100))
                activate(withPolicy: .regular)
                dismissWindow(.settings) // Shouldn't be open anyway.
                openWindow(.permissions)
            }
        }
    }

    /// Configures the internal observers for the app state.
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        // Listen for changes to the active space. We need handle some special
        // cases that NSWorkspace.shared.notificationCenter seems to miss.
        //
        // Special cases:
        //
        // * Changes to the frontmost application -- may indicate that a space
        //   on another display was made active.
        // * Left mouse down -- user may have clicked into a fullscreen space.
        //   To account for variations in system timing, we publish a value
        //   immediately upon receipt of the event, then publish another value
        //   after a delay.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .discardMerge(NSWorkspace.shared.publisher(for: \.frontmostApplication))
            .discardMerge(EventMonitor.publish(events: .leftMouseDown, scope: .universal).flatMap { _ in
                let initial = Just(())
                let delayed = initial.delay(for: 0.1, scheduler: DispatchQueue.main)
                return Publishers.Merge(initial, delayed)
            })
            .replace { Bridging.getActiveSpaceID() }
            .removeDuplicates()
            .sink { [weak self] spaceID in
                self?.activeSpace = SpaceInfo(spaceID: spaceID)
            }
            .store(in: &c)

        NSWorkspace.shared.publisher(for: \.frontmostApplication)
            .receive(on: DispatchQueue.main)
            .map { $0 == .current }
            .removeDuplicates()
            .sink { [weak self] isFrontmost in
                self?.navigationState.isAppFrontmost = isFrontmost
            }
            .store(in: &c)

        publisherForWindow(.settings)
            .removeNil()
            .flatMap { $0.publisher(for: \.isVisible) }
            .replaceEmpty(with: false)
            .throttle(for: 0.1, scheduler: DispatchQueue.main, latest: true)
            .removeDuplicates()
            .sink { [weak self] isPresented in
                guard let self else { return }
                self.navigationState.isSettingsPresented = isPresented

                // Update openWindows tracking based on actual window visibility
                if isPresented {
                    self.openWindows.insert(.settings)
                } else {
                    self.openWindows.remove(.settings)
                }
            }
            .store(in: &c)

        hidEventManager.$isDraggingMenuBarItem
            .removeDuplicates()
            .sink { [weak self] isDragging in
                self?.isDraggingMenuBarItem = isDragging
            }
            .store(in: &c)

        Publishers.CombineLatest(
            navigationState.$isAppFrontmost,
            navigationState.$isSettingsPresented
        )
        .map { $0 && $1 }
        .throttle(for: 0.1, scheduler: DispatchQueue.main, latest: true)
        .merge(with: Just(true).delay(for: 1, scheduler: DispatchQueue.main))
        .sink { [weak self] shouldUpdate in
            guard let self, shouldUpdate else {
                return
            }
            Task {
                await self.imageCache.updateCacheWithoutChecks(sections: MenuBarSection.Name.allCases)
                // Log cache status periodically (only if cache is getting full)
                if self.imageCache.cacheSize > 15 {
                    self.imageCache.logCacheStatus("Periodic update")
                }
            }
        }
        .store(in: &c)

        menuBarManager.objectWillChange
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &c)
        permissions.objectWillChange
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &c)
        settings.objectWillChange
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &c)
        updatesManager.objectWillChange
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &c)

        cancellables = c
    }

    /// Returns a Boolean value indicating whether the app has been
    /// granted the permission associated with the given key.
    func hasPermission(_ key: AppPermissions.PermissionKey) -> Bool {
        switch key {
        case .accessibility:
            permissions.accessibility.hasPermission
        case .screenRecording:
            permissions.screenRecording.hasPermission
        }
    }

    /// Returns a publisher for the window with the given identifier.
    func publisherForWindow(_ id: IceWindowIdentifier) -> some Publisher<NSWindow?, Never> {
        NSApp.publisher(for: \.windows).mergeMap { window in
            window.publisher(for: \.identifier)
                .map { [weak window] identifier in
                    guard identifier?.rawValue == id.rawValue else {
                        return nil
                    }
                    return window
                }
                .first { $0 != nil }
                .replaceEmpty(with: nil)
        }
    }

    /// Opens the window with the given identifier.
    func openWindow(_ id: IceWindowIdentifier) {
        // Async prevents conflicts with SwiftUI.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            // Check if window is already open to prevent recreation
            if self.openWindows.contains(id) {
                self.logger.debug("Window \(id, privacy: .public) already open, activating existing window")
                // If window already exists, just activate it
                self.activate(withPolicy: .regular)
                return
            }

            self.openWindows.insert(id)
            self.logger.debug("Opening window with id: \(id, privacy: .public)")
            EnvironmentValues().openWindow(id: id)

            // Ensure activation after window opens
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.activate(withPolicy: .regular)
            }
        }
    }

    /// Activates the app and sets its activation policy.
    func activate(withPolicy policy: NSApplication.ActivationPolicy? = nil) {
        if let policy {
            NSApp.setActivationPolicy(policy)
        }

        // Force activation and bring to front
        NSApp.activate(ignoringOtherApps: true)

        // Also try through NSRunningApplication as fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let frontmost = NSWorkspace.shared.frontmostApplication else {
                NSRunningApplication.current.activate()
                return
            }

            NSRunningApplication.current.activate(from: frontmost)
        }
    }

    /// Deactivates the app and sets its activation policy.
    func deactivate(withPolicy policy: NSApplication.ActivationPolicy? = nil) {
        if let policy {
            NSApp.setActivationPolicy(policy)
        }
        NSApp.deactivate()
    }
}
