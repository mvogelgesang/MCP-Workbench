public with sharing class McpToolTester {
    
    /**
     * Makes a callout to any MCP server via Named Credential
     * @param namedCredential - The Named Credential API name (e.g., 'PetStore', 'news', 'notion2')
     * @param requestBody - JSON-RPC request body as string
     * @return String - Response from MCP server (or error details in JSON format)
     */
    @AuraEnabled
    public static String callMcpServer(String namedCredential, String requestBody) {
        HttpRequest req = new HttpRequest();
        HttpResponse res;
        
        try {
            // Use the Named Credential callout with dynamic server name
            req.setEndpoint('callout:' + namedCredential);
            req.setMethod('POST');
            
            // Set the required headers for MCP protocol
            req.setHeader('Content-Type', 'application/json');
            req.setHeader('Accept', 'application/json, text/event-stream');
            
            // Set the JSON-RPC request body
            req.setBody(requestBody);
            
            // Set timeout (120 seconds max)
            req.setTimeout(120000);
            
            // Log request details for debugging
            System.debug('MCP Request to: callout:' + namedCredential);
            System.debug('Request Body: ' + requestBody);
            
            Http http = new Http();
            res = http.send(req);
            
            // Log response details
            System.debug('Response Status Code: ' + res.getStatusCode());
            System.debug('Response Status: ' + res.getStatus());
            System.debug('Response Body: ' + res.getBody());
            
            // Check response status
            if (res.getStatusCode() >= 200 && res.getStatusCode() < 300) {
                return res.getBody();
            } else {
                // Build detailed error response
                Map<String, Object> errorDetails = new Map<String, Object>{
                    '_error' => true,
                    'statusCode' => res.getStatusCode(),
                    'status' => res.getStatus(),
                    'endpoint' => 'callout:' + namedCredential,
                    'method' => 'POST',
                    'timestamp' => System.now().format('yyyy-MM-dd HH:mm:ss'),
                    'rawResponse' => res.getBody()
                };
                
                // Try to parse error as JSON-RPC error
                try {
                    Map<String, Object> parsedError = (Map<String, Object>)JSON.deserializeUntyped(res.getBody());
                    if (parsedError.containsKey('error')) {
                        errorDetails.put('mcpError', parsedError.get('error'));
                    }
                } catch (Exception e) {
                    // Not JSON, include as-is
                }
                
                // Add common error explanations
                errorDetails.put('explanation', getErrorExplanation(res.getStatusCode(), namedCredential));
                
                throw new McpException(JSON.serialize(errorDetails));
            }
            
        } catch (System.CalloutException e) {
            // Network/connectivity errors
            Map<String, Object> errorDetails = new Map<String, Object>{
                '_error' => true,
                'type' => 'CalloutException',
                'message' => e.getMessage(),
                'endpoint' => 'callout:' + namedCredential,
                'timestamp' => System.now().format('yyyy-MM-dd HH:mm:ss'),
                'explanation' => getCalloutErrorExplanation(e.getMessage(), namedCredential)
            };
            
            System.debug(LoggingLevel.ERROR, 'Callout Exception: ' + e.getMessage());
            System.debug(LoggingLevel.ERROR, 'Stack Trace: ' + e.getStackTraceString());
            
            throw new McpException(JSON.serialize(errorDetails));
            
        } catch (McpException e) {
            // Re-throw MCP exceptions as-is
            throw new AuraHandledException(e.getMessage());
            
        } catch (Exception e) {
            // Unexpected errors
            Map<String, Object> errorDetails = new Map<String, Object>{
                '_error' => true,
                'type' => e.getTypeName(),
                'message' => e.getMessage(),
                'stackTrace' => e.getStackTraceString(),
                'endpoint' => 'callout:' + namedCredential,
                'timestamp' => System.now().format('yyyy-MM-dd HH:mm:ss')
            };
            
            System.debug(LoggingLevel.ERROR, 'Unexpected Exception: ' + e.getMessage());
            System.debug(LoggingLevel.ERROR, 'Stack Trace: ' + e.getStackTraceString());
            
            throw new AuraHandledException(JSON.serialize(errorDetails));
        }
    }
    
    /**
     * Get user-friendly explanation for HTTP status codes
     */
    private static String getErrorExplanation(Integer statusCode, String namedCredential) {
        switch on statusCode {
            when 400 {
                return 'Bad Request: The MCP server rejected the request. Check that the request format is correct.';
            }
            when 401 {
                return 'Unauthorized: Authentication failed. Please check:\n' +
                       '1. Named Credential "' + namedCredential + '" is configured\n' +
                       '2. OAuth Client ID and Secret are correct\n' +
                       '3. User has assigned permission set\n' +
                       '4. UserExternalCredential is enabled';
            }
            when 403 {
                return 'Forbidden: You don\'t have permission to access this resource. Check OAuth scopes and user permissions.';
            }
            when 404 {
                return 'Not Found: The MCP endpoint does not exist. Verify the Named Credential URL is correct.';
            }
            when 406 {
                return 'Not Acceptable: The server cannot provide the requested format. This may indicate missing Accept headers.';
            }
            when 429 {
                return 'Too Many Requests: Rate limit exceeded. Wait a moment and try again.';
            }
            when 500 {
                return 'Internal Server Error: The MCP server encountered an error. Check server logs.';
            }
            when 502 {
                return 'Bad Gateway: Cannot reach the MCP server. Check that the server is running and accessible.';
            }
            when 503 {
                return 'Service Unavailable: The MCP server is temporarily down. Try again later.';
            }
            when 504 {
                return 'Gateway Timeout: The MCP server took too long to respond. The server may be overloaded.';
            }
            when else {
                return 'HTTP ' + statusCode + ' error occurred. See response details below.';
            }
        }
    }
    
    /**
     * Get explanation for callout exceptions
     */
    private static String getCalloutErrorExplanation(String errorMessage, String namedCredential) {
        if (errorMessage.contains('Unauthorized endpoint')) {
            return 'Endpoint not authorized in Remote Site Settings. Please:\n' +
                   '1. Go to Setup → Remote Site Settings\n' +
                   '2. Add the MCP server URL\n' +
                   '3. Or ensure Named Credential "' + namedCredential + '" is properly configured';
        }
        if (errorMessage.contains('timeout')) {
            return 'Connection timeout. The MCP server did not respond in time. Check:\n' +
                   '1. Server is running and accessible\n' +
                   '2. Network connectivity\n' +
                   '3. Server response time';
        }
        if (errorMessage.contains('No such host')) {
            return 'Cannot resolve hostname. The MCP server URL may be incorrect in Named Credential "' + namedCredential + '"';
        }
        if (errorMessage.contains('Connection refused')) {
            return 'Connection refused. The MCP server is not accepting connections. Check:\n' +
                   '1. Server is running\n' +
                   '2. Correct port number\n' +
                   '3. Firewall settings';
        }
        if (errorMessage.contains('We couldn\'t access the credential(s).')) {
            return 'We couldn\'t access the credential(s) which is likely caused by your user not being assigned the associated permission set.  Please check your users current permission set assignments.';
        }
        return 'Network error occurred. See error message for details.';
    }
    
    /**
     * Custom exception for MCP errors
     */
    public class McpException extends Exception {}
    
    /**
     * Call a specific MCP tool with parameters
     * @param namedCredential - The Named Credential API name
     * @param toolName - Name of the tool to call
     * @param parameters - JSON string of parameters for the tool
     * @return String - Response from the tool
     */
    @AuraEnabled
    public static String callTool(String namedCredential, String toolName, String parameters) {
        try {
            // Build the JSON-RPC request for tools/call
            Map<String, Object> request = new Map<String, Object>{
                'jsonrpc' => '2.0',
                'id' => generateRequestId(),
                'method' => 'tools/call',
                'params' => new Map<String, Object>{
                    'name' => toolName,
                    'arguments' => String.isNotBlank(parameters) 
                        ? (Map<String, Object>)JSON.deserializeUntyped(parameters)
                        : new Map<String, Object>()
                }
            };
            
            String requestBody = JSON.serialize(request);
            return callMcpServer(namedCredential, requestBody);
            
        } catch (Exception e) {
            throw new AuraHandledException('Error calling tool: ' + e.getMessage());
        }
    }
    
    /**
     * Get available tools from the MCP server
     * @param namedCredential - The Named Credential API name
     * @return String - JSON response with tools list
     */
    @AuraEnabled
    public static String getAvailableTools(String namedCredential) {
        try {
            Map<String, Object> request = new Map<String, Object>{
                'jsonrpc' => '2.0',
                'id' => generateRequestId(),
                'method' => 'tools/list'
            };
            
            String requestBody = JSON.serialize(request);
            return callMcpServer(namedCredential, requestBody);
            
        } catch (Exception e) {
            throw new AuraHandledException('Error getting tools: ' + e.getMessage());
        }
    }
    
    /**
     * Get available resources from the MCP server
     * @param namedCredential - The Named Credential API name
     * @return String - JSON response with resources list
     */
    @AuraEnabled
    public static String getAvailableResources(String namedCredential) {
        try {
            Map<String, Object> request = new Map<String, Object>{
                'jsonrpc' => '2.0',
                'id' => generateRequestId(),
                'method' => 'resources/list'
            };
            
            String requestBody = JSON.serialize(request);
            return callMcpServer(namedCredential, requestBody);
            
        } catch (Exception e) {
            throw new AuraHandledException('Error getting resources: ' + e.getMessage());
        }
    }
    
    /**
     * Initialize connection to MCP server
     * @param namedCredential - The Named Credential API name
     * @return String - JSON response with server info
     */
    @AuraEnabled
    public static String initializeConnection(String namedCredential) {
        try {
            Map<String, Object> request = new Map<String, Object>{
                'jsonrpc' => '2.0',
                'id' => generateRequestId(),
                'method' => 'initialize',
                'params' => new Map<String, Object>{
                    'protocolVersion' => '2025-06-18',
                    'capabilities' => new Map<String, Object>(),
                    'clientInfo' => new Map<String, Object>{
                        'name' => 'salesforce-mcp-tool-tester',
                        'version' => '1.0.0'
                    }
                }
            };
            
            String requestBody = JSON.serialize(request);
            return callMcpServer(namedCredential, requestBody);
            
        } catch (Exception e) {
            System.debug('Error initializing: ' + e.getMessage());
            throw new AuraHandledException(e.getMessage());
        }
    }
    
    /**
     * Get list of available Named Credentials for MCP servers
     * Note: This queries metadata - requires proper CRUD/FLS permissions
     * @return List<ServerOption> - List of Named Credentials
     */
    @AuraEnabled(cacheable=true)
    public static List<ServerOption> getAvailableServers() {
        List<ServerOption> servers = new List<ServerOption>();
        
        try {
            // Query Named Credentials metadata
            // Note: This requires user to have appropriate permissions
            // Simplified query without NamedCredentialType filter for broader compatibility
            for (NamedCredential nc : [
                SELECT Id, MasterLabel, DeveloperName 
                FROM NamedCredential 
                ORDER BY MasterLabel ASC
                LIMIT 200
            ]) {
                servers.add(new ServerOption(nc.DeveloperName, nc.MasterLabel));
            }
        } catch (Exception e) {
            // If metadata query fails, return empty list
            System.debug('Error querying Named Credentials: ' + e.getMessage());
        }
        
        return servers;
    }
    
    /**
     * Helper method to parse SSE (Server-Sent Events) response
     * MCP servers may return SSE format with "event:" and "data:" lines
     * @param sseResponse - Raw SSE response
     * @return String - Extracted JSON data
     */
    @AuraEnabled
    public static String parseSseResponse(String sseResponse) {
        try {
            // SSE format example:
            // event: message
            // data: {"jsonrpc":"2.0","result":{...}}
            
            String[] lines = sseResponse.split('\n');
            String jsonData = '';
            
            for (String line : lines) {
                if (line.startsWith('data: ')) {
                    jsonData = line.substring(6).trim();
                    break;
                }
            }
            
            return String.isNotBlank(jsonData) ? jsonData : sseResponse;
            
        } catch (Exception e) {
            throw new AuraHandledException('Error parsing SSE response: ' + e.getMessage());
        }
    }
    
    /**
     * Generate a unique request ID for JSON-RPC
     * @return Integer - Unique request ID
     */
    private static Integer generateRequestId() {
        return (Integer)(Math.random() * 1000000);
    }
    
    /**
     * Wrapper class for server options
     */
    public class ServerOption {
        @AuraEnabled public String value;
        @AuraEnabled public String label;
        
        public ServerOption(String value, String label) {
            this.value = value;
            this.label = label;
        }
    }
}
