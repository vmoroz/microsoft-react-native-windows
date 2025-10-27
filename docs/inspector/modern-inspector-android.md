# Modern Inspector Integration in React Native for Android

## Overview

This document describes how the modern JavaScript debugger (called "inspector" throughout the codebase) is integrated into React Native for Android. The inspector provides Chrome DevTools Protocol (CDP) support for debugging JavaScript execution in React Native apps.

## Core Architecture

### Key Components

Like iOS, the Android implementation follows the hierarchical Target-Agent-Session architecture defined in `ReactCommon/jsinspector-modern`:

1. **HostTarget** - Represents the top-level native host application
2. **InstanceTarget** - Represents a single React Native instance
3. **RuntimeTarget** - Represents a JavaScript runtime (e.g., Hermes, JSC)
4. **Session** - A connection between a debugger frontend and a target
5. **Agent** - Handles specific CDP domain messages (e.g., Runtime, Debugger)

### Inspector Interfaces

The core inspector interfaces are shared between iOS and Android and defined in `InspectorInterfaces.h`:

- **IInspector** - Singleton that tracks all debuggable pages/targets
- **ILocalConnection** - Allows client to send debugger messages to the VM
- **IRemoteConnection** - Allows VM to send debugger messages to the client
- **IPageStatusListener** - Receives notifications when pages are added/removed

## Android-Specific Implementation

### 1. JNI Bridge Layer (`ReactAndroid/src/main/jni/react/jni`)

Android uses Java Native Interface (JNI) to bridge between Java/Kotlin code and the C++ inspector implementation.

#### `JInspector.h/cpp`
- **Purpose**: JNI wrapper around the C++ `IInspector` singleton
- **Key Classes**:
  - `JPage` - Java wrapper for `InspectorPageDescription`
  - `JRemoteConnection` - Java interface that wraps C++ `IRemoteConnection`
  - `JLocalConnection` - Hybrid class that wraps C++ `ILocalConnection`
  - `RemoteConnection` (C++) - Bridges Java remote connection to C++ interface

**Key Pattern**: Uses Facebook's `fbjni` library for type-safe JNI bindings.

```cpp
class JInspector : public jni::HybridClass<JInspector> {
 public:
  static jni::global_ref<JInspector::javaobject> instance(jni::alias_ref<jclass>);
  jni::local_ref<jni::JArrayClass<JPage::javaobject>> getPages();
  jni::local_ref<JLocalConnection::javaobject> connect(
      int pageId,
      jni::alias_ref<JRemoteConnection::javaobject> remote);
};
```

**Java Interface** (`Inspector.kt`):
```kotlin
class Inspector private constructor(private val mHybridData: HybridData) {
  private external fun getPagesNative(): Array<Page>
  private external fun connectNative(pageId: Int, remote: RemoteConnection): LocalConnection?
  
  interface RemoteConnection {
    fun onMessage(message: String)
    fun onDisconnect()
  }
  
  class LocalConnection private constructor(private val mHybridData: HybridData) {
    external fun sendMessage(message: String)
    external fun disconnect()
  }
  
  companion object {
    @JvmStatic fun getPages(): List<Page>
    @JvmStatic fun connect(pageId: Int, remote: RemoteConnection): LocalConnection
    @JvmStatic private external fun instance(): Inspector
  }
}
```

### 2. HostTarget Integration

Android provides two different implementations for creating and managing `HostTarget`, depending on the architecture:

#### A. Legacy Architecture - `ReactInstanceManagerInspectorTarget`

Used by the traditional bridge-based architecture with `ReactInstanceManager`.

