@isTest
private class McpToolTesterTest {
  @isTest
  static void testCallMcpServerSuccess() {
    Test.setMock(
      HttpCalloutMock.class,
      new McpMockHttpResponse(
        200,
        '{"jsonrpc":"2.0","result":{"protocolVersion":"2025-06-18"},"id":1}'
      )
    );

    Test.startTest();
    String result = McpToolTester.callMcpServer(
      'TestServer',
      '{"jsonrpc":"2.0","id":1,"method":"initialize"}'
    );
    Test.stopTest();

    System.assertNotEquals(null, result);
    System.assert(result.contains('protocolVersion'));
  }

  @isTest
  static void testCallMcpServerError() {
    Test.setMock(
      HttpCalloutMock.class,
      new McpMockHttpResponse(500, '{"error":"Internal Server Error"}')
    );

    Test.startTest();
    try {
      McpToolTester.callMcpServer(
        'TestServer',
        '{"jsonrpc":"2.0","id":1,"method":"initialize"}'
      );
      System.assert(false, 'Expected exception was not thrown');
    } catch (AuraHandledException e) {
      String errorMessage = e.getMessage();
      System.debug('Error Message: ' + errorMessage);
      
      System.assert(errorMessage.contains('statusCode'), 'Expected error message to contain statusCode detail');
      System.assert(errorMessage.contains('_error'), 'Expected error message to contain _error flag');
    }
    Test.stopTest();
  }

  @isTest
  static void testInitializeConnection() {
    Test.setMock(
      HttpCalloutMock.class,
      new McpMockHttpResponse(
        200,
        '{"jsonrpc":"2.0","result":{"protocolVersion":"2025-06-18","serverInfo":{"name":"test","version":"1.0.0"}},"id":1}'
      )
    );

    Test.startTest();
    String result = McpToolTester.initializeConnection('TestServer');
    Test.stopTest();

    System.assertNotEquals(null, result);
    System.assert(result.contains('serverInfo'));
  }

  @isTest
  static void testGetAvailableTools() {
    String toolsResponse =
      '{"jsonrpc":"2.0","result":{"tools":[' +
      '{"name":"testTool","description":"Test tool","inputSchema":{"type":"object","properties":{"param1":{"type":"string"}}}}' +
      ']},"id":2}';
    Test.setMock(
      HttpCalloutMock.class,
      new McpMockHttpResponse(200, toolsResponse)
    );

    Test.startTest();
    String result = McpToolTester.getAvailableTools('TestServer');
    Test.stopTest();

    System.assertNotEquals(null, result);
    System.assert(result.contains('tools'));
    System.assert(result.contains('testTool'));
  }

  @isTest
  static void testGetAvailableResources() {
    String resourcesResponse =
      '{"jsonrpc":"2.0","result":{"resources":[' +
      '{"uri":"test://resource","name":"Test Resource","description":"A test resource"}' +
      ']},"id":3}';
    Test.setMock(
      HttpCalloutMock.class,
      new McpMockHttpResponse(200, resourcesResponse)
    );

    Test.startTest();
    String result = McpToolTester.getAvailableResources('TestServer');
    Test.stopTest();

    System.assertNotEquals(null, result);
    System.assert(result.contains('resources'));
  }

  @isTest
  static void testCallToolWithParameters() {
    String toolResponse = '{"jsonrpc":"2.0","result":{"content":[{"type":"text","text":"Success"}]},"id":4}';
    Test.setMock(
      HttpCalloutMock.class,
      new McpMockHttpResponse(200, toolResponse)
    );

    Test.startTest();
    String result = McpToolTester.callTool(
      'TestServer',
      'testTool',
      '{"param1":"value1"}'
    );
    Test.stopTest();

    System.assertNotEquals(null, result);
    System.assert(result.contains('content'));
  }

  @isTest
  static void testCallToolWithoutParameters() {
    String toolResponse = '{"jsonrpc":"2.0","result":{"content":[{"type":"text","text":"Success"}]},"id":5}';
    Test.setMock(
      HttpCalloutMock.class,
      new McpMockHttpResponse(200, toolResponse)
    );

    Test.startTest();
    String result = McpToolTester.callTool('TestServer', 'testTool', '');
    Test.stopTest();

    System.assertNotEquals(null, result);
    System.assert(result.contains('content'));
  }

  @isTest
  static void testCallToolError() {
    Test.setMock(
      HttpCalloutMock.class,
      new McpMockHttpResponse(
        400,
        '{"jsonrpc":"2.0","error":{"code":-32602,"message":"Invalid params"},"id":6}'
      )
    );

    Test.startTest();
    try {
      McpToolTester.callTool('TestServer', 'testTool', '{"invalid":"param"}');
      System.assert(false, 'Expected exception was not thrown');
    } catch (AuraHandledException e) {
      String errorMessage = e.getMessage();
      System.assert(errorMessage.contains('statusCode'), 'Expected error message to contain statusCode detail');
      System.assert(errorMessage.contains('_error'), 'Expected error message to contain _error flag');
    }
    Test.stopTest();
  }

  @isTest
  static void testGetAvailableServers() {
    Test.startTest();
    List<McpToolTester.ServerOption> servers = McpToolTester.getAvailableServers();
    Test.stopTest();

    // Should return list (may be empty if no Named Credentials exist)
    System.assertNotEquals(null, servers);
  }

