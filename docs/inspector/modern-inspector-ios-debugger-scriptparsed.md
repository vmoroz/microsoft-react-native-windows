# Modern Inspector: Debugger.scriptParsed Event Flow in iOS Bridgeless Mode

**Investigation Date:** October 29, 2025  
**Objective:** Understand how `Debugger.scriptParsed` CDP events are generated and delivered in React Native iOS bridgeless mode with Hermes

## Executive Summary

The `Debugger.scriptParsed` event flow works correctly in iOS bridgeless mode because:

1. **Hermes CDPDebugAPI** is properly initialized when `HermesRuntime` is created
2. **DebuggerDomainAgent** automatically sends `scriptParsed` notifications when debugger is **enabled**
3. The legacy `enableDebugging()` API in iOS **does NOT** initialize Hermes debugging - it only registers the runtime with the inspector page system

## Key Finding: The Critical Difference

**Windows RNW Issue:** We create `CDPDebugAPI` and `CDPAgent` objects, but `Debugger.scriptParsed` events are not sent.

**iOS Success:** Uses the same Hermes CDP implementation, and events ARE sent correctly.

**Root Cause:** The issue is NOT in Hermes initialization, but in **when DebuggerDomainAgent.enable() is called**:

- **iOS:** The legacy `enableDebugging()` creates a `CDPHandler` that wraps the runtime and ensures debugger domain is enabled
- **Windows:** We create `CDPAgent` but may not be properly enabling the debugger domain or handling the initialization sequence

## Architecture Overview

### Hermes CDP Layer (E:\GitHub\microsoft\hermes-windows\API\hermes\cdp)

```
HermesRuntime
    ↓
CDPDebugAPI::create(runtime)
    ↓ Creates
AsyncDebuggerAPI (Hermes VM debugging hooks)
    ↓ Used by
CDPAgent::create(cdpDebugAPI, ...)
    ↓ Contains
DebuggerDomainAgent (handles Debugger.* CDP commands)
```

#### CDPDebugAPI (`CDPDebugAPI.cpp`)

**Purpose:** Per-runtime debugging state and Hermes AsyncDebuggerAPI wrapper

**Key Components:**
```cpp
class CDPDebugAPI {
  HermesRuntime &runtime_;
  std::unique_ptr<debugger::AsyncDebuggerAPI> asyncDebuggerAPI_;
  ConsoleMessageStorage consoleMessageStorage_;
  ConsoleMessageDispatcher consoleMessageDispatcher_;
};
```

**Creation:**
```cpp
std::unique_ptr<CDPDebugAPI> CDPDebugAPI::create(
    HermesRuntime &runtime,
    size_t maxCachedMessages) {
  return std::unique_ptr<CDPDebugAPI>(
      new CDPDebugAPI(runtime, maxCachedMessages));
}

CDPDebugAPI::CDPDebugAPI(HermesRuntime &runtime, size_t maxCachedMessages)
    : runtime_(runtime),
      asyncDebuggerAPI_(debugger::AsyncDebuggerAPI::create(runtime)),  // ← VM hooks initialized HERE
      consoleMessageStorage_(maxCachedMessages) {}
```

**Critical Insight:** `AsyncDebuggerAPI::create(runtime)` initializes the Hermes VM's debugging infrastructure. This happens during `CDPDebugAPI` construction, NOT during `enableDebugging()`.

#### CDPAgent (`CDPAgent.cpp`)

**Purpose:** Handles CDP protocol messages and manages domain agents

**Key Components:**
```cpp
class CDPAgent {
  std::unique_ptr<CDPAgentImpl> impl_;  // Internal implementation
};

class CDPAgentImpl {
  CDPDebugAPI &cdpDebugAPI_;
  DomainAgentsImpl domainAgents_;  // Domain-specific handlers
};

struct DomainAgentsImpl {
  std::unique_ptr<DebuggerDomainAgent> debuggerAgent_;
  std::unique_ptr<RuntimeDomainAgent> runtimeAgent_;
  std::unique_ptr<ProfilerDomainAgent> profilerAgent_;
  std::unique_ptr<HeapProfilerDomainAgent> heapProfilerAgent_;
};
```

**Creation Flow:**
```cpp
std::unique_ptr<CDPAgent> CDPAgent::create(
    int32_t executionContextID,
    CDPDebugAPI &cdpDebugAPI,
    EnqueueRuntimeTaskFunc enqueueRuntimeTaskCallback,
    OutboundMessageFunc messageCallback,
    State state) {
  
  auto agent = std::unique_ptr<CDPAgent>(new CDPAgent(...));
  agent->impl_->initializeDomainAgents();  // ← Schedules initialization
  return agent;
}
```

#### DebuggerDomainAgent (`DebuggerDomainAgent.cpp`)