**Java/Kotlin Class** (`ReactInstanceManagerInspectorTarget.kt`):
```kotlin
internal class ReactInstanceManagerInspectorTarget(delegate: TargetDelegate) : AutoCloseable {
  interface TargetDelegate {
    fun getMetadata(): Map<String, String>
    fun onReload()
    fun onSetPausedInDebuggerMessage(message: String?)
    fun loadNetworkResource(url: String, listener: InspectorNetworkRequestListener)
  }
  
  private val mHybridData: HybridData = initHybrid(
    Executor { command ->
      if (UiThreadUtil.isOnUiThread()) {
        command.run()
      } else {
        UiThreadUtil.runOnUiThread(command)
      }
    },
    delegate
  )
  
  external fun sendDebuggerResumeCommand()
}
```

**C++ JNI Implementation** (`ReactInstanceManagerInspectorTarget.cpp`):

```cpp
class ReactInstanceManagerInspectorTarget 
    : public jni::HybridClass<ReactInstanceManagerInspectorTarget>,
      public jsinspector_modern::HostTargetDelegate {
      
  ReactInstanceManagerInspectorTarget(
      jni::alias_ref<ReactInstanceManagerInspectorTarget::jhybridobject> jobj,
      jni::alias_ref<JExecutor::javaobject> javaExecutor,
      jni::alias_ref<ReactInstanceManagerInspectorTarget::TargetDelegate> delegate)
      : delegate_(make_global(delegate)),
        inspectorExecutor_([javaExecutor = SafeReleaseJniRef(make_global(javaExecutor))](
                               auto callback) mutable {
          auto jrunnable = JNativeRunnable::newObjectCxxArgs(std::move(callback));
          javaExecutor->execute(jrunnable);
        }) {
    
    auto& inspectorFlags = InspectorFlags::getInstance();
    
    if (inspectorFlags.getFuseboxEnabled()) {
      inspectorTarget_ = HostTarget::create(*this, inspectorExecutor_);
      
      inspectorPageId_ = getInspectorInstance().addPage(
          "React Native Bridge",
          /* vm */ "",
          [inspectorTarget = inspectorTarget_](std::unique_ptr<IRemoteConnection> remote)
              -> std::unique_ptr<ILocalConnection> {
            return inspectorTarget->connect(std::move(remote));
          },
          {.nativePageReloads = true, .prefersFuseboxFrontend = true});
    }
  }
  
  // Implements HostTargetDelegate methods by delegating to Java
  jsinspector_modern::HostTargetMetadata getMetadata() override;
  void onReload(const PageReloadRequest& request) override;
  void onSetPausedInDebuggerMessage(
      const OverlaySetPausedInDebuggerMessageRequest&) override;
  void loadNetworkResource(...) override;
};
```

**Key Details**:
- Uses `SafeReleaseJniRef` to safely hold Java objects across threads
- Executor dispatches to UI thread using the Java `Executor` interface
- Weak reference pattern to prevent memory leaks between C++ and Java

#### B. New Architecture - `JReactHostInspectorTarget`

Used by the bridgeless architecture with `ReactHost`.

**Java/Kotlin Class** (`ReactHostInspectorTarget.kt`):
```kotlin
internal class ReactHostInspectorTarget(reactHostImpl: ReactHostImpl) : Closeable {
  private val mHybridData: HybridData = 
      initHybrid(reactHostImpl, UIThreadConditionalSyncExecutor())
  
  private external fun initHybrid(
      reactHostImpl: ReactHostImpl, 
      executor: Executor
  ): HybridData
  
  external fun sendDebuggerResumeCommand()
  
  private class UIThreadConditionalSyncExecutor : Executor {
    override fun execute(command: Runnable) {
      if (UiThreadUtil.isOnUiThread()) {
        command.run()  // Execute immediately if already on UI thread
      } else {
        UiThreadUtil.runOnUiThread(command)
      }
    }
  }
}
```

**C++ JNI Implementation** (`JReactHostInspectorTarget.cpp`):

