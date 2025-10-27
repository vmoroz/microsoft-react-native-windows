# Modern Inspector Integration with Hermes JavaScript Engine

## Overview

This document describes the interaction between the React Native modern inspector and the Hermes JavaScript engine. Understanding this integration is crucial for creating an ABI-stable API layer for Hermes on Windows, where direct access to Hermes C++ APIs is not possible.

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
