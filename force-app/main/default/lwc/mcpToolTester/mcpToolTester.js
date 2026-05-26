import { LightningElement, track, wire } from 'lwc';
import getAvailableServers from '@salesforce/apex/McpToolTester.getAvailableServers';
import initializeConnection from '@salesforce/apex/McpToolTester.initializeConnection';
import getAvailableTools from '@salesforce/apex/McpToolTester.getAvailableTools';
import callTool from '@salesforce/apex/McpToolTester.callTool';
import sendInitializedNotification from '@salesforce/apex/McpToolTester.sendInitializedNotification';
import terminateSession from '@salesforce/apex/McpToolTester.terminateSession';
import runPermissionsDiagnostic from '@salesforce/apex/McpToolTester.runPermissionsDiagnostic';

// Fallback if the server's InitializeResponse omits protocolVersion.
// We sent this in the initialize request, so it is the most defensible
// assumption for the MCP-Protocol-Version header on subsequent calls.
const DEFAULT_PROTOCOL_VERSION = '2025-06-18';

export default class McpToolTester extends LightningElement {
    @track selectedServer = '';
    @track serverOptions = [];
    @track serverListError = '';
    @track serverInfo = null;
    @track tools = [];
    @track selectedTool = null;
    @track toolParameters = {};
    @track toolResponse = '';
    @track isLoading = false;
    @track error = '';
    @track errorDetails = null;
    @track isInitialized = false;
    @track currentView = 'server-select'; // server-select, tools, testing
    @track showErrorDetails = false;
    @track showServerInfo = false;
    @track permissionsDiagnostic = null;
    @track permissionsDiagnosticError = '';
    @track permissionsDiagnosticLoading = false;
    @track additionalUsername = '';
    @track showPermissionsDiagnostic = false;
    // MCP session state (MCP 2025-06-18 Streamable HTTP spec).
    // sessionId is whatever the server returned on Mcp-Session-Id at
    // initialize time (may be null if the server doesn't use
    // sessions). negotiatedProtocolVersion is taken from the
    // InitializeResponse and sent on every subsequent request as
    // `MCP-Protocol-Version`. isReinitializing guards the auto-reinit
    // loop triggered by a 404-with-session error.
    @track sessionId = null;
    @track negotiatedProtocolVersion = null;
    isReinitializing = false;

    /**
     * Wire to get available Named Credentials. On error we surface a
     * small inline hint under the dropdown rather than a full-page
     * banner -- manual entry of the Named Credential API name is always
     * supported as a fallback.
     */
    @wire(getAvailableServers)
    wiredServers({ error, data }) {
        if (data) {
            this.serverOptions = data.map(server => ({
                label: server.label,
                value: server.value
            }));
            this.serverListError = '';
        } else if (error) {
            console.error('Error loading servers:', error);
            this.serverOptions = [];
            const parsed = this.parseApexErrorBody(error);
            this.serverListError = parsed && parsed.explanation
                ? parsed.explanation
                : 'Could not load Named Credentials. Enter the API name manually below.';
        }
    }

    get hasServerListError() {
        return !!this.serverListError;
    }

    /**
     * Handle server selection
     */
    handleServerChange(event) {
        this.terminateMcpSession();
        this.selectedServer = event.detail.value;
        this.resetState();
    }

    /**
     * Handle manual server input
     */
    handleManualServerInput(event) {
        this.terminateMcpSession();
        this.selectedServer = event.target.value;
        this.resetState();
    }

    /**
     * Reset state when changing servers
     */
    resetState() {
        this.serverInfo = null;
        this.tools = [];
        this.selectedTool = null;
        this.toolParameters = {};
        this.toolResponse = '';
        this.isInitialized = false;
        this.error = '';
        this.showServerInfo = false;
        this.permissionsDiagnostic = null;
        this.permissionsDiagnosticError = '';
        this.permissionsDiagnosticLoading = false;
        this.sessionId = null;
        this.negotiatedProtocolVersion = null;
    }

