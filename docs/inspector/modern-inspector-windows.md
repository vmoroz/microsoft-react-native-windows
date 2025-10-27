# Modern Inspector Integration in React Native for Windows

## Overview

This document describes the architecture of React Native for Windows (RNW) and analyzes the current state of modern JavaScript debugger (inspector) integration. The modern inspector provides Chrome DevTools Protocol (CDP) support for debugging JavaScript execution in React Native apps, similar to the implementations in React Native for iOS and Android.

## Core Architecture

### Key Windows-Specific Components

React Native for Windows follows a layered architecture with these primary components:

1. **ReactNativeHost** - WinRT public API for managing React instances
2. **ReactHost** - Internal C++ implementation managing instance lifetime
3. **ReactInstanceWin** - Windows-specific React instance implementation
4. **DevSupportManager** - Development support services (live reload, debugging, packager communication)
5. **ReactInspectorThread** - Windows-specific thread for inspector operations

### Component Relationships

```
Application
    ↓
ReactNativeHost (WinRT - Public API)
    ↓ creates
ReactHost (C++ - Internal)
    ↓ creates
ReactInstanceWin (C++ - Windows Implementation)
    ↓ creates
ReactInstance (C++ - Cross-platform Bridgeless)
or
Instance (C++ - Cross-platform Bridge-based)
```

## ReactNativeHost - The Public API Entry Point

### Purpose and Responsibilities

`ReactNativeHost` is the main entry point for application developers to create and manage React Native instances on Windows. It is defined as a WinRT runtime class in `ReactNativeHost.idl` and implemented in the `Microsoft.ReactNative` library.

### IDL Definition

Located in `vnext/Microsoft.ReactNative/ReactNativeHost.idl`:

```cpp
runtimeclass ReactNativeHost {
  ReactNativeHost();
  
  // Configuration
  IVector<IReactPackageProvider> PackageProviders { get; };
  ReactInstanceSettings InstanceSettings { get; set; };
  
  // Instance lifecycle
  Windows.Foundation.IAsyncAction LoadInstance();
  Windows.Foundation.IAsyncAction ReloadInstance();
  Windows.Foundation.IAsyncAction UnloadInstance();
  
  // Utilities
  static ReactNativeHost FromContext(IReactContext reactContext);
}
```

### Key Properties

#### PackageProviders
- Collection of `IReactPackageProvider` instances
- Allows registration of native modules and view managers
- Auto-linking automatically populates this list
- Delegates to `InstanceSettings.PackageProviders`

#### InstanceSettings
- Returns `ReactInstanceSettings` object
- Created on-demand if not set
- Contains all configuration for the React instance (bundle paths, debugging flags, etc.)

### Instance Lifecycle Management

#### LoadInstance() / ReloadInstance()
Both methods perform the following sequence:

1. **Create Providers**: Instantiates `NativeModulesProvider`, `ViewManagersProvider`, and `TurboModulesProvider`
2. **Build Packages**: Creates `ReactPackageBuilder` and calls `CreatePackage()` on all package providers
3. **Configure ReactOptions**: Converts `ReactInstanceSettings` to internal `ReactOptions` structure
4. **Set Inspector Target**: Assigns `m_inspectorTarget` pointer to `ReactOptions.InspectorTarget`
5. **Reload Instance**: Calls `m_reactHost->ReloadInstanceWithOptions()` with configured options

Key code from `ReactNativeHost.cpp`:

```cpp
IAsyncAction ReactNativeHost::ReloadInstance() noexcept {
  // ... create providers and package builder ...
  
  Mso::React::ReactOptions reactOptions{};
  reactOptions.Properties = m_instanceSettings.Properties();
  reactOptions.Notifications = m_instanceSettings.Notifications();
  reactOptions.SetUseDeveloperSupport(m_instanceSettings.UseDeveloperSupport());
  // ... set other options ...
  
  // Pass inspector target to ReactOptions
  reactOptions.InspectorTarget = m_inspectorTarget.get();
  
  return make<Mso::AsyncActionFutureAdapter>(
      m_reactHost->ReloadInstanceWithOptions(std::move(reactOptions)));
}
```

#### UnloadInstance()
Shuts down the current React instance and cleans up resources.

### Implementation Details

Located in `vnext/Microsoft.ReactNative/ReactNativeHost.h` and `.cpp`:

```cpp
class ReactNativeHost : ReactNativeHostT<ReactNativeHost> {
 private:
  // Core instance management
  Mso::CntPtr<Mso::React::IReactHost> m_reactHost;
  ReactNative::ReactInstanceSettings m_instanceSettings{nullptr};
  ReactNative::IReactPackageBuilder m_packageBuilder;
  
  // Modern inspector integration
  std::shared_ptr<facebook::react::jsinspector_modern::HostTargetDelegate> m_inspectorHostDelegate{nullptr};
  std::shared_ptr<facebook::react::jsinspector_modern::HostTarget> m_inspectorTarget{nullptr};
  std::optional<int32_t> m_inspectorPageId{std::nullopt};
};
```

## ReactInstanceSettings - Configuration Object

### Purpose

`ReactInstanceSettings` is a WinRT runtime class that holds all configuration needed to create a React instance. It is the Windows equivalent of what iOS and Android call "settings" or "configuration."

### IDL Definition

Located in `vnext/Microsoft.ReactNative/ReactInstanceSettings.idl`:

Key properties include:
- **Developer Support**: `UseDeveloperSupport`, `UseWebDebugger`, `UseFastRefresh`, `UseLiveReload`, `UseDirectDebugger`
- **Bundle Configuration**: `JavaScriptBundleFile`, `BundleRootPath`, `BundleAppId`, `RequestDevBundle`
- **Debugging**: `DebuggerPort`, `DebuggerRuntimeName`, `DebuggerBreakOnNextLine`
- **Packager Settings**: `SourceBundleHost`, `SourceBundlePort`, `RequestInlineSourceMap`, `DebugBundlePath`
- **JavaScript Engine**: `JSIEngineOverride` (Chakra, Hermes, V8)
- **Advanced**: `Properties` (property bag), `Notifications` (notification service), `PackageProviders`

### Lifecycle Events

The settings object provides three key events:
- **InstanceCreated**: Fired when React instance is created (before JS bundle loads)
- **InstanceLoaded**: Fired when JS bundle finishes loading (or fails)
- **InstanceDestroyed**: Fired when React instance is destroyed

These events are implemented as notifications in the `ReactNative.InstanceSettings` namespace and can be observed via the `Notifications` property.

## ReactHost - Internal Instance Manager

### Purpose and Architecture

`ReactHost` (in `Mso::React` namespace) is the internal C++ implementation that manages the lifetime of React Native instances. It is **not** exposed through the public WinRT API.

Located in `vnext/Microsoft.ReactNative/ReactHost/ReactHost.h`:

```cpp
class ReactHost final : public Mso::ActiveObject<IReactHost> {
 public:
  ReactOptions Options() const noexcept override;
  Mso::CntPtr<IReactInstance> Instance() const noexcept override;
  Mso::DispatchQueue const &NativeQueue() const noexcept override;
  
  Mso::Future<void> ReloadInstance() noexcept override;
  Mso::Future<void> ReloadInstanceWithOptions(ReactOptions &&options) noexcept override;
  Mso::Future<void> UnloadInstance() noexcept override;
  
  Mso::CntPtr<IReactViewHost> MakeViewHost(ReactViewOptions &&options) noexcept override;
  
 private:
  const Mso::ActiveReadableField<ReactOptions> m_options{Queue(), m_mutex};
  const Mso::ActiveReadableField<Mso::CntPtr<IReactInstanceInternal>> m_reactInstance{Queue(), m_mutex};
  // ... other fields ...
};
```

### Key Responsibilities

1. **Queue Management**: All operations happen on a serial `DispatchQueue` ensuring thread-safe state transitions
2. **Action Sequencing**: Uses `AsyncActionQueue` to sequence load/unload operations
3. **Instance Lifecycle**: Creates and destroys `ReactInstanceWin` instances
4. **View Host Management**: Creates and tracks `ReactViewHost` instances (for multiple root views)
5. **Global Registry**: Registers with `ReactHostRegistry` for coordinated shutdown

### Instance Loading Flow

When `ReloadInstanceWithOptions()` is called:

1. **Queue Action**: Posts load action to the serial queue
2. **Create Instance**: Instantiates `ReactInstanceWin` with the provided `ReactOptions`
3. **Initialize Instance**: Calls `reactInstance->Initialize()` to start the React runtime
4. **Track State**: Updates internal state to reflect the new instance
5. **Notify Views**: Informs all attached view hosts of the new instance

The `ReactOptions.InspectorTarget` pointer is passed unchanged to `ReactInstanceWin`.

## ReactInstanceWin - Windows React Instance

### Purpose

`ReactInstanceWin` is the Windows-specific implementation of a React instance. It handles both:
- **Bridgeless Architecture**: New architecture using `facebook::react::ReactInstance`
- **Bridge-based Architecture**: Legacy architecture using `facebook::react::Instance`

Located in `vnext/Microsoft.ReactNative/ReactHost/ReactInstanceWin.h`:

```cpp
class ReactInstanceWin : public IReactInstance, public IReactInstanceInternal {
 public:
  const ReactOptions &Options() const noexcept override;
  ReactInstanceState State() const noexcept override;
  IReactContext &GetReactContext() const noexcept override;
  // ... other methods ...
  
 private:
  const ReactOptions m_options;
  Mso::CntPtr<IReactContext> m_reactContext;
  
  // Bridgeless architecture
  std::shared_ptr<facebook::react::ReactInstance> m_bridgelessReactInstance;
  
  // Bridge-based architecture  
  std::shared_ptr<facebook::react::InstanceWrapper> m_legacyReactInstance;
  
  // Development support
  std::shared_ptr<facebook::react::IDevSupportManager> m_devManager;
  // ... other fields ...
};
```

### Bridgeless Architecture Path

For the new bridgeless architecture (when Fabric is enabled):

