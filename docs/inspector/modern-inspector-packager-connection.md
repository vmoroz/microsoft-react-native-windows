# Modern Inspector: Packager Connection Issues in RNW

**Investigation Date:** October 29, 2025  
**Issue:** WebSocket connection constantly reconnecting, preventing proper debugger operation

## Executive Summary

Windows RNW has critical issues in its `ReactInspectorPackagerConnectionDelegate` implementation that cause:

1. **Constant WebSocket Reconnections:** The connection drops and reconnects repeatedly
2. **Missing didOpen() Callback:** WebSocket never properly signals successful connection
3. **Thread Safety Issues:** Callbacks invoked on wrong threads
4. **Resource Leaks:** WebSocket not properly closed on destruction
5. **Incomplete Error Handling:** Missing error propagation to delegate

These issues prevent the modern inspector from working reliably, as the packager connection is never stable enough to exchange CDP messages with the frontend.

## Architecture: How Packager Connection Works

### Purpose

The `InspectorPackagerConnection` implements the React Native "inspector-proxy" protocol that multiplexes multiple debugger sessions over a single WebSocket connection to Metro bundler.

**Protocol Flow:**
```
Metro Bundler (inspector-proxy)
    ↕ WebSocket
InspectorPackagerConnection
    ↕ IWebSocketDelegate callbacks
InspectorPackagerConnection::Impl
    ↕ CDP messages
RuntimeAgent / DebuggerDomainAgent
```

### Key Responsibilities

1. **Establish and maintain WebSocket connection** to Metro bundler's inspector proxy
2. **Handle reconnection** with exponential backoff (2 second delay)
3. **Multiplex debugger sessions** - multiple pages can be debugged over one connection
4. **Route CDP messages** between frontend (through Metro) and runtime agents
5. **Handle page lifecycle** - notify when pages are added/removed

### Protocol Messages

**From Metro → Device:**
- `{"event": "getPages"}` - Request list of debuggable pages
- `{"event": "connect", "payload": {"pageId": "1"}}` - Connect to a page
- `{"event": "disconnect", "payload": {"pageId": "1"}}` - Disconnect from a page
- `{"event": "wrappedEvent", "payload": {"pageId": "1", "wrappedEvent": "..."}}` - CDP message

**From Device → Metro:**
- `{"event": "getPages", "payload": [...]}` - List of pages
- `{"event": "wrappedEvent", "payload": {"pageId": "1", "wrappedEvent": "..."}}` - CDP message
- `{"event": "disconnect", "payload": {"pageId": "1"}}` - Page disconnected

## iOS Implementation (Reference - Correct)

### RCTCxxInspectorPackagerConnectionDelegate

**File:** `node_modules/react-native/React/Inspector/RCTCxxInspectorPackagerConnectionDelegate.mm`

```objectivec++
std::unique_ptr<IWebSocket> RCTCxxInspectorPackagerConnectionDelegate::connectWebSocket(
    const std::string &url,
    std::weak_ptr<IWebSocketDelegate> delegate)
{
  // Creates adapter that wraps SocketRocket (iOS WebSocket library)
  auto *adapter = [[RCTCxxInspectorWebSocketAdapter alloc] 
                   initWithURL:url delegate:delegate];
  if (!adapter) {
    return nullptr;
  }
  return std::make_unique<WebSocket>(adapter);
}

void RCTCxxInspectorPackagerConnectionDelegate::scheduleCallback(
    std::function<void(void)> callback,
    std::chrono::milliseconds delayMs)
{
  // Schedule on main queue with delay
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, delayMs.count() * NSEC_PER_MSEC), 
      dispatch_get_main_queue(), 
      ^{
        callback();
      });
}
```

### RCTCxxInspectorWebSocketAdapter

**File:** `node_modules/react-native/React/Inspector/RCTCxxInspectorWebSocketAdapter.mm`