    /**
     * Best-effort MCP session termination (HTTP DELETE with
     * `Mcp-Session-Id`). Per the 2025-06-18 spec, clients SHOULD do
     * this when they no longer need the session. We fire and forget;
     * the Apex side swallows 405 (server doesn't allow DELETE) so
     * the UI never hangs on cleanup. Always clears local session
     * state regardless of network outcome.
     */
    terminateMcpSession() {
        const server = this.selectedServer;
        const sid = this.sessionId;
        this.sessionId = null;
        this.negotiatedProtocolVersion = null;
        if (!server || !sid) {
            return;
        }
        terminateSession({ namedCredential: server, sessionId: sid })
            .catch(err => {
                console.warn('MCP session terminate failed (non-fatal):', err);
            });
    }

    /**
     * Browser is tearing down the component (tab close, navigation
     * away). Mirror the spec's "client no longer needs this session"
     * intent with a best-effort DELETE.
     */
    disconnectedCallback() {
        this.terminateMcpSession();
    }

    /**
     * Initialize the MCP connection per the 2025-06-18 spec:
     *   1. POST `initialize` (no session / no protocol headers yet).
     *   2. Capture `Mcp-Session-Id` from the response, if any.
     *   3. Record the negotiated `protocolVersion` for subsequent
     *      `MCP-Protocol-Version` headers.
     *   4. Fire-and-forget `notifications/initialized`.
     *   5. Continue with tools/list and the permissions diagnostic.
     */
    async handleConnect() {
        if (!this.selectedServer) {
            this.error = 'Please select or enter a Named Credential';
            return;
        }

        // Reset session state defensively in case this is a manual
        // reconnect (user clicked Connect again on the same server).
        this.sessionId = null;
        this.negotiatedProtocolVersion = null;
        this.isLoading = true;
        this.error = '';
        this.errorDetails = null;

        try {
            const mcpResponse = await initializeConnection({
                namedCredential: this.selectedServer
            });

            if (mcpResponse && mcpResponse.sessionId) {
                this.sessionId = mcpResponse.sessionId;
            }

            const response = this.parseResponse(mcpResponse && mcpResponse.body);

            if (response.result) {
                this.serverInfo = response.result;
                this.negotiatedProtocolVersion =
                    (response.result && response.result.protocolVersion)
                    || DEFAULT_PROTOCOL_VERSION;
                this.isInitialized = true;
                // Fire-and-forget per spec: the server returns 202
                // Accepted with no body, and a failure here should
                // not block the user from testing tools.
                this.sendInitializedAcknowledgement();
                await this.loadTools();
                this.loadPermissionsDiagnostic();
            } else if (response.error) {
                this.handleMcpError('Initialization failed', response.error);
            }
        } catch (err) {
            this.handleApexError(err, 'Connection Failed');
        } finally {
            this.isLoading = false;
        }
    }

    /**
     * Send the spec-required `notifications/initialized` JSON-RPC
     * notification. Fire-and-forget: any failure is logged but does
     * not surface in the UI. The Apex side already routes through
     * executeMcp so the session and protocol-version headers go
     * along for the ride.
     */
    sendInitializedAcknowledgement() {
        if (!this.selectedServer) return;
        sendInitializedNotification({
            namedCredential: this.selectedServer,
            sessionId: this.sessionId,
            protocolVersion: this.negotiatedProtocolVersion
        }).catch(err => {
            console.warn('MCP notifications/initialized failed (non-fatal):', err);
        });
    }