```cpp
// From ReactInstanceWin.cpp, InitializeBridgeless() method
m_bridgelessReactInstance = std::make_shared<facebook::react::ReactInstance>(
    std::move(jsRuntime),
    jsMessageThread,
    timerManager,
    jsErrorHandlingFunc,
    m_options.InspectorTarget);  // HostTarget pointer passed here

// Initialize the runtime synchronously
m_bridgelessReactInstance->initializeRuntime(options, onRuntimeInitialized);
```

**Key Points**:
- Creates `facebook::react::ReactInstance` with `InspectorTarget` pointer
- Uses the cross-platform `ReactInstance` class (same as iOS/Android bridgeless)
- Inspector target is registered synchronously during `initializeRuntime()`
- This matches the iOS/Android bridgeless pattern

### Bridge-based Architecture Path

For the legacy bridge-based architecture:

```cpp
// Creates facebook::react::Instance via InstanceWrapper
m_legacyReactInstance = facebook::react::InstanceImpl::MakeAndLoadBundle(
    std::move(instance),
    // ... other parameters ...
    devSettings,
    m_devManager);
```

**Current State**: The `InspectorTarget` is **not** directly passed to the bridge-based path. This is a gap compared to iOS/Android where the inspector works with both architectures.

## DevSupportManager - Development Services

### Purpose and Responsibilities

`DevSupportManager` provides development-time features for React Native on Windows:
- **Web Debugging**: Proxy JavaScript execution through a remote debugger
- **Live Reload**: Automatically reload when bundle changes
- **Fast Refresh**: Hot reload with state preservation
- **Packager Communication**: Connect to Metro bundler
- **Inspector Integration**: Connect Hermes inspector to debugger

Located in `vnext/Shared/DevSupportManager.h`:

```cpp
class DevSupportManager final : public facebook::react::IDevSupportManager {
 public:
  virtual JSECreator LoadJavaScriptInProxyMode(...) override;
  virtual void StartPollingLiveReload(...) override;
  virtual void StopPollingLiveReload() override;
  virtual void OpenDevTools(const std::string &bundleAppId) override;
  
  virtual void EnsureHermesInspector(
      const std::string &packagerHost,
      const uint16_t packagerPort,
      const std::string &bundleAppId) noexcept override;
  virtual void UpdateBundleStatus(...) noexcept override;
  
 private:
  // Legacy inspector connection
  std::shared_ptr<InspectorPackagerConnection> m_inspectorPackagerConnection;
  
  // Modern inspector connection (Fusebox)
  std::unique_ptr<facebook::react::jsinspector_modern::InspectorPackagerConnection>
      m_fuseboxInspectorPackagerConnection;
  
  std::shared_ptr<BundleStatusProvider> m_BundleStatusProvider;
};
```

### Inspector Connection Management

The `EnsureHermesInspector` method is responsible for establishing the WebSocket connection to the Metro bundler's inspector proxy:

```cpp
void DevSupportManager::EnsureHermesInspector(
    const std::string &packagerHost,
    const uint16_t packagerPort,
    const std::string &bundleAppId) noexcept {
  
  auto &inspectorFlags = facebook::react::jsinspector_modern::InspectorFlags::getInstance();
  
  if (inspectorFlags.getFuseboxEnabled()) {
    if (!m_fuseboxInspectorPackagerConnection) {
      // Create modern inspector connection
      m_fuseboxInspectorPackagerConnection = 
          std::make_unique<jsinspector_modern::InspectorPackagerConnection>(
              getInspectorInstance(),
              "React Native Windows",
              std::make_unique<ReactInspectorPackagerConnectionDelegate>());
      m_fuseboxInspectorPackagerConnection->connect();
    }
  } else {
    // Create legacy inspector connection
    m_inspectorPackagerConnection = InspectorPackagerConnection::Make(...);
    m_inspectorPackagerConnection->connectAsync();
  }
}
```

### Packager Communication

The `DevSupportManager` uses different mechanisms for different features:

- **Bundle Download**: Direct HTTP requests to packager (via `GetJavaScriptFromServer()`)
- **Live Reload**: Polling HTTP endpoint for bundle changes
- **Fast Refresh**: WebSocket connection for hot module replacement
- **Inspector**: WebSocket connection through `InspectorPackagerConnection`

## ReactInspectorThread - Windows Inspector Thread

### Purpose

`ReactInspectorThread` is a Windows-specific singleton thread dedicated to running inspector operations. It serves the same purpose as the main UI thread on iOS/Android but is separate from the Windows UI thread.

Located in `vnext/Shared/Inspector/ReactInspectorThread.h` (likely):

```cpp
class ReactInspectorThread {
 public:
  static ReactInspectorThread& Instance();
  
  void Post(std::function<void()>&& callback);
  // ... other methods ...
};
```

### Usage in ReactNativeHost

The inspector thread is used when creating the `HostTarget`:

```cpp
// From ReactNativeHost.cpp constructor
m_inspectorTarget = facebook::react::jsinspector_modern::HostTarget::create(
    *m_inspectorHostDelegate,
    [](std::function<void()> &&callback) {
      // Executor that dispatches to inspector thread
      ReactInspectorThread::Instance().Post([callback = std::move(callback)]() {
        callback();
      });
    });
```

**Key Points**:
- Ensures all `HostTargetDelegate` callbacks run on a consistent thread
- Avoids blocking the UI thread for inspector operations
- Provides clean separation of concerns

## Current Modern Inspector Integration

### Integration State (as of October 2025)

React Native for Windows has **preliminary** modern inspector integration that is:
- ✅ Present in the codebase
- ✅ Follows iOS/Android patterns for bridgeless architecture
- ⚠️ Gated behind `InspectorFlags::getFuseboxEnabled()` flag
- ⚠️ Only integrated with bridgeless (`ReactInstance`) path, not bridge-based (`Instance`) path
- ❓ Integration completeness not verified

### What's Implemented

#### 1. HostTarget Creation (ReactNativeHost)

Located in `ReactNativeHost.cpp` constructor:

```cpp
ReactNativeHost::ReactNativeHost() noexcept {
  auto &inspectorFlags = facebook::react::jsinspector_modern::InspectorFlags::getInstance();
  
  if (inspectorFlags.getFuseboxEnabled() && !m_inspectorPageId.has_value()) {
    // Create delegate
    m_inspectorHostDelegate = std::make_shared<ModernInspectorHostTargetDelegate>(*this);
    
    // Create HostTarget with inspector thread executor
    m_inspectorTarget = HostTarget::create(
        *m_inspectorHostDelegate,
        [](std::function<void()> &&callback) {
          ReactInspectorThread::Instance().Post([callback = std::move(callback)]() {
            callback();
          });
        });
    
    // Register page with global inspector
    m_inspectorPageId = getInspectorInstance().addPage(
        "React Native Windows (Experimental)",
        /* vm */ "",
        [weakInspectorTarget = std::weak_ptr(m_inspectorTarget)](
            std::unique_ptr<IRemoteConnection> remote)
            -> std::unique_ptr<ILocalConnection> {
          if (const auto inspectorTarget = weakInspectorTarget.lock()) {
            return inspectorTarget->connect(std::move(remote));
          }
          return nullptr;  // Reject connection if target destroyed
        },
        {.nativePageReloads = true, .prefersFuseboxFrontend = true});
  }
}
```

**Observations**:
- Creates `HostTarget` during `ReactNativeHost` construction
- Uses weak pointer pattern to safely handle destruction
- Registers page with capabilities: native reloads and Fusebox preference
- Title includes "(Experimental)" indicating work-in-progress status

#### 2. HostTargetDelegate Implementation

```cpp
class ModernInspectorHostTargetDelegate : 
    public facebook::react::jsinspector_modern::HostTargetDelegate,
    public std::enable_shared_from_this<ModernInspectorHostTargetDelegate> {
 public:
  HostTargetMetadata getMetadata() override {
    return {.integrationName = "React Native Windows (Host)"};
  }
  
  void onReload(const PageReloadRequest &request) override {
    if (auto reactNativeHost = m_reactNativeHost.get()) {
      reactNativeHost.ReloadInstance();
    }
  }
  
  void onSetPausedInDebuggerMessage(
      const OverlaySetPausedInDebuggerMessageRequest &request) override {
    // Shows/hides "Paused in Debugger" overlay
    if (auto reactNativeHost = m_reactNativeHost.get()) {
      const auto instanceSettings = reactNativeHost.InstanceSettings();
      if (request.message.has_value()) {
        DebuggerNotifications::OnShowDebuggerPausedOverlay(...);
      } else {
        DebuggerNotifications::OnHideDebuggerPausedOverlay(...);
      }
    }
  }
  
 private:
  winrt::weak_ref<ReactNativeHost> m_reactNativeHost;
};
```

**Observations**:
- Implements required delegate methods
- Uses weak reference to `ReactNativeHost` to prevent cycles
- Integrates with Windows notification system for debugger overlay
- Metadata identifies the integration as "React Native Windows (Host)"

#### 3. Inspector Target Propagation

The `HostTarget` pointer flows through the architecture:

```
ReactNativeHost.m_inspectorTarget (shared_ptr)
    ↓
ReactOptions.InspectorTarget (raw pointer)
    ↓
ReactInstanceWin.m_options.InspectorTarget (raw pointer)
    ↓
ReactInstance constructor (bridgeless only)
```

#### 4. WebSocket Support

Windows uses `ReactInspectorPackagerConnectionDelegate` for WebSocket communication:

Located in `vnext/Shared/Inspector/ReactInspectorPackagerConnectionDelegate.cpp`:

```cpp
std::unique_ptr<IWebSocket> 
ReactInspectorPackagerConnectionDelegate::connectWebSocket(
    const std::string& url,
    std::weak_ptr<IWebSocketDelegate> delegate) {
  // Creates Windows WebSocket using WinRT APIs
  // Returns wrapper that implements IWebSocket interface
}

void ReactInspectorPackagerConnectionDelegate::scheduleCallback(
    std::function<void()> callback,
    std::chrono::milliseconds delayMs) {
  // Schedules callback on inspector thread
  ReactInspectorThread::Instance().Post(std::move(callback));
}
```