```objectivec++
@implementation RCTCxxInspectorWebSocketAdapter
- (instancetype)initWithURL:(const std::string &)url 
                   delegate:(std::weak_ptr<IWebSocketDelegate>)delegate
{
  if ((self = [super init])) {
    _delegate = delegate;
    _webSocket = [[SRWebSocket alloc] initWithURL:[NSURL URLWithString:NSStringFromUTF8StringView(url)]];
    _webSocket.delegate = self;
    [_webSocket open];  // ← Initiates connection
  }
  return self;
}

- (void)send:(std::string_view)message
{
  __weak RCTCxxInspectorWebSocketAdapter *weakSelf = self;
  NSString *messageStr = NSStringFromUTF8StringView(message);
  dispatch_async(dispatch_get_main_queue(), ^{
    RCTCxxInspectorWebSocketAdapter *strongSelf = weakSelf;
    if (strongSelf) {
      [strongSelf->_webSocket sendString:messageStr error:NULL];
    }
  });
}

- (void)close
{
  [_webSocket closeWithCode:1000 reason:@"End of session"];
}

// SRWebSocketDelegate methods - called on main queue by SocketRocket

- (void)webSocketDidOpen:(__unused SRWebSocket *)webSocket
{
  if (auto delegate = _delegate.lock()) {
    delegate->didOpen();  // ← CRITICAL: Called when connection succeeds
  }
}

- (void)webSocket:(__unused SRWebSocket *)webSocket 
   didFailWithError:(NSError *)error
{
  if (auto delegate = _delegate.lock()) {
    delegate->didFailWithError([error code], [error description].UTF8String);
  }
}

- (void)webSocket:(__unused SRWebSocket *)webSocket 
   didReceiveMessageWithString:(NSString *)message
{
  if (auto delegate = _delegate.lock()) {
    delegate->didReceiveMessage([message UTF8String]);
  }
}

- (void)webSocket:(__unused SRWebSocket *)webSocket
    didCloseWithCode:(__unused NSInteger)code
              reason:(__unused NSString *)reason
            wasClean:(__unused BOOL)wasClean
{
  if (auto delegate = _delegate.lock()) {
    delegate->didClose();  // ← Called when connection closes
  }
}
@end
```

**Key Points - iOS:**
1. ✅ WebSocket callbacks (`didOpen`, `didClose`, `didFailWithError`, `didReceiveMessage`) are **all properly implemented**
2. ✅ Thread safety: All callbacks happen on main queue (managed by SocketRocket)
3. ✅ Proper cleanup: WebSocket closed with code/reason
4. ✅ Weak pointer handling: Checks if delegate still exists before calling

## Windows Implementation (Current - Broken)

### ReactInspectorPackagerConnectionDelegate

**File:** `vnext/Shared/Inspector/ReactInspectorPackagerConnectionDelegate.cpp`

```cpp
std::unique_ptr<facebook::react::jsinspector_modern::IWebSocket>
ReactInspectorPackagerConnectionDelegate::connectWebSocket(
    const std::string &url,
    std::weak_ptr<facebook::react::jsinspector_modern::IWebSocketDelegate> delegate) {
  return std::make_unique<ReactInspectorWebSocket>(url, delegate);
}

void ReactInspectorPackagerConnectionDelegate::scheduleCallback(
    std::function<void(void)> callback,
    std::chrono::milliseconds delayMs) {
  RunWithDelayAsync(callback, delayMs);  // ✅ This part is OK
}

winrt::fire_and_forget RunWithDelayAsync(
    std::function<void(void)> callback, 
    std::chrono::milliseconds delayMs) {
  co_await winrt::resume_after(delayMs);
  ReactInspectorThread::Instance().InvokeElsePost([callback]() { callback(); });
}
```

### ReactInspectorWebSocket