    /**
     * Run the read-only permissions diagnostic against the connected
     * Named Credential. Errors are isolated to the diagnostic panel
     * so a failure here cannot block the tools list or testing flow.
     */
    async loadPermissionsDiagnostic() {
        if (!this.selectedServer) {
            return;
        }
        this.permissionsDiagnosticLoading = true;
        this.permissionsDiagnosticError = '';

        try {
            const result = await runPermissionsDiagnostic({
                namedCredential: this.selectedServer,
                additionalUsername: this.additionalUsername || ''
            });
            this.permissionsDiagnostic = this.decoratePermissionsDiagnostic(result);
        } catch (err) {
            console.error('Permissions diagnostic failed:', err);
            const parsed = this.parseApexErrorBody(err);
            const summary = (parsed && (parsed.explanation || parsed.message))
                || (err && err.body && err.body.message)
                || (err && err.message)
                || 'Unable to run permissions diagnostic.';
            this.permissionsDiagnosticError = summary;
            this.permissionsDiagnostic = null;
        } finally {
            this.permissionsDiagnosticLoading = false;
        }
    }

    /**
     * Pre-compute display-only fields (icon variants, joined perm-set
     * labels, summary text) so the template can stay declarative.
     * Templates cannot run expressions, so we materialise everything
     * the markup needs here.
     */
    decoratePermissionsDiagnostic(raw) {
        if (!raw) return null;
        const decorated = {
            ...raw,
            permSetsGrantingExternalCredentialDisplay: (raw.permSetsGrantingExternalCredential || []).join(', '),
            permSetsGrantingUecReadDisplay: (raw.permSetsGrantingUecRead || []).join(', '),
            hasWarning: !!raw.warning,
            userResults: (raw.userResults || []).map((u, idx) => ({
                ...u,
                key: u.userId || `user-${idx}`,
                externalCredentialIcon: u.hasExternalCredentialAccess ? 'utility:success' : 'utility:error',
                externalCredentialIconVariant: u.hasExternalCredentialAccess ? 'success' : 'error',
                externalCredentialStatus: u.hasExternalCredentialAccess ? 'Likely granted' : 'Missing',
                uecIcon: u.hasUecRead ? 'utility:success' : 'utility:error',
                uecIconVariant: u.hasUecRead ? 'success' : 'error',
                uecStatus: u.hasUecRead ? 'Granted' : 'Missing',
                rowAllGood: u.hasExternalCredentialAccess && u.hasUecRead,
                activeLabel: u.isActive ? 'Active' : 'Inactive',
                externalCredentialGrantsDisplay: (u.grantingPermSetsForExternalCredential || []).join(', '),
                uecGrantsDisplay: (u.grantingPermSetsForUec || []).join(', '),
                hasExternalCredentialGrants: (u.grantingPermSetsForExternalCredential || []).length > 0,
                hasUecGrants: (u.grantingPermSetsForUec || []).length > 0
            }))
        };
        return decorated;
    }

    handleAdditionalUsernameChange(event) {
        this.additionalUsername = event.target.value;
    }

    handleRunPermissionsDiagnostic() {
        this.loadPermissionsDiagnostic();
    }

    handleTogglePermissionsDiagnostic() {
        this.showPermissionsDiagnostic = !this.showPermissionsDiagnostic;
    }

    get permissionsDiagnosticToggleIcon() {
        return this.showPermissionsDiagnostic ? 'utility:chevrondown' : 'utility:chevronright';
    }

    get hasPermissionsDiagnostic() {
        return this.permissionsDiagnostic !== null;
    }

    get hasPermissionsDiagnosticError() {
        return this.permissionsDiagnosticError !== '';
    }

    /**
     * Load available tools from the MCP server, carrying the
     * session and negotiated protocol-version headers per the spec.
     */
    async loadTools() {
        this.isLoading = true;
        this.error = '';
        this.errorDetails = null;

        try {
            const mcpResponse = await getAvailableTools({
                namedCredential: this.selectedServer,
                sessionId: this.sessionId,
                protocolVersion: this.negotiatedProtocolVersion
            });
            this.captureRotatedSessionId(mcpResponse);
            const response = this.parseResponse(mcpResponse && mcpResponse.body);

            if (response.result && response.result.tools) {
                this.tools = response.result.tools.map(tool => ({
                    name: tool.name,
                    description: tool.description || 'No description available',
                    inputSchema: tool.inputSchema,
                    title: tool.title || tool.name,
                    key: `tool-${tool.name}`
                }));
                this.currentView = 'tools';
            } else if (response.error) {
                this.handleMcpError('Failed to load tools', response.error);
            }
        } catch (err) {
            const recovered = await this.maybeReinitializeOnSessionExpired(err, () => this.loadTools());
            if (!recovered) {
                this.handleApexError(err, 'Error Loading Tools');
            }
        } finally {
            this.isLoading = false;
        }
    }

