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
            
            if (res.getStatusCode() >= 200 && res.getStatusCode() < 300) {
                return res.getBody();
            }

            String rawBody = res.getBody();
            Map<String, Object> errorDetails = new Map<String, Object>{
                '_error' => true,
                'statusCode' => res.getStatusCode(),
                'status' => res.getStatus(),
                'endpoint' => 'callout:' + namedCredential,
                'method' => 'POST',
                'timestamp' => System.now().format('yyyy-MM-dd HH:mm:ss'),
                'rawResponse' => truncateForAura(rawBody)
            };

            try {
                Object parsed = JSON.deserializeUntyped(rawBody);
                if (parsed instanceof Map<String, Object>) {
                    Map<String, Object> parsedError = (Map<String, Object>)parsed;
                    if (parsedError.containsKey('error')) {
                        errorDetails.put('mcpError', parsedError.get('error'));
                    }
                }
            } catch (Exception parseEx) {
                errorDetails.put('rawResponseParseError', parseEx.getMessage());
            }

            errorDetails.put(
                'explanation',
                getErrorExplanation(res.getStatusCode(), namedCredential, rawBody)
            );

            throw newAuraException(JSON.serialize(errorDetails));

        } catch (AuraHandledException e) {
            // Already shaped for the LWC; let it propagate untouched.
            throw e;

        } catch (System.CalloutException e) {
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

            throw newAuraException(JSON.serialize(errorDetails));

        } catch (Exception e) {
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

            throw newAuraException(JSON.serialize(errorDetails));
        }
    }

    /**
     * Cap large response bodies before they are embedded in an
     * AuraHandledException message. Lightning sanitizes very large
     * messages to a generic "Script-thrown exception" client-side; we
     * keep enough bytes for the user to diagnose without tripping that.
     */
    @TestVisible
    private static final Integer MAX_RAW_RESPONSE_CHARS = 8000;

    @TestVisible
    private static String truncateForAura(String body) {
        if (body == null) {
            return null;
        }
        if (body.length() <= MAX_RAW_RESPONSE_CHARS) {
            return body;
        }
        return body.substring(0, MAX_RAW_RESPONSE_CHARS) +
            '\n\n... [truncated; original length ' + body.length() + ' chars]';
    }
    
    /**
     * Get user-friendly explanation for HTTP status codes. The optional
     * `responseBody` lets us refine the explanation when the upstream
     * response carries a recognisable hint (for example IP-allowlist
     * denials surfaced via 403 with "IP address ... is not allowed").
     */
    @TestVisible
    private static String getErrorExplanation(
        Integer statusCode,
        String namedCredential,
        String responseBody
    ) {
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
                if (looksLikeIpDenial(responseBody)) {
                    return 'Forbidden (IP allowlist): The MCP server rejected the request because ' +
                           'this Salesforce org\'s outbound IP is not on its allowlist. Add the org\'s ' +
                           'outbound IPs (Setup -> Salesforce IP Addresses, or hyperforce egress IPs) ' +
                           'to the MCP server\'s allowlist, or remove the IP restriction on the server.';
                }
                return 'Forbidden: You don\'t have permission to access this resource. ' +
                       'Check OAuth scopes, user permissions, and any IP-allowlist on the MCP server.';
            }
            when 404 {
                return 'Not Found: The MCP endpoint does not exist. Verify the Named Credential URL is correct.';
            }
            when 406 {
                return 'Not Acceptable: The server cannot provide the requested format. This may indicate missing Accept headers.';
            }
            when 407 {
                return 'Proxy Authentication Required: A network proxy between Salesforce and the MCP server requires authentication. ' +
                       'Configure proxy credentials on the Named Credential or use an outbound network policy that bypasses the proxy.';
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
     * Heuristic detector for upstream IP-allowlist denials. Matches the
     * common phrasings surfaced by API gateways and load balancers (AWS
     * WAF, Cloudflare, nginx, custom firewalls, MuleSoft, etc.).
     */
    @TestVisible
    private static Boolean looksLikeIpDenial(String body) {
        if (String.isBlank(body)) {
            return false;
        }
        String b = body.toLowerCase();
        return (b.contains('ip address') && b.contains('not allowed'))
            || b.contains('ip is not allowed')
            || b.contains('ip not allowed')
            || b.contains('not in the allowlist')
            || b.contains('not in the allow list')
            || b.contains('ip allowlist')
            || b.contains('forbidden by external service');
    }

    /**
     * Get explanation for callout exceptions
     */
    private static String getCalloutErrorExplanation(String errorMessage, String namedCredential) {
        if (errorMessage == null) {
            return 'Network error occurred. See error message for details.';
        }
        String msg = errorMessage;
        String lower = msg.toLowerCase();

        if (msg.contains('Unauthorized endpoint')) {
            return 'Endpoint not authorized in Remote Site Settings. Please:\n' +
                   '1. Go to Setup -> Remote Site Settings\n' +
                   '2. Add the MCP server URL\n' +
                   '3. Or ensure Named Credential "' + namedCredential + '" is properly configured';
        }
        if (lower.contains('timeout') || lower.contains('timed out')) {
            return 'Connection timeout. The MCP server did not respond in time. Check:\n' +
                   '1. Server is running and accessible\n' +
                   '2. Network connectivity\n' +
                   '3. Server response time';
        }
        if (msg.contains('No such host')) {
            return 'Cannot resolve hostname. The MCP server URL may be incorrect in Named Credential "' + namedCredential + '"';
        }
        if (msg.contains('Connection refused')) {
            return 'Connection refused. The MCP server is not accepting connections. Check:\n' +
                   '1. Server is running\n' +
                   '2. Correct port number\n' +
                   '3. Firewall settings';
        }
        if (msg.contains('We couldn\'t access the credential(s).')) {
            return 'We couldn\'t access the credential(s) which is likely caused by your user not being assigned the associated permission set.  Please check your users current permission set assignments.';
        }
        if (looksLikeIpDenial(msg)) {
            return 'Network error: The MCP server (or a gateway in front of it) rejected the request ' +
                   'because this Salesforce org\'s outbound IP is not on its allowlist. Add the org\'s ' +
                   'outbound IPs to the MCP server\'s allowlist, or remove the IP restriction.';
        }
        return 'Network error occurred. See error message for details.';
    }
    
    /**
     * Custom exception for MCP errors
     */
    public class McpException extends Exception {}
    
    private static AuraHandledException newAuraException(String message) {
        AuraHandledException ex = new AuraHandledException(message);
        ex.setMessage(message);
        return ex;
    }

    /**
     * Build a structured JSON message for unexpected exceptions in the
     * thin @AuraEnabled wrappers (e.g., JSON build/parse failures
     * before/after the callout). Mirrors the shape produced by
     * callMcpServer so the LWC's JSON.parse path renders a uniform
     * error UI regardless of where the failure originates.
     */
    private static String wrapWrapperError(String wrapperName, Exception e) {
        Map<String, Object> details = new Map<String, Object>{
            '_error' => true,
            'type' => e.getTypeName(),
            'wrapper' => wrapperName,
            'message' => e.getMessage(),
            'stackTrace' => truncateForAura(e.getStackTraceString()),
            'timestamp' => System.now().format('yyyy-MM-dd HH:mm:ss'),
            'explanation' => 'Unexpected error in ' + wrapperName + ' before/after the MCP callout. ' +
                             'See message and stackTrace for details.'
        };
        return JSON.serialize(details);
    }
    
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
            
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw newAuraException(wrapWrapperError('callTool', e));
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
            
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw newAuraException(wrapWrapperError('getAvailableTools', e));
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
            
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw newAuraException(wrapWrapperError('getAvailableResources', e));
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
            
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            System.debug('Error initializing: ' + e.getMessage());
            throw newAuraException(wrapWrapperError('initializeConnection', e));
        }
    }
    
    /**
     * Get list of available Named Credentials for MCP servers
     * Note: This queries metadata - requires proper CRUD/FLS permissions
     * @return List<ServerOption> - List of Named Credentials
     */
    @AuraEnabled(cacheable=true)
    public static List<ServerOption> getAvailableServers() {
        try {
            List<ServerOption> servers = new List<ServerOption>();
            for (NamedCredential nc : [
                SELECT Id, MasterLabel, DeveloperName, NamespacePrefix
                FROM NamedCredential
                ORDER BY MasterLabel ASC
                LIMIT 200
            ]) {
                String qualifiedName = buildQualifiedName(nc.NamespacePrefix, nc.DeveloperName);
                String label = String.isNotBlank(nc.NamespacePrefix)
                    ? nc.MasterLabel + ' (' + nc.NamespacePrefix + ')'
                    : nc.MasterLabel;
                servers.add(new ServerOption(qualifiedName, label));
            }
            return servers;
        } catch (Exception e) {
            // Surface the failure so the LWC can render an inline hint
            // ("couldn't load Named Credentials -- enter the API name
            // manually") instead of an indistinguishable empty dropdown.
            // The LWC degrades gracefully: manual entry is always allowed.
            System.debug(LoggingLevel.ERROR, 'Error querying Named Credentials: ' + e.getMessage());
            Map<String, Object> details = new Map<String, Object>{
                '_error' => true,
                'type' => e.getTypeName(),
                'message' => e.getMessage(),
                'timestamp' => System.now().format('yyyy-MM-dd HH:mm:ss'),
                'explanation' => 'Could not load the Named Credentials list. ' +
                                 'Most often caused by the running user lacking ' +
                                 '"View Setup and Configuration". You can still ' +
                                 'enter the Named Credential API name manually.'
            };
            throw newAuraException(JSON.serialize(details));
        }
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
            throw newAuraException('Error parsing SSE response: ' + e.getMessage());
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
     * Builds a namespace-qualified API name for use with callout: endpoints.
     * Managed package named credentials require the namespace prefix to resolve correctly.
     */
    @TestVisible
    private static String buildQualifiedName(String namespacePrefix, String developerName) {
        if (String.isNotBlank(namespacePrefix)) {
            return namespacePrefix + '__' + developerName;
        }
        return developerName;
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