```cpp
class ReactInspectorWebSocket : public facebook::react::jsinspector_modern::IWebSocket {
 public:
  ReactInspectorWebSocket(
      std::string const &url,
      std::weak_ptr<facebook::react::jsinspector_modern::IWebSocketDelegate> delegate);
  void send(std::string_view message) override;
  ~ReactInspectorWebSocket() override;

 private:
  std::shared_ptr<Microsoft::React::Networking::WinRTWebSocketResource> m_packagerWebSocketConnection;
  std::weak_ptr<facebook::react::jsinspector_modern::IWebSocketDelegate> m_weakDelegate;
};

ReactInspectorWebSocket::ReactInspectorWebSocket(
    std::string const &url,
    std::weak_ptr<facebook::react::jsinspector_modern::IWebSocketDelegate> delegate)
    : m_weakDelegate{delegate} {
  
  std::vector<winrt::Windows::Security::Cryptography::Certificates::ChainValidationResult> certExceptions;

  m_packagerWebSocketConnection =
      std::make_shared<Microsoft::React::Networking::WinRTWebSocketResource>(std::move(certExceptions));

  // ❌ ISSUE 1: SetOnMessage doesn't mean connection is open!
  m_packagerWebSocketConnection->SetOnMessage([delegate](auto &&, const std::string &message, bool isBinary) {
    ReactInspectorThread::Instance().InvokeElsePost([delegate, message]() {
      if (const auto strongDelegate = delegate.lock()) {
        strongDelegate->didReceiveMessage(message);
      }
    });
  });
  
  // ❌ ISSUE 2: SetOnError is for send/receive errors, NOT connection failures
  m_packagerWebSocketConnection->SetOnError(
      [delegate](const Microsoft::React::Networking::IWebSocketResource::Error &error) {
        ReactInspectorThread::Instance().InvokeElsePost([delegate, error]() {
          if (const auto strongDelegate = delegate.lock()) {
            strongDelegate->didFailWithError(std::nullopt, error.Message);
          }
        });
      });
  
  // ❌ ISSUE 3: SetOnClose might fire immediately before connection opens
  m_packagerWebSocketConnection->SetOnClose([delegate](auto &&...) {
    ReactInspectorThread::Instance().InvokeElsePost([delegate]() {
      if (const auto strongDelegate = delegate.lock()) {
        strongDelegate->didClose();
      }
    });
  });

  Microsoft::React::Networking::IWebSocketResource::Protocols protocols;
  Microsoft::React::Networking::IWebSocketResource::Options options;
  m_packagerWebSocketConnection->Connect(std::string{url}, protocols, options);
  
  // ❌ CRITICAL ISSUE 4: NO SetOnConnect() callback! 
  // delegate->didOpen() is NEVER called!
}

void ReactInspectorWebSocket::send(std::string_view message) {
  m_packagerWebSocketConnection->Send(std::string{message});
}

ReactInspectorWebSocket::~ReactInspectorWebSocket() {
  // ❌ ISSUE 5: WebSocket not properly closed
  // Commented out code means connection stays open after destruction
  
  // Avoiding async Close() during shutdown OS would cleanup the socket on process exit
  // std::string reason{"Explicit close"};
  // m_packagerWebSocketConnection->Close(
  //    Microsoft::React::Networking::WinRTWebSocketResource::CloseCode::GoingAway, reason);
}
```

## Critical Issues in Windows Implementation

### Issue 1: Missing didOpen() Callback ⚠️ CRITICAL

**Problem:** `ReactInspectorWebSocket` never calls `delegate->didOpen()`.

**Why this matters:**
```cpp
// InspectorPackagerConnection.cpp line 201
void InspectorPackagerConnection::Impl::didOpen() {
  connected_ = true;  // ← This flag is NEVER set!
}

// InspectorPackagerConnection.cpp line 228
bool InspectorPackagerConnection::Impl::isConnected() const {
  return webSocket_ != nullptr && connected_;  // ← Always returns false!
}
```

**Consequences:**
- `InspectorPackagerConnection` thinks it's never connected
- Reconnection logic constantly triggers
- `isConnected()` always returns `false`
- Messages may be dropped if sent before "connected" state

**Expected Flow:**
1. Create WebSocket
2. WebSocket connects asynchronously  
3. `WinRTWebSocketResource::PerformConnect()` succeeds
4. **MUST call** `SetOnConnect` callback → `delegate->didOpen()`
5. `InspectorPackagerConnection::Impl::didOpen()` sets `connected_ = true`

**Actual Flow:**
1. Create WebSocket
2. WebSocket connects asynchronously
3. `WinRTWebSocketResource::PerformConnect()` succeeds
4. ❌ **NO callback registered!**
5. `connected_` stays `false`
6. Reconnection timer triggers
7. Goto step 1 (infinite loop)