```cpp
class JReactHostInspectorTarget
    : public jni::HybridClass<JReactHostInspectorTarget>,
      public jsinspector_modern::HostTargetDelegate {
      
  JReactHostInspectorTarget(
      alias_ref<JReactHostImpl> reactHostImpl,
      alias_ref<JExecutor::javaobject> executor)
      : javaReactHostImpl_(make_global(makeJWeakReference(reactHostImpl))),
        inspectorExecutor_([javaExecutor = SafeReleaseJniRef(make_global(executor))](
                               std::function<void()>&& callback) mutable {
          auto jrunnable = JNativeRunnable::newObjectCxxArgs(std::move(callback));
          javaExecutor->execute(jrunnable);
        }) {
    
    auto& inspectorFlags = InspectorFlags::getInstance();
    if (inspectorFlags.getFuseboxEnabled()) {
      inspectorTarget_ = HostTarget::create(*this, inspectorExecutor_);
      
      inspectorPageId_ = getInspectorInstance().addPage(
          "React Native Bridgeless",
          /* vm */ "",
          [inspectorTargetWeak = std::weak_ptr(inspectorTarget_)](
              std::unique_ptr<IRemoteConnection> remote)
              -> std::unique_ptr<ILocalConnection> {
            if (auto inspectorTarget = inspectorTargetWeak.lock()) {
              return inspectorTarget->connect(std::move(remote));
            }
            return nullptr;  // Reject the connection
          },
          {.nativePageReloads = true, .prefersFuseboxFrontend = true});
    }
  }
  
  // HostTargetDelegate implementation delegates to Java ReactHostImpl methods
  jsinspector_modern::HostTargetMetadata getMetadata() override;
  void onReload(const PageReloadRequest& request) override;
  void onSetPausedInDebuggerMessage(...) override;
  void loadNetworkResource(...) override;
};
```

**Key Differences from Legacy**:
- Uses weak reference to `ReactHostImpl` to break reference cycles
- Uses `std::weak_ptr` for inspector target in connect callback
- Supports bridgeless architecture

### 3. Bridge Integration (`ReactInstanceManager` / `CatalystInstanceImpl`)

#### `ReactInstanceManager.java` - Legacy Architecture

The `ReactInstanceManager` creates and manages the inspector target:

```java
public class ReactInstanceManager {
  private @Nullable ReactInstanceManagerInspectorTarget mInspectorTarget;
  
  private static class InspectorTargetDelegateImpl 
      implements ReactInstanceManagerInspectorTarget.TargetDelegate {
    
    // Weak reference to break cycles between C++ HostTarget and Java ReactInstanceManager
    private WeakReference<ReactInstanceManager> mReactInstanceManagerWeak;
    
    @Override
    public Map<String, String> getMetadata() {
      return AndroidInfoHelpers.getInspectorHostMetadata(
          reactInstanceManager != null ? reactInstanceManager.mApplicationContext : null);
    }
    
    @Override
    public void onReload() {
      UiThreadUtil.runOnUiThread(() -> {
        ReactInstanceManager reactInstanceManager = mReactInstanceManagerWeak.get();
        if (reactInstanceManager != null) {
          reactInstanceManager.mDevSupportManager.handleReloadJS();
        }
      });
    }
    
    @Override
    public void onSetPausedInDebuggerMessage(@Nullable String message) {
      ReactInstanceManager reactInstanceManager = mReactInstanceManagerWeak.get();
      if (reactInstanceManager == null) return;
      
      if (message == null) {
        reactInstanceManager.mDevSupportManager.hidePausedInDebuggerOverlay();
      } else {
        reactInstanceManager.mDevSupportManager.showPausedInDebuggerOverlay(
            message,
            new PausedInDebuggerOverlayCommandListener() {
              @Override
              public void onResume() {
                if (reactInstanceManager.mInspectorTarget != null) {
                  reactInstanceManager.mInspectorTarget.sendDebuggerResumeCommand();
                }
              }
            });
      }
    }
    
    @Override
    public void loadNetworkResource(String url, InspectorNetworkRequestListener listener) {
      InspectorNetworkHelper.loadNetworkResource(url, listener);
    }
  }
  
  private @Nullable ReactInstanceManagerInspectorTarget getOrCreateInspectorTarget() {
    if (mInspectorTarget == null && InspectorFlags.getFuseboxEnabled()) {
      mInspectorTarget = 
          new ReactInstanceManagerInspectorTarget(new InspectorTargetDelegateImpl(this));
    }
    return mInspectorTarget;
  }
}
```