**Purpose:** Handles all `Debugger.*` CDP commands and events

**The Critical Method - `enable()`:**
```cpp
void DebuggerDomainAgent::enable() {
  if (enabled_) {
    return;  // Already enabled
  }
  enabled_ = true;

  // Register callback for debugger events from Hermes VM
  debuggerEventCallbackId_ = asyncDebugger_.setEventObserver(
      [this](auto &runtime, auto &asyncDebugger, auto event) {
        handleDebuggerEvent(runtime, asyncDebugger, event);
      });

  // ← ← ← THIS IS THE KEY: Send scriptParsed for ALL loaded scripts
  for (auto &srcLoc : runtime_.getDebugger().getLoadedScripts()) {
    sendScriptParsedNotificationToClient(srcLoc);

    // Apply existing breakpoints to the script
    for (auto &[cdpBreakpointID, cdpBreakpoint] : cdpBreakpoints_) {
      if (srcLoc.fileName == cdpBreakpoint.description.url) {
        applyBreakpointAndSendNotification(cdpBreakpointID, cdpBreakpoint, srcLoc);
      }
    }
  }
}
```

**Sending scriptParsed Notification:**
```cpp
void DebuggerDomainAgent::sendScriptParsedNotificationToClient(
    const debugger::SourceLocation srcLoc) {
  m::debugger::ScriptParsedNotification note;
  note.scriptId = std::to_string(srcLoc.fileId);
  note.url = srcLoc.fileName;
  note.executionContextId = executionContextID_;
  note.scriptLanguage = "JavaScript";
  
  std::string sourceMappingUrl =
      runtime_.getDebugger().getSourceMappingUrl(srcLoc.fileId);
  if (!sourceMappingUrl.empty()) {
    note.sourceMapURL = sourceMappingUrl;
  }
  
  sendNotificationToClient(note);  // ← Sends CDP event to frontend
}
```

**When New Scripts Load (ScriptLoaded event):**
```cpp
void DebuggerDomainAgent::handleDebuggerEvent(
    HermesRuntime &runtime,
    AsyncDebuggerAPI &asyncDebugger,
    DebuggerEventType event) {
  
  switch (event) {
    case DebuggerEventType::ScriptLoaded:
      processNewLoadedScript();  // ← Sends scriptParsed for new script
      asyncDebugger_.resumeFromPaused(AsyncDebugCommand::Continue);
      break;
    // ... other events
  }
}

void DebuggerDomainAgent::processNewLoadedScript() {
  auto stackTrace = runtime_.getDebugger().getProgramState().getStackTrace();
  if (stackTrace.callFrameCount() > 0) {
    debugger::SourceLocation loc = stackTrace.callFrameForIndex(0).location;
    
    if (loc.fileId != debugger::kInvalidLocation) {
      sendScriptParsedNotificationToClient(loc);  // ← Send notification
      
      // Apply existing breakpoints to new script
      for (auto &[id, breakpoint] : cdpBreakpoints_) {
        if (loc.fileName == breakpoint.description.url) {
          applyBreakpointAndSendNotification(id, breakpoint, loc);
        }
      }
    }
  }
}
```

### React Native iOS Integration

#### HermesInstance (`node_modules/react-native/ReactCommon/react/runtime/hermes/HermesInstance.cpp`)

**Two Paths:**

**Path 1: Legacy Inspector (Fusebox Disabled)**
```cpp
#ifdef HERMES_ENABLE_DEBUGGER
  auto& inspectorFlags = jsinspector_modern::InspectorFlags::getInstance();
  if (!inspectorFlags.getFuseboxEnabled()) {
    // Use LEGACY DecoratedRuntime with old enableDebugging API
    std::unique_ptr<DecoratedRuntime> decoratedRuntime =
        std::make_unique<DecoratedRuntime>(
            std::move(hermesRuntime), msgQueueThread);
    return std::make_unique<JSIRuntimeHolder>(std::move(decoratedRuntime));
  }
#endif
```

**DecoratedRuntime** (Legacy path):
```cpp
class DecoratedRuntime : public jsi::RuntimeDecorator<jsi::Runtime> {
 public:
  DecoratedRuntime(
      std::unique_ptr<HermesRuntime> runtime,
      std::shared_ptr<MessageQueueThread> msgQueueThread)
      : RuntimeDecorator<jsi::Runtime>(*runtime), 
        runtime_(std::move(runtime)) {
    
    auto adapter = std::make_unique<HermesInstanceRuntimeAdapter>(
        runtime_, msgQueueThread);

    // Legacy API: Register with old inspector system
    debugToken_ = inspector_modern::chrome::enableDebugging(
        std::move(adapter), "Hermes Bridgeless React Native");
  }

  ~DecoratedRuntime() {
    inspector_modern::chrome::disableDebugging(debugToken_);
  }

 private:
  std::shared_ptr<HermesRuntime> runtime_;
  inspector_modern::chrome::DebugSessionToken debugToken_;
};
```