  @isTest
  static void testParseSseResponse() {
    String sseResponse = 'event: message\ndata: {"jsonrpc":"2.0","result":{"tools":[]},"id":2}\n\n';

    Test.startTest();
    String result = McpToolTester.parseSseResponse(sseResponse);
    Test.stopTest();

    System.assert(result.contains('jsonrpc'));
    System.assert(result.contains('tools'));
  }

  @isTest
  static void testParseSseResponsePlainJson() {
    String jsonResponse = '{"jsonrpc":"2.0","result":{"tools":[]},"id":2}';

    Test.startTest();
    String result = McpToolTester.parseSseResponse(jsonResponse);
    Test.stopTest();

    System.assertEquals(jsonResponse, result);
  }

  @isTest
  static void testServerOptionConstructor() {
    Test.startTest();
    McpToolTester.ServerOption option = new McpToolTester.ServerOption(
      'testValue',
      'Test Label'
    );
    Test.stopTest();

    System.assertEquals('testValue', option.value);
    System.assertEquals('Test Label', option.label);
  }

  @isTest
  static void testBuildQualifiedNameWithNamespace() {
    System.assertEquals(
      'ns__MyCredential',
      McpToolTester.buildQualifiedName('ns', 'MyCredential'),
      'Should prepend namespace prefix with double underscore'
    );
  }

  @isTest
  static void testBuildQualifiedNameWithNullNamespace() {
    System.assertEquals(
      'MyCredential',
      McpToolTester.buildQualifiedName(null, 'MyCredential'),
      'Should return DeveloperName only when namespace is null'
    );
  }

  @isTest
  static void testBuildQualifiedNameWithEmptyNamespace() {
    System.assertEquals(
      'MyCredential',
      McpToolTester.buildQualifiedName('', 'MyCredential'),
      'Should return DeveloperName only when namespace is empty'
    );
  }

  // ===================================================================
  // Group 1 -- HTTP status surfacing
  //
  // Each test mocks a non-2xx HTTP response and asserts the
  // AuraHandledException message that the LWC actually receives.
  // Path: callMcpServer throws McpException(JSON) -> caught at the
  //       inner catch(McpException) -> rethrown as AuraHandledException
  //       -> wrapper catches AuraHandledException and rethrows as-is.
  // Therefore on HTTP errors the wrappers do NOT prefix the JSON.
  // ===================================================================

  @isTest
  static void testCallMcpServer_400JsonRpcError_PopulatesMcpErrorAndExplanation() {
    Test.setMock(
      HttpCalloutMock.class,
      new McpMockHttpResponse(
        400,
        '{"jsonrpc":"2.0","error":{"code":-32602,"message":"Invalid params"},"id":1}'
      )
    );

    Test.startTest();
    try {
      McpToolTester.callMcpServer('TestServer', '{"jsonrpc":"2.0","id":1,"method":"initialize"}');
      System.assert(false, 'Expected AuraHandledException');
    } catch (AuraHandledException e) {
      String msg = e.getMessage();
      System.assert(msg.contains('"_error":true'), 'Missing _error flag: ' + msg);
      System.assert(msg.contains('"statusCode":400'), 'Missing statusCode: ' + msg);
      System.assert(msg.contains('"mcpError"'), 'Missing mcpError enrichment: ' + msg);
      System.assert(msg.contains('Invalid params'), 'Missing JSON-RPC error message: ' + msg);
      System.assert(msg.contains('Bad Request'), 'Missing 400 explanation: ' + msg);
    }
    Test.stopTest();
  }

  @isTest
  static void testCallMcpServer_401_ExplanationMentionsCredentialAndPermSet() {
    Test.setMock(
      HttpCalloutMock.class,
      new McpMockHttpResponse(401, '{"error":"invalid_token"}')
    );

    Test.startTest();
    try {
      McpToolTester.callMcpServer('PetStore', '{"jsonrpc":"2.0","id":1,"method":"initialize"}');
      System.assert(false, 'Expected AuraHandledException');
    } catch (AuraHandledException e) {
      String msg = e.getMessage();
      System.assert(msg.contains('"statusCode":401'), 'Missing statusCode: ' + msg);
      System.assert(msg.contains('Unauthorized'), 'Missing 401 explanation: ' + msg);
      System.assert(msg.contains('PetStore'), 'Explanation should reference Named Credential: ' + msg);
      System.assert(msg.contains('permission set'), 'Explanation should mention perm set: ' + msg);
    }
    Test.stopTest();
  }

  // After the A.4 fix: a 403 whose body looks like an IP-allowlist
  // denial gets the dedicated explanation pointing the user at the
  // org's outbound IPs. Body is still embedded in rawResponse.
  @isTest
  static void testCallMcpServer_403IpBlocked_HitsIpAllowlistExplanation() {
    String body = 'IP address 1.2.3.4 is not allowed to access this service';
    Test.setMock(
      HttpCalloutMock.class,
      new McpMockHttpResponse(403, body)
    );

    Test.startTest();
    try {
      McpToolTester.callMcpServer('TestServer', '{"jsonrpc":"2.0","id":1,"method":"initialize"}');
      System.assert(false, 'Expected AuraHandledException');
    } catch (AuraHandledException e) {
      String msg = e.getMessage();
      System.assert(msg.contains('"statusCode":403'), 'Missing statusCode: ' + msg);
      System.assert(msg.contains('1.2.3.4'), 'Raw response body should be embedded: ' + msg);
      System.assert(!msg.contains('"mcpError"'), 'Plain-text body should NOT yield mcpError: ' + msg);
      String explanation = extractExplanation(msg);
      System.assertNotEquals(null, explanation, 'Explanation must be present: ' + msg);
      System.assert(explanation.containsIgnoreCase('IP allowlist'),
        'Explanation should call out IP allowlist: ' + explanation);
      System.assert(explanation.containsIgnoreCase('outbound IP'),
        'Explanation should mention outbound IPs: ' + explanation);
    }
    Test.stopTest();
  }