#### `CatalystInstanceImpl.java` - Bridge Initialization

```java
public class CatalystInstanceImpl implements CatalystInstance {
  private @Nullable ReactInstanceManagerInspectorTarget mInspectorTarget;
  
  private CatalystInstanceImpl(
      final ReactQueueConfigurationSpec reactQueueConfigurationSpec,
      final JavaScriptExecutor jsExecutor,
      final NativeModuleRegistry nativeModuleRegistry,
      final JSBundleLoader jsBundleLoader,
      JSExceptionHandler jSExceptionHandler,
      @Nullable ReactInstanceManagerInspectorTarget inspectorTarget) {
    
    mInspectorTarget = inspectorTarget;
    
    initializeBridge(
        new InstanceCallback(this),
        jsExecutor,
        mReactQueueConfiguration.getJSQueueThread(),
        mNativeModulesQueueThread,
        mNativeModuleRegistry.getJavaModules(this),
        mNativeModuleRegistry.getCxxModules(),
        mInspectorTarget);  // Pass inspector target to C++
  }
  
  private native void initializeBridge(
      InstanceCallback callback,
      JavaScriptExecutor jsExecutor,
      MessageQueueThread jsQueue,
      MessageQueueThread moduleQueue,
      Collection<JavaModuleWrapper> javaModules,
      Collection<ModuleHolder> cxxModules,
      @Nullable ReactInstanceManagerInspectorTarget inspectorTarget);
}
```

#### `CatalystInstanceImpl.cpp` - C++ Bridge Implementation

```cpp
void CatalystInstanceImpl::initializeBridge(
    jni::alias_ref<JInstanceCallback::javaobject> callback,
    JavaScriptExecutorHolder* jseh,
    jni::alias_ref<JavaMessageQueueThread::javaobject> jsQueue,
    jni::alias_ref<JavaMessageQueueThread::javaobject> nativeModulesQueue,
    jni::alias_ref<jni::JCollection<JavaModuleWrapper::javaobject>::javaobject> javaModules,
    jni::alias_ref<jni::JCollection<ModuleHolder::javaobject>::javaobject> cxxModules,
    jni::alias_ref<ReactInstanceManagerInspectorTarget::javaobject> inspectorTarget) {
  
  moduleMessageQueue_ = std::make_shared<JMessageQueueThread>(nativeModulesQueue);
  
  moduleRegistry_ = std::make_shared<ModuleRegistry>(
      buildNativeModuleList(
          std::weak_ptr<Instance>(instance_),
          javaModules,
          cxxModules,
          moduleMessageQueue_));
  
  // Pass inspector target pointer to C++ Instance
  instance_->initializeBridge(
      std::make_unique<InstanceCallbackImpl>(callback),
      jseh->getExecutorFactory(),
      std::make_unique<JMessageQueueThread>(jsQueue),
      moduleRegistry_,
      inspectorTarget != nullptr 
          ? inspectorTarget->cthis()->getInspectorTarget()
          : nullptr);
}
```

**Key Details**:
- `inspectorTarget->cthis()` extracts the C++ hybrid object from Java wrapper
- `getInspectorTarget()` returns raw pointer to `HostTarget*`
- Same `Instance::initializeBridge` flow as iOS (see iOS documentation)

### 4. WebSocket Integration

Android uses OkHttp for WebSocket communication instead of SocketRocket (iOS).

#### `CxxInspectorPackagerConnection.kt`
- **Purpose**: Kotlin wrapper around C++ `InspectorPackagerConnection`
- **WebSocket**: Uses OkHttp's `WebSocket` implementation
- **Threading**: Uses Android main thread handler (`Handler(Looper.getMainLooper())`)

**Key Implementation**:

```kotlin
internal class CxxInspectorPackagerConnection(
    url: String,
    deviceName: String,
    packageName: String
) : IInspectorPackagerConnection {
  
  private val mHybridData: HybridData
  
  init {
    mHybridData = initHybrid(url, deviceName, packageName, DelegateImpl())
  }
  
  external override fun connect()
  external override fun closeQuietly()
  external override fun sendEventToAllConnections(event: String?)
  
  private class DelegateImpl {
    private val httpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .writeTimeout(10, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MINUTES)  // Disable read timeouts
        .build()
    
    private val mHandler = Handler(Looper.getMainLooper())
    
    @DoNotStrip
    fun connectWebSocket(urlParam: String?, delegate: WebSocketDelegate): IWebSocket {
      val url = requireNotNull(urlParam)
      val request = Request.Builder().url(url).build()
      
      val webSocket = httpClient.newWebSocket(request, object : WebSocketListener() {
        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
          scheduleCallback({
            delegate.didFailWithError(null, t.message ?: "<Unknown error>")
            delegate.close()
          }, delayMs = 0)
        }
        
        override fun onMessage(webSocket: WebSocket, text: String) {
          scheduleCallback({ delegate.didReceiveMessage(text) }, delayMs = 0)
        }
        
        override fun onOpen(webSocket: WebSocket, response: Response) {
          scheduleCallback({ delegate.didOpen() }, delayMs = 0)
        }
        
        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
          scheduleCallback({
            delegate.didClose()
            delegate.close()
          }, delayMs = 0)
        }
      })
      
      return object : IWebSocket {
        override fun send(message: String) {
          webSocket.send(message)
        }
        
        override fun close() {
          webSocket.close(1000, "End of session")
        }
      }
    }
    
    @DoNotStrip
    fun scheduleCallback(runnable: Runnable, delayMs: Long) {
      mHandler.postDelayed(runnable, delayMs)
    }
  }
}
```

#### JNI WebSocket Adapter (`JCxxInspectorPackagerConnectionDelegateImpl.cpp`)

The C++ side creates a wrapper around the Java delegate:

```cpp
std::unique_ptr<IWebSocket>
JCxxInspectorPackagerConnectionDelegateImpl::connectWebSocket(
    const std::string& url,
    std::weak_ptr<IWebSocketDelegate> delegate) {
  
  using JWebSocket = JCxxInspectorPackagerConnectionWebSocket;
  using JWebSocketDelegate = JCxxInspectorPackagerConnectionWebSocketDelegate;
  
  static auto method = javaClassStatic()
      ->getMethod<alias_ref<JWebSocket::javaobject>(
          const std::string&, alias_ref<JWebSocketDelegate::javaobject>)>(
          "connectWebSocket");
  
  // Create Java WebSocketDelegate that wraps C++ delegate
  auto jWebSocket = method(
      self(), 
      url, 
      make_global(JWebSocketDelegate::newObjectCxxArgs(delegate)));
  
  return jWebSocket->wrapInUniquePtr();
}

void JCxxInspectorPackagerConnectionDelegateImpl::scheduleCallback(
    std::function<void(void)> callback,
    std::chrono::milliseconds delayMs) {
  
  static auto method = javaClassStatic()
      ->getMethod<void(alias_ref<JRunnable::javaobject>, jlong)>("scheduleCallback");
  
  method(
      self(),
      JNativeRunnable::newObjectCxxArgs(std::move(callback)),
      static_cast<jlong>(delayMs.count()));
}
```

**Key Details**:
- `JNativeRunnable` wraps C++ lambda for execution on Java thread
- All WebSocket events are scheduled on main thread via `Handler`
- `SafeReleaseJniRef` ensures safe cleanup across threads

## Threading Model

### Critical Threading Requirements

The Android inspector follows similar threading patterns to iOS but uses Android-specific threading primitives:

#### 1. UI Thread (Main Thread)
- **HostTarget** operations run on the UI thread
- `HostTargetDelegate` methods must be called on UI thread
- Android UI thread identified by `Looper.getMainLooper()`
- `HostTarget::create()` receives executor that dispatches to UI thread:
  ```kotlin
  Executor { command ->
    if (UiThreadUtil.isOnUiThread()) {
      command.run()  // Already on UI thread
    } else {
      UiThreadUtil.runOnUiThread(command)
    }
  }
  ```

#### 2. JavaScript Thread
- **Instance** and **Runtime** operations run on the JS thread
- Managed by `MessageQueueThread` abstraction
- Created during bridge initialization

#### 3. WebSocket Thread (Main Thread)
- OkHttp WebSocket callbacks run on the thread that created the OkHttpClient
- In practice, scheduled to run on main thread via `Handler(Looper.getMainLooper())`
- All messages dispatched to main thread with 0ms delay using `scheduleCallback()`

#### 4. Thread Transitions

**UI Thread → JS Thread**:
```java
// Via MessageQueueThread
jsQueue.runOnQueue(() -> {
  // Code runs on JS thread
});
```

**Any Thread → UI Thread**:
```kotlin
UiThreadUtil.runOnUiThread {
  // Code runs on UI thread
  // Executes immediately if already on UI thread
}
```

**Inspector Thread → JS Thread** (via RuntimeExecutor):
```cpp
RuntimeExecutor runtimeExecutor = getRuntimeExecutor();
runtimeExecutor([](jsi::Runtime& runtime) {
  // Code runs on JS thread with access to JSI runtime
});
```

### JNI Threading Considerations

Android's JNI adds additional threading complexities:

#### JNI Thread Attachment
- JNI requires threads to be attached to the JVM
- `jni::ThreadScope` ensures thread is attached for JNI calls
- Used in callbacks that may execute on arbitrary threads:

```cpp
void onBatchComplete() override {
  jni::ThreadScope guard;  // Attach thread to JVM
  static auto method = JInstanceCallback::javaClassStatic()
      ->getMethod<void()>("onBatchComplete");
  method(jobj_);
}
```

#### SafeReleaseJniRef
- Special wrapper for JNI global references that may be released on any thread
- Ensures proper cleanup of Java objects held by C++ code
- Used for executors that may be copied to arbitrary threads:

```cpp
inspectorExecutor_([javaExecutor = SafeReleaseJniRef(make_global(javaExecutor))](
                       auto callback) mutable {
  auto jrunnable = JNativeRunnable::newObjectCxxArgs(std::move(callback));
  javaExecutor->execute(jrunnable);
})
```

#### Weak References
- Java `WeakReference` used to break reference cycles
- Prevents memory leaks when C++ holds reference to Java object
- Example: `ReactInstanceManager` → `HostTarget` cycle

```java
private WeakReference<ReactInstanceManager> mReactInstanceManagerWeak;

@Override
public void onReload() {
  ReactInstanceManager reactInstanceManager = mReactInstanceManagerWeak.get();
  if (reactInstanceManager != null) {
    // Safe to use
  }
}
```

### Executor Pattern

Android uses the same executor pattern as iOS but with Android-specific implementations:

#### VoidExecutor
```cpp
using VoidExecutor = std::function<void(std::function<void()>&& callback)>;
```
Executes a callback on the appropriate thread (typically UI thread).

**Android Implementation**:
```cpp
VoidExecutor inspectorExecutor_ = [javaExecutor = SafeReleaseJniRef(make_global(javaExecutor))](
                                       auto callback) mutable {
  // Wrap C++ callback in Java Runnable
  auto jrunnable = JNativeRunnable::newObjectCxxArgs(std::move(callback));
  // Execute on UI thread via Java Executor
  javaExecutor->execute(jrunnable);
};
```

#### ScopedExecutor<Self>
Same as iOS - uses weak pointers to prevent calling callbacks on destroyed objects.

#### RuntimeExecutor
```cpp
using RuntimeExecutor = std::function<void(std::function<void(jsi::Runtime&)>&& callback)>;
```
Executes a callback on the JS thread with access to the `jsi::Runtime` object.