### Issue 2: Incorrect Error Handling

**Problem:** `SetOnError` is called for **send/receive errors**, NOT connection failures.

From `WinRTWebSocketResource.h`:
```cpp
enum class ErrorType {
  Ping,
  Send,
  Receive,
  Connection  // ← This is what we need to handle
};
```

The current implementation only catches **send/receive** errors via `SetOnError`, but connection failures happen in `PerformConnect()` and are reported differently.

**What should happen:**
```cpp
// In WinRTWebSocketResource::PerformConnect()
IAsyncAction WinRTWebSocketResource::PerformConnect(Uri &&uri) noexcept {
  // ...
  auto result = async.ErrorCode();
  if (result >= 0) {
    self->m_readyState = ReadyState::Open;
    if (self->m_connectHandler) {  // ← This is SetOnConnect callback
      self->m_connectHandler();
    }
  } else {
    if (self->m_errorHandler) {  // ← This is SetOnError callback
      self->m_errorHandler({
          Utilities::HResultToString(std::move(result)), 
          ErrorType::Connection  // ← Connection-specific error
      });
    }
  }
}
```

But `ReactInspectorWebSocket` doesn't register `SetOnConnect`, so success case is ignored!

### Issue 3: Race Condition in didClose()

**Problem:** `SetOnClose` callback might fire before connection is established.

**Scenario:**
1. `Connect()` is called
2. Connection fails immediately (e.g., Metro not running)
3. `WinRTWebSocketResource` calls `OnClose` handler
4. `delegate->didClose()` is called
5. `InspectorPackagerConnection::Impl::didClose()` tries to reconnect
6. But connection was never in `connected_` state!

This creates a ping-pong effect where:
- WebSocket tries to connect
- Fails immediately
- Triggers `didClose()`
- `reconnect()` is called
- New WebSocket created
- Repeat infinitely

### Issue 4: No Cleanup on Destruction

**Problem:** WebSocket is not properly closed when `ReactInspectorWebSocket` is destroyed.

**Why this matters:**
- Leaves dangling connections
- Metro thinks device is still connected
- Can prevent new connections
- Resource leak

**Correct implementation should be:**
```cpp
ReactInspectorWebSocket::~ReactInspectorWebSocket() {
  if (m_packagerWebSocketConnection) {
    m_packagerWebSocketConnection->Close(
        Microsoft::React::Networking::WinRTWebSocketResource::CloseCode::GoingAway, 
        "Inspector connection closed");
  }
}
```

### Issue 5: Thread Safety Concerns

The Windows implementation uses `ReactInspectorThread::Instance().InvokeElsePost()` for all callbacks, which is good. However, `WinRTWebSocketResource` callbacks may fire on different threads:

- `PerformConnect()` runs on background thread (`co_await resume_background()`)
- `OnMessageReceived()` fires on WinRT thread pool
- Callbacks must be marshaled to correct thread

**Current marshaling:**
```cpp
m_packagerWebSocketConnection->SetOnMessage([delegate](auto &&, const std::string &message, bool) {
  ReactInspectorThread::Instance().InvokeElsePost([delegate, message]() {
    if (const auto strongDelegate = delegate.lock()) {
      strongDelegate->didReceiveMessage(message);
    }
  });
});
```

This is **correct**, but it's only half the solution. We also need `SetOnConnect` marshaled correctly.

## How InspectorPackagerConnection Detects Connection State

### Connection State Machine

```cpp
// InspectorPackagerConnection::Impl state
std::unique_ptr<IWebSocket> webSocket_;  // ← Not null when socket exists
bool connected_{false};                   // ← Set by didOpen()
bool closed_{false};                      // ← Set by closeQuietly()
bool reconnectPending_{false};            // ← Reconnection scheduled

bool isConnected() const {
  return webSocket_ != nullptr && connected_;  // ← BOTH must be true!
}
```

### Connection Lifecycle

**Normal flow:**
```
1. connect() 
   → webSocket_ = delegate_->connectWebSocket(...)
   
2. WebSocket connects asynchronously
   → didOpen() is called
   → connected_ = true
   
3. [Connection active - messages can flow]
   
4. closeQuietly() or connection drops
   → didClose() is called
   → connected_ = false
   → webSocket_.reset()
```

