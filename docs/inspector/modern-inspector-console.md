# Console Message Support for Modern Inspector

## Overview

This document describes the implementation of console message support for the React Native Windows modern inspector. Console messages (e.g., `console.log()`, `console.error()`, etc.) must be captured and forwarded to Chrome DevTools for display in the Console panel.

## Architecture Background

### React Native Console Message Flow

The console message flow in React Native follows this path:

1. **JavaScript Console API**: Developer calls `console.log(...)`, `console.error(...)`, etc.
2. **RuntimeTarget Console Handlers**: React Native core intercepts these calls via `RuntimeTargetConsole.cpp`
3. **RuntimeTargetDelegate**: Platform-specific delegate receives console messages
4. **CDPDebugAPI**: Hermes CDP subsystem stores and dispatches messages
5. **RuntimeDomainAgent**: Serializes messages to CDP format
6. **Chrome DevTools**: Displays messages in Console panel

### Key Components

- **RuntimeTargetConsole.cpp**: Installs JavaScript console method interceptors in React Native core
- **RuntimeTargetDelegate**: Abstract interface for platform-specific console handling
- **HermesRuntimeTargetDelegate**: Windows implementation of RuntimeTargetDelegate
- **CDPDebugAPI**: Hermes debugger API that manages console message storage and dispatch
- **ConsoleMessage**: Data structure containing timestamp, type, arguments, and stack trace

### ConsoleMessage Structure

```cpp
struct ConsoleMessage {
  double timestamp;
  ConsoleAPIType type;  // kLog, kError, kWarn, etc.
  std::vector<jsi::Value> args;  // Console arguments as JSI values
  StackTrace stackTrace;
};
```

## The JSI Value Challenge

### Problem Statement

Console message arguments are passed as `std::vector<jsi::Value>`. JSI values have critical constraints:

- **Runtime-Specific**: JSI values are tied to a specific `jsi::Runtime` instance
- **Thread-Bound**: Must remain on the JavaScript thread
- **Non-Serializable**: Cannot be converted to JSON without losing object inspection capabilities
- **Live References**: Represent live objects in the VM that can be inspected

Serializing JSI values to JSON (e.g., converting objects to strings) would prevent Chrome DevTools from:
- Expanding objects to see their properties
- Navigating object hierarchies
- Lazy-loading large data structures
- Type-accurate display (objects vs arrays vs primitives)

### iOS Reference Implementation

The iOS implementation bypasses this problem by calling the C++ API directly:

```cpp
void HermesRuntimeTargetDelegate::addConsoleMessage(
    jsi::Runtime& runtime,
    ConsoleMessage message) {
  cdpDebugAPI_->addConsoleMessage(std::move(message));
}
```

This works because iOS code can directly link against Hermes C++ APIs without ABI stability concerns.

## Windows C API Requirement

### Why C API is Required

React Native Windows requires an ABI-stable C API boundary between RNW and Hermes for several reasons:

1. **ABI Stability**: C++ ABI is not stable across compiler versions or STL implementations
2. **Multi-Language Support**: C API can be consumed from C#, Rust, or other languages
3. **Binary Compatibility**: Allows independent updates of RNW and Hermes binaries
4. **Clear Contract**: Explicit API surface with version negotiation

This is a strict architectural requirement that cannot be bypassed.

## Solution: Global Property Pass-Through

### Approach

Since JSI values must stay in the VM and remain on the JS thread, we can pass them through the C API boundary by temporarily storing them as a property on the global object.

**Key Insight**: Each `jsi::Value` is a C++ handle to an object that lives inside the VM. We can collect all console argument `jsi::Value` entries into a single `jsi::Array`, store it as a special property in `jsi::Runtime::global()`, pass the property name through the C API, then retrieve and delete the property on the Hermes side.

### Implementation Details

#### On the RNW Side (HermesRuntimeTargetDelegate.cpp)

```cpp
void HermesRuntimeTargetDelegate::addConsoleMessage(
    jsi::Runtime& runtime,
    ConsoleMessage message) {
  
  // Create a jsi::Array from the vector of jsi::Values
  jsi::Array argsArray(runtime, message.args.size());
  for (size_t i = 0; i < message.args.size(); ++i) {
    argsArray.setValueAtIndex(runtime, i, std::move(message.args[i]));
  }
  
  // Store array as a temporary global property
  const char* propName = "__rnw_cdp_console_args";
  runtime.global().setProperty(runtime, propName, argsArray);
  
  // Call C API with property name instead of serialized args
  hermesApi_->hermes_cdp_agent_add_console_message(
      hermesDebugger_,
      message.timestamp,
      static_cast<int>(message.type),
      propName,  // Pass property name, not serialized JSON
      stackTraceJson.c_str());
  
  // Property will be cleaned up by Hermes side
}
```

#### On the Hermes Side (hermes_api.cpp)