**Path 2: Modern Inspector (Fusebox Enabled)**
```cpp
// Falls through to:
return std::make_unique<HermesJSRuntime>(std::move(hermesRuntime));

class HermesJSRuntime : public JSRuntime {
  jsinspector_modern::RuntimeTargetDelegate& getRuntimeTargetDelegate() override {
    if (!targetDelegate_) {
      targetDelegate_.emplace(runtime_);  // ← Creates HermesRuntimeTargetDelegate
    }
    return *targetDelegate_;
  }
  
 private:
  std::shared_ptr<HermesRuntime> runtime_;
  std::optional<jsinspector_modern::HermesRuntimeTargetDelegate> targetDelegate_;
};
```

#### Legacy enableDebugging() Flow

**Registration.cpp:**
```cpp
DebugSessionToken enableDebugging(
    std::unique_ptr<RuntimeAdapter> adapter,
    const std::string& title) {
  return demux().enableDebugging(std::move(adapter), title);
}
```

**ConnectionDemux.cpp:**
```cpp
DebugSessionToken ConnectionDemux::enableDebugging(
    std::unique_ptr<RuntimeAdapter> adapter,
    const std::string& title) {
  
  auto waitForDebugger =
      (inspectedContexts_->find(title) != inspectedContexts_->end());
  
  // Creates CDPHandler - this is the old inspector implementation
  return addPage(hermes::inspector_modern::chrome::CDPHandler::create(
      std::move(adapter), title, waitForDebugger));
}

int ConnectionDemux::addPage(
    std::shared_ptr<hermes::inspector_modern::chrome::CDPHandler> conn) {
  
  auto connectFunc = [conn, this](std::unique_ptr<IRemoteConnection> remoteConn)
      -> std::unique_ptr<ILocalConnection> {
    
    std::shared_ptr<IRemoteConnection> sharedConn = std::move(remoteConn);
    
    // Register callbacks so CDPHandler can send/receive messages
    if (!conn->registerCallbacks(
            [sharedConn](const std::string& message) {
              sharedConn->onMessage(message);  // Send to frontend
            },
            [sharedConn]() { 
              sharedConn->onDisconnect(); 
            })) {
      return nullptr;
    }

    return std::make_unique<LocalConnection>(conn, inspectedContexts_);
  };

  // Register with global inspector (adds to page list)
  int pageId = globalInspector_.addPage(
      conn->getTitle(), "Hermes", std::move(connectFunc));
  
  conns_[pageId] = std::move(conn);
  return pageId;
}
```

**Key Point:** `CDPHandler` is part of the OLD inspector system. It's not available in Windows because we're using the MODERN inspector API directly.

## The Critical Sequence: When Are scriptParsed Events Sent?

### Scenario 1: Debugger Enabled BEFORE Scripts Load

1. Frontend connects to inspector
2. Frontend sends `Debugger.enable` CDP command
3. `DebuggerDomainAgent::enable()` is called
4. `runtime_.getDebugger().getLoadedScripts()` returns **empty list** (no scripts yet)
5. JavaScript bundle loads → triggers `ScriptLoaded` event
6. `handleDebuggerEvent()` → `processNewLoadedScript()` → `sendScriptParsedNotificationToClient()`
7. ✅ Frontend receives `Debugger.scriptParsed` notification

### Scenario 2: Debugger Enabled AFTER Scripts Already Loaded

1. JavaScript bundle loads (debugger not connected yet)
2. Scripts are registered in Hermes VM via `runtime_.getDebugger()`
3. Frontend connects to inspector
4. Frontend sends `Debugger.enable` CDP command
5. `DebuggerDomainAgent::enable()` is called
6. `runtime_.getDebugger().getLoadedScripts()` returns **list of all loaded scripts**
7. Loop through scripts: `sendScriptParsedNotificationToClient(srcLoc)` for each
8. ✅ Frontend receives `Debugger.scriptParsed` notifications for all scripts

**This is the mechanism that ensures the frontend always gets script information!**

## Windows RNW: What's Missing?

Based on this investigation, the Windows implementation should work because:

1. ✅ `CDPDebugAPI::create(runtime)` initializes `AsyncDebuggerAPI` (VM hooks)
2. ✅ `CDPAgent::create()` creates `DebuggerDomainAgent`
3. ✅ When frontend sends `Debugger.enable`, it should call `DebuggerDomainAgent::enable()`
4. ✅ `enable()` should iterate `runtime_.getDebugger().getLoadedScripts()` and send scriptParsed