  @isTest
  static void testCallMcpServer_404Empty_ExplanationMentionsEndpoint() {
    Test.setMock(HttpCalloutMock.class, new McpMockHttpResponse(404, ''));

    Test.startTest();
    try {
      McpToolTester.callMcpServer('TestServer', '{"jsonrpc":"2.0","id":1,"method":"tools/list"}');
      System.assert(false, 'Expected AuraHandledException');
    } catch (AuraHandledException e) {
      String msg = e.getMessage();
      System.assert(msg.contains('"statusCode":404'), 'Missing statusCode: ' + msg);
      System.assert(msg.contains('Not Found'), 'Missing 404 explanation: ' + msg);
      System.assert(msg.contains('Named Credential URL'), 'Explanation should reference URL: ' + msg);
    }
    Test.stopTest();
  }

  @isTest
  static void testCallMcpServer_406_ExplanationMentionsAcceptHeader() {
    Test.setMock(HttpCalloutMock.class, new McpMockHttpResponse(406, 'Not Acceptable'));

    Test.startTest();
    try {
      McpToolTester.callMcpServer('TestServer', '{"jsonrpc":"2.0","id":1,"method":"tools/list"}');
      System.assert(false, 'Expected AuraHandledException');
    } catch (AuraHandledException e) {
      String msg = e.getMessage();
      System.assert(msg.contains('"statusCode":406'), 'Missing statusCode: ' + msg);
      System.assert(msg.contains('Accept'), 'Explanation should mention Accept header: ' + msg);
    }
    Test.stopTest();
  }

  @isTest
  static void testCallMcpServer_429_ExplanationMentionsRateLimit() {
    Test.setMock(
      HttpCalloutMock.class,
      new McpMockHttpResponse(429, '{"error":"rate_limited","retry_after":60}')
    );

    Test.startTest();
    try {
      McpToolTester.callMcpServer('TestServer', '{"jsonrpc":"2.0","id":1,"method":"tools/list"}');
      System.assert(false, 'Expected AuraHandledException');
    } catch (AuraHandledException e) {
      String msg = e.getMessage();
      System.assert(msg.contains('"statusCode":429'), 'Missing statusCode: ' + msg);
      System.assert(msg.contains('Too Many Requests'), 'Missing 429 explanation: ' + msg);
    }
    Test.stopTest();
  }

  // Pins A.1: a non-JSON 5xx body must still be carried through as
  // rawResponse, but mcpError enrichment should be silently skipped.
  @isTest
  static void testCallMcpServer_500HtmlBody_RawResponsePreservedNoMcpError() {
    String body = '<html><body><h1>500 Internal Server Error</h1></body></html>';
    Test.setMock(HttpCalloutMock.class, new McpMockHttpResponse(500, body));

    Test.startTest();
    try {
      McpToolTester.callMcpServer('TestServer', '{"jsonrpc":"2.0","id":1,"method":"tools/list"}');
      System.assert(false, 'Expected AuraHandledException');
    } catch (AuraHandledException e) {
      String msg = e.getMessage();
      System.assert(msg.contains('"statusCode":500'), 'Missing statusCode: ' + msg);
      System.assert(msg.contains('500 Internal Server Error'), 'Raw HTML body should be embedded: ' + msg);
      System.assert(!msg.contains('"mcpError"'), 'Non-JSON body should not yield mcpError: ' + msg);
      System.assert(msg.contains('Internal Server Error'), 'Missing 500 explanation: ' + msg);
    }
    Test.stopTest();
  }

  @isTest
  static void testCallMcpServer_502_ExplanationMentionsBadGateway() {
    Test.setMock(HttpCalloutMock.class, new McpMockHttpResponse(502, 'Bad Gateway'));

    Test.startTest();
    try {
      McpToolTester.callMcpServer('TestServer', '{"jsonrpc":"2.0","id":1,"method":"tools/list"}');
      System.assert(false, 'Expected AuraHandledException');
    } catch (AuraHandledException e) {
      String msg = e.getMessage();
      System.assert(msg.contains('"statusCode":502'), 'Missing statusCode: ' + msg);
      System.assert(msg.contains('Bad Gateway'), 'Missing 502 explanation: ' + msg);
    }
    Test.stopTest();
  }

  @isTest
  static void testCallMcpServer_503_ExplanationMentionsServiceUnavailable() {
    Test.setMock(HttpCalloutMock.class, new McpMockHttpResponse(503, 'Service Unavailable'));

    Test.startTest();
    try {
      McpToolTester.callMcpServer('TestServer', '{"jsonrpc":"2.0","id":1,"method":"tools/list"}');
      System.assert(false, 'Expected AuraHandledException');
    } catch (AuraHandledException e) {
      String msg = e.getMessage();
      System.assert(msg.contains('"statusCode":503'), 'Missing statusCode: ' + msg);
      System.assert(msg.contains('Service Unavailable'), 'Missing 503 explanation: ' + msg);
    }
    Test.stopTest();
  }