**Windows ACTUAL flow:**
```
1. connect()
   → webSocket_ = std::make_unique<ReactInspectorWebSocket>(...)
   → ReactInspectorWebSocket constructor calls Connect()
   
2. WinRTWebSocketResource connects asynchronously
   → PerformConnect() succeeds
   → m_connectHandler() is called (if registered)
   → ❌ BUT SetOnConnect was never called!
   → ❌ didOpen() never called!
   → ❌ connected_ stays false!
   
3. isConnected() returns false (because connected_ == false)
   → reconnect() is triggered
   → Creates NEW WebSocket
   → Goto step 1 (infinite loop)
```

### Reconnection Logic

```cpp
void InspectorPackagerConnection::Impl::reconnect() {
  if (reconnectPending_) {
    return;  // Already have a reconnection scheduled
  }
  
  if (isConnected()) {
    return;  // Already connected (but this never happens on Windows!)
  }

  reconnectPending_ = true;

  delegate_->scheduleCallback(
      [weakSelf = weak_from_this()] {
        auto strongSelf = weakSelf.lock();
        if (strongSelf && !strongSelf->closed_) {
          strongSelf->reconnectPending_ = false;

          if (strongSelf->isConnected()) {
            return;  // Check again - still never true on Windows!
          }

          strongSelf->connect();  // ← Creates ANOTHER WebSocket!

          if (!strongSelf->isConnected()) {
            strongSelf->reconnect();  // ← Schedules ANOTHER reconnection!
          }
        }
      },
      RECONNECT_DELAY);  // 2 seconds
}
```

**On Windows:** Because `isConnected()` is always false, `reconnect()` keeps getting called every 2 seconds, creating new WebSocket instances that never properly signal connection success.

## The Fix: What Needs to Change

### Fix 1: Add SetOnConnect Callback ⚠️ CRITICAL

```cpp
ReactInspectorWebSocket::ReactInspectorWebSocket(
    std::string const &url,
    std::weak_ptr<facebook::react::jsinspector_modern::IWebSocketDelegate> delegate)
    : m_weakDelegate{delegate} {
  
  std::vector<winrt::Windows::Security::Cryptography::Certificates::ChainValidationResult> certExceptions;

  m_packagerWebSocketConnection =
      std::make_shared<Microsoft::React::Networking::WinRTWebSocketResource>(std::move(certExceptions));

  // ✅ FIX: Add SetOnConnect callback
  m_packagerWebSocketConnection->SetOnConnect([delegate]() {
    ReactInspectorThread::Instance().InvokeElsePost([delegate]() {
      if (const auto strongDelegate = delegate.lock()) {
        strongDelegate->didOpen();  // ← This is the critical missing call!
      }
    });
  });

  m_packagerWebSocketConnection->SetOnMessage([delegate](auto &&, const std::string &message, bool isBinary) {
    ReactInspectorThread::Instance().InvokeElsePost([delegate, message]() {
      if (const auto strongDelegate = delegate.lock()) {
        strongDelegate->didReceiveMessage(message);
      }
    });
  });
  
  m_packagerWebSocketConnection->SetOnError(
      [delegate](const Microsoft::React::Networking::IWebSocketResource::Error &error) {
        ReactInspectorThread::Instance().InvokeElsePost([delegate, error]() {
          if (const auto strongDelegate = delegate.lock()) {
            // ✅ FIX: Distinguish connection errors from send/receive errors
            if (error.Type == Microsoft::React::Networking::IWebSocketResource::ErrorType::Connection) {
              // Connection failed - will trigger reconnection
              strongDelegate->didFailWithError(std::nullopt, error.Message);
            } else {
              // Send/receive error - may not need full reconnection
              // Could log or handle differently
            }
          }
        });
      });
  
  m_packagerWebSocketConnection->SetOnClose([delegate](auto &&...) {
    ReactInspectorThread::Instance().InvokeElsePost([delegate]() {
      if (const auto strongDelegate = delegate.lock()) {
        strongDelegate->didClose();
      }
    });
  });

  Microsoft::React::Networking::IWebSocketResource::Protocols protocols;
  Microsoft::React::Networking::IWebSocketResource::Options options;
  m_packagerWebSocketConnection->Connect(std::string{url}, protocols, options);
}
```