### Possible Issues:

**Issue 1: Debugger Domain Not Actually Enabled**
- Check if `HermesRuntimeAgentDelegate::enableDebuggerDomain()` is being called
- Check if it correctly calls `DebuggerDomainAgent::enable()`

**Issue 2: AsyncDebuggerAPI Not Properly Initialized**
- Verify `CDPDebugAPI` is created before any JavaScript loads
- Verify it's created on the correct thread

**Issue 3: Event Observer Not Registered**
- Check if `asyncDebugger_.setEventObserver()` is being called
- Check if `ScriptLoaded` events are firing

**Issue 4: Loaded Scripts Not Available**
- Check if `runtime_.getDebugger().getLoadedScripts()` returns scripts
- This might indicate Hermes debugging is not properly initialized

## Verification Steps for Windows

### Step 1: Verify CDPDebugAPI Creation
```cpp
// In HermesRuntimeTargetDelegate constructor
hermesCdpDebugger_(HermesDebuggerApi::createCdpDebugger(
    hermesRuntimeHolder_->getHermesRuntime()))
```
Add logging to confirm this is called and succeeds.

### Step 2: Verify CDPAgent Creation
```cpp
// In HermesRuntimeAgentDelegate constructor
hermesCdpAgent_(HermesDebuggerApi::createCdpAgent(...))
```
Add logging to confirm this is called with correct parameters.

### Step 3: Verify Debugger Domain Enable
```cpp
// In HermesRuntimeAgentDelegate constructor
if (sessionState.isDebuggerDomainEnabled) {
  HermesDebuggerApi::enableDebuggerDomain(hermesCdpAgent_.get());
}
```
Add logging to:
- Confirm `sessionState.isDebuggerDomainEnabled` is true
- Confirm `enableDebuggerDomain` is called
- Confirm it eventually calls `DebuggerDomainAgent::enable()`

### Step 4: Verify Loaded Scripts
In Hermes `DebuggerDomainAgent::enable()`, add logging:
```cpp
auto loadedScripts = runtime_.getDebugger().getLoadedScripts();
// Log: "Loaded scripts count: " + loadedScripts.size()
for (auto &srcLoc : loadedScripts) {
  // Log: "Script: " + srcLoc.fileName + " (ID: " + srcLoc.fileId + ")"
  sendScriptParsedNotificationToClient(srcLoc);
}
```

### Step 5: Verify ScriptLoaded Events
In `DebuggerDomainAgent::handleDebuggerEvent()`:
```cpp
case DebuggerEventType::ScriptLoaded:
  // Log: "ScriptLoaded event received"
  processNewLoadedScript();
  break;
```

## Comparison: Legacy vs Modern API

### Legacy API (iOS non-Fusebox)
```
enableDebugging()
  → ConnectionDemux::enableDebugging()
  → CDPHandler::create(RuntimeAdapter)  ← Old Hermes inspector wrapper
  → IInspector::addPage()
  → Page registered with connectFunc
  → When frontend connects: CDPHandler handles CDP messages
```

**CDPHandler responsibilities:**
- Wraps HermesRuntime with RuntimeAdapter
- Handles CDP message routing
- Manages debugger lifecycle
- Internally uses Hermes's old inspector API

### Modern API (Windows RNW, iOS Fusebox)
```
HermesRuntimeTargetDelegate::createAgentDelegate()
  → HermesRuntimeAgentDelegate(...)
  → HermesDebuggerApi::createCdpAgent()
  → Hermes CDPAgent::create()
  → CDPAgent::initializeDomainAgents()
  → DebuggerDomainAgent created
  → When Debugger.enable received: DebuggerDomainAgent::enable()
```

**Key Difference:** Modern API skips the `CDPHandler` wrapper and uses Hermes CDP implementation directly.

## Conclusion

The `Debugger.scriptParsed` events ARE generated by Hermes's `DebuggerDomainAgent` when:

1. **Debugger domain is enabled** (`DebuggerDomainAgent::enable()` is called)
2. **Scripts are loaded** (either before or after enable)

The iOS legacy path works because `CDPHandler` ensures the debugger domain is enabled and properly routes messages.

The Windows modern path should work identically, but there's likely a missing step in:
- Enabling the debugger domain at the right time
- Ensuring `sessionState.isDebuggerDomainEnabled` is set correctly
- Properly routing the `Debugger.enable` CDP command to `DebuggerDomainAgent`

**Next Action:** Add detailed logging to trace the exact CDP message flow from frontend → RN Inspector → HermesRuntimeAgentDelegate → Hermes CDPAgent → DebuggerDomainAgent to identify where the chain breaks.

**The issue is NOT in Hermes VM initialization - it's in the CDP protocol handling layer.**