  @isTest
  static void testCallMcpServer_504_ExplanationMentionsGatewayTimeout() {
    Test.setMock(HttpCalloutMock.class, new McpMockHttpResponse(504, 'Gateway Timeout'));

    Test.startTest();
    try {
      McpToolTester.callMcpServer('TestServer', '{"jsonrpc":"2.0","id":1,"method":"tools/list"}');
      System.assert(false, 'Expected AuraHandledException');
    } catch (AuraHandledException e) {
      String msg = e.getMessage();
      System.assert(msg.contains('"statusCode":504'), 'Missing statusCode: ' + msg);
      System.assert(msg.contains('Gateway Timeout'), 'Missing 504 explanation: ' + msg);
    }
    Test.stopTest();
  }

  // Pins the fallback branch in getErrorExplanation for unmapped codes.
  @isTest
  static void testCallMcpServer_418Unmapped_FallsBackToGenericExplanation() {
    Test.setMock(HttpCalloutMock.class, new McpMockHttpResponse(418, 'I\'m a teapot'));

    Test.startTest();
    try {
      McpToolTester.callMcpServer('TestServer', '{"jsonrpc":"2.0","id":1,"method":"tools/list"}');
      System.assert(false, 'Expected AuraHandledException');
    } catch (AuraHandledException e) {
      String msg = e.getMessage();
      System.assert(msg.contains('"statusCode":418'), 'Missing statusCode: ' + msg);
      System.assert(msg.contains('HTTP 418 error occurred'), 'Should hit generic fallback: ' + msg);
    }
    Test.stopTest();
  }

  // After the A.5 fix: 407 has a dedicated explanation that points at
  // the proxy-auth requirement.
  @isTest
  static void testCallMcpServer_407_HitsProxyAuthExplanation() {
    Test.setMock(
      HttpCalloutMock.class,
      new McpMockHttpResponse(407, 'Proxy Authentication Required')
    );

    Test.startTest();
    try {
      McpToolTester.callMcpServer('TestServer', '{"jsonrpc":"2.0","id":1,"method":"tools/list"}');
      System.assert(false, 'Expected AuraHandledException');
    } catch (AuraHandledException e) {
      String msg = e.getMessage();
      System.assert(msg.contains('"statusCode":407'), 'Missing statusCode: ' + msg);
      String explanation = extractExplanation(msg);
      System.assertNotEquals(null, explanation, 'Explanation must be present: ' + msg);
      System.assert(explanation.contains('Proxy Authentication Required'),
        'Explanation should mention proxy auth: ' + explanation);
    }
    Test.stopTest();
  }

  // ===================================================================
  // Group 2 -- CalloutException surfacing
  //
  // CalloutException is caught by callMcpServer and rethrown as an
  // McpException (NOT an AuraHandledException). Sibling catches do not
  // fire, so it propagates raw out of callMcpServer.
  //
  // Wrapper handling differs by entry point:
  //   - callTool / getAvailableTools / getAvailableResources  -> prepend
  //     "Error <verb>: " before the JSON message (BUG: breaks LWC
  //     JSON.parse so the structured error UI is suppressed).
  //   - initializeConnection                                  -> passes
  //     the JSON message through unchanged.
  // ===================================================================

  // After the A.3 fix: CalloutException is converted directly to an
  // AuraHandledException (no longer a raw McpException), so the LWC
  // framework receives a properly-shaped error.
  @isTest
  static void testCallMcpServer_CalloutException_UnauthorizedEndpoint_RemoteSiteExplanation() {
    Test.setMock(
      HttpCalloutMock.class,
      new McpMockCalloutFailure(
        'Unauthorized endpoint, please check Setup->Security->Remote site settings. endpoint = https://foo.example.com'
      )
    );

    Test.startTest();
    try {
      McpToolTester.callMcpServer('TestServer', '{"jsonrpc":"2.0","id":1,"method":"initialize"}');
      System.assert(false, 'Expected an exception');
    } catch (AuraHandledException e) {
      String msg = e.getMessage();
      System.assert(msg.contains('"type":"CalloutException"'), 'Missing type: ' + msg);
      System.assert(msg.contains('Remote Site Settings'), 'Missing remote-site explanation: ' + msg);
      System.assert(msg.contains('TestServer'), 'Explanation should reference Named Credential: ' + msg);
    }
    Test.stopTest();
  }

  // The substring check matches "timeout" (case-insensitive after A.5).
  @isTest
  static void testCallMcpServer_CalloutException_TimeoutKeyword_HitsTimeoutExplanation() {
    Test.setMock(
      HttpCalloutMock.class,
      new McpMockCalloutFailure('Request timeout while waiting for response')
    );

    Test.startTest();
    try {
      McpToolTester.callMcpServer('TestServer', '{"jsonrpc":"2.0","id":1,"method":"initialize"}');
      System.assert(false, 'Expected an exception');
    } catch (AuraHandledException e) {
      String msg = e.getMessage();
      System.assert(msg.contains('Connection timeout'), 'Should hit timeout explanation: ' + msg);
    }
    Test.stopTest();
  }

