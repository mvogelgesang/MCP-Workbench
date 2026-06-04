import { LightningElement, track, wire } from 'lwc';
import getAvailableServers from '@salesforce/apex/McpToolTester.getAvailableServers';
import initializeConnection from '@salesforce/apex/McpToolTester.initializeConnection';
import getAvailableTools from '@salesforce/apex/McpToolTester.getAvailableTools';
import callTool from '@salesforce/apex/McpToolTester.callTool';
import runPermissionsDiagnostic from '@salesforce/apex/McpToolTester.runPermissionsDiagnostic';
import { isLikelyMarkdown, markdownToHtml } from './markdown';

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
    @track traceEntries = [];
    @track showNetworkTrace = false;

    // Tool-testing view state. `testTab` toggles between the Test surface
    // (inputs + response) and the Schema reference. `responseTab` drives the
    // sub-tabs inside the Response card. `responseMetadata` is a snapshot of
    // the trace entry produced by the last Execute call -- it gives us status,
    // duration, headers, and the raw body without having to look up the trace
    // entries list each render. `formResetKey` is bumped on Reset so that
    // `lightning-input` instances are torn down and rebuilt empty (we don't
    // two-way bind value, so a fresh key is the cleanest way to clear them).
    @track testTab = 'test';
    @track responseTab = 'pretty';
    @track descriptionExpanded = false;
    @track responseMetadata = null;
    @track inputsHasOverflow = false;
    @track responseCopiedMsg = '';
    @track schemaCopiedMsg = '';
    formResetKey = 0;

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
        this.selectedServer = event.detail.value;
        this.resetState();
    }

    /**
     * Handle manual server input
     */
    handleManualServerInput(event) {
        this.selectedServer = event.target.value;
        this.resetState();
    }

    /**
     * Reset state when changing servers. The network-trace is a
     * per-session log, so swapping the Named Credential starts a
     * fresh trace.
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
        this.traceEntries = [];
    }

    /**
     * Initialize the MCP connection
     */
    async handleConnect() {
        if (!this.selectedServer) {
            this.error = 'Please select or enter a Named Credential';
            return;
        }

        this.isLoading = true;
        this.error = '';
        this.errorDetails = null;

        try {
            const result = await initializeConnection({ 
                namedCredential: this.selectedServer 
            });
            const response = this.parseResponse(result);
            
            if (response.result) {
                this.serverInfo = response.result;
                this.isInitialized = true;
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
     * Load available tools from the MCP server
     */
    async loadTools() {
        this.isLoading = true;
        this.error = '';
        this.errorDetails = null;

        try {
            const result = await getAvailableTools({ 
                namedCredential: this.selectedServer 
            });
            const response = this.parseResponse(result);
            
            if (response.result && response.result.tools) {
                this.tools = response.result.tools.map((tool) =>
                    this.decorateToolForList(tool, /* expanded */ false)
                );
                this.currentView = 'tools';
            } else if (response.error) {
                this.handleMcpError('Failed to load tools', response.error);
            }
        } catch (err) {
            this.handleApexError(err, 'Error Loading Tools');
        } finally {
            this.isLoading = false;
        }
    }

    /**
     * Build the view model for a single tool tile. We pre-compute the
     * markdown HTML, the "Show more" toggle hint, and the container class
     * string here so the template stays declarative -- LWC for:each can't
     * call methods per item or branch on derived state without exploding
     * into nested templates.
     *
     * `expanded` is carried per-tool so a user can pop just the tile they
     * care about without disturbing the rest of the grid.
     */
    decorateToolForList(tool, expanded) {
        const description = tool.description || 'No description available';
        const descriptionIsMarkdown = isLikelyMarkdown(description);
        const toggleNeeded = this.shouldClampDescription(description);
        return {
            name: tool.name,
            description,
            descriptionIsMarkdown,
            descriptionHtml: descriptionIsMarkdown ? markdownToHtml(description) : '',
            descriptionExpanded: expanded,
            descriptionToggleNeeded: toggleNeeded,
            descriptionToggleLabel: expanded ? 'Show less' : 'Show more',
            descriptionContainerClass: this.toolDocContainerClass(expanded, toggleNeeded),
            inputSchema: tool.inputSchema,
            title: tool.title || tool.name,
            // Bumping the key when collapse-state flips would re-mount
            // lightning-formatted-rich-text; keep the key tied to the
            // tool name so the rich-text component just re-renders.
            key: `tool-${tool.name}`
        };
    }

    /**
     * Shared rule for "this description is long enough to deserve a
     * Show more toggle." Roughly the same heuristic the testing-view
     * description uses -- short prose stays inline.
     */
    shouldClampDescription(text) {
        if (typeof text !== 'string') return false;
        if (text.length > 220) return true;
        return text.split('\n').length > 3;
    }

    toolDocContainerClass(expanded, toggleNeeded) {
        const base = 'tool-card__doc';
        if (!toggleNeeded) return base;
        return expanded ? `${base} ${base}_expanded` : `${base} ${base}_collapsed`;
    }

    /**
     * Toggle the per-tile description clamp. Stops propagation so the
     * click does not bubble up to the article's `handleToolSelect`
     * handler and navigate the user into the testing view.
     */
    handleToggleToolDescription(event) {
        event.stopPropagation();
        const name = event.currentTarget.dataset.tool;
        this.tools = this.tools.map((t) => {
            if (t.name !== name) return t;
            return this.decorateToolForList(t, !t.descriptionExpanded);
        });
    }

    /**
     * Handle tool selection. Resets the per-tool testing surface so the
     * inputs, response card, and tab selection start clean -- previous
     * response/headers are not relevant to a freshly-selected tool.
     */
    handleToolSelect(event) {
        const toolName = event.currentTarget.dataset.tool;
        this.selectedTool = this.tools.find(t => t.name === toolName);
        this.toolParameters = {};
        this.toolResponse = '';
        this.responseMetadata = null;
        this.responseTab = 'pretty';
        this.testTab = 'test';
        this.descriptionExpanded = false;
        this.inputsHasOverflow = false;
        this.responseCopiedMsg = '';
        this.schemaCopiedMsg = '';
        this.formResetKey++;
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
     * Execute the selected tool
     */
    async handleExecuteTool() {
        if (!this.selectedTool) return;

        this.isLoading = true;
        this.error = '';
        this.errorDetails = null;
        this.toolResponse = '';
        this.responseMetadata = null;
        this.responseCopiedMsg = '';

        try {
            const params = JSON.stringify(this.toolParameters);
            const result = await callTool({ 
                namedCredential: this.selectedServer,
                toolName: this.selectedTool.name,
                parameters: params
            });
            
            const response = this.parseResponse(result);
            
            if (response.result) {
                // Format the response for better readability
                const formattedResponse = this.formatMcpResponse(response.result);
                this.toolResponse = formattedResponse;
                this.responseMetadata = this.snapshotLatestTraceAsResponseMeta();
                this.responseTab = 'pretty';
            } else if (response.error) {
                this.handleMcpError('Tool execution failed', response.error);
            }
        } catch (err) {
            this.handleApexError(err, 'Tool Execution Error');
        } finally {
            this.isLoading = false;
        }
    }

    /**
     * Grab the most recent trace entry (the one just produced by the
     * callTool roundtrip) and reshape it into the fields the Response card
     * needs. We snapshot rather than re-derive from `traceEntries` on every
     * render so a later trace entry (e.g. a permissions check) doesn't
     * silently overwrite what the Response card is showing.
     */
    snapshotLatestTraceAsResponseMeta() {
        const last = this.traceEntries[this.traceEntries.length - 1];
        if (!last) {
            return null;
        }
        const tone = this.statusToneFor(last.statusCode, last.isError);
        const statusLabel = last.statusText
            ? `${last.statusCode} ${last.statusText}`
            : `${last.statusCode || '—'}`;
        const headerEntries = this.formatHeaderEntries(last.responseHeaders);
        return {
            statusCode: last.statusCode,
            statusLabel,
            statusTone: tone,
            statusPillClass: `response-status response-status_${tone}`,
            durationMs: last.durationMs,
            durationLabel: this.formatDuration(last.durationMs),
            rawBody: last.responseBody || '',
            headerEntries,
            hasHeaders: headerEntries.length > 0,
            startedAt: last.startedAt
        };
    }

    formatHeaderEntries(headers) {
        if (!headers || typeof headers !== 'object') return [];
        return Object.keys(headers)
            .sort((a, b) => a.localeCompare(b))
            .map((name, idx) => ({
                key: `hdr-${idx}-${name}`,
                name,
                value: String(headers[name])
            }));
    }

    /**
     * Map an HTTP status / error flag to a semantic tone used by the
     * status pill. 2xx -> success, 3xx -> info, 4xx -> warning,
     * 5xx / explicit isError -> error. Unknowns fall back to neutral.
     */
    statusToneFor(statusCode, isError) {
        if (isError) return 'error';
        const code = Number(statusCode);
        if (!code) return 'neutral';
        if (code >= 200 && code < 300) return 'success';
        if (code >= 300 && code < 400) return 'info';
        if (code >= 400 && code < 500) return 'warning';
        if (code >= 500) return 'error';
        return 'neutral';
    }

    formatDuration(ms) {
        if (ms == null) return '';
        const n = Number(ms);
        if (!Number.isFinite(n)) return '';
        if (n < 1000) return `${n} ms`;
        return `${(n / 1000).toFixed(2)} s`;
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
     * Handle Apex/HTTP errors with detailed information. If the
     * server-side error JSON carries a `trace` field (added by the
     * network-trace work in McpToolTester.cls), append it to the
     * trace panel so the failed step is visible alongside the
     * successful ones.
     */
    handleApexError(err, title) {
        console.log('Error Object:', JSON.stringify(err, null, 2));
        const errorBody = err && err.body ? err.body.message : (err && err.message);
        console.log('Error Body:', errorBody);

        const parsedError = this.parseApexErrorBody(err);
        if (parsedError) {
            console.log('Parsed Apex Error:', JSON.stringify(parsedError, null, 2));
            if (parsedError.trace) {
                this.pushTraceEntry(parsedError.trace);
            }
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
     * Navigate back to server selection
     */
    handleBackToServers() {
        this.resetState();
        this.currentView = 'server-select';
    }

    /**
     * Parse MCP response (handles both plain JSON and SSE format).
     *
     * Two-step:
     *   1. If `responseStr` is the `McpCallResult` envelope returned
     *      by Apex (`{trace, body}`), push the trace to the
     *      network-trace panel and continue with the embedded body.
     *   2. Parse the body as JSON-RPC (or SSE-wrapped JSON-RPC).
     *
     * On parse failure, surface a JSON-RPC-shaped error whose `data`
     * field carries the raw body (truncated) and the parser exception
     * so handleMcpError can render actionable detail.
     */
    parseResponse(responseStr) {
        const RAW_PREVIEW_MAX = 4000;
        const body = this.recordTraceAndUnwrap(responseStr);
        try {
            if (body && body.includes('event:') && body.includes('data:')) {
                const lines = body.split('\n');
                for (const line of lines) {
                    if (line.startsWith('data: ')) {
                        return JSON.parse(line.substring(6).trim());
                    }
                }
            }
            return JSON.parse(body);
        } catch (e) {
            console.error('Error parsing response:', e);
            const preview = (body || '').slice(0, RAW_PREVIEW_MAX);
            const truncated = (body || '').length > RAW_PREVIEW_MAX;
            return {
                error: {
                    code: 'PARSE_ERROR',
                    message: 'Invalid response format from MCP server',
                    data: {
                        detail: e && e.message ? e.message : String(e),
                        rawResponse: preview,
                        rawResponseTruncated: truncated,
                        rawResponseLength: (body || '').length
                    }
                }
            };
        }
    }

    /**
     * Try to interpret a String returned from `@AuraEnabled` Apex as
     * an `McpCallResult` envelope. When it is, append the trace to
     * `traceEntries` and return the inner `body` string. When the
     * input is not an envelope (e.g. an older method or a future
     * unwrapped response), return it unchanged so callers degrade
     * gracefully.
     */
    recordTraceAndUnwrap(responseStr) {
        if (typeof responseStr !== 'string' || !responseStr.startsWith('{')) {
            return responseStr;
        }
        try {
            const parsed = JSON.parse(responseStr);
            if (
                parsed
                && typeof parsed === 'object'
                && parsed.trace
                && Object.prototype.hasOwnProperty.call(parsed, 'body')
            ) {
                this.pushTraceEntry(parsed.trace);
                return parsed.body;
            }
        } catch (parseErr) { // eslint-disable-line no-unused-vars
            // Not an envelope; let the caller continue with the raw
            // string so existing parse paths still apply.
        }
        return responseStr;
    }

    /**
     * Append a trace entry returned from Apex to the
     * network-trace panel. Each entry already carries an `id`
     * generated server-side so the LWC can use it as a stable key.
     */
    pushTraceEntry(entry) {
        if (!entry || !entry.id) {
            return;
        }
        this.traceEntries = [...this.traceEntries, entry];
    }

    handleToggleNetworkTrace() {
        this.showNetworkTrace = !this.showNetworkTrace;
    }

    handleClearNetworkTrace() {
        this.traceEntries = [];
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
                // `formResetKey` is bumped by handleResetInputs so the
                // template tears down old lightning-inputs and rebuilds them
                // empty. We don't two-way bind `value`, so a fresh key is
                // the cleanest way to clear native form state.
                key: `field-${key}-${this.formResetKey}`,
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

    // ---------- Tool-testing view: tabs, description, reset, copy ----------

    handleSwitchToTestTab() {
        this.testTab = 'test';
    }

    handleSwitchToSchemaTab() {
        this.testTab = 'schema';
    }

    handleResponseTabPretty() {
        this.responseTab = 'pretty';
    }

    handleResponseTabRaw() {
        this.responseTab = 'raw';
    }

    handleResponseTabHeaders() {
        this.responseTab = 'headers';
    }

    handleToggleDescription() {
        this.descriptionExpanded = !this.descriptionExpanded;
    }

    /**
     * Wipe the input form. We rebuild every lightning-input by bumping
     * `formResetKey` (see `toolInputFields`) and clear the parameter map
     * so the next Execute submits an empty payload. The previous response
     * is intentionally left in place -- it stays available as a reference
     * until the user runs another tool call.
     */
    handleResetInputs() {
        this.toolParameters = {};
        this.formResetKey++;
    }

    handleCopyResponse() {
        const text = this.activeResponseText;
        this.copyToClipboard(text).then((ok) => {
            this.responseCopiedMsg = ok ? 'Copied' : 'Copy failed';
            this.scheduleClear('responseCopiedMsg');
        });
    }

    handleCopySchema() {
        this.copyToClipboard(this.selectedToolSchema).then((ok) => {
            this.schemaCopiedMsg = ok ? 'Copied' : 'Copy failed';
            this.scheduleClear('schemaCopiedMsg');
        });
    }

    /**
     * Promise-returning wrapper around `navigator.clipboard.writeText` that
     * never throws. LWC runs in a modern browser, but the Clipboard API can
     * still fail (insecure context, focus loss, permission denial) -- in
     * those cases we resolve `false` so callers surface a "Copy failed"
     * hint instead of a thrown exception.
     */
    async copyToClipboard(text) {
        try {
            if (text == null) return false;
            if (navigator && navigator.clipboard && navigator.clipboard.writeText) {
                await navigator.clipboard.writeText(String(text));
                return true;
            }
            return false;
        } catch (copyErr) { // eslint-disable-line no-unused-vars
            return false;
        }
    }

    scheduleClear(prop) {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        window.setTimeout(() => {
            this[prop] = '';
        }, 1500);
    }

    get activeResponseText() {
        if (!this.responseMetadata) return this.toolResponse;
        if (this.responseTab === 'raw') return this.responseMetadata.rawBody || '';
        if (this.responseTab === 'headers') {
            return this.responseMetadata.headerEntries
                .map((h) => `${h.name}: ${h.value}`)
                .join('\n');
        }
        return this.toolResponse;
    }

    // ---------- Tool-testing view: getters ----------

    get isTestTab() {
        return this.testTab === 'test';
    }

    get isSchemaTab() {
        return this.testTab === 'schema';
    }

    get isResponsePrettyTab() {
        return this.responseTab === 'pretty';
    }

    get isResponseRawTab() {
        return this.responseTab === 'raw';
    }

    get isResponseHeadersTab() {
        return this.responseTab === 'headers';
    }

    get testTabBtnClass() {
        return `test-tab-strip__btn${this.isTestTab ? ' test-tab-strip__btn_active' : ''}`;
    }

    get schemaTabBtnClass() {
        return `test-tab-strip__btn${this.isSchemaTab ? ' test-tab-strip__btn_active' : ''}`;
    }

    get prettyTabBtnClass() {
        return `response-card__sub-tab${this.isResponsePrettyTab ? ' response-card__sub-tab_active' : ''}`;
    }

    get rawTabBtnClass() {
        return `response-card__sub-tab${this.isResponseRawTab ? ' response-card__sub-tab_active' : ''}`;
    }

    get headersTabBtnClass() {
        return `response-card__sub-tab${this.isResponseHeadersTab ? ' response-card__sub-tab_active' : ''}`;
    }

    get hasResponse() {
        return this.responseMetadata !== null;
    }

    get testSurfaceClass() {
        return this.hasResponse
            ? 'test-surface test-surface_executed'
            : 'test-surface test-surface_empty';
    }

    get inputsCardClass() {
        return this.inputsHasOverflow
            ? 'inputs-card inputs-card_overflow'
            : 'inputs-card';
    }

    get descriptionContainerClass() {
        const base = 'tool-doc';
        return this.descriptionExpanded ? `${base} ${base}_expanded` : `${base} ${base}_collapsed`;
    }

    get descriptionToggleLabel() {
        return this.descriptionExpanded ? 'Show less' : 'Show more';
    }

    get hasDescription() {
        return (
            this.selectedTool
            && typeof this.selectedTool.description === 'string'
            && this.selectedTool.description.trim().length > 0
        );
    }

    /**
     * Whether the testing-view description deserves a "Show more"
     * affordance. Reuses the same heuristic as the tool tiles so a
     * description that fits inline in the tile also fits inline in
     * the testing view.
     */
    get descriptionToggleNeeded() {
        if (!this.hasDescription) return false;
        return this.shouldClampDescription(this.selectedTool.description || '');
    }

    get hasResponseHeaders() {
        return !!(this.responseMetadata && this.responseMetadata.hasHeaders);
    }

    /**
     * After each render, check whether the inputs scroll region overflows
     * its container. We only update state when the boolean actually flips
     * so the renderedCallback does not loop -- assigning the same value
     * still triggers an LWC reactivity check, but no extra renders.
     */
    renderedCallback() {
        if (!this.isTestingView) return;
        const el = this.template.querySelector('[data-id="inputs-scroll"]');
        if (!el) {
            if (this.inputsHasOverflow) {
                this.inputsHasOverflow = false;
            }
            return;
        }
        const overflows = el.scrollHeight > el.clientHeight + 1;
        if (overflows !== this.inputsHasOverflow) {
            this.inputsHasOverflow = overflows;
        }
    }
}
