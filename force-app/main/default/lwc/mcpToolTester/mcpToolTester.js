import { LightningElement, track, wire } from 'lwc';
import getAvailableServers from '@salesforce/apex/McpToolTester.getAvailableServers';
import initializeConnection from '@salesforce/apex/McpToolTester.initializeConnection';
import getAvailableTools from '@salesforce/apex/McpToolTester.getAvailableTools';
import callTool from '@salesforce/apex/McpToolTester.callTool';

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
            this.handleApexError(err, 'Error Loading Tools');
        } finally {
            this.isLoading = false;
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
     * Execute the selected tool
     */
    async handleExecuteTool() {
        if (!this.selectedTool) return;

        this.isLoading = true;
        this.error = '';
        this.errorDetails = null;
        this.toolResponse = '';

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
     * Navigate back to server selection
     */
    handleBackToServers() {
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