  // After the A.5 fix: "Read timed out" is recognised via the broadened
  // substring check ("timed out") and gets the timeout explanation.
  @isTest
  static void testCallMcpServer_CalloutException_ReadTimedOut_HitsTimeoutExplanation() {
    Test.setMock(HttpCalloutMock.class, new McpMockCalloutFailure('Read timed out'));

    Test.startTest();
    try {
      McpToolTester.callMcpServer('TestServer', '{"jsonrpc":"2.0","id":1,"method":"initialize"}');
      System.assert(false, 'Expected an exception');
    } catch (AuraHandledException e) {
      String msg = e.getMessage();
      System.assert(msg.contains('Connection timeout'),
        'After fix, "Read timed out" should hit timeout explanation: ' + msg);
    }
    Test.stopTest();
  }

  @isTest
  static void testCallMcpServer_CalloutException_NoSuchHost_HitsHostnameExplanation() {
    Test.setMock(
      HttpCalloutMock.class,
      new McpMockCalloutFailure('IO Exception: No such host is known (foo.example.com)')
    );

    Test.startTest();
    try {
      McpToolTester.callMcpServer('TestServer', '{"jsonrpc":"2.0","id":1,"method":"initialize"}');
      System.assert(false, 'Expected an exception');
    } catch (AuraHandledException e) {
      String msg = e.getMessage();
      System.assert(msg.contains('Cannot resolve hostname'), 'Should hit hostname explanation: ' + msg);
      System.assert(msg.contains('TestServer'), 'Explanation should reference Named Credential: ' + msg);
    }
    Test.stopTest();
  }

  @isTest
  static void testCallMcpServer_CalloutException_ConnectionRefused_HitsConnectionExplanation() {
    Test.setMock(
      HttpCalloutMock.class,
      new McpMockCalloutFailure('IO Exception: Connection refused')
    );

    Test.startTest();
    try {
      McpToolTester.callMcpServer('TestServer', '{"jsonrpc":"2.0","id":1,"method":"initialize"}');
      System.assert(false, 'Expected an exception');
    } catch (AuraHandledException e) {
      String msg = e.getMessage();
      System.assert(msg.contains('Connection refused'), 'Should mention refusal: ' + msg);
      System.assert(msg.contains('Firewall'), 'Should mention firewall in explanation: ' + msg);
    }
    Test.stopTest();
  }

  @isTest
  static void testCallMcpServer_CalloutException_CredentialAccess_HitsPermSetExplanation() {
    Test.setMock(
      HttpCalloutMock.class,
      new McpMockCalloutFailure('We couldn\'t access the credential(s).')
    );

    Test.startTest();
    try {
      McpToolTester.callMcpServer('TestServer', '{"jsonrpc":"2.0","id":1,"method":"initialize"}');
      System.assert(false, 'Expected an exception');
    } catch (AuraHandledException e) {
      String msg = e.getMessage();
      System.assert(msg.contains('permission set'), 'Should hit perm-set explanation: ' + msg);
    }
    Test.stopTest();
  }

  // After the A.4 fix: a CalloutException whose message looks like an
  // IP-allowlist denial gets the dedicated explanation pointing at the
  // org's outbound IPs. This was the original team-reported symptom.
  @isTest
  static void testCallMcpServer_CalloutException_IpBlocked_HitsIpAllowlistExplanation() {
    Test.setMock(
      HttpCalloutMock.class,
      new McpMockCalloutFailure('Forbidden by external service: IP address 1.2.3.4 is not allowed')
    );

    Test.startTest();
    try {
      McpToolTester.callMcpServer('TestServer', '{"jsonrpc":"2.0","id":1,"method":"initialize"}');
      System.assert(false, 'Expected an exception');
    } catch (AuraHandledException e) {
      String msg = e.getMessage();
      String explanation = extractExplanation(msg);
      System.assertNotEquals(null, explanation, 'Explanation must be present: ' + msg);
      System.assert(explanation.containsIgnoreCase('outbound IP'),
        'After fix, explanation must mention outbound IPs: ' + explanation);
      System.assert(explanation.containsIgnoreCase('allowlist'),
        'After fix, explanation must mention allowlist: ' + explanation);
      System.assert(msg.contains('1.2.3.4'),
        'Raw message must still be embedded for diagnostics: ' + msg);
    }
    Test.stopTest();
  }

  // ===================================================================
  // Group 3 -- Wrapper prefix consistency
  //
  // Pins the inconsistency that surfaces when callMcpServer raises a
  // raw McpException (CalloutException path). The HTTP-error path
  // (status >= 300) preserves the JSON via AuraHandledException
  // re-throw, so a 500 mock proves the consistent-on-HTTP behavior.
  // ===================================================================

