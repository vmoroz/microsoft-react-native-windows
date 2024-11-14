// Core RN code expects to be able to use #include <FBReactNativeSpec/FBReactNativeSpecJSI.h> to import the generated headers.
// We should look into moving the codegen output into a FBReactNativeSpec folder, and running codegen using FBReactNative as the library name
// But for now this redirection header will suffice
#include <codegen/rnwcoreJSI.h>