**Observations**:
- Adapts Windows WinRT WebSocket APIs to inspector's `IWebSocket` interface
- Uses `ReactInspectorThread` for callback scheduling
- Follows same pattern as iOS (SocketRocket) and Android (OkHttp) adaptations

### What's Missing or Uncertain

#### 1. Bridge-based Architecture Support
The legacy `Instance` (bridge-based) path does **not** appear to pass `InspectorTarget` through. On iOS/Android, both architectures support the modern inspector.

**Impact**: Apps using the bridge-based architecture (non-Fabric) may not have working modern inspector support.

#### 2. Synchronous Registration
Need to verify that Windows follows the iOS/Android pattern of **synchronous** inspector registration before JavaScript execution. From `ReactInstanceWin.cpp`:

```cpp
m_bridgelessReactInstance = std::make_shared<facebook::react::ReactInstance>(
    std::move(jsRuntime),
    jsMessageThread,
    timerManager,
    jsErrorHandlingFunc,
    m_options.InspectorTarget);

m_bridgelessReactInstance->initializeRuntime(options, onRuntimeInitialized);
```

The cross-platform `ReactInstance::initializeRuntime()` should handle synchronous registration, but this needs verification.

#### 3. DevSupportManager Integration
There appears to be some duplication between:
- Modern inspector path (`m_fuseboxInspectorPackagerConnection`)
- Legacy inspector path (`m_inspectorPackagerConnection`)

Need to clarify:
- When is each used?
- Do they coordinate or operate independently?
- Should DevSupportManager be involved in modern inspector setup?

#### 4. Instance Registration Verification
Need to verify that `InstanceTarget` and `RuntimeTarget` are properly created and registered. The cross-platform C++ code should handle this, but Windows-specific verification is needed.

## Comparison with iOS and Android

### Architectural Similarities

| Component | iOS | Android | Windows |
|-----------|-----|---------|---------|
| **Public API** | `RCTBridge` / `RCTHost` | `ReactInstanceManager` / `ReactHost` | `ReactNativeHost` |
| **Host Target Owner** | `RCTBridge` | `ReactInstanceManagerInspectorTarget` | `ReactNativeHost` |
| **Inspector Thread** | Main Queue | UI Thread | `ReactInspectorThread` |
| **WebSocket Library** | SocketRocket | OkHttp | WinRT WebSockets |
| **Delegate Pattern** | `RCTBridgeHostTargetDelegate` | JNI wrappers | `ModernInspectorHostTargetDelegate` |

### Key Differences

#### 1. Threading Model

**iOS**: Uses main queue for all `HostTarget` operations
```objc++
HostTarget::create(*_inspectorHostDelegate, [](auto callback) {
  RCTExecuteOnMainQueue(^{ callback(); });
});
```

**Android**: Uses UI thread via `UiThreadUtil`
```kotlin
Executor { command ->
  if (UiThreadUtil.isOnUiThread()) {
    command.run()
  } else {
    UiThreadUtil.runOnUiThread(command)
  }
}
```

**Windows**: Uses dedicated `ReactInspectorThread`
```cpp
HostTarget::create(*m_inspectorHostDelegate, [](auto callback) {
  ReactInspectorThread::Instance().Post(std::move(callback));
});
```

**Analysis**: Windows' approach provides better separation but requires careful coordination with UI thread for overlay operations.

#### 2. Lifecycle Management

**iOS**: `RCTBridge` creates `HostTarget` on main thread, unregisters on main thread in dealloc
```objc++
if (_inspectorPageId.has_value()) {
  RCTExecuteOnMainQueue(^{
    getInspectorInstance().removePage(*inspectorPageId);
  });
}
```

**Android**: Similar cleanup in `close()` method with UI thread dispatch

**Windows**: Cleanup in `ReactNativeHost` destructor on current thread
```cpp
ReactNativeHost::~ReactNativeHost() noexcept {
  if (m_inspectorPageId.has_value()) {
    getInspectorInstance().removePage(*m_inspectorPageId);
    m_inspectorPageId.reset();
    m_inspectorTarget.reset();
  }
}
```

**Analysis**: Windows should ensure cleanup happens on inspector thread to avoid potential race conditions.

#### 3. Weak Reference Pattern

**iOS**: Uses `__weak` references
```objc++
RCTBridgeHostTargetDelegate(RCTBridge *bridge) : bridge_(bridge) {}
// bridge_ is __weak
```

**Android**: Uses `WeakReference<>` and `std::weak_ptr<>`
```kotlin
private WeakReference<ReactInstanceManager> mReactInstanceManagerWeak;
```

**Windows**: Uses `winrt::weak_ref<>`
```cpp
winrt::weak_ref<ReactNativeHost> m_reactNativeHost;
```

**Analysis**: All three platforms properly use weak references to prevent retain cycles. Windows uses WinRT-specific weak reference type.

### Integration Completeness

| Feature | iOS | Android | Windows |
|---------|-----|---------|---------|
| HostTarget Creation | ✅ Complete | ✅ Complete | ✅ Complete |
| Page Registration | ✅ Complete | ✅ Complete | ✅ Complete |
| WebSocket Connection | ✅ Complete | ✅ Complete | ✅ Complete |
| Delegate Callbacks | ✅ Complete | ✅ Complete | ✅ Complete |
| Debugger Overlay | ✅ Complete | ✅ Complete | ✅ Implemented |
| Bridgeless Support | ✅ Complete | ✅ Complete | ✅ Implemented |
| Bridge-based Support | ✅ Complete | ✅ Complete | ❓ Unclear |
| Synchronous Init | ✅ Verified | ✅ Verified | ❓ Needs Verification |
| Runtime Registration | ✅ Complete | ✅ Complete | ❓ Needs Verification |
| Production Ready | ✅ Yes | ✅ Yes | ⚠️ Experimental |

## Recommendations for Complete Integration

Based on the analysis of iOS/Android implementations and the current Windows state, here are recommendations:

### 1. Enable by Default (Remove Fusebox Gate)

**Current State**: Modern inspector only works when `InspectorFlags::getFuseboxEnabled()` returns true.

**Recommendation**: Once verified working, remove the Fusebox flag gate and enable modern inspector by default for development builds.

**Rationale**: iOS and Android enable modern inspector by default. The flag was likely added during initial development but should be removed once stable.

### 2. Add Bridge-based Architecture Support

**Current State**: Only bridgeless (`ReactInstance`) path passes `InspectorTarget`.

**Recommendation**: Modify the bridge-based initialization path to also receive and use `InspectorTarget`:

```cpp
// In InstanceImpl or similar bridge initialization code
instance->initializeBridge(
    callback,
    executorFactory,
    jsQueue,
    moduleRegistry,
    m_options.InspectorTarget);  // Add this parameter
```

**Rationale**: Many Windows apps still use bridge-based architecture. Inspector should work for both.

### 3. Verify Synchronous Registration

**Current State**: Unclear if Windows ensures inspector is fully initialized before JS executes.

**Recommendation**: Add explicit verification that:
- `HostTarget::create()` completes before `ReactInstance` is created
- `ReactInstance::initializeRuntime()` synchronously registers instance and runtime
- No JavaScript executes until inspector is ready

**Implementation**: Review `ReactInstanceWin::InitializeBridgeless()` and add logging/assertions to verify timing:

```cpp
// Ensure inspector target is ready
if (m_options.InspectorTarget) {
  OutputDebugStringA("Inspector target ready, creating ReactInstance\n");
}

m_bridgelessReactInstance = std::make_shared<facebook::react::ReactInstance>(
    std::move(jsRuntime),
    jsMessageThread,
    timerManager,
    jsErrorHandlingFunc,
    m_options.InspectorTarget);

// The following should block until inspector is registered
m_bridgelessReactInstance->initializeRuntime(options, onRuntimeInitialized);

OutputDebugStringA("Runtime initialized, inspector should be registered\n");
```

### 4. Thread Safety for Cleanup

**Current State**: Destructor calls `removePage()` on current thread.

**Recommendation**: Ensure cleanup happens on inspector thread:

```cpp
ReactNativeHost::~ReactNativeHost() noexcept {
  if (m_inspectorPageId.has_value()) {
    auto pageIdCopy = *m_inspectorPageId;
    auto targetCopy = m_inspectorTarget;
    
    ReactInspectorThread::Instance().Post([pageIdCopy, targetCopy]() {
      getInspectorInstance().removePage(pageIdCopy);
      // targetCopy will be destroyed here, on inspector thread
    });
    
    m_inspectorPageId.reset();
    m_inspectorTarget.reset();
  }
}
```

**Rationale**: Matches iOS/Android pattern of cleanup on same thread as creation. Prevents race conditions.

### 5. Clarify DevSupportManager Role

**Current State**: Both `DevSupportManager` and `ReactNativeHost` create inspector connections.

**Recommendation**: 
- `ReactNativeHost` should own the `HostTarget` (already done)
- `DevSupportManager` should only create `InspectorPackagerConnection` for the legacy pre-Fusebox path
- Modern path should use only `HostTarget` machinery
- Consider deprecating legacy inspector path once modern inspector is stable

**Rationale**: Avoids duplication and confusion. Single code path is easier to maintain.

### 6. Testing Strategy

Develop comprehensive tests to verify:

1. **Page Registration**: Verify page appears in `chrome://inspect`
2. **WebSocket Connection**: Verify successful connection to Metro
3. **CDP Message Routing**: Verify Runtime and Debugger domain messages work
4. **Breakpoint Functionality**: Verify breakpoints can be set and hit
5. **Console Logging**: Verify `console.log()` appears in debugger
6. **Page Reload**: Verify reload from debugger works
7. **Clean Shutdown**: Verify no crashes on close
8. **Multiple Instances**: Test multiple `ReactNativeHost` instances
9. **Bridge-based**: Test with non-Fabric configuration
10. **Bridgeless**: Test with Fabric configuration