  @isTest
  static void testWrappers_HttpError_AllPreserveJsonMessage() {
    Test.setMock(HttpCalloutMock.class, new McpMockHttpResponse(500, '{"jsonrpc":"2.0","error":{"code":-1,"message":"boom"}}'));

    Test.startTest();
    String initMsg = captureWrapperMessage(WrapperEntry.INITIALIZE);
    String toolsMsg = captureWrapperMessage(WrapperEntry.LIST_TOOLS);
    String resMsg = captureWrapperMessage(WrapperEntry.LIST_RESOURCES);
    String callMsg = captureWrapperMessage(WrapperEntry.CALL_TOOL);
    Test.stopTest();

    System.assert(initMsg.startsWith('{'), 'initializeConnection should pass JSON through: ' + initMsg);
    System.assert(toolsMsg.startsWith('{'), 'getAvailableTools should pass JSON through on HTTP errors: ' + toolsMsg);
    System.assert(resMsg.startsWith('{'), 'getAvailableResources should pass JSON through on HTTP errors: ' + resMsg);
    System.assert(callMsg.startsWith('{'), 'callTool should pass JSON through on HTTP errors: ' + callMsg);
  }

  // After the A.2 + A.3 fix: CalloutException is now converted to
  // AuraHandledException inside callMcpServer, the wrappers re-throw it
  // untouched, and so all four entry points produce a parseable JSON
  // message. The earlier wrapper-prefix bug is gone.
  @isTest
  static void testWrappers_CalloutException_AllPreserveJsonMessage() {
    Test.setMock(HttpCalloutMock.class, new McpMockCalloutFailure('IO Exception: Connection refused'));

    Test.startTest();
    String initMsg = captureWrapperMessage(WrapperEntry.INITIALIZE);
    String toolsMsg = captureWrapperMessage(WrapperEntry.LIST_TOOLS);
    String resMsg = captureWrapperMessage(WrapperEntry.LIST_RESOURCES);
    String callMsg = captureWrapperMessage(WrapperEntry.CALL_TOOL);
    Test.stopTest();

    System.assert(initMsg.startsWith('{'),
      'initializeConnection should pass JSON through: ' + initMsg);
    System.assert(toolsMsg.startsWith('{'),
      'getAvailableTools should pass JSON through (no prefix): ' + toolsMsg);
    System.assert(resMsg.startsWith('{'),
      'getAvailableResources should pass JSON through (no prefix): ' + resMsg);
    System.assert(callMsg.startsWith('{'),
      'callTool should pass JSON through (no prefix): ' + callMsg);

    for (String m : new List<String>{ initMsg, toolsMsg, resMsg, callMsg }) {
      System.assert(m.contains('"_error":true'),
        'Each wrapper message must carry the structured _error flag: ' + m);
      System.assert(m.contains('"type":"CalloutException"'),
        'Each wrapper message must preserve the CalloutException type: ' + m);
    }
  }

  // Build a String of `count` repetitions of `c`. Apex's String.repeat
  // is available in newer API versions but doubling is portable.
  private static String repeatChar(String c, Integer count) {
    String s = c;
    while (s.length() * 2 <= count) {
      s += s;
    }
    while (s.length() < count) {
      s += c;
    }
    return s;
  }

  // Helper enum + dispatch for Group 3 to keep tests compact.
  private enum WrapperEntry { INITIALIZE, LIST_TOOLS, LIST_RESOURCES, CALL_TOOL }

  // Extract the value of the JSON "explanation" field from a serialized
  // errorDetails map. Returns null if the message is not parseable JSON
  // or does not contain the field.
  private static String extractExplanation(String exceptionMessage) {
    try {
      Object parsed = JSON.deserializeUntyped(exceptionMessage);
      if (parsed instanceof Map<String, Object>) {
        Map<String, Object> m = (Map<String, Object>)parsed;
        Object expl = m.get('explanation');
        return expl == null ? null : String.valueOf(expl);
      }
    } catch (Exception ignored) {
      // Not parseable JSON - could be a wrapper-prefixed message.
    }
    return null;
  }

  private static String captureWrapperMessage(WrapperEntry which) {
    try {
      switch on which {
        when INITIALIZE { McpToolTester.initializeConnection('TestServer'); }
        when LIST_TOOLS { McpToolTester.getAvailableTools('TestServer'); }
        when LIST_RESOURCES { McpToolTester.getAvailableResources('TestServer'); }
        when CALL_TOOL { McpToolTester.callTool('TestServer', 'someTool', '{}'); }
      }
      System.assert(false, 'Expected AuraHandledException from ' + which);
      return null;
    } catch (AuraHandledException e) {
      return e.getMessage();
    }
  }

  // ===================================================================
  // Group 4 -- Body shape edge cases
  // ===================================================================

  // 200 OK with empty body is returned verbatim. Downstream the LWC's
  // parseResponse will collapse this into "Invalid response format",
  // but Apex itself does not surface anything.
  @isTest
  static void testCallMcpServer_200EmptyBody_ReturnedVerbatim() {
    Test.setMock(HttpCalloutMock.class, new McpMockHttpResponse(200, ''));

    Test.startTest();
    String result = McpToolTester.callMcpServer(
      'TestServer',
      '{"jsonrpc":"2.0","id":1,"method":"initialize"}'
    );
    Test.stopTest();

    System.assertEquals('', result, 'Empty 200 body should be returned verbatim');
  }

  // SSE parsing happens client-side via parseSseResponse; Apex returns
  // the raw body. This pins that contract.
  @isTest
  static void testCallMcpServer_200SseBody_ReturnedVerbatim() {
    String sse = 'event: message\ndata: {"jsonrpc":"2.0","result":{"tools":[]},"id":1}\n\n';
    Test.setMock(HttpCalloutMock.class, new McpMockHttpResponse(200, sse));

    Test.startTest();
    String result = McpToolTester.callMcpServer(
      'TestServer',
      '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
    );
    Test.stopTest();

    System.assertEquals(sse, result, 'SSE body should pass through Apex unchanged');
  }