**On Android**: Implemented by dispatching to the JS message queue thread.

## Key Android-Specific Features

### 1. fbjni Integration
- Android uses Facebook's `fbjni` library for type-safe JNI bindings
- `HybridClass` template for C++ objects with Java wrappers
- Automatic reference counting and cleanup
- Type-safe method lookup and invocation

**Example**:
```cpp
class JInspector : public jni::HybridClass<JInspector> {
 public:
  static constexpr auto kJavaDescriptor = "Lcom/facebook/react/bridge/Inspector;";
  
  static void registerNatives() {
    javaClassStatic()->registerNatives({
        makeNativeMethod("instance", JInspector::instance),
        makeNativeMethod("getPagesNative", JInspector::getPages),
        makeNativeMethod("connectNative", JInspector::connect),
    });
  }
};
```

### 2. Proguard Annotations
- `@DoNotStrip` prevents proguard from removing JNI-accessed code
- `@DoNotStripAny` prevents stripping entire class and members
- Critical for release builds

```kotlin
@DoNotStrip
class Inspector private constructor(@Suppress("NoHungarianNotation") private val mHybridData: HybridData) {
  @DoNotStrip
  interface RemoteConnection {
    @DoNotStrip fun onMessage(message: String)
    @DoNotStrip fun onDisconnect()
  }
}
```

### 3. SoLoader Integration
- Native libraries loaded via Facebook's SoLoader
- Handles dependency resolution and loading
- Alternative to `System.loadLibrary()`

```kotlin
companion object {
  init {
    SoLoader.loadLibrary("react_devsupportjni")
  }
}
```

### 4. OkHttp for WebSockets
- Industry-standard HTTP client for Android
- Built-in WebSocket support
- Connection pooling and timeout configuration
- More robust than raw Java WebSocket APIs

### 5. Two Architecture Support
- Legacy: `ReactInstanceManager` + `CatalystInstanceImpl` (bridge-based)
- New: `ReactHost` + bridgeless architecture
- Both use same underlying inspector infrastructure
- Different Java APIs, same C++ core

## Comparison: Android vs iOS

### Similarities
1. **Same C++ Core**: Both use `ReactCommon/jsinspector-modern`
2. **Same Architecture**: HostTarget → InstanceTarget → RuntimeTarget
3. **Same Threading Model**: UI thread for host, JS thread for runtime
4. **Same Executor Pattern**: VoidExecutor, ScopedExecutor, RuntimeExecutor
5. **Same Capabilities**: Both support Fusebox, page reloads, network inspection

### Differences

| Aspect | Android | iOS |
|--------|---------|-----|
| **Language** | Java/Kotlin + JNI | Objective-C++ |
| **Bridge** | fbjni library | Direct C++ interop |
| **WebSocket** | OkHttp | SocketRocket |
| **UI Thread** | `UiThreadUtil` + `Handler` | `dispatch_async(dispatch_get_main_queue())` |
| **Reference Management** | `WeakReference` + `SafeReleaseJniRef` | `__weak` references |
| **Memory Safety** | JNI global refs + `HybridData` | ARC + manual C++ management |
| **Thread Attachment** | `jni::ThreadScope` for JVM | Not required |
| **Native Library Loading** | `SoLoader` | Static linking |
| **Architecture Support** | Legacy + Bridgeless | Bridge only (currently) |

### Threading Differences

**Android**:
```kotlin
// Conditional execution on UI thread
Executor { command ->
  if (UiThreadUtil.isOnUiThread()) {
    command.run()
  } else {
    UiThreadUtil.runOnUiThread(command)
  }
}
```

**iOS**:
```objc++
// Always dispatch async (even if already on main queue)
[](auto callback) {
  RCTExecuteOnMainQueue(^{
    callback();
  });
}
```

Android's approach is more efficient when already on the UI thread.

## Integration Checklist for Windows

Based on the Android implementation, React Native for Windows needs:

### Required Components

1. **HostTarget Creation**
   - Create a `HostTargetDelegate` implementation for Windows
   - Use Windows UI thread dispatcher (similar to `UiThreadUtil`)
   - Create `HostTarget` with appropriate executor

2. **JNI/C++/CLI Bridge** (if using managed code)
   - Implement bridge between C++/CLI or WinRT and C++ inspector
   - Handle reference counting and lifetime management
   - Ensure thread-safe cross-boundary calls

3. **WebSocket Support**
   - Implement `InspectorPackagerConnectionDelegate`
   - Use WinRT WebSocket APIs or similar
   - Implement `scheduleCallback()` for UI thread dispatch

4. **Bridge Integration**
   - Hook inspector into React Native Windows host
   - Register page with `getInspectorInstance().addPage()`
   - Pass `HostTarget*` to C++ Instance initialization

5. **Instance Registration**
   - Ensure `Instance::initializeBridge()` receives parent `HostTarget*`
   - Handle synchronous registration (same as iOS/Android)
   - Register runtime with `InstanceTarget`

6. **Threading**
   - Define executor that dispatches to Windows UI thread
   - Ensure `HostTarget` operations run on UI thread
   - Verify JS thread safety for `RuntimeTarget` operations

7. **Lifecycle Management**
   - Properly unregister instances and runtimes on shutdown
   - Unregister page from global inspector
   - Destroy inspector targets on correct threads
   - Handle weak references to prevent cycles

### Key Files to Reference

**Android Implementation**:
- `ReactAndroid/src/main/java/com/facebook/react/bridge/Inspector.kt` - Java wrapper
- `ReactAndroid/src/main/jni/react/jni/JInspector.cpp` - JNI bridge
- `ReactAndroid/src/main/java/com/facebook/react/bridge/ReactInstanceManagerInspectorTarget.kt` - Host target wrapper
- `ReactAndroid/src/main/jni/react/jni/ReactInstanceManagerInspectorTarget.cpp` - Host target implementation
- `ReactAndroid/src/main/java/com/facebook/react/devsupport/CxxInspectorPackagerConnection.kt` - WebSocket connection
- `ReactAndroid/src/main/jni/react/devsupport/JCxxInspectorPackagerConnectionDelegateImpl.cpp` - WebSocket delegate
- `ReactAndroid/src/main/jni/react/jni/CatalystInstanceImpl.cpp` - Bridge initialization

**Cross-Platform C++ Core**:
Same files as listed in iOS documentation.

### Windows-Specific Considerations

1. **Threading Model**
   - Use `Windows::UI::Core::CoreDispatcher` for UI thread
   - Or `winrt::apartment_context` for modern WinRT
   - Consider `std::future`/`std::promise` for synchronization

2. **Memory Management**
   - C++/WinRT uses reference counting
   - Handle COM reference cycles
   - Consider `winrt::weak_ref` for weak references

3. **WebSocket APIs**
   - WinRT `Windows::Networking::Sockets::MessageWebSocket`
   - Or use third-party library (e.g., Boost.Beast, WebSocket++)
   - Ensure callbacks run on correct thread

4. **Error Handling**
   - WinRT uses `winrt::hresult_error` exceptions
   - Map to C++ inspector error handling
   - Consider Platform::Exception for C++/CLI

## Summary

The React Native for Android inspector integration demonstrates:

1. **Robust JNI Bridge** - fbjni provides type-safe, maintainable C++/Java interop
2. **Dual Architecture Support** - Works with both legacy bridge and modern bridgeless
3. **Thread Safety** - Careful use of weak references, thread attachment, and safe ref wrappers
4. **Platform Integration** - Leverages Android platform APIs (OkHttp, Handler, Looper)

For Windows, the key insight is that the Android implementation provides a clear pattern for bridging between managed/native code boundaries while respecting the underlying C++ inspector architecture. The Windows implementation should follow similar patterns using Windows-specific APIs for threading, WebSockets, and memory management.
