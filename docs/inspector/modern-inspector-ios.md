# Modern Inspector Integration in React Native for iOS

## Overview

This document describes how the modern JavaScript debugger (called "inspector" throughout the codebase) is integrated into React Native for iOS. The inspector provides Chrome DevTools Protocol (CDP) support for debugging JavaScript execution in React Native apps.

## Core Architecture

### Key Components

The modern inspector follows a hierarchical Target-Agent-Session architecture defined in `ReactCommon/jsinspector-modern`:

1. **HostTarget** - Represents the top-level native host application
2. **InstanceTarget** - Represents a single React Native instance
3. **RuntimeTarget** - Represents a JavaScript runtime (e.g., Hermes, JSC)
4. **Session** - A connection between a debugger frontend and a target
5. **Agent** - Handles specific CDP domain messages (e.g., Runtime, Debugger)

### Inspector Interfaces

The core inspector interfaces are defined in `InspectorInterfaces.h`:

- **IInspector** - Singleton that tracks all debuggable pages/targets
- **ILocalConnection** - Allows client to send debugger messages to the VM
- **IRemoteConnection** - Allows VM to send debugger messages to the client
- **IPageStatusListener** - Receives notifications when pages are added/removed

## iOS-Specific Implementation

### 1. Inspector Wrapper Layer (`React/Inspector`)

iOS provides Objective-C++ wrappers around the C++ inspector interfaces:

#### `RCTInspector.h/mm`
- **Purpose**: Wraps the modern C++ inspector for use from Objective-C code
- **Key Classes**:
  - `RCTInspectorPage` - Represents a debuggable page (wraps `InspectorPageDescription`)
  - `RCTInspectorLocalConnection` - Wraps `ILocalConnection`
  - `RCTInspectorRemoteConnection` - Wraps `IRemoteConnection`
  - `RemoteConnection` (C++) - Bridges Objective-C remote connection to C++ interface

**Key Pattern**: The iOS implementation mirrors the Android implementation and serves as a simple bridge between Objective-C and the C++ inspector implementation.

```objc
@interface RCTInspector : NSObject
+ (NSArray<RCTInspectorPage *> *)pages;
+ (RCTInspectorLocalConnection *)connectPage:(NSInteger)pageId
                         forRemoteConnection:(RCTInspectorRemoteConnection *)remote;
@end
```

### 2. WebSocket Integration (`React/Inspector`)

The inspector communicates with the debugger frontend (typically Metro or Chrome DevTools) over WebSockets.

#### `RCTCxxInspectorPackagerConnection.h/mm`
- **Purpose**: Manages the WebSocket connection to the Metro bundler's inspector proxy
- **Implementation**: Wraps `InspectorPackagerConnection` (C++ class)
- **Key Methods**:
  - `initWithURL:` - Creates connection with device metadata
  - `connect` - Establishes WebSocket connection
  - `sendEventToAllConnections:` - Broadcasts events
  - `closeQuietly` - Closes connection without errors

#### `RCTCxxInspectorPackagerConnectionDelegate.mm`
- **Purpose**: Provides platform-specific implementations required by `InspectorPackagerConnection`
- **Key Responsibilities**:
  - **WebSocket Creation**: Creates `RCTCxxInspectorWebSocketAdapter` instances
  - **Async Scheduling**: Uses `dispatch_after` on the main queue for delayed callbacks