  // 200 OK whose body contains a JSON-RPC level error is the MCP server
  // signalling failure with HTTP success. Apex returns it verbatim and
  // the LWC's handleMcpError path takes over.
  @isTest
  static void testCallMcpServer_200JsonRpcError_BodyReturnedForLwcHandling() {
    String body = '{"jsonrpc":"2.0","error":{"code":-32603,"message":"Internal error","data":{"detail":"db down"}},"id":1}';
    Test.setMock(HttpCalloutMock.class, new McpMockHttpResponse(200, body));

    Test.startTest();
    String result = McpToolTester.callMcpServer(
      'TestServer',
      '{"jsonrpc":"2.0","id":1,"method":"tools/call"}'
    );
    Test.stopTest();

    System.assertEquals(body, result, '200 + JSON-RPC error body must pass through to LWC');
  }

  // Pins the success path of the inner JSON parse: when a 5xx body is
  // valid JSON with an `error` key, errorDetails.mcpError is enriched.
  @isTest
  static void testCallMcpServer_500JsonBodyWithErrorKey_PopulatesMcpError() {
    String body = '{"error":{"code":"db_unreachable","message":"db down"}}';
    Test.setMock(HttpCalloutMock.class, new McpMockHttpResponse(500, body));

    Test.startTest();
    try {
      McpToolTester.callMcpServer('TestServer', '{"jsonrpc":"2.0","id":1,"method":"tools/list"}');
      System.assert(false, 'Expected AuraHandledException');
    } catch (AuraHandledException e) {
      String msg = e.getMessage();
      System.assert(msg.contains('"mcpError"'), 'mcpError key should be present: ' + msg);
      System.assert(msg.contains('db_unreachable'), 'mcpError should embed the parsed error: ' + msg);
    }
    Test.stopTest();
  }

  // ===================================================================
  // Group 5 -- Oversized payload
  //
  // Pins that the Apex side does not truncate large rawResponse bodies.
  // Client-side, very large AuraHandledException messages can manifest
  // as "Script-thrown exception" depending on Lightning framework
  // version; if a future refactor truncates rawResponse, this test
  // will need an explicit update.
  // ===================================================================

  // After the A.7 fix: rawResponse is truncated to MAX_RAW_RESPONSE_CHARS
  // (~8 KB) with a marker so the AuraHandledException message stays
  // small enough to survive Lightning sanitation. The first chunk is
  // preserved verbatim; the marker carries the original length.
  @isTest
  static void testCallMcpServer_LargeRawResponse_TruncatedWithMarker() {
    String chunk = '0123456789ABCDEF0123456789ABCDEF';
    String big = '';
    for (Integer i = 0; i < 1024; i++) {
      big += chunk;
    }
    System.assertEquals(32768, big.length(), 'Sanity check: built a 32KB body');

    Test.setMock(HttpCalloutMock.class, new McpMockHttpResponse(500, big));

    Test.startTest();
    try {
      McpToolTester.callMcpServer('TestServer', '{"jsonrpc":"2.0","id":1,"method":"tools/list"}');
      System.assert(false, 'Expected AuraHandledException');
    } catch (AuraHandledException e) {
      String msg = e.getMessage();
      Integer cap = McpToolTester.MAX_RAW_RESPONSE_CHARS;
      System.assert(msg.contains(big.substring(0, cap)),
        'Truncated rawResponse must preserve the first ' + cap + ' chars');
      System.assert(!msg.contains(big),
        'Full 32KB body must not be embedded after truncation fix');
      System.assert(msg.contains('truncated; original length 32768'),
        'Must include a marker with the original length: ' + msg);
    }
    Test.stopTest();
  }

  // Pin the truncateForAura helper directly so the contract is testable
  // independent of the callout flow. Contract:
  //   - null / empty / <= cap inputs pass through unchanged
  //   - over-cap inputs preserve the first `cap` chars verbatim,
  //     append a marker carrying the original length, and bound the
  //     output below cap + a small constant marker overhead.
  @isTest
  static void testTruncateForAura_BoundaryBehavior() {
    Integer cap = McpToolTester.MAX_RAW_RESPONSE_CHARS;
    System.assertEquals(null, McpToolTester.truncateForAura(null), 'null passes through');
    System.assertEquals('', McpToolTester.truncateForAura(''), 'empty passes through');

    String exact = repeatChar('x', cap);
    System.assertEquals(exact, McpToolTester.truncateForAura(exact),
      'exactly cap chars must not be truncated');

    // Build a very large input so the marker overhead is dwarfed by
    // the savings -- the assertion that truncation actually shrinks
    // the payload is meaningful here.
    String huge = repeatChar('A', cap * 4);
    String trimmed = McpToolTester.truncateForAura(huge);
    System.assert(trimmed.length() < huge.length(),
      'huge input must be shrunk: trimmed=' + trimmed.length() + ' huge=' + huge.length());
    System.assert(trimmed.startsWith(huge.substring(0, cap)),
      'first cap chars must be preserved verbatim');
    System.assert(trimmed.contains('original length ' + huge.length()),
      'marker must carry the original length');
    System.assert(trimmed.length() < cap + 100,
      'output must be bounded by cap + small marker overhead, was ' + trimmed.length());
  }