### 7. Documentation and Examples

**Recommendation**: Create developer documentation covering:
- How to enable modern inspector debugging
- Required Metro configuration
- Troubleshooting common issues
- Differences from legacy debugging
- Migration guide from web debugging

## Architectural Diagrams

### Instance Creation Flow

```
Application
    ↓
ReactNativeHost() constructor
    ↓
Create ModernInspectorHostTargetDelegate
    ↓
Create HostTarget with ReactInspectorThread executor
    ↓
Register page with getInspectorInstance()
    ↓
Store m_inspectorTarget pointer
    ↓
Application calls ReloadInstance()
    ↓
Create ReactOptions with InspectorTarget
    ↓
ReactHost.ReloadInstanceWithOptions()
    ↓
Create ReactInstanceWin with ReactOptions
    ↓
ReactInstanceWin.Initialize()
    ↓ (Bridgeless path)
Create ReactInstance with InspectorTarget
    ↓
ReactInstance.initializeRuntime()
    ↓
Synchronously register InstanceTarget and RuntimeTarget
    ↓
Load JavaScript bundle
```

### Inspector Connection Flow

```
Chrome DevTools or Metro Inspector Proxy
    ↓ (WebSocket)
Windows WebSocket (via WinRT)
    ↓
ReactInspectorPackagerConnectionDelegate
    ↓
IWebSocket interface
    ↓
InspectorPackagerConnection
    ↓
getInspectorInstance()
    ↓
HostTarget.connect()
    ↓
InstanceTarget
    ↓
RuntimeTarget (Hermes/JSC)
    ↓
JavaScript Runtime
```

### Threading Architecture

```
Main Thread (UI)
- ReactNativeHost creation
- Settings configuration
- View updates
- Debugger overlay

ReactInspectorThread
- HostTarget operations
- HostTargetDelegate callbacks
- WebSocket message dispatch
- Inspector page management

ReactHost Queue
- Instance lifecycle operations
- Load/reload/unload sequencing
- Options management

JS Thread
- JavaScript execution
- RuntimeTarget operations
- JSI calls
- TurboModule invocations
```

## Design Decisions and Best Practices

### Q1: Should ReactInspectorThread be exposed from DevSupportManager?

**Answer**: **No, keep them separate** (current design is correct).

**Rationale**:

1. **Different Concerns**: 
   - `ReactInspectorThread` is infrastructure for running inspector callbacks
   - `DevSupportManager` provides development services (bundles, live reload, WebSocket)
   - These are orthogonal concerns that don't need tight coupling

2. **iOS/Android Don't Have This Pattern**:
   - **iOS**: Uses system main queue directly via `RCTExecuteOnMainQueue()`
   - **Android**: Uses system UI thread directly via `UiThreadUtil.runOnUiThread()`
   - Neither platform has a "DevSupportManager owns inspector thread" pattern

3. **Multiple Usage Contexts**:
   - `ReactInspectorThread` is used by:
     - `ReactNativeHost` for `HostTarget` executor
     - `ReactInspectorPackagerConnectionDelegate` for WebSocket callbacks
     - Potentially other inspector-related code
   - Making it accessible via `DevSupportManager` would create an unnecessary dependency chain

4. **Cleaner Architecture**:
   ```cpp
   // Current (Good): Direct access to singleton
   ReactInspectorThread::Instance().Post(callback);
   
   // Alternative (Worse): Indirect access through DevSupportManager
   GetSharedDevManager()->GetInspectorThread().Post(callback);
   ```

5. **Singleton is the Right Pattern**: Since both are singletons, there's no ownership relationship - they're peers, not parent-child.

**Recommendation**: Keep `ReactInspectorThread` as a standalone singleton accessible directly. This matches the platform pattern where the inspector thread is a system-provided resource (main/UI thread), not something owned by dev support.

### Q2: When Should We Register Debugger Pages?

**Answer**: **Register in constructor, NOT before LoadInstance** (current design is correct).

**Analysis of iOS Pattern**:

```objc++
// From node_modules/react-native/React/Base/RCTBridge.mm

- (instancetype)initWithDelegate:(id<RCTBridgeDelegate>)delegate
                       bundleURL:(NSURL *)bundleURL
                  moduleProvider:(RCTBridgeModuleListProvider)block
                   launchOptions:(NSDictionary *)launchOptions {
  if (self = [super init]) {
    _inspectorHostDelegate = std::make_unique<RCTBridgeHostTargetDelegate>(self);
    [self setUp];  // ← Inspector page registered HERE in setUp
  }
  return self;
}

- (void)setUp {
  // ... performance logger setup ...
  
  // Register inspector page BEFORE loading any JavaScript
  if (inspectorFlags.getFuseboxEnabled() && !_inspectorPageId.has_value()) {
    _inspectorTarget = HostTarget::create(*_inspectorHostDelegate, executor);
    _inspectorPageId = getInspectorInstance().addPage(
        "React Native Bridge",
        /* vm */ "",
        connectCallback,
        capabilities);
  }
  
  // ... then create and start the bridge ...
}
```

**Analysis of Android Pattern**:

```cpp
// From node_modules/react-native/ReactAndroid/.../ReactInstanceManagerInspectorTarget.cpp

ReactInstanceManagerInspectorTarget::ReactInstanceManagerInspectorTarget(
    jni::alias_ref<jhybridobject> jobj,
    jni::alias_ref<JExecutor::javaobject> javaExecutor,
    jni::alias_ref<TargetDelegate> delegate) {
  
  // Register inspector page in CONSTRUCTOR
  if (inspectorFlags.getFuseboxEnabled()) {
    inspectorTarget_ = HostTarget::create(*this, inspectorExecutor_);
    
    inspectorPageId_ = getInspectorInstance().addPage(
        "React Native Bridge",
        /* vm */ "",
        connectCallback,
        capabilities);
  }
}
```

**Key Insights**:

1. **Early Registration**: Both iOS and Android register the page **as soon as the host object is created**, not when instance loads
2. **Page Represents the Host**: The page represents the capability to debug, not the running instance
3. **Ready for Connection**: Debugger can connect even before JS loads (useful for debugging initialization)
4. **Consistent Page ID**: The same page persists across instance reloads

**Current Windows Implementation**: ✅ **Correct**

```cpp
ReactNativeHost::ReactNativeHost() noexcept {
  // Register page in constructor
  if (inspectorFlags.getFuseboxEnabled() && !m_inspectorPageId.has_value()) {
    m_inspectorHostDelegate = std::make_shared<ModernInspectorHostTargetDelegate>(*this);
    m_inspectorTarget = HostTarget::create(*m_inspectorHostDelegate, executor);
    m_inspectorPageId = getInspectorInstance().addPage(...);
  }
}
```

**Why NOT Register Before LoadInstance?**:

- ❌ Would delay debugger availability
- ❌ Would prevent debugging initialization code
- ❌ Would require re-registration logic on reload
- ❌ Would diverge from iOS/Android patterns

**Recommendation**: **Keep registration in `ReactNativeHost` constructor**. The current implementation is correct and matches iOS/Android.

### Q3: When Should Debugger Pages Be Unregistered?

**Answer**: **Pages should survive instance reloads and be unregistered only on host destruction** (current design is correct).

**Analysis of iOS Pattern**:

```objc++
- (void)dealloc {
  // Unregister only in dealloc (destructor)
  if (_inspectorPageId.has_value()) {
    __block auto inspectorPageId = std::move(_inspectorPageId);
    __block auto inspectorTarget = std::move(_inspectorTarget);
    RCTExecuteOnMainQueue(^{
      getInspectorInstance().removePage(*inspectorPageId);
      inspectorPageId.reset();
      // ... destroy inspectorTarget on JS thread ...
    });
  }
}

- (void)didReceiveReloadCommand {
  // Reload does NOT unregister the page
  [self reload:^(NSURL *) {}];
}
```

**Analysis of Android Pattern**:

```cpp
ReactInstanceManagerInspectorTarget::~ReactInstanceManagerInspectorTarget() {
  // Unregister only in destructor
  if (inspectorPageId_.has_value()) {
    inspectorExecutor_([inspectorPageId = *inspectorPageId_,
                        inspectorTarget = std::move(inspectorTarget_)]() {
      getInspectorInstance().removePage(inspectorPageId);
      (void)inspectorTarget;
    });
  }
}
```

**Key Insights**:

1. **Page Lifetime = Host Lifetime**: The inspector page lives as long as the host object
2. **Survives Reloads**: Instance reloads do NOT unregister/re-register the page
3. **Consistent Page ID**: The debugger sees the same page across reloads
4. **Sessions Survive**: Active debugging sessions can survive instance reload (debugger stays connected)

**Why Pages Survive Reloads**:

1. **Debugger UX**: User doesn't want to reconnect debugger after every reload
2. **Fast Refresh**: During development, apps reload frequently - reconnecting would be annoying
3. **Session Continuity**: Breakpoints, watches, and debugger state can persist
4. **Metro Design**: Metro's inspector proxy expects stable page IDs

**Current Windows Implementation**: ✅ **Correct**

```cpp
ReactNativeHost::~ReactNativeHost() noexcept {
  // Unregister only in destructor
  if (m_inspectorPageId.has_value()) {
    getInspectorInstance().removePage(*m_inspectorPageId);
    m_inspectorPageId.reset();
    m_inspectorTarget.reset();
  }
}

// ReloadInstance() does NOT touch inspector page
IAsyncAction ReactNativeHost::ReloadInstance() noexcept {
  // ... reload logic, but m_inspectorPageId unchanged ...
}
```

**Recommendation**: **Keep unregistration only in destructor**. The current implementation is correct and matches iOS/Android.

### Q4: How to Associate Specific RNH Instance with DevSupportManager?

**Answer**: **DevSupportManager doesn't need to know about specific RNH instances** - it provides shared services, and the association happens through other mechanisms.

**Current Architecture Analysis**:

```cpp
// DevSupportManager is a singleton providing shared services
const std::shared_ptr<IDevSupportManager> &GetSharedDevManager() noexcept {
  static std::shared_ptr<IDevSupportManager> s_devManager(...);
  return s_devManager;
}

// Called during instance initialization (bridge-based path)
void OInstance::Initialize() {
  if (shouldStartHermesInspector(*m_devSettings)) {
    m_devManager->EnsureHermesInspector(
        m_devSettings->sourceBundleHost,
        m_devSettings->sourceBundlePort,
        m_devSettings->bundleAppId);
  }
}

// DevSupportManager creates shared infrastructure
void DevSupportManager::EnsureHermesInspector(...) {
  static std::once_flag once;
  std::call_once(once, [this, ...]() {
    // Create single shared InspectorPackagerConnection
    m_fuseboxInspectorPackagerConnection = 
        std::make_unique<InspectorPackagerConnection>(
            getInspectorInstance(),  // ← Global inspector
            "React Native Windows",
            delegate);
    m_fuseboxInspectorPackagerConnection->connect();
  });
}
```

**Key Insights**:

1. **DevSupportManager Provides Shared Services**:
   - Single WebSocket connection to Metro
   - Bundle downloading
   - Live reload coordination
   - BUT: Does NOT know about specific instances

2. **Association Happens Through Global Inspector**:
   ```
   RNH #1 → HostTarget #1 ──┐
   RNH #2 → HostTarget #2 ──┼─→ getInspectorInstance() ←─ InspectorPackagerConnection
   RNH #3 → HostTarget #3 ──┘     (Global Singleton)          (in DevSupportManager)
   ```

3. **Per-Instance State Lives in HostTarget**:
   - Each `ReactNativeHost` has its own `HostTarget`
   - Each `HostTarget` has its own delegate with instance-specific logic
   - When debugger connects to a page, it connects to that specific `HostTarget`

4. **Communication Flow**:
   ```
   Metro ←─ WebSocket ─→ InspectorPackagerConnection (singleton)
                                     ↓
                           getInspectorInstance() (global)
                                     ↓
                           Routes to specific HostTarget based on page ID
                                     ↓
                           HostTarget #N (per-instance)
                                     ↓
                           ReactNativeHost #N
   ```

**Why DevSupportManager Doesn't Track Instances**:

1. **Global Inspector Handles Routing**: The `IInspector` singleton already tracks all pages and routes messages
2. **Decoupling**: `DevSupportManager` doesn't need to know about React instances
3. **Matches iOS/Android**: Neither platform has dev support manager tracking instances

**What About EnsureHermesInspector?**

Looking at the current call:
```cpp
m_devManager->EnsureHermesInspector(sourceBundleHost, sourceBundlePort, bundleAppId);
```

This is called per-instance but uses `std::call_once` internally, so only the **first** call actually creates the connection. Subsequent calls from other instances do nothing.

**Potential Issue**: If different RNH instances want different `sourceBundleHost` or `sourceBundlePort`, only the first one wins!

**Recommendation for EnsureHermesInspector**:

```cpp
// Option 1: Remove per-instance call, make it truly global
class DevSupportManager {
 public:
  // Call once at app startup, not per-instance
  static void InitializeInspector(
      const std::string &packagerHost,
      const uint16_t packagerPort) {
    static std::once_flag once;
    std::call_once(once, [&]() {
      GetSharedDevManager()->createInspectorConnection(packagerHost, packagerPort);
    });
  }
};

// Option 2: Validate subsequent calls match initial settings
void DevSupportManager::EnsureHermesInspector(
    const std::string &packagerHost,
    const uint16_t packagerPort,
    const std::string &bundleAppId) {
  
  static std::once_flag once;
  static std::string initialHost;
  static uint16_t initialPort;
  
  std::call_once(once, [&]() {
    initialHost = packagerHost;
    initialPort = packagerPort;
    // Create connection...
  });
  
  // Warn if different instances use different settings
  if (packagerHost != initialHost || packagerPort != initialPort) {
    OutputDebugStringA("Warning: Multiple RNH instances with different packager settings!");
  }
}
```

**Summary**: DevSupportManager doesn't need to track RNH instances. The global `IInspector` handles routing, and each `HostTarget` maintains its own instance-specific state. The current architecture is fundamentally sound, but consider making packager settings truly global to avoid confusion.

## Architectural Recommendations Summary

Based on this analysis, here are the **confirmed correct design decisions**:

1. ✅ **ReactInspectorThread as Standalone Singleton**: Keep it separate from `DevSupportManager`
2. ✅ **Register Pages in Constructor**: `ReactNativeHost` constructor is the right place
3. ✅ **Unregister Pages in Destructor Only**: Pages survive instance reloads
4. ✅ **DevSupportManager Doesn't Track Instances**: Association happens through global `IInspector`

The **only potential improvement**:
- ⚠️ **Make packager settings truly global** or validate that all instances use the same settings

The current Windows implementation correctly follows iOS/Android patterns in all key areas!

## Multi-RNH Windows-Specific Considerations

### Overview

While iOS and Android typically support a single React instance per app, React Native Windows supports **multiple `ReactNativeHost` (RNH) instances simultaneously** within a single process. This is a **prime scenario** in Windows applications where you might embed multiple React Native views/windows.

This section addresses two critical questions unique to multi-RNH scenarios:
1. How does the packager service associate with specific RNH instances?
2. Can we debug RNH instances that load JavaScript from a bundle (not the packager)?

### Question 1: Packager Service Association with Specific RNH Instances

#### Current Architecture Analysis

```
Metro Packager (port 8081)
    ↓ (Single WebSocket)
InspectorPackagerConnection (Singleton)
    ↓ (Manages all pages)
getInspectorInstance() (Global)
    ├─ Page 1 (id: 1) → RNH #1 (bundleAppId: "app1")
    ├─ Page 2 (id: 2) → RNH #2 (bundleAppId: "app2")
    └─ Page 3 (id: 3) → RNH #3 (bundleAppId: "app3")
```

**Key Implementation Details**:

1. **Single WebSocket for All RNH Instances**:
   ```cpp
   // DevSupportManager.cpp - called with std::call_once
   m_fuseboxInspectorPackagerConnection = 
       std::make_unique<InspectorPackagerConnection>(
           getInspectorInstance(),  // Global inspector with ALL pages
           "React Native Windows",  // appName (shared by all)
           delegate);
   ```

2. **Page Registration** (per RNH):
   ```cpp
   // ReactNativeHost.cpp - each instance registers its own page
   m_inspectorPageId = getInspectorInstance().addPage(
       "React Native Windows (Experimental)",  // description
       "",  // vm
       connectFunc,
       capabilities);
   ```

3. **Metro's "getPages" Request Handling**:
   ```cpp
   // InspectorPackagerConnection.cpp
   void Impl::handleProxyMessage(folly::const_dynamic_view message) {
     if (event == "getPages") {
       sendToPackager(
           folly::dynamic::object("event", "getPages")("payload", pages()));
     }
   }
   
   folly::dynamic Impl::pages() {
     auto pages = getInspectorInstance().getPages();  // Gets ALL registered pages
     folly::dynamic array = folly::dynamic::array();
     
     for (const auto& page : pages) {
       folly::dynamic pageDescription = folly::dynamic::object;
       pageDescription["id"] = std::to_string(page.id);
       pageDescription["title"] = appName_ + " (" + deviceName_ + ")";  // ⚠️ SAME for all
       pageDescription["description"] = page.description + " [C++ connection]";
       pageDescription["app"] = appName_;  // ⚠️ SAME for all
       // ...
       array.push_back(pageDescription);
     }
     return array;
   }
   ```

4. **InspectorPageDescription Structure**:
   ```cpp
   // InspectorInterfaces.h
   struct InspectorPageDescription {
     const int id;                        // ✅ Unique per page
     const std::string description;       // ⚠️ Same for all Windows instances
     const std::string vm;                // Empty
     const InspectorTargetCapabilities capabilities;
   };
   ```

#### The Problem: Insufficient Page Differentiation

**Current State**: All RNH instances appear in Metro with:
- Different `id` (unique page IDs: 1, 2, 3...)
- **Same** `title`: "React Native Windows (Device Name)"
- **Same** `app`: "React Native Windows"
- **Same** `description`: "React Native Windows (Experimental) [C++ connection]"

**Example Metro Response**:
```json
{
  "event": "getPages",
  "payload": [
    {
      "id": "1",
      "title": "React Native Windows (DESKTOP-ABC)",
      "description": "React Native Windows (Experimental) [C++ connection]",
      "app": "React Native Windows"
    },
    {
      "id": "2",
      "title": "React Native Windows (DESKTOP-ABC)",  // ⚠️ Identical!
      "description": "React Native Windows (Experimental) [C++ connection]",  // ⚠️ Identical!
      "app": "React Native Windows"  // ⚠️ Identical!
    }
  ]
}
```

**Impact**: While Metro can technically route to the correct page using the unique `id`, **developers cannot distinguish between multiple instances** when looking at the debugger page list.

#### Why bundleAppId Isn't Visible to Metro

The `bundleAppId` configuration flows through the system but **never becomes part of the page metadata**:

```cpp
// ReactNativeHost.cpp
reactOptions.DeveloperSettings.BundleAppId = to_string(m_instanceSettings.BundleAppId());

// Used for bundle URLs like: http://localhost:8081/index.bundle?app=myapp
// But NOT exposed to inspector page descriptions
```

**Root Cause**: `InspectorPageDescription` doesn't include `HostTargetMetadata`, where per-instance information could be stored:

```cpp
// HostTarget.h - metadata is available but not exposed
struct HostTargetMetadata {
  std::optional<std::string> appDisplayName;
  std::optional<std::string> appIdentifier;
  std::optional<std::string> deviceName;
  std::string integrationName;  // Currently: "React Native Windows (Host)"
  std::optional<std::string> platform;
  std::optional<std::string> reactNativeVersion;
};
```

