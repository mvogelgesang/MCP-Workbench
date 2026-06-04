import { LightningElement, api, track } from "lwc";

/**
 * DevTools-style network trace panel. Renders one row per HTTP
 * callout that the Apex layer recorded (success or failure) and lets
 * the user expand any row to inspect headers, payload, response, and
 * error explanation.
 *
 * Stateless with regard to the underlying call list: the parent
 * owns `entries` and we re-decorate on each set. Local state is
 * limited to which row is currently expanded.
 */
export default class McpNetworkTrace extends LightningElement {
  _entries = [];
  @track expandedIds = {};

  @api
  get entries() {
    return this._entries;
  }
  set entries(value) {
    this._entries = Array.isArray(value) ? value : [];
  }

  @api expanded = false;

  /**
   * Decorated copy of `entries` ready for the template. Each row
   * gets a stable React-style key, a colored status badge, a
   * monospaced duration label, a short ISO timestamp, and
   * pre-formatted JSON bodies so the template can stay declarative.
   */
  get decoratedEntries() {
    return this._entries.map((entry, idx) => {
      const seq = idx + 1;
      const isError = !!entry.isError;
      const statusCode = entry.statusCode != null ? entry.statusCode : "--";
      const statusVariant = this.statusVariantFor(entry);
      const statusIcon = this.statusIconFor(entry);
      const statusLabel = this.statusLabelFor(entry);
      const rowClass = this.rowClassFor(entry);
      const durationLabel = this.formatDuration(entry.durationMs);
      const startedLabel = this.formatStartedAt(entry.startedAt);
      const isExpanded = !!this.expandedIds[entry.id];

      return {
        ...entry,
        seq,
        key: entry.id || `entry-${idx}`,
        statusCodeLabel: statusCode,
        statusVariant,
        statusIcon,
        statusLabel,
        rowClass,
        durationLabel,
        startedLabel,
        isExpanded,
        hasResponse: entry.responseBody != null && entry.responseBody !== "",
        hasRequest: entry.requestBody != null && entry.requestBody !== "",
        hasRequestHeaders:
          entry.requestHeaders && Object.keys(entry.requestHeaders).length > 0,
        hasResponseHeaders:
          entry.responseHeaders &&
          Object.keys(entry.responseHeaders).length > 0,
        requestHeadersList: this.headersToList(
          entry.requestHeaders,
          `${entry.id}-req`
        ),
        responseHeadersList: this.headersToList(
          entry.responseHeaders,
          `${entry.id}-res`
        ),
        prettyRequestBody: this.tryPrettyJson(entry.requestBody),
        prettyResponseBody: this.tryPrettyJson(entry.responseBody),
        toggleIcon: isExpanded ? "utility:chevrondown" : "utility:chevronright",
        showError: isError,
        errorTypeLabel: this.errorTypeLabel(entry.errorType)
      };
    });
  }

  get entryCount() {
    return this._entries.length;
  }

  get errorCount() {
    return this._entries.filter((e) => e.isError).length;
  }

  get hasEntries() {
    return this.entryCount > 0;
  }

  get headerLabel() {
    const errors = this.errorCount;
    const total = this.entryCount;
    if (!total) {
      return "Network (no requests yet)";
    }
    if (errors > 0) {
      return `Network (${total} requests, ${errors} error${errors === 1 ? "" : "s"})`;
    }
    return `Network (${total} request${total === 1 ? "" : "s"})`;
  }

  get headerIcon() {
    return this.errorCount > 0 ? "utility:error" : "utility:wifi";
  }

  get headerIconVariant() {
    return this.errorCount > 0 ? "error" : "success";
  }

  get toggleIcon() {
    return this.expanded ? "utility:chevrondown" : "utility:chevronup";
  }

  get bodyClass() {
    return this.expanded
      ? "trace-body trace-body_expanded"
      : "trace-body trace-body_collapsed";
  }

  handleHeaderToggle() {
    this.dispatchEvent(new CustomEvent("toggle"));
  }

  handleClear(event) {
    // Don't let the click bubble into the header-toggle handler
    // when the user clicks the Clear button.
    event.stopPropagation();
    this.dispatchEvent(new CustomEvent("clear"));
  }

  handleRowToggle(event) {
    const id = event.currentTarget.dataset.id;
    if (!id) return;
    const next = { ...this.expandedIds };
    if (next[id]) {
      delete next[id];
    } else {
      next[id] = true;
    }
    this.expandedIds = next;
  }

  statusVariantFor(entry) {
    if (entry.isError) return "error";
    if (entry.statusCode >= 200 && entry.statusCode < 300) return "success";
    if (entry.statusCode >= 300 && entry.statusCode < 400) return "warning";
    return "error";
  }

  statusIconFor(entry) {
    if (entry.isError) return "utility:error";
    if (entry.statusCode >= 200 && entry.statusCode < 300)
      return "utility:success";
    if (entry.statusCode >= 300 && entry.statusCode < 400)
      return "utility:warning";
    return "utility:error";
  }