    /**
     * Some servers may rotate the session ID across requests (rare
     * but allowed by the spec since clients echo back whatever
     * `Mcp-Session-Id` the server most recently issued). If the
     * server returned a new session id on this response, adopt it.
     */
    captureRotatedSessionId(mcpResponse) {
        if (mcpResponse && mcpResponse.sessionId && mcpResponse.sessionId !== this.sessionId) {
            this.sessionId = mcpResponse.sessionId;
        }
    }

    /**
     * MCP 2025-06-18 spec: "When a client receives HTTP 404 in
     * response to a request containing an Mcp-Session-Id, it MUST
     * start a new session by sending a new InitializeRequest
     * without a session ID attached."
     *
     * We detect that via the `sessionExpired` flag the Apex side
     * sets on the structured `_error` payload, re-initialize once,
     * and (if init succeeds) retry the original action. Returns
     * true when the recovery path ran -- callers should skip their
     * normal error rendering in that case.
     */
    async maybeReinitializeOnSessionExpired(err, retryFn) {
        if (this.isReinitializing) {
            // Already in the middle of one recovery; don't loop.
            return false;
        }
        const parsed = this.parseApexErrorBody(err);
        if (!parsed || !parsed.sessionExpired) {
            return false;
        }
        this.isReinitializing = true;
        try {
            console.info('MCP session expired (HTTP 404 with Mcp-Session-Id). Re-initializing per spec.');
            this.sessionId = null;
            this.negotiatedProtocolVersion = null;
            const initResponse = await initializeConnection({
                namedCredential: this.selectedServer
            });
            if (initResponse && initResponse.sessionId) {
                this.sessionId = initResponse.sessionId;
            }
            const parsedInit = this.parseResponse(initResponse && initResponse.body);
            if (parsedInit.error) {
                this.handleMcpError('Re-initialization failed after session expiry', parsedInit.error);
                return true;
            }
            this.serverInfo = parsedInit.result;
            this.negotiatedProtocolVersion =
                (parsedInit.result && parsedInit.result.protocolVersion)
                || DEFAULT_PROTOCOL_VERSION;
            this.sendInitializedAcknowledgement();
            if (typeof retryFn === 'function') {
                await retryFn();
            }
            return true;
        } catch (reinitErr) {
            this.handleApexError(reinitErr, 'Re-initialization failed after session expiry');
            return true;
        } finally {
            this.isReinitializing = false;
        }
    }

    /**
     * Handle tool selection
     */
    handleToolSelect(event) {
        const toolName = event.currentTarget.dataset.tool;
        this.selectedTool = this.tools.find(t => t.name === toolName);
        this.toolParameters = {};
        this.toolResponse = '';
        this.currentView = 'testing';
    }

    /**
     * Handle parameter input changes
     */
    handleParameterChange(event) {
        const paramName = event.target.dataset.param;
        const paramValue = event.target.value;
        
        this.toolParameters = {
            ...this.toolParameters,
            [paramName]: paramValue
        };
    }

    /**
     * Handle array item input changes
     */
    handleArrayItemChange(event) {
        const paramName = event.target.dataset.param;
        const itemIndex = parseInt(event.target.dataset.index, 10);
        const itemValue = event.target.value;
        
        const currentArray = this.toolParameters[paramName] || [];
        const newArray = [...currentArray];
        newArray[itemIndex] = itemValue;
        
        this.toolParameters = {
            ...this.toolParameters,
            [paramName]: newArray
        };
    }