#### The Solution: Enhance Page Description with RNH-Specific Identifiers

**Recommendation 1**: Include instance-specific information in the page `description`:

```cpp
// ReactNativeHost.cpp - generate unique description per instance
std::string GeneratePageDescription() {
  std::string desc = "React Native Windows";
  
  // Option A: Use bundleAppId if available
  if (m_instanceSettings.BundleAppId()) {
    desc += " (" + to_string(m_instanceSettings.BundleAppId()) + ")";
  }
  
  // Option B: Use ReactNativeHost address as fallback
  else {
    std::ostringstream oss;
    oss << " (Host 0x" << std::hex << reinterpret_cast<uintptr_t>(this) << ")";
    desc += oss.str();
  }
  
  return desc;
}

// Use in addPage:
m_inspectorPageId = getInspectorInstance().addPage(
    GeneratePageDescription(),  // ✅ Now unique per instance
    "",
    connectFunc,
    capabilities);
```

**Result in Metro**:
```json
{
  "payload": [
    {
      "id": "1",
      "description": "React Native Windows (myapp) [C++ connection]",
      "app": "React Native Windows"
    },
    {
      "id": "2",
      "description": "React Native Windows (otherapp) [C++ connection]",
      "app": "React Native Windows"
    }
  ]
}
```

**Recommendation 2**: Enhance `HostTargetMetadata` with instance-specific data:

```cpp
// ReactNativeHost.cpp
facebook::react::jsinspector_modern::HostTargetMetadata getMetadata() override {
  auto host = m_reactNativeHost.get();
  return {
      .appDisplayName = host ? winrt::to_string(host.InstanceSettings().BundleAppId()) : std::nullopt,
      .integrationName = "React Native Windows (Host)",
      .platform = "windows",
      .reactNativeVersion = "0.76.0",  // From version constants
  };
}
```

While this metadata is used internally (passed to `HostAgent`), it's **not currently sent to Metro**. This would require enhancing the cross-platform `InspectorPageDescription` structure, which is outside Windows-specific changes.

**Recommendation 3**: Allow custom packager connection per RNH group:

For advanced scenarios where different RNH instances connect to **different Metro packagers**:

```cpp
// Extend DevSupportManager to support multiple connections
std::shared_ptr<InspectorPackagerConnection> GetOrCreatePackagerConnection(
    const std::string& host, 
    uint16_t port,
    const std::string& appName) {
  std::string key = host + ":" + std::to_string(port);
  
  auto it = m_packagerConnections.find(key);
  if (it != m_packagerConnections.end()) {
    return it->second;
  }
  
  auto connection = std::make_shared<InspectorPackagerConnection>(
      getInspectorInstance(),
      appName,  // Now per-connection
      delegate);
  
  m_packagerConnections[key] = connection;
  return connection;
}
```

**Summary for Question 1**:
- ✅ **Current routing works**: Metro routes by unique page ID
- ⚠️ **Developer experience issue**: Can't distinguish instances in debugger page list
- ✅ **Fix is straightforward**: Include `bundleAppId` or instance identifier in page description
- 🔧 **Recommended**: Implement unique descriptions in `ReactNativeHost::ReactNativeHost()`

### Question 2: Debugging RNH Instances with Bundled JavaScript

#### Architecture: Two Inspector Connection Types

The modern inspector supports **two modes of connection**:

**Mode 1: Metro Proxy (Development)**
```
Chrome DevTools → Metro Packager (ws://localhost:8081/inspector/device)
                      ↓
                  InspectorPackagerConnection
                      ↓
                  getInspectorInstance()
                      ↓
                  HostTarget → InstanceTarget → RuntimeTarget
```

**Mode 2: Direct CDP Connection (Development & Production)**
```
Chrome DevTools → Direct WebSocket (ws://localhost:8315)
                      ↓
                  getInspectorInstance()
                      ↓
                  HostTarget → InstanceTarget → RuntimeTarget
```

#### Can Bundled JS Be Debugged?

**Answer: YES** ✅

**Reasoning**:

1. **HostTarget Registration is Independent**:
   ```cpp
   // ReactNativeHost.cpp - happens regardless of bundle source
   if (inspectorFlags.getFuseboxEnabled()) {
     m_inspectorTarget = HostTarget::create(*m_inspectorHostDelegate, executor);
     m_inspectorPageId = getInspectorInstance().addPage(...);  // ✅ Always registers
   }
   ```
   
   Page registration happens in the `ReactNativeHost` constructor **before** JavaScript is loaded, and doesn't depend on where the JS comes from (packager vs bundle).

2. **InspectorPackagerConnection is Optional**:
   ```cpp
   // DevSupportManager.cpp
   void EnsureHermesInspector(...) {
     if (!m_fuseboxInspectorPackagerConnection) {
       m_fuseboxInspectorPackagerConnection = 
           std::make_unique<InspectorPackagerConnection>(...);
     }
   }
   ```
   
   `InspectorPackagerConnection` is only needed for **Metro-proxied debugging**. It's not required for:
   - Direct CDP connections
   - Local inspector functionality
   - Debugging bundled JS

3. **Direct CDP Server**:
   
   React Native Windows can expose a **direct CDP server** (enabled via `ReactInstanceSettings.UseDirectDebugger = true`):
   
   ```cpp
   // Creates a WebSocket server that accepts direct CDP connections
   // No Metro required!
   auto cdpServer = std::make_unique<CDPServer>(port);
   cdpServer->listen();
   ```
   
   This allows Chrome DevTools to connect directly via `chrome://inspect` → "Configure..." → `localhost:8315` without Metro involvement.

4. **getInspectorInstance() is Global**:
   
   The global inspector registry works regardless of:
   - JavaScript source (packager/bundle)
   - Metro connection status
   - Number of RNH instances
   
   ```cpp
   // Any CDP client can query and connect
   auto pages = getInspectorInstance().getPages();        // Get all debuggable pages
   auto connection = getInspectorInstance().connect(1, remote);  // Connect to page 1
   ```

#### Debugging Scenarios

| Scenario | Metro Connection | Can Debug? | How |
|----------|------------------|------------|-----|
| Development with Metro | Yes | ✅ Yes | `chrome://inspect` → Metro proxy |
| Development without Metro | No | ✅ Yes | Direct CDP server (`UseDirectDebugger`) |
| Production with bundle | No | ✅ Yes | Direct CDP server if enabled |
| Multiple RNH, mixed sources | Partial | ✅ Yes | Each RNH registers independently |

#### Practical Example: Debugging Bundled JS

```cpp
// App configuration
auto instanceSettings = ReactInstanceSettings();
instanceSettings.BundleRootPath(L"ms-appx:///Bundle/");  // Load from bundle
instanceSettings.JavaScriptBundleFile(L"index.windows");
instanceSettings.UseDirectDebugger(true);                 // ✅ Enable direct debugging
instanceSettings.DebuggerPort(8315);                      // Custom port

auto host = ReactNativeHost();
host.InstanceSettings(instanceSettings);
```

**Debugging Steps**:
1. App loads JavaScript from bundle (no Metro needed)
2. App creates `HostTarget` and registers with `getInspectorInstance()`
3. App starts direct CDP server on port 8315
4. Developer opens Chrome → `chrome://inspect`
5. Developer clicks "Configure..." → Adds `localhost:8315`
6. Developer sees "React Native Windows (bundled)" and clicks "inspect"
7. Chrome DevTools connects directly via CDP
8. ✅ **Full debugging works**: breakpoints, console, profiling, etc.

#### Limitations and Considerations

**Limitation 1: Live Reload Unavailable**

When loading from bundle:
- Metro live reload won't work (no Metro connection)
- Hot Module Replacement (HMR) unavailable
- Manual restart required for code changes

**Limitation 2: Source Maps**

Bundled JS requires source maps for readable debugging:

```cpp
// Ensure source maps are generated and accessible
instanceSettings.SourceBundleHost(L"localhost");
instanceSettings.SourceBundlePort(8081);  // For fetching source maps

// Or embed source maps in bundle:
// metro.config.js: { inlineSourceMap: true }
```

**Limitation 3: Security**

Production builds with debugging enabled:
- ⚠️ **Security risk**: Allows remote code execution
- ⚠️ **Performance impact**: Debugger overhead
- ✅ **Recommendation**: Disable in production releases or restrict to localhost only

**Best Practice**:
```cpp
#if _DEBUG
  instanceSettings.UseDirectDebugger(true);
#else
  instanceSettings.UseDirectDebugger(false);
#endif
```

#### Summary for Question 2:
- ✅ **Yes, bundled JS can be debugged**
- ✅ **InspectorPackagerConnection is optional** (only for Metro proxy)
- ✅ **Direct CDP connections work independently**
- ✅ **All RNH instances debuggable** regardless of JS source
- ⚠️ **Disable in production** for security
- 🔧 **Use `UseDirectDebugger = true`** for non-Metro debugging

## JavaScript Source Resolution: Bundle vs Packager

### Overview

A critical aspect of understanding React Native Windows debugging is knowing **how the system decides** whether to load JavaScript from a **local bundle file** or from the **Metro packager server**. This decision affects debugging availability and behavior.

### The Decision Logic

The choice between bundle file and packager is made in `InstanceImpl::loadBundleInternal()` based on **three conditions**:

```cpp
// From vnext/Shared/OInstance.cpp
void InstanceImpl::loadBundleInternal(std::string &&jsBundleRelativePath, bool synchronously) {
  if (m_devSettings->useWebDebugger ||           // ①
      m_devSettings->liveReloadCallback != nullptr ||  // ②
      m_devSettings->useFastRefresh) {           // ③
    
    // Load from PACKAGER SERVER
    LoadRemoteUrlScript(m_devSettings, m_devManager, std::move(jsBundleRelativePath), ...);
    
  } else {
    // Load from BUNDLE FILE
    auto bundleString = JsBigStringFromPath(m_devSettings, jsBundleRelativePath);
    m_innerInstance->loadScriptFromString(std::move(bundleString), ...);
  }
}
```