  statusLabelFor(entry) {
    if (entry.statusCode != null) {
      return `${entry.statusCode}${entry.statusText ? " " + entry.statusText : ""}`;
    }
    if (entry.isError) {
      return entry.errorMessage ? entry.errorMessage : "Failed";
    }
    return "Pending";
  }

  rowClassFor(entry) {
    if (entry.isError) return "trace-row trace-row_error";
    if (entry.statusCode >= 200 && entry.statusCode < 300)
      return "trace-row trace-row_success";
    if (entry.statusCode >= 300 && entry.statusCode < 400)
      return "trace-row trace-row_redirect";
    return "trace-row trace-row_error";
  }

  errorTypeLabel(errorType) {
    switch (errorType) {
      case "http":
        return "HTTP error";
      case "callout":
        return "Callout exception";
      case "parse":
        return "Parse error";
      case "mcp":
        return "MCP error";
      case "unexpected":
        return "Unexpected exception";
      default:
        return errorType || "Error";
    }
  }

  formatDuration(durationMs) {
    if (durationMs == null) return "--";
    if (durationMs < 1000) return `${durationMs} ms`;
    return `${(durationMs / 1000).toFixed(2)} s`;
  }

  formatStartedAt(iso) {
    if (!iso) return "--";
    try {
      const d = new Date(iso);
      if (isNaN(d.getTime())) return iso;
      return d.toLocaleTimeString();
    } catch {
      return iso;
    }
  }

  headersToList(headerMap, prefix) {
    if (!headerMap) return [];
    return Object.keys(headerMap).map((name, idx) => ({
      key: `${prefix}-${idx}`,
      name,
      value: headerMap[name]
    }));
  }

  /**
   * Pretty-print a value that may already be a JSON string.
   *
   * Three formats are recognised:
   *   1. A JSON object/array literal -> parse + stringify(indent=2).
   *   2. An SSE response of the form `event: message\ndata: {...}`
   *      -> extract the first `data:` line and pretty-print its JSON.
   *      The original SSE framing is preserved as a comment-style
   *      preamble so the user can still see they hit an SSE endpoint.
   *   3. Anything else (HTML error pages, plain text, etc.) -> returned
   *      unchanged so the panel still shows something useful.
   *
   * Nested stringified JSON (common in MCP `content[].text`) is
   * recursively un-stringified before printing so the resulting body
   * is fully readable rather than a mix of indented JSON and escaped
   * inline strings.
   */
  tryPrettyJson(value) {
    if (value == null) return "";
    if (typeof value !== "string") {
      try {
        return JSON.stringify(this.unstringifyNestedJson(value), null, 2);
      } catch {
        return String(value);
      }
    }
    const trimmed = value.trim();
    if (!trimmed) return value;
    if (trimmed.startsWith("{") || trimmed.startsWith("[")) {
      try {
        const parsed = this.unstringifyNestedJson(JSON.parse(trimmed));
        return JSON.stringify(parsed, null, 2);
      } catch {
        // Not parseable as JSON; fall through to SSE / raw.
      }
    }
    if (trimmed.includes("event:") && trimmed.includes("data:")) {
      const preamble = [];
      let parsedData = null;
      const lines = trimmed.split("\n");
      for (const line of lines) {
        if (line.startsWith("data: ") && parsedData == null) {
          const payload = line.substring(6).trim();
          try {
            const parsed = this.unstringifyNestedJson(JSON.parse(payload));
            parsedData = JSON.stringify(parsed, null, 2);
          } catch {
            // The data line wasn't JSON; abandon SSE pretty-printing.
            return value;
          }
        } else if (line.trim() !== "" && parsedData == null) {
          preamble.push(line);
        }
      }
      if (parsedData != null) {
        return `${preamble.join("\n")}\ndata:\n${parsedData}`;
      }
    }
    return value;
  }

  /**
   * Walk a parsed JSON structure and replace any string value that
   * itself parses as a JSON object or array with the parsed value.
   * Mirrors the behavior of the parent's `formatMcpResponse` but
   * works generically on the whole tree (not just `result.content`).
   */
  unstringifyNestedJson(node) {
    if (Array.isArray(node)) {
      return node.map((v) => this.unstringifyNestedJson(v));
    }
    if (node !== null && typeof node === "object") {
      const out = {};
      for (const k of Object.keys(node)) {
        out[k] = this.unstringifyNestedJson(node[k]);
      }
      return out;
    }
    if (typeof node === "string") {
      const trimmed = node.trim();
      if (
        (trimmed.startsWith("{") && trimmed.endsWith("}")) ||
        (trimmed.startsWith("[") && trimmed.endsWith("]"))
      ) {
        try {
          return this.unstringifyNestedJson(JSON.parse(trimmed));
        } catch {
          return node;
        }
      }
    }
    return node;
  }
}
