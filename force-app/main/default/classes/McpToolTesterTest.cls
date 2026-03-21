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
}