**JavaScript is loaded from the packager if ANY of these is true:**
1. ① **`UseWebDebugger = true`** - Remote debugging via browser
2. ② **Live Reload is enabled** - `UseLiveReload = true`
3. ③ **Fast Refresh is enabled** - `UseFastRefresh = true`

**JavaScript is loaded from a local bundle if ALL are false.**

### Configuration Mapping

The conditions map to `ReactInstanceSettings` properties:

```cpp
// ReactNativeHost.cpp - Settings flow to DevSettings
reactOptions.SetUseWebDebugger(m_instanceSettings.UseWebDebugger());
reactOptions.SetUseFastRefresh(m_instanceSettings.UseFastRefresh());
reactOptions.SetUseLiveReload(m_instanceSettings.UseLiveReload());
```

| Setting | Effect | Default |
|---------|--------|---------|
| `UseDeveloperSupport` | Enables dev menu, RedBox, enables conditions for packager | `false` |
| `UseWebDebugger` | ① Forces packager load, remote JS debugging | `false` |
| `UseFastRefresh` | ③ Forces packager load, enables Hot Module Replacement | `false` |
| `UseLiveReload` | ② Forces packager load, auto-reload on changes | `false` |
| `UseDirectDebugger` | Enables direct CDP server (works with either source) | `false` |

### Packager Loading: How It Works

When loading from packager, the system:

1. **Constructs Bundle URL**:
   ```cpp
   // URL format: http://{host}:{port}/{bundlePath}?platform=windows&dev=true&app={appId}
   auto bundleUrl = DevServerHelper::get_BundleUrl(
       devSettings->sourceBundleHost,      // Default: "localhost"
       devSettings->sourceBundlePort,      // Default: 8081
       jsBundleRelativePath,               // e.g., "index.windows"
       devSettings->platformName,          // "windows"
       devSettings->bundleAppId,           // From BundleAppId setting
       devSettings->devBundle,             // true for dev builds
       devSettings->useFastRefresh,
       devSettings->inlineSourceMap,
       hermesBytecodeVersion);
   ```

2. **Downloads JavaScript**:
   ```cpp
   auto [jsBundleString, success] = GetJavaScriptFromServer(...);
   ```
   
   Example request: `http://localhost:8081/index.windows.bundle?platform=windows&dev=true&app=myapp`

3. **Handles Hermes Bytecode** (if enabled):
   - Detects HBC magic number: `0xC61FC35`
   - Parses multi-module HBC format
   - Loads each module segment

4. **Loads Script**:
   ```cpp
   m_innerInstance->loadScriptFromString(script, bundleUrl, false);
   ```

### Bundle File Loading: How It Works

When loading from bundle file, the system:

1. **Resolves Bundle Path**:
   ```cpp
   // Path construction: {BundleRootPath}/{JavaScriptBundleFile}
   std::wstring bundlePath;
   
   if (devSettings->bundleRootPath.starts_with("resource://")) {
     // RCDATA embedded resource
     auto uri = Uri(to_hstring(bundleRootPath), to_hstring(jsBundleRelativePath));
     bundlePath = uri.ToString();
   } else {
     // File system path
     bundlePath = (fs::path(bundleRootPath) / (jsBundleRelativePath + ".bundle")).wstring();
   }
   ```

2. **Memory-Maps File**:
   ```cpp
   // Win32: Direct file mapping
   auto bundleString = FileMappingBigString::fromPath(bundlePath);
   
   // UWP: StorageFile access
   auto bundleString = StorageFileBigString(bundlePath);
   ```

3. **Loads Script**:
   ```cpp
   m_innerInstance->loadScriptFromString(bundleString, jsBundleRelativePath, synchronously);
   ```

### Common Configuration Scenarios

#### Scenario 1: Development with Metro (Typical)
```cpp
auto settings = ReactInstanceSettings();
settings.UseDeveloperSupport(true);      // Enable dev features
settings.UseFastRefresh(true);           // ③ Triggers packager load
settings.JavaScriptBundleFile(L"index.windows");
settings.SourceBundleHost(L"localhost");
settings.SourceBundlePort(8081);
```
**Result**: Loads from `http://localhost:8081/index.windows.bundle?platform=windows&dev=true`

#### Scenario 2: Production with Bundle
```cpp
auto settings = ReactInstanceSettings();
settings.UseDeveloperSupport(false);     // Disable dev features
settings.BundleRootPath(L"ms-appx:///Bundle/");
settings.JavaScriptBundleFile(L"index.windows");
```
**Result**: Loads from `ms-appx:///Bundle/index.windows.bundle` (embedded resource)

#### Scenario 3: Bundle with Direct Debugging
```cpp
auto settings = ReactInstanceSettings();
settings.UseDeveloperSupport(true);      // Enable dev menu
settings.UseFastRefresh(false);          // Don't force packager
settings.UseLiveReload(false);           // Don't force packager
settings.UseDirectDebugger(true);        // Enable CDP server
settings.BundleRootPath(L"C:\\App\\");
settings.JavaScriptBundleFile(L"index.windows");
```
**Result**: Loads from `C:\App\index.windows.bundle` + Direct debugging available

#### Scenario 4: Multiple RNH Instances from Different Sources
```cpp
// Instance 1: Development from Metro
auto settings1 = ReactInstanceSettings();
settings1.UseFastRefresh(true);
settings1.BundleAppId(L"app1");
auto host1 = ReactNativeHost();
host1.InstanceSettings(settings1);

// Instance 2: Production from bundle
auto settings2 = ReactInstanceSettings();
settings2.BundleRootPath(L"ms-appx:///Bundle/");
settings2.JavaScriptBundleFile(L"app2");
auto host2 = ReactNativeHost();
host2.InstanceSettings(settings2);
```
**Result**: 
- `host1` loads from packager: `http://localhost:8081/index.windows.bundle?app=app1`
- `host2` loads from bundle: `ms-appx:///Bundle/app2.bundle`
- Both can be debugged independently

### Impact on Debugging

| JavaScript Source | Modern Inspector (Fusebox) | Direct Debugger | Web Debugger |
|-------------------|------------------------------|-----------------|--------------|
| **Packager** | ✅ Full support | ✅ Works | ✅ Works |
| **Bundle File** | ✅ Full support | ✅ Works | ❌ Incompatible* |

*Web debugging requires packager because it loads JS into the browser's JavaScript engine instead of Hermes/Chakra.

**Key Insight**: Modern inspector (Fusebox) and direct debugging work with **either source** because they:
- Register `HostTarget` during `ReactNativeHost` construction (before JS loads)
- Connect to the actual runtime (Hermes/Chakra) via CDP
- Don't depend on where JavaScript came from

### Best Practices

1. **Development Workflow**:
   - Use `UseFastRefresh = true` for best developer experience
   - JavaScript automatically loads from Metro
   - Changes reflect immediately without full reload

2. **Testing Production Bundles**:
   - Set all packager triggers to `false`
   - Enable `UseDirectDebugger = true` for debugging
   - Test with actual bundle files to catch bundling issues

3. **Multi-Instance Apps**:
   - Use different `BundleAppId` values to distinguish instances in Metro
   - Each instance can use different sources independently
   - Consider which instances need hot reload vs stable bundles

4. **Conditional Configuration**:
   ```cpp
   #if _DEBUG
     settings.UseDeveloperSupport(true);
     settings.UseFastRefresh(true);
     settings.UseDirectDebugger(true);
   #else
     settings.UseDeveloperSupport(false);
     settings.BundleRootPath(L"ms-appx:///Bundle/");
   #endif
   ```

### Common Pitfalls

**Pitfall 1: Bundle Not Found**
```
Error: Cannot find bundle file at C:\App\index.windows.bundle
```
**Solution**: Ensure bundle is built and `BundleRootPath` is correct

**Pitfall 2: Packager Connection Failed**
```
Error: A connection with the server http://localhost:8081 could not be established
```
**Solution**: Start Metro (`npx react-native start`) or disable packager triggers

**Pitfall 3: Unexpected Packager Load**
```
// Intent: Load from bundle
settings.UseFastRefresh(true);  // ⚠️ This forces packager load!
settings.BundleRootPath(L"...");
```
**Solution**: Set `UseFastRefresh = false` to load from bundle

**Pitfall 4: Can't Debug Bundle**
```
// Intent: Debug bundled JS
settings.UseWebDebugger(true);  // ⚠️ Forces packager load + incompatible with bundle
```
**Solution**: Use `UseDirectDebugger = true` instead

## Multi-RNH Recommendations Summary

### For Multiple RNH Instances
1. ✅ **Current architecture is sound**: Global inspector + per-RNH HostTarget
2. 🔧 **Improve UX**: Add instance-specific identifiers to page descriptions
3. 🔧 **Use bundleAppId**: Include in description for Metro page list differentiation
4. ⚠️ **Validate packager settings**: Warn if multiple RNH instances use different Metro endpoints

### For Bundled/Offline Debugging
1. ✅ **Fully supported**: Use `UseDirectDebugger = true`
2. ✅ **No Metro required**: Direct CDP connections work
3. 🔧 **Configure chrome://inspect**: Add direct debugger port
4. ⚠️ **Security**: Disable in production builds

### DevSupportManager - Shared Singleton Pattern

**Question**: Is `DevSupportManager` a singleton per application?

**Answer**: **YES**. The implementation confirms this:

```cpp
// From vnext/Shared/InstanceManager.cpp
const std::shared_ptr<facebook::react::IDevSupportManager> &GetSharedDevManager() noexcept {
  static std::shared_ptr<facebook::react::IDevSupportManager> s_devManager(
      facebook::react::CreateDevSupportManager());
  return s_devManager;
}
```

This creates a **single shared instance** per process that is reused by all React instances. This matches the pattern where:
- Multiple `ReactNativeHost` instances can exist
- All share the same `DevSupportManager`
- The `DevSupportManager` contains the singleton `InspectorPackagerConnection`
- Only **one WebSocket connection** to Metro exists per app