### Fix 2: Proper Cleanup on Destruction

```cpp
ReactInspectorWebSocket::~ReactInspectorWebSocket() {
  if (m_packagerWebSocketConnection) {
    std::string reason{"Inspector connection closed"};
    m_packagerWebSocketConnection->Close(
        Microsoft::React::Networking::WinRTWebSocketResource::CloseCode::GoingAway, 
        reason);
  }
}
```

### Fix 3: Handle Connection State Correctly

The current implementation assumes WebSocket is immediately connected after `Connect()` is called. This is incorrect - connection is **asynchronous**.

The fixed implementation should:

1. ✅ Call `Connect()` (async operation starts)
2. ✅ Wait for `SetOnConnect` callback
3. ✅ Call `delegate->didOpen()`
4. ✅ Now `InspectorPackagerConnection` knows we're connected
5. ✅ Messages can flow

## Testing the Fix

### Verification Steps

1. **Add logging** to trace WebSocket lifecycle:
   ```cpp
   // In ReactInspectorWebSocket constructor
   OutputDebugStringA("[Inspector] Creating WebSocket connection\n");
   
   // In SetOnConnect callback
   OutputDebugStringA("[Inspector] WebSocket connected - calling didOpen()\n");
   
   // In SetOnClose callback
   OutputDebugStringA("[Inspector] WebSocket closed - calling didClose()\n");
   
   // In SetOnError callback
   OutputDebugStringA("[Inspector] WebSocket error\n");
   ```

2. **Check Metro logs** - should see:
   ```
   Debugger session from <device> for <app>
   ```
   Only ONCE, not repeatedly every 2 seconds

3. **Check RNW logs** - should see:
   ```
   [Inspector] Creating WebSocket connection
   [Inspector] WebSocket connected - calling didOpen()
   ```
   NOT:
   ```
   [Inspector] Creating WebSocket connection
   [Inspector] Creating WebSocket connection  ← Repeated creation = BUG
   [Inspector] Creating WebSocket connection
   ```

4. **Open Chrome DevTools** - connection should be stable, no reconnections

### Expected Behavior After Fix

- ✅ Single WebSocket connection established
- ✅ Connection stays open
- ✅ `isConnected()` returns `true`
- ✅ CDP messages flow correctly
- ✅ No constant reconnections
- ✅ Can see list of source files from Metro bundler

## Additional Notes: Script List from Metro

The user observed that they only see 2 files:
1. `http://localhost:8081/Samples/rntester.bundle//&platform=windows...` (bundle file)
2. `Form_JSI_API_not_a_real_file`

But with old debugger saw 100+ files.

**Explanation:**

The **old debugger** connects to Metro's `/debugger-proxy` endpoint which:
- Receives source maps from Metro
- Expands bundle into individual source files
- Sends `Debugger.scriptParsed` for each source file

The **new debugger** connects directly to Hermes VM which:
- Only knows about the bundle file it loaded
- Doesn't have Metro's source map information
- Only reports files it actually loaded

This is **expected behavior**. The individual source files should come from **source maps** loaded by Chrome DevTools, not from `Debugger.scriptParsed` events.

However, the constant reconnection issue may be preventing the frontend from properly loading source maps, which would explain why you're not seeing individual files.

**After fixing the WebSocket issues**, the frontend should:
1. Receive `Debugger.scriptParsed` for the bundle file
2. Load source map from Metro
3. Display individual source files based on source map

## Conclusion

The Windows implementation of `ReactInspectorPackagerConnectionDelegate` has a critical missing piece: it never calls `delegate->didOpen()` when the WebSocket successfully connects.

This single missing callback causes a cascade of issues:
- Connection state is never set to "connected"
- Reconnection logic thinks connection failed
- New WebSocket instances created every 2 seconds
- Instability prevents proper debugger operation

**The fix is simple: Add `SetOnConnect()` callback that calls `delegate->didOpen()`.**

This is a **ONE LINE FIX** that will unblock the entire modern inspector implementation.