    /**
     * Add a new item to an array parameter
     */
    handleAddArrayItem(event) {
        const paramName = event.target.dataset.param;
        const currentArray = this.toolParameters[paramName] || [];
        
        this.toolParameters = {
            ...this.toolParameters,
            [paramName]: [...currentArray, '']
        };
    }

    /**
     * Remove an item from an array parameter
     */
    handleRemoveArrayItem(event) {
        const paramName = event.target.dataset.param;
        const itemIndex = parseInt(event.target.dataset.index, 10);
        const currentArray = this.toolParameters[paramName] || [];
        
        const newArray = currentArray.filter((_, index) => index !== itemIndex);
        
        this.toolParameters = {
            ...this.toolParameters,
            [paramName]: newArray
        };
    }

    /**
     * Execute the selected tool, carrying the session and negotiated
     * protocol-version headers per the 2025-06-18 spec.
     */
    async handleExecuteTool() {
        if (!this.selectedTool) return;

        this.isLoading = true;
        this.error = '';
        this.errorDetails = null;
        this.toolResponse = '';

        try {
            const params = JSON.stringify(this.toolParameters);
            const mcpResponse = await callTool({
                namedCredential: this.selectedServer,
                toolName: this.selectedTool.name,
                parameters: params,
                sessionId: this.sessionId,
                protocolVersion: this.negotiatedProtocolVersion
            });
            this.captureRotatedSessionId(mcpResponse);
            const response = this.parseResponse(mcpResponse && mcpResponse.body);

            if (response.result) {
                const formattedResponse = this.formatMcpResponse(response.result);
                this.toolResponse = formattedResponse;
            } else if (response.error) {
                this.handleMcpError('Tool execution failed', response.error);
            }
        } catch (err) {
            const recovered = await this.maybeReinitializeOnSessionExpired(err, () => this.handleExecuteTool());
            if (!recovered) {
                this.handleApexError(err, 'Tool Execution Error');
            }
        } finally {
            this.isLoading = false;
        }
    }
    
    /**
     * Handle MCP protocol (JSON-RPC) errors. Surface code and any
     * actionable `data.detail` directly in the banner so users do not
     * have to expand the technical-details panel for the common case.
     */
    handleMcpError(title, error) {
        const code = error.code !== undefined && error.code !== null ? ` [code ${error.code}]` : '';
        let detailHint = '';
        if (error.data) {
            if (typeof error.data === 'string') {
                detailHint = ` -- ${error.data}`;
            } else if (error.data.detail) {
                detailHint = ` -- ${error.data.detail}`;
            } else if (error.data.message) {
                detailHint = ` -- ${error.data.message}`;
            }
        }
        this.error = `${title}${code}: ${error.message || 'Unknown error'}${detailHint}`;
        this.errorDetails = {
            type: 'MCP Error',
            code: error.code,
            message: error.message,
            data: error.data,
            title: title
        };
    }

    /**
     * Extract the parseable JSON payload from an Apex AuraHandledException
     * (returned by callMcpServer / wrappers / getAvailableServers). Returns
     * null when the message is not the structured shape.
     */
    parseApexErrorBody(err) {
        const errorBody = err && err.body ? err.body.message : (err && err.message);
        if (!errorBody) {
            return null;
        }
        try {
            const parsed = JSON.parse(errorBody);
            return parsed && parsed._error ? parsed : null;
        } catch (parseErr) { // eslint-disable-line no-unused-vars
            return null;
        }
    }