### Inspector Architecture for Multiple Instances

The correct architecture for supporting multiple React instances is:

```
Metro Packager (Single)
    ↓ (Single WebSocket)
InspectorPackagerConnection (Singleton in DevSupportManager)
    ↓ (Communicates with)
IInspector Global Singleton (getInspectorInstance())
    ↓ (Manages multiple pages)
    ├─ Page 1: HostTarget #1 → ReactNativeHost #1 → React Instance #1
    ├─ Page 2: HostTarget #2 → ReactNativeHost #2 → React Instance #2
    └─ Page N: HostTarget #N → ReactNativeHost #N → React Instance #N
```

**Key Insight**: This architecture matches iOS and Android:

**iOS**:
- Multiple `RCTBridge` instances each create their own `HostTarget`
- All register with global `getInspectorInstance()`
- Typically one `InspectorPackagerConnection` per app (though technically per bridge, only one is active)
- Metro sees multiple pages from the same app

**Android**:
- Multiple `ReactInstanceManager` instances each create their own `ReactInstanceManagerInspectorTarget`
- All register with global `getInspectorInstance()`
- Single `InspectorPackagerConnection` per app
- Metro sees multiple pages from the same app

**Windows (Current)**:
- Multiple `ReactNativeHost` instances each create their own `HostTarget`
- All register with global `getInspectorInstance()`
- Single `InspectorPackagerConnection` in shared `DevSupportManager`
- Metro sees multiple pages from the same app

### Recommendation: HostTarget Association

**Question**: Should the inspector `HostTarget` be associated with `ReactNativeHost` or `DevSupportManager`?

**Answer**: **`HostTarget` should remain with `ReactNativeHost`** (current design is correct).

**Rationale**:

1. **One HostTarget per React Instance**: Each React instance needs its own `HostTarget` to represent it in the debugger. The `HostTarget` manages the instance and runtime registration.

2. **DevSupportManager is Shared Infrastructure**: The `DevSupportManager` provides **shared services** across all instances:
   - WebSocket connection (`InspectorPackagerConnection`)
   - Bundle downloading
   - Live reload coordination
   - But it doesn't represent any specific instance

3. **Matches iOS/Android Pattern**: 
   - iOS: Each `RCTBridge` owns its `HostTarget`
   - Android: Each `ReactInstanceManager` owns its `ReactInstanceManagerInspectorTarget`
   - Windows: Each `ReactNativeHost` owns its `HostTarget`

4. **Delegate Lifecycle**: The `HostTargetDelegate` needs access to instance-specific operations:
   - `onReload()` → Should reload the specific `ReactNativeHost`
   - `onSetPausedInDebuggerMessage()` → Should show overlay for the specific instance
   - `getMetadata()` → Should return metadata for the specific instance

5. **Multiple Pages in Debugger**: When you open Chrome DevTools and navigate to `chrome://inspect`, you should see **multiple pages** if you have multiple `ReactNativeHost` instances. Each page represents one instance and can be debugged independently.

**Current Implementation is Correct**:
```cpp
// Each ReactNativeHost creates its own HostTarget
ReactNativeHost::ReactNativeHost() {
  m_inspectorHostDelegate = std::make_shared<ModernInspectorHostTargetDelegate>(*this);
  m_inspectorTarget = HostTarget::create(*m_inspectorHostDelegate, executor);
  m_inspectorPageId = getInspectorInstance().addPage(...);
}
```

**DevSupportManager's Role**:
```cpp
// DevSupportManager creates the shared PackagerConnection
void DevSupportManager::EnsureHermesInspector(...) {
  if (!m_fuseboxInspectorPackagerConnection) {
    m_fuseboxInspectorPackagerConnection = 
        std::make_unique<InspectorPackagerConnection>(
            getInspectorInstance(),  // Global inspector with all pages
            "React Native Windows",
            delegate);
  }
}
```

### ReactInspectorThread - Singleton vs Per-Instance

**Question**: Should `ReactInspectorThread` be a singleton or per-`ReactNativeHost` dispatcher queue?

**Answer**: **Singleton is the correct design** for Windows, but with an important consideration.

**Analysis**:

#### Current Implementation
```cpp
// vnext/Shared/Inspector/ReactInspectorThread.h
class ReactInspectorThread {
 public:
  static Mso::DispatchQueue &Instance() {
    static Mso::DispatchQueue queue = Mso::DispatchQueue::MakeSerialQueue();
    return queue;
  }
};
```

This creates a **single serial dispatch queue** for all inspector operations across all `ReactNativeHost` instances.

#### Comparison with iOS/Android

| Platform | Inspector Thread | Notes |
|----------|------------------|-------|
| **iOS** | Main Queue (UI Thread) | All `RCTBridge` instances share the main queue for `HostTarget` operations |
| **Android** | UI Thread | All `ReactInstanceManager` instances share the UI thread for `HostTarget` operations |
| **Windows** | ReactInspectorThread (Singleton) | All `ReactNativeHost` instances share a dedicated serial queue |

#### Why Singleton is Correct

1. **Matches iOS/Android Pattern**: Both platforms use a **shared thread** (main/UI) for all inspector operations across multiple instances.

2. **InspectorPackagerConnection is Singleton**: Since there's one WebSocket connection handling messages for all pages, it makes sense that all `HostTarget` executors use the same thread for consistency.

3. **Thread Safety**: The global `IInspector` and `InspectorPackagerConnection` are designed to be thread-safe and coordinate multiple pages. Using a single executor thread simplifies synchronization.

4. **Simpler Mental Model**: All inspector callbacks (`onReload`, `onSetPausedInDebuggerMessage`) run on the same thread, making reasoning about execution order straightforward.

5. **Cross-Instance Coordination**: Operations that affect multiple instances (like Metro sending reload signal) can be coordinated on a single thread.

#### Important Consideration: UI Operations

There is one critical issue with the current implementation: **UI operations may not work correctly**.

The `HostTargetDelegate::onSetPausedInDebuggerMessage()` needs to show a "Paused in Debugger" overlay:

```cpp
void onSetPausedInDebuggerMessage(...) {
  DebuggerNotifications::OnShowDebuggerPausedOverlay(
      instanceSettings.Notifications(), 
      request.message.value(), 
      onResume);
}
```

Looking at the notification system:
```cpp
static void OnShowDebuggerPausedOverlay(
    IReactNotificationService const &service,
    std::string message,
    std::function<void()> onResume) {
  service.SendNotification(ShowDebuggerPausedOverlayEventName(), nullptr, nonAbiValue);
}
```

The notification system handles threading internally via the `IReactDispatcher` that subscribers provide:

```cpp
static IReactNotificationSubscription SubscribeShowDebuggerPausedOverlay(
    IReactNotificationService const &service,
    IReactDispatcher const &dispatcher,  // ← Subscriber provides dispatcher
    std::function<void(std::string, std::function<void()>)> showCallback,
    std::function<void()> hideCallback) {
  return service.Subscribe(
      ShowDebuggerPausedOverlayEventName(),
      dispatcher,  // ← Callback runs on this dispatcher
      callback);
}
```

**This is perfect!** The notification pattern means:
- Inspector delegate calls notification on ReactInspectorThread
- Notification service delivers to subscribers on their own dispatcher (typically UI dispatcher)
- UI components can safely update on UI thread

**Verdict**: The current singleton `ReactInspectorThread` design is **correct and optimal**.

#### Alternative Considered: Per-Instance Queue

Using a per-`ReactNativeHost` dispatcher queue would:
- ❌ Add unnecessary complexity
- ❌ Break the shared `InspectorPackagerConnection` model
- ❌ Make cross-instance coordination harder
- ❌ Diverge from iOS/Android patterns
- ❌ Provide no real benefits

The only potential benefit (thread isolation per instance) is not needed because:
- `HostTarget` operations are lightweight
- The notification system handles UI threading
- Multiple instances naturally coordinate through the global `IInspector`

### Architectural Recommendations

Based on this analysis, the **current architecture is fundamentally sound**:

1. ✅ **Keep HostTarget per ReactNativeHost** - Correctly represents each instance
2. ✅ **Keep DevSupportManager as singleton** - Correctly provides shared services
3. ✅ **Keep ReactInspectorThread as singleton** - Correctly matches iOS/Android pattern
4. ✅ **Keep InspectorPackagerConnection in DevSupportManager** - Correctly shares one WebSocket

The main work needed is:
- Remove the Fusebox experimental flag
- Verify multi-instance debugging works correctly
- Add tests for multiple `ReactNativeHost` scenarios
- Ensure proper cleanup when instances are destroyed

## Conclusion

React Native for Windows has a solid foundation for modern inspector integration that closely follows the iOS and Android patterns. The key components are in place:

✅ **HostTarget creation and management** (per `ReactNativeHost`)
✅ **HostTargetDelegate implementation** (per instance)
✅ **Inspector thread abstraction** (singleton, matches iOS/Android)
✅ **WebSocket adapter** (singleton via `DevSupportManager`)
✅ **Bridgeless architecture support**
✅ **Multi-instance architecture** (matches iOS/Android)

However, several areas need attention to achieve feature parity with iOS/Android:

⚠️ **Remove experimental flag** (Fusebox gate)
⚠️ **Add bridge-based architecture support**
⚠️ **Verify synchronous initialization**
⚠️ **Test multi-instance scenarios**
⚠️ **Improve thread safety in cleanup**

The architecture is well-designed with clean separation between:
- **ReactNativeHost**: Public API and per-instance management (owns `HostTarget`)
- **ReactHost**: Internal lifecycle and threading (per instance)
- **ReactInstanceWin**: Platform-specific implementation (per instance)
- **DevSupportManager**: Shared development services (singleton)
- **ReactInspectorThread**: Shared inspector operations (singleton)
- **InspectorPackagerConnection**: Shared Metro communication (singleton)

By following the recommendations above and conducting thorough testing, React Native for Windows can achieve full modern inspector support equivalent to iOS and Android platforms.