#### `RCTCxxInspectorWebSocketAdapter.mm`
- **Purpose**: Adapts iOS `SRWebSocket` (SocketRocket library) to the inspector's `IWebSocket` interface
- **Threading**: All WebSocket delegate callbacks run on the main queue (per SocketRocket's defaults)
- **Key Methods**:
  - `send:` - Dispatches messages to main queue for sending
  - `close` - Closes WebSocket with status code 1000
  - Implements `SRWebSocketDelegate` to forward events to C++ `IWebSocketDelegate`

### 3. Bridge Integration (`React/Base`)

#### `RCTBridge.mm` - HostTarget Integration

The main `RCTBridge` class creates and manages the `HostTarget`:

**Key Components**:

##### `RCTBridgeHostTargetDelegate`
A C++ class that implements `HostTargetDelegate` interface:

```objc++
class RCTBridgeHostTargetDelegate : public facebook::react::jsinspector_modern::HostTargetDelegate {
  // Provides metadata about the iOS app
  HostTargetMetadata getMetadata() override;
  
  // Handles page reload requests from debugger
  void onReload(const PageReloadRequest &request) override;
  
  // Shows/hides "Paused in Debugger" overlay
  void onSetPausedInDebuggerMessage(const OverlaySetPausedInDebuggerMessageRequest &request) override;
  
  // Handles Network.loadNetworkResource CDP requests
  void loadNetworkResource(const RCTInspectorLoadNetworkResourceRequest &params, 
                          RCTInspectorNetworkExecutor executor) override;
};
```

**Key Details**:
- Stores weak reference to `RCTBridge` to avoid retain cycles
- Manages `RCTPausedInDebuggerOverlayController` for debugger UI
- Manages `RCTInspectorNetworkHelper` for network inspection
- All delegate methods must run on the **main queue** (`RCTAssertMainQueue()`)

##### Inspector Lifecycle in RCTBridge

**Creation** (in `setUp` method):
```objc++
// Create the delegate
_inspectorHostDelegate = std::make_unique<RCTBridgeHostTargetDelegate>(self);

// Create the HostTarget with main queue executor
_inspectorTarget = HostTarget::create(*_inspectorHostDelegate, [](auto callback) {
  RCTExecuteOnMainQueue(^{
    callback();
  });
});

// Register the page with the global inspector
_inspectorPageId = getInspectorInstance().addPage(
    "React Native Bridge",
    /* vm */ "",
    [weakSelf](std::unique_ptr<IRemoteConnection> remote)
        -> std::unique_ptr<ILocalConnection> {
      RCTBridge *strongSelf = weakSelf;
      if (!strongSelf) {
        return nullptr;  // Reject connection if bridge is deallocating
      }
      return strongSelf->_inspectorTarget->connect(std::move(remote));
    },
    {.nativePageReloads = true, .prefersFuseboxFrontend = true}
);
```

**Destruction** (in `dealloc` method):
```objc++
if (_inspectorPageId.has_value()) {
  __block auto inspectorPageId = std::move(_inspectorPageId);
  __block auto inspectorTarget = std::move(_inspectorTarget);
  
  RCTExecuteOnMainQueue(^{
    // Unregister from global inspector
    getInspectorInstance().removePage(*inspectorPageId);
    inspectorPageId.reset();
    
    // Destroy inspector target on JS thread (if bridge still valid)
    if (batchedBridge) {
      [batchedBridge dispatchBlock:^{
        inspectorTarget.reset();
      } queue:RCTJSThread];
    } else {
      inspectorTarget.reset();
    }
  });
}
```

### 4. CxxBridge Integration (`React/CxxBridge`)

#### `RCTCxxBridge.mm` - Instance and Runtime Registration

The `RCTCxxBridge` manages the lower-level `Instance` (C++ React instance):

**Inspector Initialization Flow**:

1. **Main Thread** - Bridge start sequence:
   ```objc++
   // Capture parent bridge's HostTarget on main thread
   RCTAssertMainQueue();
   HostTarget *parentInspectorTarget = _parentBridge.inspectorTarget;
   ```

2. **JS Thread** - Initialize bridge with inspector:
   ```objc++
   [self ensureOnJavaScriptThread:^{
     [weakSelf _initializeBridge:executorFactory 
              parentInspectorTarget:parentInspectorTarget];
   }];
   ```

3. **JS Thread** - Create React instance and register with inspector:
   ```objc++
   - (void)_initializeBridgeLocked:(std::shared_ptr<JSExecutorFactory>)executorFactory
             parentInspectorTarget:(HostTarget *)parentInspectorTarget {
     _reactInstance->initializeBridge(
       std::make_unique<RCTInstanceCallback>(self),
       executorFactory,
       _jsMessageThread,
       [self _buildModuleRegistryUnlocked],
       parentInspectorTarget  // Pass HostTarget to C++ Instance
     );
   }
   ```

### 5. C++ Instance Registration (`ReactCommon/cxxreact`)

#### `Instance.cpp` - Synchronous Inspector Registration

The C++ `Instance` class registers itself with the `HostTarget`:

```cpp
void Instance::initializeBridge(
    std::unique_ptr<InstanceCallback> callback,
    std::shared_ptr<JSExecutorFactory> jsef,
    std::shared_ptr<MessageQueueThread> jsQueue,
    std::shared_ptr<ModuleRegistry> moduleRegistry,
    jsinspector_modern::HostTarget* parentInspectorTarget) {
  
  jsQueue->runOnQueueSync([this, &jsef, jsQueue]() mutable {
    nativeToJsBridge_ = std::make_shared<NativeToJsBridge>(...);
    
    if (parentInspectorTarget != nullptr) {
      auto inspectorExecutor = parentInspectorTarget->executorFromThis();
      
      // IMPORTANT: Wait for inspector initialization to complete synchronously
      std::mutex inspectorInitializedMutex;
      std::condition_variable inspectorInitializedCv;
      bool inspectorInitialized = false;
      
      // Schedule work on inspector thread (usually main queue)
      inspectorExecutor([this, &inspectorInitialized, &inspectorInitializedMutex, 
                        &inspectorInitializedCv](HostTarget& hostTarget) {
        // Register Instance as an InstanceTarget
        inspectorTarget_ = &hostTarget.registerInstance(*this);
        
        // Register Runtime with the InstanceTarget
        RuntimeExecutor runtimeExecutorIfJsi = getRuntimeExecutor();
        runtimeInspectorTarget_ = &inspectorTarget_->registerRuntime(
            nativeToJsBridge_->getInspectorTargetDelegate(),
            runtimeExecutorIfJsi ? runtimeExecutorIfJsi : [](auto) {}
        );
        
        // Signal completion
        {
          std::lock_guard lock(inspectorInitializedMutex);
          inspectorInitialized = true;
        }
        inspectorInitializedCv.notify_one();
      });
      
      // Wait for inspector initialization
      {
        std::unique_lock lock(inspectorInitializedMutex);
        inspectorInitializedCv.wait(lock, [&] { return inspectorInitialized; });
      }
    }
    
    // Initialize JavaScript runtime AFTER inspector is ready
    nativeToJsBridge_->initializeRuntime();
  });
}
```

**Key Details**:
- Inspector registration happens **synchronously** before JS runtime initialization
- Uses condition variable to wait for inspector thread to complete registration
- This ensures inspector is fully set up before any JavaScript executes
- On iOS, the inspector thread is the **main queue**

## Threading Model

### Critical Threading Requirements

The inspector has strict threading requirements that must be respected:

#### 1. Inspector Thread (Main Queue)
- **HostTarget** operations run on the main queue
- `HostTargetDelegate` methods (`onReload`, `onSetPausedInDebuggerMessage`) must be called on main queue
- `HostTarget::create()` receives a `VoidExecutor` that dispatches to main queue:
  ```objc++
  HostTarget::create(*_inspectorHostDelegate, [](auto callback) {
    RCTExecuteOnMainQueue(^{
      callback();
    });
  });
  ```

#### 2. JavaScript Thread
- **Instance** and **Runtime** operations run on the JS thread
- `RCTJSThread` is a custom dispatch queue: `"com.facebook.react.JavaScript"`
- JS thread is created early in bridge startup with:
  ```objc++
  _jsThread = [[NSThread alloc] initWithTarget:[self class] 
                                      selector:@selector(runRunLoop) 
                                        object:nil];
  _jsThread.name = RCTJSThreadName;
  _jsThread.qualityOfService = NSOperationQualityOfServiceUserInteractive;
  [_jsThread start];
  ```

#### 3. WebSocket Thread (Main Queue)
- WebSocket callbacks from `SRWebSocket` run on **main queue** (SocketRocket default)
- Messages are forwarded to C++ `IWebSocketDelegate` on same thread
- Sending messages dispatches to main queue:
  ```objc++
  - (void)send:(std::string_view)message {
    dispatch_async(dispatch_get_main_queue(), ^{
      [_webSocket sendString:messageStr error:NULL];
    });
  }
  ```

#### 4. Thread Transitions

**Main Queue → JS Thread**:
```objc++
[bridge dispatchBlock:^{
  // Code runs on JS thread
} queue:RCTJSThread];
```

**Any Thread → Main Queue**:
```objc++
RCTExecuteOnMainQueue(^{
  // Code runs on main queue
  // Executes immediately if already on main queue
});
```

**Inspector Thread → JS Thread** (via RuntimeExecutor):
```cpp
RuntimeExecutor runtimeExecutor = getRuntimeExecutor();
runtimeExecutor([](jsi::Runtime& runtime) {
  // Code runs on JS thread with access to JSI runtime
});
```

### Executor Pattern

The inspector uses a sophisticated executor pattern to manage cross-thread communication safely:

#### VoidExecutor
```cpp
using VoidExecutor = std::function<void(std::function<void()>&& callback)>;
```
Executes a callback on the appropriate thread without passing any parameters.

#### ScopedExecutor<Self>
```cpp
template <typename Self>
using ScopedExecutor = std::function<void(std::function<void(Self& self)>&& callback)>;
```
Executes a callback with a reference to `Self`, but only if `Self` is still alive.

**Key Feature**: Uses weak pointers to prevent calling callbacks on destroyed objects:
```cpp
template <typename Self>
ScopedExecutor<Self> makeScopedExecutor(
    std::shared_ptr<Self> self,
    VoidExecutor executor) {
  return [self = std::weak_ptr(self), executor](auto&& callback) {
    executor([self, callback = std::move(callback)]() {
      auto lockedSelf = self.lock();
      if (!lockedSelf) {
        return;  // Object destroyed, don't call callback
      }
      callback(*lockedSelf);
    });
  };
}
```

#### RuntimeExecutor
```cpp
using RuntimeExecutor = std::function<void(std::function<void(jsi::Runtime&)>&& callback)>;
```
Executes a callback on the JS thread with access to the `jsi::Runtime` object.

**On iOS**: Implemented by dispatching to the JS message queue thread.

### Thread Safety Guarantees

1. **HostTarget** lifetime managed on main queue
2. **InstanceTarget** and **RuntimeTarget** operations synchronized through executors
3. **IRemoteConnection** methods are thread-safe when using `InspectorPackagerConnection`
4. **WebSocket** send operations are thread-safe (dispatched to main queue internally)
5. **ScopedExecutor** prevents use-after-free by checking weak pointers

## Inspector Capabilities

The inspector exposes various capabilities through the `InspectorTargetCapabilities` struct:

```cpp
struct InspectorTargetCapabilities {
  bool nativePageReloads = false;         // Page can be reloaded from native code
  bool nativeSourceCodeFetching = false;  // Native can fetch source code
  bool prefersFuseboxFrontend = false;    // Prefers Fusebox debugger UI
};
```

On iOS, `RCTBridge` registers with:
```objc++
{.nativePageReloads = true, .prefersFuseboxFrontend = true}
```

## Key iOS-Specific Considerations

### 1. Synchronous Inspector Initialization
- iOS requires **synchronous** inspector registration before JS runtime initialization
- Uses condition variables to block JS thread until inspector is ready
- Ensures debugger can attach before any JavaScript executes

### 2. Main Queue Affinity
- `HostTarget` operations must run on main queue
- Bridge lifecycle (creation/destruction) happens on main queue
- WebSocket operations run on main queue

### 3. Bridge Lifecycle Management
- `RCTBridge` creates the `HostTarget`
- `RCTCxxBridge` manages the `Instance` which registers with the `HostTarget`
- Careful cleanup required: unregister on correct threads in correct order

### 4. Retain Cycle Prevention
- `RCTBridgeHostTargetDelegate` holds **weak** reference to `RCTBridge`
- Check weak pointer before using bridge in delegate methods

### 5. Conditional Compilation
Inspector code is only compiled when:
```objc++
#if RCT_DEV || RCT_REMOTE_PROFILE
// Inspector code here
#endif
```

### 6. Fusebox Support
iOS has preliminary support for "Fusebox" - the next-generation debugger:
```objc++
auto &inspectorFlags = InspectorFlags::getInstance();
if (inspectorFlags.getFuseboxEnabled() && !_inspectorPageId.has_value()) {
  // Create HostTarget and register page
}
```

## Integration Checklist for Windows

To integrate the modern inspector into React Native for Windows, you need to:

### Required Components

1. **HostTarget Creation**
   - Create a `HostTargetDelegate` implementation for Windows
   - Implement `getMetadata()`, `onReload()`, `onSetPausedInDebuggerMessage()`
   - Create `HostTarget` with appropriate executor for Windows UI thread

2. **WebSocket Support**
   - Implement `InspectorPackagerConnectionDelegate`
   - Provide WebSocket implementation (adapt Windows WebSocket APIs)
   - Implement `scheduleCallback()` for delayed execution on UI thread

3. **Bridge Integration**
   - Hook inspector into React Native Windows bridge/host equivalent
   - Register page with `getInspectorInstance().addPage()`
   - Pass `HostTarget*` down to C++ Instance initialization

4. **Instance Registration**
   - Ensure `Instance::initializeBridge()` receives parent `HostTarget*`
   - Verify synchronous registration on inspector thread
   - Register runtime with `InstanceTarget`

5. **Threading**
   - Define executor that dispatches to Windows UI thread
   - Ensure `HostTarget` operations run on UI thread
   - Verify JS thread safety for `RuntimeTarget` operations

6. **Lifecycle Management**
   - Properly unregister instances and runtimes on shutdown
   - Unregister page from global inspector
   - Destroy inspector targets on correct threads

### Key Files to Reference

**iOS Implementation**:
- `React/Inspector/RCTInspector.mm` - Basic wrapper pattern
- `React/Inspector/RCTCxxInspectorPackagerConnection.mm` - Connection management
- `React/Inspector/RCTCxxInspectorPackagerConnectionDelegate.mm` - Platform delegation
- `React/Inspector/RCTCxxInspectorWebSocketAdapter.mm` - WebSocket adaptation
- `React/Base/RCTBridge.mm` (lines 265-340, 390-430, 560-600) - HostTarget integration
- `React/CxxBridge/RCTCxxBridge.mm` (lines 430-530, 700-750) - Instance initialization

**Cross-Platform C++ Core**:
- `ReactCommon/jsinspector-modern/InspectorInterfaces.h` - Core interfaces
- `ReactCommon/jsinspector-modern/HostTarget.h/cpp` - HostTarget implementation
- `ReactCommon/jsinspector-modern/InstanceTarget.h/cpp` - InstanceTarget implementation
- `ReactCommon/jsinspector-modern/RuntimeTarget.h/cpp` - RuntimeTarget implementation
- `ReactCommon/jsinspector-modern/InspectorPackagerConnection.h` - Connection protocol
- `ReactCommon/jsinspector-modern/ScopedExecutor.h` - Executor patterns
- `ReactCommon/cxxreact/Instance.cpp` (lines 30-120) - Inspector registration

### Testing Strategy

1. Verify page appears in Chrome DevTools `chrome://inspect`
2. Test WebSocket connection establishment
3. Verify CDP message routing (Runtime, Debugger domains)
4. Test breakpoint setting and hitting
5. Verify console.log() messages appear in debugger
6. Test page reload from debugger
7. Verify clean shutdown without crashes
8. Test multiple connection/disconnection cycles

## Summary

The modern inspector integration in React Native for iOS follows a clean three-tier architecture:

1. **Objective-C++ Wrapper Layer** - Bridges C++ inspector to iOS code
2. **C++ Core Inspector** - Platform-agnostic CDP implementation
3. **Platform Delegates** - iOS-specific implementations (WebSockets, threading, UI)

The key insight for Windows integration is that most of the heavy lifting is done by the cross-platform C++ code. The platform-specific work primarily involves:
- WebSocket adaptation
- Threading/executor implementation
- UI thread integration
- Lifecycle management

By following the iOS patterns and respecting the threading requirements, React Native for Windows can achieve full modern inspector support.