    /**
     * Handle Apex/HTTP errors with detailed information.
     */
    handleApexError(err, title) {
        console.log('Error Object:', JSON.stringify(err, null, 2));
        const errorBody = err && err.body ? err.body.message : (err && err.message);
        console.log('Error Body:', errorBody);

        const parsedError = this.parseApexErrorBody(err);
        if (parsedError) {
            console.log('Parsed Apex Error:', JSON.stringify(parsedError, null, 2));
            const summary = parsedError.message
                || parsedError.status
                || parsedError.explanation
                || 'Error occurred';
            this.error = `${title}: ${summary}`;
            this.errorDetails = {
                ...parsedError,
                title: title
            };
            return;
        }

        if (errorBody === 'Script-thrown exception') {
            this.error = `${title}: Script-thrown exception (Apex returned a generic error).` +
                ' Open the browser console and Salesforce Debug Log for the underlying message.';
            this.errorDetails = {
                title: title,
                hint: 'AuraHandledException did not carry a structured message. ' +
                    'This usually means the Apex side hit an unexpected exception type, ' +
                    'or the message exceeded Lightning size limits.',
                rawErrorObject: this.safeStringify(err)
            };
            return;
        }

        this.error = `${title}: ${errorBody}`;
        this.errorDetails = { title: title, message: errorBody };
    }

    safeStringify(obj) {
        try {
            return JSON.stringify(obj, null, 2);
        } catch (stringifyErr) { // eslint-disable-line no-unused-vars
            return String(obj);
        }
    }
    
    /**
     * Toggle error details visibility
     */
    handleToggleErrorDetails() {
        this.showErrorDetails = !this.showErrorDetails;
    }

    handleToggleServerInfo() {
        this.showServerInfo = !this.showServerInfo;
    }

    get serverInfoToggleIcon() {
        return this.showServerInfo ? 'utility:chevrondown' : 'utility:chevronright';
    }

    /**
     * Navigate back to tools list
     */
    handleBackToTools() {
        this.selectedTool = null;
        this.toolParameters = {};
        this.toolResponse = '';
        this.currentView = 'tools';
    }

    /**
     * Navigate back to server selection. Per the 2025-06-18 spec,
     * clients that no longer need a session SHOULD terminate it via
     * HTTP DELETE. We fire that off best-effort before resetting
     * local state.
     */
    handleBackToServers() {
        this.terminateMcpSession();
        this.resetState();
        this.currentView = 'server-select';
    }

    /**
     * Parse MCP response (handles both plain JSON and SSE format).
     * On parse failure, surface a JSON-RPC-shaped error whose `data`
     * field carries the raw body (truncated) and the parser exception
     * so handleMcpError can render actionable detail. Previously this
     * collapsed every failure to "Invalid response format" with no body.
     */
    parseResponse(responseStr) {
        const RAW_PREVIEW_MAX = 4000;
        try {
            if (responseStr && responseStr.includes('event:') && responseStr.includes('data:')) {
                const lines = responseStr.split('\n');
                for (const line of lines) {
                    if (line.startsWith('data: ')) {
                        return JSON.parse(line.substring(6).trim());
                    }
                }
            }
            return JSON.parse(responseStr);
        } catch (e) {
            console.error('Error parsing response:', e);
            const preview = (responseStr || '').slice(0, RAW_PREVIEW_MAX);
            const truncated = (responseStr || '').length > RAW_PREVIEW_MAX;
            return {
                error: {
                    code: 'PARSE_ERROR',
                    message: 'Invalid response format from MCP server',
                    data: {
                        detail: e && e.message ? e.message : String(e),
                        rawResponse: preview,
                        rawResponseTruncated: truncated,
                        rawResponseLength: (responseStr || '').length
                    }
                }
            };
        }
    }

