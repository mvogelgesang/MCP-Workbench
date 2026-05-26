public with sharing class McpToolTester {

    /**
     * MCP "Streamable HTTP" session-management headers as defined by
     * https://modelcontextprotocol.io/specification/2025-06-18/basic/transports#session-management.
     *
     * The header names are cased per the spec text. Apex header
     * matching is case-insensitive on the response side, but the
     * server we are calling may not be -- so we send these casings
     * verbatim.
     */
    @TestVisible
    private static final String HEADER_SESSION_ID = 'Mcp-Session-Id';
    @TestVisible
    private static final String HEADER_PROTOCOL_VERSION = 'MCP-Protocol-Version';

    /**
     * Legacy AuraEnabled entrypoint. Sends a POST without an
     * `Mcp-Session-Id` or `MCP-Protocol-Version` header and returns
     * the raw response body as a String. Retained so existing
     * scripts / tests that call callMcpServer directly keep working;
     * new code should go through the higher-level methods which
     * return McpResponse and propagate the session lifecycle.
     */
    @AuraEnabled
    public static String callMcpServer(String namedCredential, String requestBody) {
        McpResponse r = executeMcp(namedCredential, requestBody, null, null, 'POST');
        return r.body;
    }

    /**
     * Core HTTP helper that implements the MCP 2025-06-18 Streamable
     * HTTP transport contract:
     *
     *   - Adds `Mcp-Session-Id` when the caller supplies one.
     *   - Adds `MCP-Protocol-Version` when the caller supplies one
     *     (per spec, only after the version is negotiated during
     *     initialization).
     *   - Captures the server-returned `Mcp-Session-Id` so callers
     *     (initializeConnection) can stash it for the rest of the
     *     session.
     *   - Detects the spec-defined "server expired our session"
     *     signal (HTTP 404 while we held a session ID) and surfaces
     *     it as `sessionExpired = true` on the structured error
     *     payload, so the LWC can transparently re-initialize.
     *
     * httpMethod is one of 'POST', 'GET', or 'DELETE'. For DELETE
     * (session termination), no body is sent.
     */
    private static McpResponse executeMcp(
        String namedCredential,
        String requestBody,
        String sessionId,
        String protocolVersion,
        String httpMethod
    ) {
        HttpRequest req = new HttpRequest();
        HttpResponse res;
        String method = String.isNotBlank(httpMethod) ? httpMethod : 'POST';

        try {
            req.setEndpoint('callout:' + namedCredential);
            req.setMethod(method);
            req.setHeader('Content-Type', 'application/json');
            req.setHeader('Accept', 'application/json, text/event-stream');

            if (String.isNotBlank(sessionId)) {
                req.setHeader(HEADER_SESSION_ID, sessionId);
            }
            if (String.isNotBlank(protocolVersion)) {
                req.setHeader(HEADER_PROTOCOL_VERSION, protocolVersion);
            }
            if (String.isNotBlank(requestBody) && method != 'DELETE') {
                req.setBody(requestBody);
            }

            req.setTimeout(120000);

            System.debug('MCP Request to: callout:' + namedCredential + ' (' + method + ')');
            System.debug('Request Body: ' + requestBody);

            Http http = new Http();
            res = http.send(req);

            Integer code = res.getStatusCode();
            String responseSessionId = res.getHeader(HEADER_SESSION_ID);
            Boolean sessionExpiredFlag = (code == 404 && String.isNotBlank(sessionId));

            System.debug('Response Status Code: ' + code);
            System.debug('Response Status: ' + res.getStatus());
            System.debug('Response Body: ' + res.getBody());

            if (code >= 200 && code < 300) {
                McpResponse out = new McpResponse();
                out.body = res.getBody();
                out.statusCode = code;
                out.sessionId = responseSessionId;
                out.sessionExpired = false;
                return out;
            }

            String rawBody = res.getBody();
            Map<String, Object> errorDetails = new Map<String, Object>{
                '_error' => true,
                'statusCode' => code,
                'status' => res.getStatus(),
                'endpoint' => 'callout:' + namedCredential,
                'method' => method,
                'timestamp' => System.now().format('yyyy-MM-dd HH:mm:ss'),
                'rawResponse' => truncateForAura(rawBody)
            };

            if (sessionExpiredFlag) {
                // Spec: "When a client receives HTTP 404 in response to
                // a request containing an Mcp-Session-Id, it MUST start
                // a new session by sending a new InitializeRequest
                // without a session ID attached." The LWC keys off this
                // flag to do exactly that.
                errorDetails.put('sessionExpired', true);
            }

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
                sessionExpiredFlag
                    ? 'The MCP server returned 404 for a request carrying our Mcp-Session-Id. ' +
                      'Per the MCP 2025-06-18 spec, this means the session was terminated server-side. ' +
                      'Start a new session by re-running Connect (the workbench will do this automatically).'
                    : getErrorExplanation(code, namedCredential, rawBody)
            );

            throw newAuraException(JSON.serialize(errorDetails));

        } catch (AuraHandledException e) {
            throw e;

        } catch (System.CalloutException e) {
            Map<String, Object> errorDetails = new Map<String, Object>{
                '_error' => true,
                'type' => 'CalloutException',
                'message' => e.getMessage(),
                'endpoint' => 'callout:' + namedCredential,
                'method' => method,
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
                'method' => method,
                'timestamp' => System.now().format('yyyy-MM-dd HH:mm:ss')
            };

            System.debug(LoggingLevel.ERROR, 'Unexpected Exception: ' + e.getMessage());
            System.debug(LoggingLevel.ERROR, 'Stack Trace: ' + e.getStackTraceString());

            throw newAuraException(JSON.serialize(errorDetails));
        }
    }

    /**
     * Wrapper response for MCP HTTP calls. `body` carries the raw
     * response body the LWC parses today (JSON or SSE). `sessionId`
     * is the `Mcp-Session-Id` the server returned on this response
     * (only populated on initializeConnection in practice, but
     * forwarded on every call so the LWC can adapt if the server
     * decides to rotate). `sessionExpired` is reserved for the
     * 404-with-session path surfaced via the structured error
     * payload; on success it is always false.
     */
    public class McpResponse {
        @AuraEnabled public String body;
        @AuraEnabled public Integer statusCode;
        @AuraEnabled public String sessionId;
        @AuraEnabled public Boolean sessionExpired;
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
     * Call a specific MCP tool with parameters.
     *
     * Per the MCP 2025-06-18 Streamable HTTP spec, every request
     * after `initialize` MUST carry the `Mcp-Session-Id` (if the
     * server assigned one) and the `MCP-Protocol-Version` the
     * client negotiated. The LWC tracks both and passes them in.
     */
    @AuraEnabled
    public static McpResponse callTool(
        String namedCredential,
        String toolName,
        String parameters,
        String sessionId,
        String protocolVersion
    ) {
        try {
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
            return executeMcp(namedCredential, requestBody, sessionId, protocolVersion, 'POST');

        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw newAuraException(wrapWrapperError('callTool', e));
        }
    }

    /**
     * Get available tools from the MCP server. Carries the
     * negotiated session ID and protocol version so the server can
     * scope the response to this client's session per the
     * 2025-06-18 spec.
     */
    @AuraEnabled
    public static McpResponse getAvailableTools(
        String namedCredential,
        String sessionId,
        String protocolVersion
    ) {
        try {
            Map<String, Object> request = new Map<String, Object>{
                'jsonrpc' => '2.0',
                'id' => generateRequestId(),
                'method' => 'tools/list'
            };

            String requestBody = JSON.serialize(request);
            return executeMcp(namedCredential, requestBody, sessionId, protocolVersion, 'POST');

        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw newAuraException(wrapWrapperError('getAvailableTools', e));
        }
    }

    /**
     * Get available resources from the MCP server. Same session
     * headers as getAvailableTools.
     */
    @AuraEnabled
    public static McpResponse getAvailableResources(
        String namedCredential,
        String sessionId,
        String protocolVersion
    ) {
        try {
            Map<String, Object> request = new Map<String, Object>{
                'jsonrpc' => '2.0',
                'id' => generateRequestId(),
                'method' => 'resources/list'
            };

            String requestBody = JSON.serialize(request);
            return executeMcp(namedCredential, requestBody, sessionId, protocolVersion, 'POST');

        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw newAuraException(wrapWrapperError('getAvailableResources', e));
        }
    }

    /**
     * Initialize the MCP session. By spec, this is the only call
     * that runs without an `Mcp-Session-Id` and without an
     * `MCP-Protocol-Version` header -- both are server-determined
     * /negotiated from this exchange. The server MAY return an
     * `Mcp-Session-Id` on the response; if it does, the LWC stashes
     * it on McpResponse.sessionId and passes it back on every
     * subsequent call.
     */
    @AuraEnabled
    public static McpResponse initializeConnection(String namedCredential) {
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
            return executeMcp(namedCredential, requestBody, null, null, 'POST');

        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            System.debug('Error initializing: ' + e.getMessage());
            throw newAuraException(wrapWrapperError('initializeConnection', e));
        }
    }

    /**
     * Sends the spec-required `notifications/initialized`
     * notification after the LWC has parsed a successful
     * InitializeResponse. JSON-RPC notifications carry no `id` and
     * receive HTTP 202 Accepted with an empty body; we still go
     * through executeMcp so session/protocol headers are applied.
     *
     * Failures here are non-fatal -- the LWC fire-and-forgets this
     * call and continues even if the notification is rejected, so a
     * misbehaving server cannot block the workbench.
     */
    @AuraEnabled
    public static McpResponse sendInitializedNotification(
        String namedCredential,
        String sessionId,
        String protocolVersion
    ) {
        try {
            Map<String, Object> request = new Map<String, Object>{
                'jsonrpc' => '2.0',
                'method' => 'notifications/initialized'
            };
            String requestBody = JSON.serialize(request);
            return executeMcp(namedCredential, requestBody, sessionId, protocolVersion, 'POST');

        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw newAuraException(wrapWrapperError('sendInitializedNotification', e));
        }
    }

    /**
     * Best-effort session termination via HTTP DELETE on the MCP
     * endpoint, carrying `Mcp-Session-Id`. Per spec the server MAY
     * respond with 405 Method Not Allowed (DELETE not supported);
     * we swallow that and any other failure so the LWC can call
     * this on navigation without crashing the UI. Even when the
     * server rejects the DELETE the local session state is cleared.
     */
    @AuraEnabled
    public static McpResponse terminateSession(
        String namedCredential,
        String sessionId
    ) {
        if (String.isBlank(sessionId)) {
            McpResponse noop = new McpResponse();
            noop.body = '';
            noop.statusCode = 0;
            noop.sessionExpired = false;
            return noop;
        }
        try {
            return executeMcp(namedCredential, null, sessionId, null, 'DELETE');
        } catch (AuraHandledException e) {
            // 405 (Method Not Allowed) and other rejections are
            // expected per spec; surface a stub response so the LWC
            // can clear local state regardless.
            McpResponse stub = new McpResponse();
            stub.body = e.getMessage();
            stub.statusCode = 0;
            stub.sessionExpired = false;
            return stub;
        } catch (Exception e) {
            McpResponse stub = new McpResponse();
            stub.body = e.getMessage();
            stub.statusCode = 0;
            stub.sessionExpired = false;
            return stub;
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

    /**
     * Runs a read-only permissions diagnostic surfacing whether each
     * relevant user (current admin, Platform Integration User(s)
     * matching `Name LIKE 'Platform%'`, and an optional ad-hoc
     * Username) has:
     *
     *   1. A Permission Set granting access to a SetupEntityType of
     *      `ExternalCredentialParameter`. ExternalCredential and its
     *      Principal are NOT queryable directly, so this is a
     *      heuristic indicator: a user with any ExternalCredentialParameter
     *      grant in their assigned permission sets is highly likely
     *      to also have the principal access for this MCP. Tie-break
     *      to the specific MCP is not possible from Apex SOQL.
     *   2. Read on the `UserExternalCredential` sObject (verified
     *      exactly via `ObjectPermissions`).
     *
     * Never writes. Degrades gracefully when setup objects are not
     * queryable for the running user: partial results plus a
     * populated `warning` are returned instead of a thrown exception.
     */
    @AuraEnabled
    public static PermissionDiagnostic runPermissionsDiagnostic(
        String namedCredential,
        String additionalUsername
    ) {
        try {
            PermissionDiagnostic result = new PermissionDiagnostic();
            result.namedCredential = namedCredential;
            result.permSetsGrantingExternalCredential = new List<String>();
            result.permSetsGrantingUecRead = new List<String>();
            result.userResults = new List<UserCheckResult>();

            Map<Id, String> permSetLabels = new Map<Id, String>();

            // Stage 1: permission sets that grant ExternalCredentialParameter access.
            // ExternalCredential / ExternalCredentialPrincipal aren't
            // directly queryable, so we infer access from any grant
            // of `ExternalCredentialParameter` on the user's assigned
            // permission sets. Profile-owned permsets surface here
            // too, so profile grants are covered automatically.
            Set<Id> permSetsGrantingExternalCredentialIds = new Set<Id>();
            try {
                for (SetupEntityAccess sea : [
                    SELECT ParentId, Parent.Label, Parent.Name,
                           Parent.IsOwnedByProfile, Parent.Profile.Name
                    FROM SetupEntityAccess
                    WHERE SetupEntityType = 'ExternalCredentialParameter'
                ]) {
                    permSetsGrantingExternalCredentialIds.add(sea.ParentId);
                    String label = labelForPermSetParent(sea.Parent);
                    permSetLabels.put(sea.ParentId, label);
                    if (!result.permSetsGrantingExternalCredential.contains(label)) {
                        result.permSetsGrantingExternalCredential.add(label);
                    }
                }
            } catch (Exception e) {
                result.warning = 'Could not query SetupEntityAccess for ' +
                    'ExternalCredentialParameter -- the running user likely ' +
                    'lacks "View Setup and Configuration". Underlying: ' +
                    e.getMessage();
            }

            // Stage 2: permission sets that grant Read on UserExternalCredential.
            Set<Id> permSetsGrantingUecIds = new Set<Id>();
            try {
                for (ObjectPermissions op : [
                    SELECT ParentId, Parent.Label, Parent.Name,
                           Parent.IsOwnedByProfile, Parent.Profile.Name
                    FROM ObjectPermissions
                    WHERE SobjectType = 'UserExternalCredential'
                      AND PermissionsRead = true
                ]) {
                    permSetsGrantingUecIds.add(op.ParentId);
                    String label = labelForPermSetParent(op.Parent);
                    permSetLabels.put(op.ParentId, label);
                    if (!result.permSetsGrantingUecRead.contains(label)) {
                        result.permSetsGrantingUecRead.add(label);
                    }
                }
            } catch (Exception e) {
                if (String.isBlank(result.warning)) {
                    result.warning = 'Could not query ObjectPermissions for ' +
                        'UserExternalCredential: ' + e.getMessage();
                }
            }

            // Stage 3: identify users to check. Use a sentinel for the
            // optional Username so the bind is always non-null and
            // cannot accidentally match a real account.
            Id currentUserId = UserInfo.getUserId();
            String addUser = String.isNotBlank(additionalUsername)
                ? additionalUsername.trim()
                : '__mcp_workbench_no_additional_user__';

            List<User> users = [
                SELECT Id, Name, Username, IsActive
                FROM User
                WHERE Id = :currentUserId
                   OR Name LIKE 'Platform%'
                   OR Username = :addUser
                ORDER BY Name ASC
            ];

            Set<Id> userIds = new Set<Id>();
            for (User u : users) {
                userIds.add(u.Id);
            }

            // Stage 4: each user's assigned permission sets (covers
            // standalone permsets and the auto-permset owned by the
            // user's profile; both surface as PermissionSet rows).
            Map<Id, Set<Id>> userPermSets = new Map<Id, Set<Id>>();
            for (Id uid : userIds) {
                userPermSets.put(uid, new Set<Id>());
            }
            if (!userIds.isEmpty()) {
                for (PermissionSetAssignment psa : [
                    SELECT AssigneeId, PermissionSetId
                    FROM PermissionSetAssignment
                    WHERE AssigneeId IN :userIds
                ]) {
                    if (userPermSets.containsKey(psa.AssigneeId)) {
                        userPermSets.get(psa.AssigneeId).add(psa.PermissionSetId);
                    }
                }
            }

            // Stage 5: intersect, classify, and build remediation hints.
            for (User u : users) {
                UserCheckResult ucr = new UserCheckResult();
                ucr.userId = u.Id;
                ucr.name = u.Name;
                ucr.username = u.Username;
                ucr.isActive = u.IsActive;
                ucr.isCurrentUser = (u.Id == currentUserId);

                if (ucr.isCurrentUser) {
                    ucr.roleLabel = 'Current admin';
                } else if (u.Name != null && u.Name.startsWith('Platform')) {
                    ucr.roleLabel = 'Platform Integration User';
                } else {
                    ucr.roleLabel = 'Custom check';
                }

                ucr.grantingPermSetsForExternalCredential = new List<String>();
                ucr.grantingPermSetsForUec = new List<String>();

                Set<Id> assigned = userPermSets.get(u.Id);
                if (assigned == null) {
                    assigned = new Set<Id>();
                }
                for (Id psId : assigned) {
                    if (permSetsGrantingExternalCredentialIds.contains(psId)) {
                        String lbl = permSetLabels.get(psId);
                        if (lbl != null && !ucr.grantingPermSetsForExternalCredential.contains(lbl)) {
                            ucr.grantingPermSetsForExternalCredential.add(lbl);
                        }
                    }
                    if (permSetsGrantingUecIds.contains(psId)) {
                        String lbl = permSetLabels.get(psId);
                        if (lbl != null && !ucr.grantingPermSetsForUec.contains(lbl)) {
                            ucr.grantingPermSetsForUec.add(lbl);
                        }
                    }
                }

                ucr.hasExternalCredentialAccess = !ucr.grantingPermSetsForExternalCredential.isEmpty();
                ucr.hasUecRead = !ucr.grantingPermSetsForUec.isEmpty();

                List<String> missing = new List<String>();
                if (!ucr.hasExternalCredentialAccess) {
                    missing.add('Access to an ExternalCredentialParameter');
                }
                if (!ucr.hasUecRead) {
                    missing.add('Read on UserExternalCredential');
                }
                if (missing.isEmpty()) {
                    ucr.fixHint = 'Heuristic check passed: user has a Permission ' +
                        'Set granting ExternalCredentialParameter access and ' +
                        'Read on UserExternalCredential. (The principal cannot ' +
                        'be tied to this specific MCP from Apex; verify via Setup ' +
                        'if behavior is still broken.)';
                } else {
                    ucr.fixHint = 'Missing: ' + String.join(missing, '; ') +
                        '. Assign a Permission Set that grants these ' +
                        'to ' + (ucr.name != null ? ucr.name : 'this user') + '.';
                }

                result.userResults.add(ucr);
            }

            return result;

        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw newAuraException(wrapWrapperError('runPermissionsDiagnostic', e));
        }
    }

    /**
     * Render a friendly label for the PermissionSet parent of a
     * SetupEntityAccess / ObjectPermissions row, distinguishing
     * profile-owned permission sets from standalone permission sets.
     */
    private static String labelForPermSetParent(PermissionSet parent) {
        if (parent == null) {
            return 'Unknown permission set';
        }
        if (parent.IsOwnedByProfile) {
            String profileName = (parent.Profile != null && parent.Profile.Name != null)
                ? parent.Profile.Name
                : '(unknown)';
            return 'Profile: ' + profileName;
        }
        String label = parent.Label != null ? parent.Label : parent.Name;
        return 'Permission Set: ' + label;
    }

    /**
     * Diagnostic payload returned to the LWC. All collection fields
     * are always populated (possibly empty) so the client can render
     * a stable table even when sub-queries fail and `warning` is set.
     */
    public class PermissionDiagnostic {
        @AuraEnabled public String namedCredential;
        @AuraEnabled public List<String> permSetsGrantingExternalCredential;
        @AuraEnabled public List<String> permSetsGrantingUecRead;
        @AuraEnabled public List<UserCheckResult> userResults;
        @AuraEnabled public String warning;
    }

    /**
     * Per-user diagnostic row. `grantingPermSetsForExternalCredential`
     * and `grantingPermSetsForUec` are the intersection of the user's
     * assigned permission sets with the permission sets that grant
     * each access, so the LWC can show exactly which assignment is
     * carrying the access (or surface that there is none).
     */
    public class UserCheckResult {
        @AuraEnabled public Id userId;
        @AuraEnabled public String name;
        @AuraEnabled public String username;
        @AuraEnabled public Boolean isActive;
        @AuraEnabled public Boolean isCurrentUser;
        @AuraEnabled public String roleLabel;
        @AuraEnabled public Boolean hasExternalCredentialAccess;
        @AuraEnabled public Boolean hasUecRead;
        @AuraEnabled public List<String> grantingPermSetsForExternalCredential;
        @AuraEnabled public List<String> grantingPermSetsForUec;
        @AuraEnabled public String fixHint;
    }
}
