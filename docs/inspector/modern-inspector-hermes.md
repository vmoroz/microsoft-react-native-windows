# Modern Inspector Integration with Hermes JavaScript Engine

## Overview

This document describes the interaction between the React Native modern inspector and the Hermes JavaScript engine. Understanding this integration is crucial for creating an ABI-stable API layer for Hermes on Windows, where direct access to Hermes C++ APIs is not possible.

## Table of Contents

1. [Core Concepts](#core-concepts)
2. [RuntimeTarget and RuntimeAgent Lifecycle](#runtimetarget-and-runtimeagent-lifecycle)
3. [FrontendChannel Architecture](#frontendchannel-architecture)
4. [Terminology: "Debugger" vs "Inspector"](#terminology-debugger-vs-inspector)
5. [Architecture Overview](#architecture-overview)
6. [Core Components](#core-components)
7. [Implementation Details](#implementation-details)

## Core Concepts

### RuntimeTarget vs RuntimeAgent

These are two **distinct** components with different lifetimes and purposes:

#### RuntimeTarget

**What it is**: Represents a **JavaScript runtime instance** (e.g., one Hermes VM).

**Lifetime**: 
- Created when JS runtime is initialized
- Lives as long as the JS runtime exists
- Destroyed when runtime is torn down (e.g., on reload)

**Ownership**: 
- Owned by `InstanceTarget` (via `std::shared_ptr`)
- One per React instance's JS runtime

**Key Responsibilities**:
- Install console handler in JS global scope
- Manage runtime-level debugging infrastructure
- Create `RuntimeAgent` instances for each debug session
- Notify agents when debugging sessions start/stop

#### RuntimeAgent

**What it is**: Represents a **debugging session** for a runtime.

**Lifetime**:
- Created when Chrome DevTools connects
- Lives as long as the debug session is active
- Destroyed when session disconnects
- **Multiple agents can exist** for the same `RuntimeTarget` (multiple debugger connections)

**Ownership**:
- Created by `RuntimeTarget::createAgent()`
- Owned by the session (via `std::shared_ptr`)
- Tracked by `RuntimeTarget` in a `WeakList<RuntimeAgent>`

**Key Responsibilities**:
- Handle CDP requests for a specific session
- Maintain session state (breakpoints, etc.)
- Communicate with frontend via `FrontendChannel`
- Delegate engine-specific work to `RuntimeAgentDelegate`

### Lifetime Relationship

```
ReactNativeHost (Windows-specific lifetime)
    ↓
ReactInstance (bridgeless) or Instance (bridge-based)
    ↓ creates/destroys on each reload
HermesRuntimeHolder (Windows-specific - recreated on reload)
    ↓ owns
HermesRuntime (jsi::Runtime - recreated on reload)
    ↓ 
HermesRuntimeTargetDelegate (recreated on reload)
    ↓ passed to
RuntimeTarget (recreated on reload)
    ↓ creates for each session
RuntimeAgent (session 1), RuntimeAgent (session 2), ...
    ↓ creates
HermesRuntimeAgentDelegate (session-specific)
```

**Key Insight**: When RNH reloads:
1. ✅ `ReactNativeHost` **survives** the reload
2. ❌ `HermesRuntimeHolder` is **destroyed and recreated**
3. ❌ `HermesRuntime` is **destroyed and recreated**
4. ❌ `HermesRuntimeTargetDelegate` is **destroyed and recreated**
5. ❌ `RuntimeTarget` is **destroyed and recreated**
6. ❌ `RuntimeAgent` instances are **destroyed and recreated** (sessions reconnect)

### Expected Lifetime Behavior

From iOS/Android implementation analysis:

```cpp
// In ReactInstance.cpp (cross-platform bridgeless)
void ReactInstance::initializeRuntime(...) {
  // Runtime created here
  
  if (parentInspectorTarget_) {
    parentInspectorTarget_->execute([this, ...](HostTarget& hostTarget) {
      // Register InstanceTarget (survives reloads)
      inspectorTarget_ = &hostTarget.registerInstance(*this);
      
      // Register RuntimeTarget (RECREATED on each reload)
      runtimeInspectorTarget_ = &inspectorTarget_->registerRuntime(
          runtime_->getRuntimeTargetDelegate(),  // HermesRuntimeTargetDelegate
          runtimeExecutor);
    });
  }
}

void ReactInstance::unregisterFromInspector() {
  if (inspectorTarget_) {
    // Unregister RuntimeTarget BEFORE destroying runtime
    inspectorTarget_->unregisterRuntime(*runtimeInspectorTarget_);
    
    // InstanceTarget remains registered (survives reload)
    // Only unregistered when ReactNativeHost is destroyed
  }
}
```

### Windows RNH Reload Sequence

**Current Windows behavior** (from your description):

1. **Reload triggered**
2. `HermesRuntimeHolder` destroyed
3. `HermesRuntime` destroyed
4. **Problem**: `RuntimeTarget` may still exist, holding reference to destroyed runtime
5. New `HermesRuntimeHolder` created
6. New `HermesRuntime` created
7. New `RuntimeTarget` should be created

**Correct sequence** (should match iOS/Android):

1. **Before destroying runtime**:
   ```cpp
   // In ReactInstanceWin::Uninitialize() or similar
   if (m_inspectorTarget && m_runtimeInspectorTarget) {
     m_inspectorTarget->unregisterRuntime(*m_runtimeInspectorTarget);
     m_runtimeInspectorTarget = nullptr;
   }
   ```

2. **Destroy old runtime**:
   ```cpp
   m_hermesRuntimeHolder.reset();  // Destroys Hermes runtime
   ```

3. **Create new runtime**:
   ```cpp
   m_hermesRuntimeHolder = std::make_shared<HermesRuntimeHolder>(...);
   ```

4. **Register new runtime**:
   ```cpp
   if (m_inspectorTarget) {
     auto& newRuntimeTarget = m_inspectorTarget->registerRuntime(
         m_hermesRuntimeHolder->getRuntimeTargetDelegate(),
         runtimeExecutor);
     m_runtimeInspectorTarget = &newRuntimeTarget;
   }
   ```

### Critical Constraint from React Native

From `RuntimeTarget.cpp`:

```cpp
RuntimeTarget::~RuntimeTarget() {
  // Agents are owned by the session, not by RuntimeTarget, but
  // they hold a RuntimeTarget& that we must guarantee is valid.
  assert(
      agents_.empty() &&
      "RuntimeAgent objects must be destroyed before their RuntimeTarget. "
      "Did you call InstanceTarget::unregisterRuntime()?");
}
```

**This means**: 
- ✅ You **MUST** call `unregisterRuntime()` before destroying the JS runtime
- ✅ This gives sessions a chance to disconnect gracefully
- ✅ `RuntimeAgent` instances will be destroyed before `RuntimeTarget`
- ❌ **Never** destroy the runtime while `RuntimeTarget` still exists

### Windows HermesRuntimeHolder Integration

**Current challenge**: `HermesRuntimeHolder` is recreated on reload, but `RuntimeTarget` needs careful coordination.

**Recommended pattern**:

```cpp
class HermesRuntimeHolder {
 public:
  HermesRuntimeHolder(...) {
    // Create Hermes runtime
    m_hermesRuntime = makeHermesRuntime(...);
    
    // Create runtime target delegate
    m_runtimeTargetDelegate = std::make_shared<HermesRuntimeTargetDelegate>(
        m_hermesRuntime);
  }
  
  ~HermesRuntimeHolder() {
    // RuntimeTarget will be unregistered by ReactInstanceWin BEFORE
    // HermesRuntimeHolder is destroyed
    
    // Destroy in reverse order
    m_runtimeTargetDelegate.reset();
    m_hermesRuntime.reset();
  }
  
  HermesRuntimeTargetDelegate& getRuntimeTargetDelegate() {
    return *m_runtimeTargetDelegate;
  }
  
 private:
  std::shared_ptr<jsi::Runtime> m_hermesRuntime;
  std::shared_ptr<HermesRuntimeTargetDelegate> m_runtimeTargetDelegate;
};
```

**In ReactInstanceWin**:

```cpp
class ReactInstanceWin {
 public:
  void Initialize() {
    // Create runtime holder
    m_hermesRuntimeHolder = std::make_shared<HermesRuntimeHolder>(...);
    
    // Register with inspector
    if (m_instanceInspectorTarget) {
      m_runtimeInspectorTarget = &m_instanceInspectorTarget->registerRuntime(
          m_hermesRuntimeHolder->getRuntimeTargetDelegate(),
          m_runtimeExecutor);
    }
  }
  
  void Reload() {
    // CRITICAL: Unregister BEFORE destroying runtime
    if (m_instanceInspectorTarget && m_runtimeInspectorTarget) {
      m_instanceInspectorTarget->unregisterRuntime(*m_runtimeInspectorTarget);
      m_runtimeInspectorTarget = nullptr;
    }
    
    // Now safe to destroy old runtime
    m_hermesRuntimeHolder.reset();
    
    // Create new runtime
    m_hermesRuntimeHolder = std::make_shared<HermesRuntimeHolder>(...);
    
    // Register new runtime
    if (m_instanceInspectorTarget) {
      m_runtimeInspectorTarget = &m_instanceInspectorTarget->registerRuntime(
          m_hermesRuntimeHolder->getRuntimeTargetDelegate(),
          m_runtimeExecutor);
    }
  }
  
  ~ReactInstanceWin() {
    // Unregister runtime before destruction
    if (m_instanceInspectorTarget && m_runtimeInspectorTarget) {
      m_instanceInspectorTarget->unregisterRuntime(*m_runtimeInspectorTarget);
    }
    
    // Now safe to destroy
    m_hermesRuntimeHolder.reset();
  }
  
 private:
  std::shared_ptr<HermesRuntimeHolder> m_hermesRuntimeHolder;
  InstanceTarget* m_instanceInspectorTarget{nullptr};  // Not owned
  RuntimeTarget* m_runtimeInspectorTarget{nullptr};    // Not owned
};
```

### Summary: Lifetime Expectations

| Component | Lifetime Scope | Recreated on Reload? | Owner |
|-----------|---------------|---------------------|--------|
| **ReactNativeHost** | Application lifetime | ❌ No | Application |
| **HostTarget** | ReactNativeHost lifetime | ❌ No | ReactNativeHost |
| **InstanceTarget** | ReactNativeHost lifetime | ❌ No | HostTarget |
| **ReactInstance** | Per-load (reload cycles) | ✅ Yes | ReactNativeHost |
| **HermesRuntimeHolder** | Per-load (reload cycles) | ✅ Yes | ReactInstance |
| **HermesRuntime** | Per-load (reload cycles) | ✅ Yes | HermesRuntimeHolder |
| **HermesRuntimeTargetDelegate** | Per-load (reload cycles) | ✅ Yes | HermesRuntimeHolder |
| **RuntimeTarget** | Per-load (reload cycles) | ✅ Yes | InstanceTarget |
| **RuntimeAgent** | Per debug session | ✅ Yes (session reconnects) | Session |
| **HermesRuntimeAgentDelegate** | Per debug session | ✅ Yes (session reconnects) | RuntimeAgent |

**Key Principle**: 
- Components that wrap the JS runtime (`HermesRuntimeHolder`, `RuntimeTarget`, delegates) are **recreated on each reload**
- Components that represent the host/instance level survive reloads
- Proper `unregisterRuntime()` call is **mandatory** before destroying the runtime

## FrontendChannel Architecture

### What is FrontendChannel?

`FrontendChannel` is a **callback function** used to send CDP messages (responses and events) from the inspector back to the debugging frontend (Chrome DevTools, VS Code, etc.).

**Type Signature**:
```cpp
namespace facebook::react::jsinspector_modern {

/**
 * A callback that can be used to send debugger messages (method responses and
 * events) to the frontend. The message must be a JSON-encoded string.
 * The callback may be called from any thread.
 */
using FrontendChannel = std::function<void(std::string_view messageJson)>;

} // namespace facebook::react::jsinspector_modern
```

### FrontendChannel vs ReactInspectorThread

**Question**: Is `FrontendChannel` the same as the `ReactInspectorThread` singleton dispatcher?

**Answer**: **No, they are different concepts with different purposes.**

#### FrontendChannel

- **Purpose**: Send CDP messages **from inspector → frontend**
- **Direction**: Outbound messages (responses/events)
- **Type**: `std::function<void(std::string_view)>` callback
- **Threading**: Can be called from **any thread** (thread-safe)
- **Lifetime**: Per debug session (each `RuntimeAgent` gets its own)
- **Implementation**: Wraps WebSocket send or other transport

#### ReactInspectorThread (Windows-specific)

- **Purpose**: Serialize inspector **control operations**
- **Direction**: Internal inspector coordination
- **Type**: `Mso::DispatchQueue` singleton
- **Threading**: Single serial queue for **all** inspector instances
- **Lifetime**: Process-wide singleton
- **Implementation**: Windows-specific executor for `HostTarget::create()`, etc.

### How FrontendChannel Works

```
Chrome DevTools
    ↑ (WebSocket)
    | FrontendChannel sends CDP messages here
InspectorPackagerConnection (Metro) or Direct CDP Server
    ↑ (FrontendChannel callback)
HostTarget Session
    ↑ (Creates FrontendChannel)
InstanceAgent
    ↑ (Forwards FrontendChannel)
RuntimeAgent
    ↑ (Forwards FrontendChannel)
HermesRuntimeAgentDelegate
    ↑ (Forwards FrontendChannel)
Hermes CDPAgent
    | Calls FrontendChannel("{ \"id\": 1, \"result\": {...} }")
    ↓
Frontend receives CDP message
```

### FrontendChannel Creation Flow

1. **Session connects** (Chrome DevTools → Metro/DirectDebugger → HostTarget)

2. **HostTarget creates session with FrontendChannel**:
   ```cpp
   // In HostTarget.cpp
   class HostTargetSession {
    public:
     explicit HostTargetSession(
         std::unique_ptr<IRemoteConnection> remote,
         ...) 
         : remote_(std::make_shared<RAIIRemoteConnection>(std::move(remote))),
           frontendChannel_(
               // Create FrontendChannel that sends via WebSocket
               [remoteWeak = std::weak_ptr(remote_)](std::string_view message) {
                 if (auto remote = remoteWeak.lock()) {
                   remote->onMessage(std::string(message));  // Send to frontend
                 }
               }),
           hostAgent_(frontendChannel_, ...) {}  // Pass to HostAgent
   };
   ```

3. **HostAgent forwards to InstanceAgent**:
   ```cpp
   auto instanceAgent = std::make_shared<InstanceAgent>(
       frontendChannel_,  // Same channel
       ...);
   ```

4. **InstanceAgent forwards to RuntimeAgent**:
   ```cpp
   auto runtimeAgent = std::make_shared<RuntimeAgent>(
       channel,  // Same channel
       ...);
   ```

5. **RuntimeAgent creates RuntimeAgentDelegate** (e.g., HermesRuntimeAgentDelegate):
   ```cpp
   delegate_.createAgentDelegate(
       channel,  // Same channel
       sessionState,
       ...);
   ```

6. **HermesRuntimeAgentDelegate creates Hermes CDPAgent**:
   ```cpp
   hermes_ = hermes::cdp::CDPAgent::create(
       executionContextID,
       cdpDebugAPI,
       runtimeTaskCallback,
       frontendChannel,  // Hermes will call this to send messages
       previousState);
   ```

### FrontendChannel Thread Safety

**Key Property**: `FrontendChannel` can be called from **any thread**.

**Why**: 
- Hermes CDPAgent may send messages from JS thread
- Some CDP events are triggered from background threads
- The transport (WebSocket) handles thread synchronization

**Example in InspectorPackagerConnection**:
```cpp
// InspectorPackagerConnection.cpp
class RemoteConnection : public IRemoteConnection {
  void onMessage(std::string message) override {
    // This may be called from ANY thread
    // InspectorPackagerConnection handles synchronization
    webSocket_->send(message);
  }
};
```

### FrontendChannel in Windows Integration

**Your Windows implementation** should:

1. **Create FrontendChannel in session**:
   ```cpp
   // When session connects
   auto frontendChannel = [weakWebSocket = std::weak_ptr(webSocket_)](
       std::string_view messageJson) {
     if (auto ws = weakWebSocket.lock()) {
       ws->send(std::string(messageJson));  // Send to Metro or Chrome
     }
   };
   ```

2. **Pass to HermesRuntimeAgentDelegate**:
   ```cpp
   auto hermesAgentDelegate = std::make_unique<HermesRuntimeAgentDelegate>(
       frontendChannel,  // Hermes will use this to respond
       sessionState,
       previousState,
       executionContextDescription,
       hermesRuntime,
       runtimeTargetDelegate,
       runtimeExecutor);
   ```

3. **Hermes calls it to send CDP messages**:
   ```cpp
   // Inside Hermes CDPAgent
   frontendChannel(R"({"id": 1, "result": {"breakpointId": "1:10:0"}})");
   ```

### Relationship to ReactInspectorThread

**ReactInspectorThread** is used for:
- ✅ `HostTarget::create()` executor parameter
- ✅ Serializing inspector infrastructure operations
- ✅ Ensuring inspector control flow is single-threaded

**FrontendChannel** is used for:
- ✅ Sending CDP messages to frontend
- ✅ Per-session communication
- ✅ Can be called from any thread

**They are complementary**, not the same:

```cpp
// ReactInspectorThread: For inspector infrastructure
auto inspectorThread = ReactInspectorThread::Instance();
m_inspectorTarget = HostTarget::create(
    *m_inspectorHostDelegate,
    [](std::function<void()>&& callback) {
      // Use ReactInspectorThread for control operations
      ReactInspectorThread::Instance().Post(std::move(callback));
    });

// FrontendChannel: For sending CDP messages to Chrome
auto frontendChannel = [webSocket](std::string_view msg) {
  webSocket->send(std::string(msg));  // To frontend
};
auto runtimeAgent = runtimeTarget.createAgent(frontendChannel, sessionState);
```

### Summary: FrontendChannel vs ReactInspectorThread

| Aspect | FrontendChannel | ReactInspectorThread |
|--------|----------------|---------------------|
| **Purpose** | Send CDP messages to frontend | Serialize inspector operations |
| **Direction** | Outbound (inspector → frontend) | Internal (infrastructure coordination) |
| **Lifetime** | Per session | Process singleton |
| **Threading** | Can be called from any thread | Single serial queue |
| **Usage** | Communication with debugger | Inspector infrastructure setup |
| **Type** | `std::function<void(std::string_view)>` | `Mso::DispatchQueue` |
| **Example** | `frontendChannel("{\"result\": {}}")` | `inspectorThread.Post([]() { ... })` |

## Terminology: "Debugger" vs "Inspector"

**Question**: What is the difference between "debugger" and "inspector"?

**Answer**: In the React Native and Chrome DevTools Protocol context:

- **Inspector** - The broader system that tracks and manages debuggable targets (pages/runtimes), handles connections, routes CDP messages, and provides the infrastructure for debugging. This includes:
  - The inspector singleton (`IInspector`)
  - Host/Instance/Runtime targets
  - Session management
  - Message routing
  
- **Debugger** - Specifically refers to the debugging functionality of a JavaScript engine:
  - Setting breakpoints
  - Stepping through code
  - Evaluating expressions in paused state
  - Stack inspection
  - The actual CDP Debugger domain implementation

In Hermes specifically:
- **CDPDebugAPI** - Hermes's API for console messages and debugging infrastructure
- **CDPAgent** - Hermes's implementation of CDP message handling
- **Debugger** - Hermes's internal debugger (breakpoints, stepping, etc.)

**Recommendation**: For your ABI-stable API, `hermes_inspector_vtable` would be more accurate than `hermes_debugger_vtable` because:
1. It includes more than just debugging (console, profiling, CDP handling)
2. It aligns with React Native's terminology (RuntimeTargetDelegate, RuntimeAgentDelegate)
3. It's the interface between RN inspector and Hermes, not just the debugger

However, `hermes_debugger_vtable` is also acceptable and commonly used in the industry. The current Hermes API uses "CDPDebugAPI" which contains both debugging and console functionality.

## Architecture Overview

### Two-Layer Integration

The Hermes-Inspector integration has two conceptual layers:

1. **Modern Inspector Layer** (React Native side)
   - Location: `ReactCommon/hermes/inspector-modern/chrome/`
   - Classes: `HermesRuntimeTargetDelegate`, `HermesRuntimeAgentDelegate`
   - Purpose: Adapts Hermes to React Native's modern inspector architecture
   - Language: C++ (React Native code)

2. **Hermes CDP Layer** (Hermes engine side)
   - Location: Hermes SDK headers (`hermes/cdp/`, `hermes/inspector/`)
   - Classes: `CDPDebugAPI`, `CDPAgent`, `CDPHandler`
   - Purpose: Hermes's native Chrome DevTools Protocol implementation
   - Language: C++ (Hermes engine code)

### Key Integration Points

```
React Native Inspector (jsinspector-modern)
    ↓
HermesRuntimeTargetDelegate (RuntimeTargetDelegate implementation)
    ↓
HermesRuntimeAgentDelegate (RuntimeAgentDelegate implementation)
    ↓
Hermes CDPAgent (CDP message handler)
    ↓
Hermes CDPDebugAPI (Debugger + Console API)
    ↓
Hermes Runtime (JavaScript engine)
```

## Core Components

### 1. HermesRuntimeTargetDelegate

**File**: `ReactCommon/hermes/inspector-modern/chrome/HermesRuntimeTargetDelegate.h/cpp`

**Purpose**: Implements `RuntimeTargetDelegate` interface to enable React Native to debug a Hermes runtime.

**Key Responsibilities**:
1. Create agent delegates for CDP sessions
2. Handle console messages
3. Capture stack traces
4. Enable/disable sampling profiler
5. Provide access to `CDPDebugAPI`

**Core API**:

```cpp
class HermesRuntimeTargetDelegate : public RuntimeTargetDelegate {
 public:
  explicit HermesRuntimeTargetDelegate(
      std::shared_ptr<hermes::HermesRuntime> hermesRuntime);
  
  // Create agent for a CDP session
  std::unique_ptr<RuntimeAgentDelegate> createAgentDelegate(
      FrontendChannel frontendChannel,
      SessionState& sessionState,
      std::unique_ptr<RuntimeAgentDelegate::ExportedState> previouslyExportedState,
      const ExecutionContextDescription& executionContextDescription,
      RuntimeExecutor runtimeExecutor) override;
  
  // Console API integration
  void addConsoleMessage(jsi::Runtime& runtime, ConsoleMessage message) override;
  bool supportsConsole() const override;
  
  // Stack trace capture
  std::unique_ptr<StackTrace> captureStackTrace(
      jsi::Runtime& runtime,
      size_t framesToSkip) override;
  
  // Profiling support
  void enableSamplingProfiler() override;
  void disableSamplingProfiler() override;
  tracing::RuntimeSamplingProfile collectSamplingProfile() override;
  
  // Access to Hermes CDP API (when HERMES_ENABLE_DEBUGGER is defined)
  hermes::cdp::CDPDebugAPI& getCDPDebugAPI();
};
```

**Implementation Details**:

The implementation uses the **Private Implementation (pimpl) idiom** to hide Hermes CDP dependencies:

```cpp
class HermesRuntimeTargetDelegate::Impl final : public RuntimeTargetDelegate {
 public:
  explicit Impl(
      HermesRuntimeTargetDelegate& delegate,
      std::shared_ptr<HermesRuntime> hermesRuntime)
      : delegate_(delegate),
        runtime_(hermesRuntime),
        cdpDebugAPI_(CDPDebugAPI::create(*runtime_)),  // Create Hermes CDP API
        samplingProfileDelegate_(...) {}
  
  CDPDebugAPI& getCDPDebugAPI() {
    return *cdpDebugAPI_;
  }
  
 private:
  HermesRuntimeTargetDelegate& delegate_;
  std::shared_ptr<HermesRuntime> runtime_;
  const std::unique_ptr<CDPDebugAPI> cdpDebugAPI_;  // Hermes CDP interface
  std::unique_ptr<HermesRuntimeSamplingProfileDelegate> samplingProfileDelegate_;
};
```

**Why pimpl?**
- The public header can be included without `HERMES_ENABLE_DEBUGGER` defined
- Callers don't need to know about Hermes CDP types
- Same binary layout regardless of build configuration

### 2. HermesRuntimeAgentDelegate

**File**: `ReactCommon/hermes/inspector-modern/chrome/HermesRuntimeAgentDelegate.h/cpp`

**Purpose**: Implements `RuntimeAgentDelegate` to handle CDP requests for a specific Hermes debugging session.

**Key Responsibilities**:
1. Create and manage Hermes `CDPAgent`
2. Route CDP messages to Hermes
3. Maintain session state
4. Enable Runtime and Debugger CDP domains

**Core API**:

```cpp
class HermesRuntimeAgentDelegate : public RuntimeAgentDelegate {
 public:
  HermesRuntimeAgentDelegate(
      FrontendChannel frontendChannel,
      SessionState& sessionState,
      std::unique_ptr<RuntimeAgentDelegate::ExportedState> previouslyExportedState,
      const ExecutionContextDescription& executionContextDescription,
      hermes::HermesRuntime& runtime,
      HermesRuntimeTargetDelegate& runtimeTargetDelegate,
      RuntimeExecutor runtimeExecutor);
  
  // Handle CDP request
  bool handleRequest(const cdp::PreparsedRequest& req) override;
  
  // Export state for session persistence
  std::unique_ptr<RuntimeAgentDelegate::ExportedState> getExportedState() override;
};
```

**Implementation Details**:

```cpp
class HermesRuntimeAgentDelegate::Impl final : public RuntimeAgentDelegate {
  using HermesState = hermes::cdp::State;
  
 public:
  Impl(
      FrontendChannel frontendChannel,
      SessionState& sessionState,
      std::unique_ptr<RuntimeAgentDelegate::ExportedState> previouslyExportedState,
      const ExecutionContextDescription& executionContextDescription,
      HermesRuntime& runtime,
      HermesRuntimeTargetDelegate& runtimeTargetDelegate,
      const RuntimeExecutor& runtimeExecutor)
      : hermes_(hermes::cdp::CDPAgent::create(
            executionContextDescription.id,
            runtimeTargetDelegate.getCDPDebugAPI(),
            // Convert RuntimeExecutor to Hermes RuntimeTask callback
            [runtimeExecutor, &runtime](facebook::hermes::debugger::RuntimeTask fn) {
              runtimeExecutor([&runtime, fn = std::move(fn)](auto&) { 
                fn(runtime); 
              });
            },
            frontendChannel,
            HermesStateWrapper::unwrapDestructively(previouslyExportedState.get()))) {
    
    // Enable domains based on session state
    if (sessionState.isRuntimeDomainEnabled) {
      hermes_->enableRuntimeDomain();
    }
    if (sessionState.isDebuggerDomainEnabled) {
      hermes_->enableDebuggerDomain();
    }
  }
  
  bool handleRequest(const cdp::PreparsedRequest& req) override {
    if (req.method.rfind("Log.", 0) == 0) {
      // Log domain handled by HostAgent, not Hermes
      return false;
    }
    // Forward everything else to Hermes's CDPAgent
    hermes_->handleCommand(req.toJson());
    return true;
  }
  
 private:
  std::unique_ptr<hermes::cdp::CDPAgent> hermes_;  // Hermes CDP agent
};
```

**Key Points**:
- Creates Hermes `CDPAgent` with execution context ID
- Converts React Native's `RuntimeExecutor` to Hermes's `RuntimeTask` callback
- Forwards CDP messages to Hermes (except Log domain)
- Enables Runtime and Debugger domains based on session state

## Hermes CDP API Layer

### CDPDebugAPI (Hermes SDK)

**Purpose**: Provides high-level debugging and console API for Hermes.

**Key Functions** (based on usage in RN):
```cpp
namespace facebook::hermes::cdp {

class CDPDebugAPI {
 public:
  // Factory method
  static std::unique_ptr<CDPDebugAPI> create(HermesRuntime& runtime);
  
  // Add console message to the debugger
  void addConsoleMessage(ConsoleMessage message);
  
  // Get debugger for stack trace capture
  debugger::Debugger& getDebugger();
};

// Console message structure
struct ConsoleMessage {
  double timestamp;
  ConsoleAPIType type;  // log, error, warn, etc.
  std::vector<jsi::Value> args;
  debugger::StackTrace stackTrace;
};

enum class ConsoleAPIType {
  kLog,
  kDebug,
  kInfo,
  kError,
  kWarning,
  kDir,
  kDirXML,
  kTable,
  kTrace,
  kStartGroup,
  kStartGroupCollapsed,
  kEndGroup,
  kClear,
  kAssert,
  kTimeEnd,
  kCount
};

} // namespace facebook::hermes::cdp
```

### CDPAgent (Hermes SDK)

**Purpose**: Handles Chrome DevTools Protocol messages for Hermes.

**Key Functions**:
```cpp
namespace facebook::hermes::cdp {

class CDPAgent {
 public:
  // Factory method
  static std::unique_ptr<CDPAgent> create(
      int32_t executionContextID,
      CDPDebugAPI& cdpDebugAPI,
      std::function<void(debugger::RuntimeTask)> runtimeTaskCallback,
      FrontendChannel frontendChannel,
      State state = {});
  
  // Handle CDP command
  void handleCommand(const std::string& json);
  
  // Enable CDP domains
  void enableRuntimeDomain();
  void enableDebuggerDomain();
  
  // Get current state (for persistence)
  State getState();
};

// State for session persistence
struct State {
  // Opaque state that can be serialized/deserialized
  // Used to maintain breakpoints, etc. across sessions
};

} // namespace facebook::hermes::cdp
```

### RuntimeTask Callback

**Purpose**: Execute code on the JavaScript thread with access to Hermes runtime.

**Type Signature**:
```cpp
namespace facebook::hermes::debugger {

// Function that takes HermesRuntime and does something with it
using RuntimeTask = std::function<void(HermesRuntime&)>;

} // namespace facebook::hermes::debugger
```

**Usage in Integration**:
```cpp
// React Native's RuntimeExecutor signature
using RuntimeExecutor = std::function<void(std::function<void(jsi::Runtime&)>&&)>;

// Conversion in HermesRuntimeAgentDelegate
[runtimeExecutor, &runtime](facebook::hermes::debugger::RuntimeTask fn) {
  runtimeExecutor([&runtime, fn = std::move(fn)](auto&) { 
    fn(runtime);  // Call Hermes-specific function with HermesRuntime
  });
}
```

## Console API Integration

### Flow: console.log() → CDP Frontend

1. **JavaScript calls console.log()**
   ```javascript
   console.log("Hello", 42, {key: "value"});
   ```

2. **RuntimeTarget intercepts console call**
   - Via JSI host function installed by `RuntimeTarget::installConsoleHandler()`
   - Captures arguments and stack trace
   - Creates `ConsoleMessage` object

3. **RuntimeTargetDelegate::addConsoleMessage() called**
   ```cpp
   void RuntimeTarget::handleConsoleLog(args...) {
     auto stackTrace = delegate_.captureStackTrace(runtime, 1);
     ConsoleMessage message{
       .timestamp = getCurrentTime(),
       .type = ConsoleAPIType::kLog,
       .args = std::move(args),
       .stackTrace = std::move(stackTrace)
     };
     delegate_.addConsoleMessage(runtime, std::move(message));
   }
   ```

4. **HermesRuntimeTargetDelegate converts to Hermes format**
   ```cpp
   void HermesRuntimeTargetDelegate::Impl::addConsoleMessage(
       jsi::Runtime& runtime, 
       ConsoleMessage message) {
     
     // Convert React Native console type to Hermes console type
     HermesConsoleAPIType hermesType = convertConsoleType(message.type);
     
     // Extract Hermes stack trace from wrapper
     HermesStackTrace hermesStackTrace = 
         extractHermesStackTrace(message.stackTrace);
     
     // Create Hermes console message
     HermesConsoleMessage hermesMessage{
         message.timestamp,
         hermesType,
         std::move(message.args),
         std::move(hermesStackTrace)
     };
     
     // Send to Hermes CDP API
     cdpDebugAPI_->addConsoleMessage(std::move(hermesMessage));
   }
   ```

5. **CDPDebugAPI forwards to all connected sessions**
   - Converts message to CDP Runtime.consoleAPICalled event
   - Sends to all connected debugger frontends

6. **CDP Frontend displays in DevTools console**

### Stack Trace Capture

**Purpose**: Capture JavaScript call stack for console messages and errors.

**Flow**:
```cpp
// React Native requests stack trace
std::unique_ptr<StackTrace> HermesRuntimeTargetDelegate::captureStackTrace(
    jsi::Runtime& runtime,
    size_t framesToSkip) {
  
  // Get Hermes debugger
  auto hermesStackTrace = runtime_->getDebugger().captureStackTrace();
  
  // Wrap in React Native StackTrace interface
  return std::make_unique<HermesStackTraceWrapper>(
      std::move(hermesStackTrace));
}
```

**Note**: `framesToSkip` parameter is currently ignored. Hermes's `CDPDebugAPI::addConsoleMessage` strips the host function frame automatically.

## CDP Message Handling

### Flow: CDP Request → Hermes → CDP Response

1. **Frontend sends CDP request**
   ```json
   {
     "id": 1,
     "method": "Debugger.setBreakpointByUrl",
     "params": {
       "lineNumber": 10,
       "url": "index.bundle.js"
     }
   }
   ```

2. **Inspector routes to RuntimeAgent**
   - `HostTarget` → `InstanceTarget` → `RuntimeTarget` → `RuntimeAgent`

3. **RuntimeAgent delegates to RuntimeAgentDelegate**
   ```cpp
   bool RuntimeAgent::handleRequest(const cdp::PreparsedRequest& req) {
     // ... handle some requests directly ...
     
     // Delegate to engine-specific handler
     if (delegate_->handleRequest(req)) {
       return true;  // Handled
     }
     
     // ... handle other requests ...
   }
   ```

4. **HermesRuntimeAgentDelegate forwards to Hermes**
   ```cpp
   bool HermesRuntimeAgentDelegate::Impl::handleRequest(
       const cdp::PreparsedRequest& req) {
     
     if (req.method.rfind("Log.", 0) == 0) {
       // Log domain not handled by Hermes
       return false;
     }
     
     // Forward to Hermes CDPAgent
     hermes_->handleCommand(req.toJson());
     return true;  // Hermes will respond
   }
   ```

5. **Hermes CDPAgent processes command**
   - Parses CDP message
   - Executes debugger command (set breakpoint, step, evaluate, etc.)
   - Sends response via FrontendChannel

6. **FrontendChannel sends response to frontend**
   ```json
   {
     "id": 1,
     "result": {
       "breakpointId": "1:10:0",
       "locations": [...]
     }
   }
   ```

### Domain Handling

**CDP Domains** are groups of related functionality:

- **Runtime** - JavaScript execution, evaluation, object inspection
- **Debugger** - Breakpoints, stepping, paused state
- **Profiler** - CPU profiling
- **HeapProfiler** - Memory profiling
- **Console** - Console messages (partially handled by Hermes)
- **Log** - Generic logging (handled by React Native HostAgent)

**Hermes handles**:
- `Runtime.*` (via CDPAgent)
- `Debugger.*` (via CDPAgent)
- `Profiler.*` (partially)
- `Console.*` (via CDPDebugAPI)

**React Native handles**:
- `Log.*` (HostAgent)
- `Network.*` (NetworkIOAgent)
- `Tracing.*` (TracingAgent)

## Session State Management

### Purpose
Maintain debugger state (breakpoints, watches, etc.) across:
- Page reloads
- Connection reconnects
- Hot module replacement

### State Export/Import

```cpp
class HermesRuntimeAgentDelegate::Impl {
  struct HermesStateWrapper : public ExportedState {
    explicit HermesStateWrapper(HermesState state) 
        : state_(std::move(state)) {}
    
    static HermesState unwrapDestructively(ExportedState* wrapper) {
      if (!wrapper) {
        return {};  // No previous state
      }
      if (auto* typedWrapper = dynamic_cast<HermesStateWrapper*>(wrapper)) {
        return std::move(typedWrapper->state_);
      }
      return {};
    }
    
   private:
    HermesState state_;  // Hermes CDP state
  };
  
 public:
  // Constructor receives previous state
  Impl(..., std::unique_ptr<ExportedState> previouslyExportedState, ...) {
    // Create CDPAgent with previous state
    hermes_ = CDPAgent::create(
        executionContextID,
        cdpDebugAPI,
        runtimeTaskCallback,
        frontendChannel,
        HermesStateWrapper::unwrapDestructively(previouslyExportedState.get()));
  }
  
  // Export current state
  std::unique_ptr<ExportedState> getExportedState() override {
    return std::make_unique<HermesStateWrapper>(hermes_->getState());
  }
};
```

### Domain State

```cpp
struct SessionState {
  bool isRuntimeDomainEnabled = false;
  bool isDebuggerDomainEnabled = false;
};

// Enable domains based on session state
if (sessionState.isRuntimeDomainEnabled) {
  hermes_->enableRuntimeDomain();
}
if (sessionState.isDebuggerDomainEnabled) {
  hermes_->enableDebuggerDomain();
}
```

## Profiling Integration

### Sampling Profiler

**Purpose**: Collect CPU profiling data for performance analysis.

**Implementation**:

```cpp
class HermesRuntimeSamplingProfileDelegate {
 public:
  explicit HermesRuntimeSamplingProfileDelegate(
      std::shared_ptr<HermesRuntime> hermesRuntime)
      : hermesRuntime_(std::move(hermesRuntime)) {}
  
  void startSampling() {
    auto* hermesAPI = jsi::castInterface<IHermesRootAPI>(makeHermesRootAPI());
    hermesAPI->enableSamplingProfiler(HERMES_SAMPLING_FREQUENCY_HZ);  // 10kHz
  }
  
  void stopSampling() {
    auto* hermesAPI = jsi::castInterface<IHermesRootAPI>(makeHermesRootAPI());
    hermesAPI->disableSamplingProfiler();
  }
  
  tracing::RuntimeSamplingProfile collectSamplingProfile() {
    // Get Hermes profile data
    auto hermesProfile = hermesRuntime_->dumpSampledTraceToProfile();
    
    // Convert to React Native tracing format
    return HermesRuntimeSamplingProfileSerializer::
        serializeToTracingSamplingProfile(hermesProfile);
  }
};
```

**Usage**:
1. Frontend sends `Profiler.start`
2. React Native calls `enableSamplingProfiler()`
3. Hermes samples call stacks at 10kHz
4. Frontend sends `Profiler.stop`
5. React Native calls `collectSamplingProfile()`
6. Profile data sent to frontend for visualization

## Threading Model

### RuntimeExecutor

**Purpose**: Execute code on the JavaScript thread.

**Type**:
```cpp
using RuntimeExecutor = std::function<void(std::function<void(jsi::Runtime&)>&&)>;
```

**Usage in Hermes Integration**:
```cpp
// Hermes wants RuntimeTask
using RuntimeTask = std::function<void(HermesRuntime&)>;

// Convert RuntimeExecutor to RuntimeTask callback
auto hermesRuntimeTaskCallback = [runtimeExecutor, &runtime](RuntimeTask fn) {
  runtimeExecutor([&runtime, fn = std::move(fn)](jsi::Runtime&) {
    fn(runtime);  // Call with HermesRuntime
  });
};
```

**Critical**: All Hermes debugger operations must run on the JS thread. The `RuntimeTask` callback ensures this.

## Legacy Hermes Inspector (ConnectionDemux)

**Note**: This is the OLD inspector API, not used by modern inspector but still present in codebase.

**Location**: `ReactCommon/hermes/inspector-modern/chrome/ConnectionDemux.h/cpp`

**Purpose**: Older Hermes debugging infrastructure using `CDPHandler`.

**Key Difference**:
- Modern: Uses `CDPDebugAPI` + `CDPAgent`
- Legacy: Uses `CDPHandler` + `RuntimeAdapter`

**Not used in modern inspector integration**, but may be relevant for understanding Hermes's debugging history.

## ABI-Stable API Design Recommendations

Based on the Hermes-Inspector integration, here's what your `hermes_inspector_vtable` (or `hermes_debugger_vtable`) needs to support:

### Required Functions

```c
typedef struct hermes_inspector_vtable {
  //==========================================================================
  // CDPDebugAPI Creation
  //==========================================================================
  
  // Create CDP debug API for a runtime
  hermes_status (*create_cdp_debug_api)(
      hermes_runtime runtime,
      hermes_cdp_debug_api* result);
  
  // Release CDP debug API
  hermes_status (*release_cdp_debug_api)(
      hermes_cdp_debug_api debug_api);
  
  //==========================================================================
  // CDPAgent Creation and Management
  //==========================================================================
  
  // Create CDP agent for a session
  hermes_status (*create_cdp_agent)(
      hermes_cdp_debug_api debug_api,
      int32_t execution_context_id,
      hermes_runtime_task_functor runtime_task_callback,
      hermes_frontend_message_functor frontend_channel,
      hermes_cdp_state previous_state,
      hermes_cdp_agent* result);
  
  // Release CDP agent
  hermes_status (*release_cdp_agent)(
      hermes_cdp_agent agent);
  
  //==========================================================================
  // CDP Message Handling
  //==========================================================================
  
  // Handle CDP command (JSON string)
  hermes_status (*cdp_agent_handle_command)(
      hermes_cdp_agent agent,
      const char* json_utf8,
      size_t json_size);
  
  //==========================================================================
  // Domain Management
  //==========================================================================
  
  // Enable Runtime domain
  hermes_status (*cdp_agent_enable_runtime_domain)(
      hermes_cdp_agent agent);
  
  // Enable Debugger domain
  hermes_status (*cdp_agent_enable_debugger_domain)(
      hermes_cdp_agent agent);
  
  //==========================================================================
  // State Management
  //==========================================================================
  
  // Get current CDP state (for persistence)
  hermes_status (*cdp_agent_get_state)(
      hermes_cdp_agent agent,
      hermes_cdp_state* result);
  
  // Release CDP state
  hermes_status (*release_cdp_state)(
      hermes_cdp_state state);
  
  //==========================================================================
  // Console API
  //==========================================================================
  
  // Add console message
  hermes_status (*add_console_message)(
      hermes_cdp_debug_api debug_api,
      const hermes_console_message* message);
  
  //==========================================================================
  // Stack Trace Capture
  //==========================================================================
  
  // Capture current stack trace
  hermes_status (*capture_stack_trace)(
      hermes_runtime runtime,
      hermes_stack_trace* result);
  
  // Release stack trace
  hermes_status (*release_stack_trace)(
      hermes_stack_trace stack_trace);
  
  //==========================================================================
  // Profiling
  //==========================================================================
  
  // Enable sampling profiler
  hermes_status (*enable_sampling_profiler)(
      hermes_runtime runtime);
  
  // Disable sampling profiler
  hermes_status (*disable_sampling_profiler)(
      hermes_runtime runtime);
  
  // Collect sampling profile
  hermes_status (*collect_sampling_profile)(
      hermes_runtime runtime,
      hermes_sampling_profile* result);
  
  // Release sampling profile
  hermes_status (*release_sampling_profile)(
      hermes_sampling_profile profile);
  
} hermes_inspector_vtable;
```

### Required Types

```c
// Opaque handles
typedef struct hermes_cdp_debug_api_s* hermes_cdp_debug_api;
typedef struct hermes_cdp_agent_s* hermes_cdp_agent;
typedef struct hermes_cdp_state_s* hermes_cdp_state;
typedef struct hermes_stack_trace_s* hermes_stack_trace;
typedef struct hermes_sampling_profile_s* hermes_sampling_profile;

// Console message structure
typedef enum {
  HERMES_CONSOLE_LOG,
  HERMES_CONSOLE_DEBUG,
  HERMES_CONSOLE_INFO,
  HERMES_CONSOLE_ERROR,
  HERMES_CONSOLE_WARNING,
  HERMES_CONSOLE_DIR,
  HERMES_CONSOLE_DIRXML,
  HERMES_CONSOLE_TABLE,
  HERMES_CONSOLE_TRACE,
  HERMES_CONSOLE_START_GROUP,
  HERMES_CONSOLE_START_GROUP_COLLAPSED,
  HERMES_CONSOLE_END_GROUP,
  HERMES_CONSOLE_CLEAR,
  HERMES_CONSOLE_ASSERT,
  HERMES_CONSOLE_TIME_END,
  HERMES_CONSOLE_COUNT,
} hermes_console_api_type;

typedef struct {
  double timestamp;
  hermes_console_api_type type;
  const jsr_value* args;      // Array of JSR values
  size_t args_count;
  hermes_stack_trace stack_trace;  // May be NULL
} hermes_console_message;

// Runtime task callback
typedef void (*hermes_runtime_task_callback)(
    void* cb_data,
    hermes_runtime runtime);

typedef struct {
  void* data;
  hermes_runtime_task_callback invoke;
  hermes_release_callback release;
} hermes_runtime_task_functor;

// Frontend message callback (CDP events/responses)
typedef void (*hermes_frontend_message_callback)(
    void* cb_data,
    const char* json_utf8,
    size_t json_size);

typedef struct {
  void* data;
  hermes_frontend_message_callback invoke;
  hermes_release_callback release;
} hermes_frontend_message_functor;
```

### Comparison with Your Current API

**Your Current API** (`hermes_debugger_vtable`):
```c
typedef struct {
  hermes_create_cdp_debugger create_cdp_debugger;  // ✅ Similar to create_cdp_debug_api
  hermes_create_cdp_agent create_cdp_agent;        // ✅ Correct
  hermes_get_cdp_state get_cdp_state;              // ✅ Correct
  hermes_capture_stack_trace capture_stack_trace;  // ✅ Correct
  hermes_release_cdp_debugger release_cdp_debugger;
  hermes_release_cdp_agent release_cdp_agent;
  hermes_release_cdp_state release_cdp_state;
  hermes_release_stack_trace release_stack_trace;
  hermes_cdp_agent_handle_command cdp_agent_handle_command;  // ✅ Correct
  hermes_cdp_agent_enable_runtime_domain cdp_agent_enable_runtime_domain;   // ✅ Correct
  hermes_cdp_agent_enable_debugger_domain cdp_agent_enable_debugger_domain; // ✅ Correct
} hermes_debugger_vtable;
```

**What's Missing**:
1. ❌ **Console message support** (`add_console_message`)
2. ❌ **Profiling support** (`enable/disable_sampling_profiler`, `collect_sampling_profile`)
3. ❌ **Explicit state export** (you have `get_cdp_state` which is correct)

**What's Good**:
- ✅ Core CDP agent creation and handling
- ✅ Domain enabling
- ✅ Stack trace capture
- ✅ State management
- ✅ Release functions for cleanup

### Recommendations for Your API

1. **Add Console Support**:
   ```c
   hermes_status (*add_console_message)(
       hermes_cdp_debugger debugger,
       const hermes_console_message* message);
   ```

2. **Add Profiling Support**:
   ```c
   hermes_status (*enable_sampling_profiler)(hermes_runtime runtime);
   hermes_status (*disable_sampling_profiler)(hermes_runtime runtime);
   hermes_status (*collect_sampling_profile)(
       hermes_runtime runtime,
       hermes_sampling_profile* result);
   hermes_status (*release_sampling_profile)(hermes_sampling_profile profile);
   ```

3. **Consider Renaming** `create_cdp_debugger` → `create_cdp_debug_api`:
   - More accurate (it's an API, not just a debugger)
   - Matches Hermes terminology (`CDPDebugAPI`)

4. **Keep the name** `hermes_debugger_vtable`:
   - It's commonly understood in the industry
   - Hermes uses "CDPDebugAPI" which also uses "Debug"
   - Shorter than `hermes_inspector_vtable`
   - The functionality is primarily debugging-focused

## Summary

### Key Takeaways

1. **Two-Layer Architecture**:
   - React Native layer: `HermesRuntimeTargetDelegate` + `HermesRuntimeAgentDelegate`
   - Hermes layer: `CDPDebugAPI` + `CDPAgent`

2. **Critical APIs**:
   - `CDPDebugAPI::create()` - Create debug API for runtime
   - `CDPAgent::create()` - Create agent for session
   - `CDPAgent::handleCommand()` - Process CDP messages
   - `CDPDebugAPI::addConsoleMessage()` - Forward console output
   - `enableRuntimeDomain()` / `enableDebuggerDomain()` - Enable CDP domains

3. **Threading**:
   - All Hermes operations must run on JS thread
   - Use `RuntimeTask` callback to execute on JS thread
   - Convert React Native's `RuntimeExecutor` to Hermes's `RuntimeTask`

4. **State Management**:
   - Export/import CDP state for session persistence
   - Maintain breakpoints across reloads
   - Use `getState()` / restore in `create()`

5. **Console Integration**:
   - React Native intercepts console calls
   - Captures stack trace
   - Converts to Hermes format
   - Forwards to `CDPDebugAPI::addConsoleMessage()`

6. **CDP Message Flow**:
   - Frontend → Inspector → RuntimeAgent → RuntimeAgentDelegate → Hermes CDPAgent
   - Hermes handles Runtime/Debugger/Profiler domains
   - React Native handles Log/Network/Tracing domains

7. **Your API is Good**:
   - Core functionality is present
   - Consider adding console and profiling support
   - Name is acceptable (`hermes_debugger_vtable`)

### For Windows Integration

Your ABI-stable API should provide:
1. ✅ CDP agent creation and lifecycle
2. ✅ CDP command handling
3. ✅ Domain enabling
4. ✅ State persistence
5. ✅ Stack trace capture
6. ➕ Console message forwarding (add this)
7. ➕ Profiling support (add this)

The key insight is that Hermes provides a complete CDP implementation (`CDPAgent`), and React Native just needs to:
- Create it with appropriate callbacks
- Forward CDP messages to it
- Handle console messages
- Manage session state
- Provide JS thread execution

Your current API captures the core requirements well!
