# Modern Inspector Integration - TODO List

This document provides a concise checklist of tasks for completing modern inspector integration in React Native Windows. For detailed explanations, refer to `modern-inspector-windows.md` and `modern-inspector-hermes.md`.

## Legend
- ✅ Done
- 🔧 In Progress
- ⚠️ Needs Investigation
- ❌ Not Started
- 💡 Optional Enhancement

## Core Integration Tasks

### Inspector Infrastructure

- [ ] ❌ Move inspector code from ReactNativeHost.cpp to ReactHost.cpp (RNH should be thin ABI layer)
- [ ] ❌ Register inspector pages only when direct debugger is enabled for RNH
- [ ] ❌ Handle inspector page registration/unregistration on reload when debugger enabled/disabled
- [ ] ❌ Implement/fix debugger overlay when instance is paused in debugger
- [ ] ❌ Remove old Hermes-specific inspector code in favor of modern inspector
- [ ] ⚠️ Verify synchronous inspector registration before JS execution (bridgeless)
- [ ] ⚠️ Verify synchronous inspector registration before JS execution (bridge-based)
- [ ] ❌ Add bridge-based architecture support (pass InspectorTarget to Instance::initializeBridge)
- [ ] ❌ Remove Fusebox flag gate once verified stable
- [ ] 🔧 Fix thread safety for cleanup (dispatch to ReactInspectorThread in destructor)
- [ ] ⚠️ Verify RuntimeTarget and InstanceTarget registration/unregistration flow
- [ ] ⚠️ Test `unregisterFromInspector()` is called before ReactInstance destruction

### CDP Protocol Implementation

- [x] ✅ Fix domain enablement (use SessionState flags, not unconditional enable)
- [ ] ⚠️ Verify RuntimeAgent forwards CDP requests correctly
- [ ] ⚠️ Test CDP message routing (Runtime, Debugger, Log domains)
- [ ] ⚠️ Verify FrontendChannel propagation through agent hierarchy
- [ ] ⚠️ Test console.log() messages appear in debugger

### Multi-Instance Support

- [ ] ❌ Add unique page descriptions per ReactNativeHost (include BundleAppId)
- [ ] ⚠️ Test multiple ReactNativeHost instances with different BundleAppIds
- [ ] 💡 Support multiple packager connections for different Metro instances
- [ ] ⚠️ Validate packager settings when multiple instances use different hosts/ports

### WebSocket & Connectivity

- [ ] ⚠️ Test WebSocket connection to Metro inspector proxy
- [ ] ⚠️ Verify ReactInspectorPackagerConnectionDelegate thread safety
- [ ] ⚠️ Test direct CDP server (UseDirectDebugger) mode
- [ ] ⚠️ Verify bundled JS debugging with direct CDP connection

## Hermes ABI-Stable API

### Core Debugger API

- [x] ✅ Define `hermes_debugger_vtable` structure
- [x] ✅ Implement core CDP agent functions (create, handle_command, enable domains)
- [ ] ❌ Add console message support (`add_console_message`)
- [ ] ❌ Add profiling support (`enable/disable_sampling_profiler`, `collect_sampling_profile`)
- [ ] ⚠️ Test state persistence (get_cdp_state, restore on reconnect)
- [ ] ⚠️ Verify stack trace capture works correctly

### Integration with RN Inspector

- [ ] ⚠️ Verify HermesRuntimeTargetDelegate provides correct RuntimeTargetDelegate implementation
- [ ] ⚠️ Test HermesRuntimeAgentDelegate respects SessionState domain flags
- [ ] ⚠️ Verify FrontendChannel callback reaches Hermes CDPAgent
- [ ] ⚠️ Test RuntimeTask executor for JS thread execution
- [ ] ⚠️ Verify HermesRuntimeHolder cleanup doesn't race with inspector unregistration

### SessionState Handling

- [ ] ⚠️ Verify conditional domain enablement in HermesRuntimeAgentDelegate
- [ ] ⚠️ Test multiple debugging sessions with different domains enabled
- [ ] ⚠️ Verify session state persistence across disconnects/reconnects

## Testing & Validation

### Basic Functionality