  // ===================================================================
  // Group 6 -- getAvailableServers behavior
  //
  // After the A.6 fix the contract is: either return a (possibly empty)
  // list of options, or throw an AuraHandledException carrying our
  // structured _error payload so the LWC can render an inline hint.
  // Whether a given Standard-User profile can query NamedCredential is
  // org-config dependent, so this test accepts both branches and
  // asserts the shape in each.
  // ===================================================================

  @isTest
  static void testGetAvailableServers_AsRestrictedUser_EitherReturnsListOrSurfacesError() {
    Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
    User restricted = new User(
      ProfileId = p.Id,
      Username = 'mcp.swallow.' + System.currentTimeMillis() + '@example.invalid',
      Alias = 'mcpsw',
      Email = 'mcp.swallow@example.invalid',
      EmailEncodingKey = 'UTF-8',
      LastName = 'Swallow',
      LanguageLocaleKey = 'en_US',
      LocaleSidKey = 'en_US',
      TimeZoneSidKey = 'America/Los_Angeles'
    );
    insert restricted;

    Test.startTest();
    System.runAs(restricted) {
      List<McpToolTester.ServerOption> servers = null;
      String surfacedError = null;
      try {
        servers = McpToolTester.getAvailableServers();
      } catch (AuraHandledException e) {
        surfacedError = e.getMessage();
      }

      if (surfacedError != null) {
        System.assert(surfacedError.contains('"_error":true'),
          'Surfaced error must use the structured shape: ' + surfacedError);
        System.assert(surfacedError.contains('Named Credentials'),
          'Explanation must reference Named Credentials: ' + surfacedError);
        System.assert(surfacedError.contains('manually'),
          'Explanation must tell the user manual entry is still possible: ' + surfacedError);
      } else {
        System.assertNotEquals(null, servers,
          'When the query succeeds, must return a non-null list (possibly empty)');
      }
    }
    Test.stopTest();
  }

  // ===================================================================
  // Group 7 -- parseSseResponse edge cases
  // ===================================================================

  @isTest
  static void testParseSseResponse_MultiDataLines_ReturnsFirstDataPayload() {
    String sse =
      'event: message\n' +
      'data: {"jsonrpc":"2.0","result":{"first":true},"id":1}\n' +
      'event: message\n' +
      'data: {"jsonrpc":"2.0","result":{"second":true},"id":2}\n\n';

    Test.startTest();
    String result = McpToolTester.parseSseResponse(sse);
    Test.stopTest();

    System.assert(result.contains('"first":true'),
      'parseSseResponse should return the first data payload: ' + result);
    System.assert(!result.contains('"second":true'),
      'parseSseResponse should stop at the first data line: ' + result);
  }

  @isTest
  static void testParseSseResponse_DataLineWithColonInPayload_NotCorrupted() {
    String sse = 'event: message\ndata: {"jsonrpc":"2.0","result":{"url":"https://example.com:8080/x"},"id":1}\n\n';

    Test.startTest();
    String result = McpToolTester.parseSseResponse(sse);
    Test.stopTest();

    System.assertEquals(
      '{"jsonrpc":"2.0","result":{"url":"https://example.com:8080/x"},"id":1}',
      result,
      'substring(6) must not split inner colons in the JSON payload'
    );
  }

  @isTest
  static void testParseSseResponse_EmptyInput_ReturnsEmptyInput() {
    Test.startTest();
    String result = McpToolTester.parseSseResponse('');
    Test.stopTest();

    System.assertEquals('', result,
      'Pin current behavior: empty input passes through (String.isNotBlank guard returns the input)');
  }

  /**
   * Mock HTTP Response class for testing
   */
  private class McpMockHttpResponse implements HttpCalloutMock {
    private Integer statusCode;
    private String body;

    public McpMockHttpResponse(Integer statusCode, String body) {
      this.statusCode = statusCode;
      this.body = body;
    }

    public HttpResponse respond(HttpRequest req) {
      // Verify request headers
      System.assertEquals('application/json', req.getHeader('Content-Type'));
      System.assertEquals(
        'application/json, text/event-stream',
        req.getHeader('Accept')
      );

      // Verify endpoint format
      System.assert(
        req.getEndpoint().startsWith('callout:'),
        'Endpoint should use Named Credential format'
      );

      HttpResponse res = new HttpResponse();
      res.setStatusCode(statusCode);
      res.setStatus(statusCode == 200 ? 'OK' : 'Error');
      res.setBody(body);
      res.setHeader('Content-Type', 'application/json');
      return res;
    }
  }

  /**
   * Mock HTTP that throws a CalloutException from respond(). Used to
   * exercise the network-failure branch in callMcpServer for cases that
   * never produce an HTTP response (DNS failures, refused connections,
   * Salesforce IP-allowlist denials, "We couldn't access the
   * credential(s)", and so on).
   *
   * NOTE: Class name deliberately does NOT end in "Exception" because
   * Apex auto-treats any class with that suffix as an Exception subclass.
   */
  private class McpMockCalloutFailure implements HttpCalloutMock {
    private String message;

    public McpMockCalloutFailure(String message) {
      this.message = message;
    }

    public HttpResponse respond(HttpRequest req) {
      CalloutException ex = new CalloutException();
      ex.setMessage(message);
      throw ex;
    }
  }
}
