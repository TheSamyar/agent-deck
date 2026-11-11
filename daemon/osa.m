#import <node_api.h>
#import <Foundation/Foundation.h>
#import <OSAKit/OSAKit.h>
#import <Carbon/Carbon.h>

// Runs AppleScript inside node. node is already allowed to control the Mac,
// and a separate osascript process is not.

static NSString *TextOf(NSAppleEventDescriptor *result) {
  if (result == nil) return @"";
  NSString *text = result.stringValue;
  if (text != nil) return text;
  NSAppleEventDescriptor *coerced = [result coerceToDescriptorType:typeUnicodeText];
  return coerced.stringValue ?: @"";
}

static NSString *AppleQuote(NSString *value) {
  NSString *escaped = [value stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
  escaped = [escaped stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
  return [NSString stringWithFormat:@"\"%@\"", escaped];
}

static NSString *RunScript(NSString *source, NSArray<NSString *> *argv, NSString **errorOut) {
  {
    NSArray<NSString *> *lines = [source componentsSeparatedByString:@"\n"];
    NSMutableArray<NSString *> *quoted = [NSMutableArray array];
    for (NSString *line in lines) [quoted addObject:AppleQuote(line)];
    NSMutableArray<NSString *> *params = [NSMutableArray array];
    for (NSString *arg in argv) [params addObject:AppleQuote(arg)];
    source = [NSString stringWithFormat:@"with timeout of 3 seconds\nrun script (%@) with parameters {%@}\nend timeout",
              [quoted componentsJoinedByString:@" & linefeed & "],
              [params componentsJoinedByString:@", "]];
  }
  NSAppleScript *script = [[NSAppleScript alloc] initWithSource:source];
  if (script == nil) {
    *errorOut = @"Could not read the AppleScript.";
    return nil;
  }
  NSDictionary *errorInfo = nil;
  NSAppleEventDescriptor *result = [script executeAndReturnError:&errorInfo];
  if (errorInfo != nil) {
    NSString *message = errorInfo[NSAppleScriptErrorMessage];
    NSNumber *number = errorInfo[NSAppleScriptErrorNumber];
    *errorOut = [NSString stringWithFormat:@"%@ (%@)", message ?: @"AppleScript failed", number ?: @0];
    return nil;
  }
  return TextOf(result);
}

static NSString *CopyString(napi_env env, napi_value value) {
  size_t length = 0;
  napi_get_value_string_utf8(env, value, NULL, 0, &length);
  char *buffer = calloc(length + 1, 1);
  napi_get_value_string_utf8(env, value, buffer, length + 1, &length);
  NSString *text = [NSString stringWithUTF8String:buffer] ?: @"";
  free(buffer);
  return text;
}

static napi_value MakeResult(napi_env env, BOOL ok, NSString *stdoutText, NSString *errorText) {
  napi_value result, okValue, outValue, errValue;
  napi_create_object(env, &result);
  napi_get_boolean(env, ok, &okValue);
  napi_create_string_utf8(env, stdoutText.UTF8String ?: "", NAPI_AUTO_LENGTH, &outValue);
  napi_create_string_utf8(env, errorText.UTF8String ?: "", NAPI_AUTO_LENGTH, &errValue);
  napi_set_named_property(env, result, "ok", okValue);
  napi_set_named_property(env, result, "stdout", outValue);
  napi_set_named_property(env, result, "error", errValue);
  return result;
}

static napi_value Run(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2];
  napi_get_cb_info(env, info, &argc, args, NULL, NULL);
  if (argc < 1) return MakeResult(env, NO, @"", @"Missing script.");

  NSString *source = CopyString(env, args[0]);
  NSMutableArray<NSString *> *argv = [NSMutableArray array];
  if (argc > 1) {
    uint32_t count = 0;
    napi_get_array_length(env, args[1], &count);
    for (uint32_t i = 0; i < count; i++) {
      napi_value item;
      napi_get_element(env, args[1], i, &item);
      [argv addObject:CopyString(env, item)];
    }
  }

  NSString *errorText = nil;
  NSString *output = RunScript(source, argv, &errorText);
  if (output == nil) return MakeResult(env, NO, @"", errorText ?: @"AppleScript failed");
  return MakeResult(env, YES, output, @"");
}

static napi_value Init(napi_env env, napi_value exports) {
  napi_value fn;
  napi_create_function(env, "run", NAPI_AUTO_LENGTH, Run, NULL, &fn);
  napi_set_named_property(env, exports, "run", fn);
  return exports;
}

NAPI_MODULE(osa, Init)