- [ ] ⚠️ Verify page appears in `chrome://inspect`
- [ ] ⚠️ Test successful WebSocket connection establishment
- [ ] ⚠️ Test breakpoint setting and hitting
- [ ] ⚠️ Test step over/into/out debugging
- [ ] ⚠️ Test evaluate expression in debugger
- [ ] ⚠️ Test console output appears in DevTools
- [ ] ⚠️ Test reload from debugger
- [ ] ⚠️ Test debugger overlay (paused in debugger message)

### Architecture-Specific

- [ ] ⚠️ Test bridgeless (Fabric) architecture debugging
- [ ] ⚠️ Test bridge-based (non-Fabric) architecture debugging
- [ ] ⚠️ Test with Hermes engine
- [ ] ⚠️ Test with V8 engine (if supported)

### Multi-Instance Scenarios

- [ ] ⚠️ Test multiple ReactNativeHost instances with unique descriptions
- [ ] ⚠️ Test debugging different instances simultaneously
- [ ] ⚠️ Test bundled JS + packager JS in different instances
- [ ] ⚠️ Test instance reload doesn't break other instances' debugging

### Edge Cases & Robustness

- [ ] ⚠️ Test clean shutdown without crashes
- [ ] ⚠️ Test debugger disconnect/reconnect cycles
- [ ] ⚠️ Test rapid reload operations
- [ ] ⚠️ Test memory cleanup (no leaks after multiple reload cycles)
- [ ] ⚠️ Test race conditions during destruction

## Documentation & Examples

- [ ] ❌ Create developer guide for enabling modern inspector
- [ ] ❌ Document required Metro configuration
- [ ] ❌ Create troubleshooting guide for common issues
- [ ] ❌ Document differences from legacy web debugging
- [ ] ❌ Create migration guide from web debugging to modern inspector
- [ ] ❌ Add code examples for different debugging scenarios
- [ ] ❌ Document multi-instance debugging patterns
- [ ] ❌ Document direct CDP debugging for bundled JS

## Performance & Security

- [ ] ⚠️ Verify no performance impact when debugger not connected
- [ ] ⚠️ Measure overhead of inspector infrastructure
- [ ] ❌ Add security recommendations for production builds
- [ ] ❌ Document how to disable inspector in production
- [ ] ❌ Add compile-time flag to exclude inspector code

## Code Quality

- [ ] ⚠️ Add logging/diagnostics for inspector operations
- [ ] ⚠️ Add assertions for critical invariants
- [ ] ⚠️ Review error handling paths
- [ ] ⚠️ Add unit tests for inspector components (if feasible)
- [ ] ⚠️ Add integration tests for CDP protocol
- [ ] ❌ Review thread safety across all inspector code paths

## Future Enhancements (Optional)

- [ ] 💡 Support VSCode debugging protocol
- [ ] 💡 Add inspector UI in app (in-app debugger)
- [ ] 💡 Add network inspection support
- [ ] 💡 Add React DevTools integration
- [ ] 💡 Support profiling/performance analysis tools
- [ ] 💡 Add memory leak detection tools
- [ ] 💡 Support remote debugging over network

## Notes

### Critical Path Items (Must Do First)
1. **Move inspector code from ReactNativeHost to ReactHost** (architectural cleanup)
2. **Conditional inspector registration** (only when direct debugger enabled)
3. **Handle debugger enable/disable on reload** (DevMenu scenario)
4. Verify synchronous inspector registration
5. Fix conditional domain enablement (already done)
6. Test basic debugging flow (breakpoints, console)
7. Add bridge-based architecture support

### High Priority (Do Soon)
1. **Implement/fix debugger overlay** (blocked in debugger UI)
2. **Remove old Hermes inspector code** (cleanup legacy code)
3. Add unique page descriptions for multi-instance
4. Fix thread-safe cleanup in destructors
5. Test bundled JS debugging
6. Add console message support to Hermes ABI

### Medium Priority
1. Add profiling support to Hermes ABI
2. Create developer documentation
3. Test edge cases and robustness
4. Performance validation

### Low Priority (Nice to Have)
1. Advanced multi-instance scenarios
2. Security hardening for production
3. Future enhancements

## References

- **Detailed Architecture**: `modern-inspector-windows.md`
- **Hermes Integration**: `modern-inspector-hermes.md`
- **iOS Implementation**: `modern-inspector-ios.md`
- **Android Implementation**: `modern-inspector-android.md`