```cpp
extern "C" bool hermes_cdp_agent_add_console_message(
    hermes_debugger debugger,
    double timestamp,
    int type,
    const char* args_property_name,
    const char* stack_trace_json) {
  
  try {
    auto* dbg = reinterpret_cast<DebuggerAPI*>(debugger);
    jsi::Runtime& runtime = dbg->runtime();
    
    // Retrieve the array from global property
    jsi::Value argsValue = runtime.global().getProperty(
        runtime, args_property_name);
    
    // Convert jsi::Array back to std::vector<jsi::Value>
    std::vector<jsi::Value> args;
    if (argsValue.isObject()) {
      jsi::Array argsArray = argsValue.asObject(runtime).asArray(runtime);
      size_t length = argsArray.length(runtime);
      args.reserve(length);
      
      for (size_t i = 0; i < length; ++i) {
        args.push_back(argsArray.getValueAtIndex(runtime, i));
      }
    }
    
    // Delete the temporary property
    runtime.global().setProperty(
        runtime, args_property_name, jsi::Value::undefined());
    
    // Parse stack trace JSON...
    StackTrace stackTrace = parseStackTraceJson(stack_trace_json);
    
    // Create ConsoleMessage and add to CDP
    ConsoleMessage message{
      timestamp,
      static_cast<ConsoleAPIType>(type),
      std::move(args),
      std::move(stackTrace)
    };
    
    dbg->cdpDebugAPI()->addConsoleMessage(std::move(message));
    return true;
    
  } catch (...) {
    return false;
  }
}
```

#### C API Function Signature

```cpp
// In hermes_api.h vtable
bool (*hermes_cdp_agent_add_console_message)(
    hermes_debugger debugger,
    double timestamp,
    int console_api_type,
    const char* args_property_name,  // Global property containing jsi::Array
    const char* stack_trace_json);
```

### Why This Works

1. **Synchronous Execution**: All code executes synchronously on the JS thread
2. **No Cross-Thread Access**: JSI values never leave the JS thread
3. **No Serialization**: JSI values remain as live VM references
4. **No Observation**: The temporary property exists only during the function call
5. **Clean Boundary**: C API only sees primitive types (double, int, const char*)
6. **ABI Stable**: No C++ types cross the C API boundary

### Property Name Considerations

The property name `__rnw_cdp_console_args` is:
- Unlikely to collide with user code (double underscore prefix)
- Self-documenting (rnw = React Native Windows, cdp = Chrome DevTools Protocol)
- Temporary (deleted immediately after retrieval)
- Synchronous (no chance of observation by other code)

Passing the property name as a parameter provides flexibility:
- Different call sites could use different property names if needed
- Property name can be changed without breaking ABI
- Makes the temporary nature explicit in the API

## Stack Trace Handling

Stack traces can be serialized to JSON and passed as strings through the C API. The stack trace structure is relatively simple:

```cpp
struct StackTrace {
  std::vector<StackFrame> frames;
};

struct StackFrame {
  std::string functionName;
  std::string scriptId;
  std::string url;
  int lineNumber;
  int columnNumber;
};
```

This can be serialized to JSON format:

```json
{
  "frames": [
    {
      "functionName": "myFunction",
      "scriptId": "123",
      "url": "MyModule.js",
      "lineNumber": 42,
      "columnNumber": 10
    }
  ]
}
```

## ConsoleAPIType Values

The console message type is passed as an integer corresponding to:

```cpp
enum class ConsoleAPIType {
  kLog = 0,
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
```

## Implementation Steps

1. **Update hermes_api.h**: Define C API function signature with args_property_name parameter
2. **Update hermes_api.cpp**: Implement property retrieval and conversion logic
3. **Update HermesRuntimeTargetDelegate.cpp**: Implement array creation and global property storage
4. **Add Stack Trace Serialization**: Implement JSON serialization for StackTrace structure
5. **Test Console Methods**: Verify console.log, console.error, console.warn, etc. in DevTools

## Testing Strategy

Test cases should verify:

1. **Simple Values**: `console.log("hello")`, `console.log(42)`, `console.log(true)`
2. **Objects**: `console.log({foo: "bar"})` with expandable properties in DevTools
3. **Arrays**: `console.log([1, 2, 3])` with proper array display
4. **Multiple Arguments**: `console.log("value:", obj, arr)`
5. **Different Types**: console.error, console.warn, console.info
6. **Stack Traces**: Verify function names and line numbers appear correctly
7. **Nested Objects**: Deep object hierarchies remain inspectable

## Benefits of This Approach

1. **ABI Stable**: Only primitive types cross C API boundary
2. **Full Fidelity**: JSI values preserve object inspection capabilities
3. **Thread Safe**: All operations on JS thread, synchronous execution
4. **No Serialization Loss**: Objects remain inspectable in DevTools
5. **Clean Architecture**: Respects C API requirement while handling C++ constraints
6. **Multi-Language Ready**: C API can be called from any language with C FFI

## Alternative Approaches Considered

### Direct C++ API (Rejected)

Calling Hermes C++ APIs directly from RNW code bypasses ABI stability requirements. This approach is used in iOS but violates Windows architectural constraints.

**Rejection Reason**: Does not meet strict C API requirement for ABI stability and multi-language support.

### JSON Serialization (Rejected)

Serializing JSI values to JSON strings and passing through C API.

**Rejection Reason**: Loses object inspection capabilities in DevTools. Users cannot expand objects, navigate hierarchies, or see lazy-loaded properties.

### Opaque Handles (Rejected)

Passing opaque pointers to JSI values through C API.

**Rejection Reason**: Pointers to C++ objects violate ABI stability. Different compiler versions have different vtable layouts and memory representations.

## Future Considerations

- **Performance**: Profile the temporary property creation/deletion overhead
- **Property Name Collisions**: Consider using GUIDs if multiple simultaneous console calls are possible
- **Error Handling**: Add validation for array retrieval and type checking
- **Memory Pressure**: Monitor impact of large console argument arrays

## Conclusion

The global property pass-through approach successfully bridges the C API requirement with JSI value lifetime constraints. By temporarily storing console arguments as a global property, we maintain ABI stability while preserving full object inspection capabilities in Chrome DevTools.

This solution respects the strict architectural requirement for C API usage while delivering the complete console debugging experience developers expect.