    /**
     * Format MCP response for better readability
     * Handles nested JSON strings in content.text fields
     */
    formatMcpResponse(result) {
        try {
            // Check if result has content array (standard MCP format)
            if (result.content && Array.isArray(result.content)) {
                const formatted = {
                    ...result,
                    content: result.content.map(item => {
                        if (item.type === 'text' && item.text) {
                            // Try to parse the text as JSON
                            try {
                                const parsedText = JSON.parse(item.text);
                                return {
                                    ...item,
                                    text: parsedText, // Replace string with parsed object
                                    _note: 'Nested JSON detected and parsed'
                                };
                            } catch (notJson) { // eslint-disable-line no-unused-vars
                                return item;
                            }
                        }
                        return item;
                    })
                };
                return JSON.stringify(formatted, null, 2);
            }
            
            // Fallback: just stringify the result
            return JSON.stringify(result, null, 2);
        } catch (e) {
            console.error('Error formatting response:', e);
            return JSON.stringify(result, null, 2);
        }
    }

    /**
     * Get properties for the selected tool's input schema
     */
    get toolInputFields() {
        if (!this.selectedTool || !this.selectedTool.inputSchema) {
            return [];
        }

        const schema = this.selectedTool.inputSchema;
        const properties = schema.properties || {};
        const required = schema.required || [];

        console.log('Schema:', JSON.stringify(schema, null, 2));

        return Object.keys(properties).map(key => {
            const prop = properties[key];
            const isArray = prop.type === 'array';
            
            let itemType = 'text';
            if (isArray && prop.items) {
                itemType = this.getInputType(prop.items.type || 'string');
            }
            
            // Get current array items dynamically
            const currentValue = this.toolParameters[key];
            let arrayItems = [];
            if (isArray && Array.isArray(currentValue)) {
                arrayItems = currentValue.map((value, index) => ({
                    value: value,
                    index: index,
                    key: `${key}-item-${index}`
                }));
            }
            
            return {
                name: key,
                label: this.formatLabel(key),
                type: this.getInputType(prop.type),
                isArray: isArray,
                itemType: itemType,
                description: prop.description || '',
                required: required.includes(key),
                key: `field-${key}`,
                items: arrayItems
            };
        });
    }

    /**
     * Get the current array items for a field
     */
    getArrayItemsForField(fieldName) {
        const currentValue = this.toolParameters[fieldName];
        if (!Array.isArray(currentValue)) {
            return [];
        }
        return currentValue.map((value, index) => ({
            value: value,
            index: index,
            key: `${fieldName}-item-${index}`
        }));
    }

    /**
     * Format field label from camelCase/snake_case
     */
    formatLabel(name) {
        return name
            .replace(/([A-Z])/g, ' $1')
            .replace(/_/g, ' ')
            .replace(/^./, str => str.toUpperCase())
            .trim();
    }

    /**
     * Map JSON schema types to Lightning input types
     */
    getInputType(schemaType) {
        const typeMap = {
            'string': 'text',
            'number': 'number',
            'integer': 'number',
            'boolean': 'checkbox'
        };
        return typeMap[schemaType] || 'text';
    }

    // Computed properties for conditional rendering
    get isServerSelectView() {
        return this.currentView === 'server-select';
    }

    get isToolsView() {
        return this.currentView === 'tools';
    }

    get isTestingView() {
        return this.currentView === 'testing';
    }

    get hasTools() {
        return this.tools.length > 0;
    }

    get hasError() {
        return this.error !== '';
    }
    
    get hasErrorDetails() {
        return this.errorDetails !== null;
    }
    
    get errorDetailsJson() {
        return this.errorDetails ? JSON.stringify(this.errorDetails, null, 2) : '';
    }

    get hasToolResponse() {
        return this.toolResponse !== '';
    }

    get hasServerOptions() {
        return this.serverOptions.length > 0;
    }

    get serverInfoDisplay() {
        if (!this.serverInfo) return '';
        return JSON.stringify(this.serverInfo, null, 2);
    }

    get selectedToolSchema() {
        if (!this.selectedTool || !this.selectedTool.inputSchema) {
            return 'No schema available';
        }
        return JSON.stringify(this.selectedTool.inputSchema, null, 2);
    }

    get selectedServerLabel() {
        const option = this.serverOptions.find(s => s.value === this.selectedServer);
        return option ? option.label : this.selectedServer;
    }
}
