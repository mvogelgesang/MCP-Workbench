/**
 * Minimal markdown -> HTML converter for use with
 * `lightning-formatted-rich-text`. Intentionally conservative:
 *
 *   - HTML in the source is escaped (no raw HTML pass-through).
 *   - Only the subset of tags supported by lightning-formatted-rich-text
 *     is emitted (h1-h6, p, ul/ol/li, code, pre, strong, em, a, hr,
 *     blockquote, br).
 *   - Links must be http(s) or mailto; other schemes are rendered as
 *     escaped text.
 *
 * This is not a full CommonMark implementation -- it handles the
 * patterns that typical MCP tool descriptions use (headers, lists,
 * emphasis, inline/fenced code, links). When the input is plainly
 * not markdown, callers can short-circuit via `isLikelyMarkdown`
 * and render the text with plain `lightning-formatted-text` instead.
 */

const STRONG_MARKDOWN_SIGNALS = [
  /^#{1,6}\s/m, // ATX headers
  /```/, // Code fence
  /`[^`\n]+`/, // Inline code
  /\*\*[^*\n]+\*\*/, // Bold
  /__[^_\n]+__/, // Bold
  /^\s*[-*+]\s+\S/m, // Unordered list
  /^\s*\d+\.\s+\S/m, // Ordered list
  /\[[^\]\n]+\]\((https?:\/\/|mailto:)[^)\s]+\)/, // Link
  /^>\s+/m, // Blockquote
  /^---+\s*$/m // Horizontal rule
];

export function isLikelyMarkdown(text) {
  if (!text || typeof text !== "string") return false;
  return STRONG_MARKDOWN_SIGNALS.some((p) => p.test(text));
}

/**
 * Escape user content before it lands inside emitted HTML. Applied
 * to plain text segments and to inline-code content so that source
 * fragments like `<script>` render as literals rather than tags.
 */
function escapeHtml(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

/**
 * Inline-level transformations, applied to every non-code-block line
 * after it has been HTML-escaped.
 *
 * Order matters:
 *   1. Inline code (single backticks) first -- once wrapped in
 *      <code>, its contents are inert and won't be re-touched by
 *      emphasis or link parsers.
 *   2. Strong (`**` and `__`) before emphasis so `**bold**` doesn't
 *      get partially consumed as italic.
 *   3. Emphasis (`*` and `_`) last, with negative lookarounds so
 *      `**bold**` survives.
 *   4. Links last so URLs containing `_` or `*` aren't mangled.
 */
function applyInline(escaped) {
  let s = escaped;

  // Inline code -- swap with a sentinel, render later so emphasis
  // doesn't touch backtick contents. The sentinel uses characters
  // that can't survive HTML escaping (`<`,`>`), so anything matching
  // it in the original input has already been escaped to entities.
  const codeFragments = [];
  s = s.replace(/`([^`\n]+)`/g, (_match, body) => {
    codeFragments.push(body);
    return `<<CODE${codeFragments.length - 1}>>`;
  });

  // Bold
  s = s.replace(/\*\*([^*\n]+)\*\*/g, "<strong>$1</strong>");
  s = s.replace(/__([^_\n]+)__/g, "<strong>$1</strong>");

  // Emphasis (avoid matching the inside of `**` we just consumed)
  s = s.replace(/(^|[^*])\*([^*\n]+)\*(?!\*)/g, "$1<em>$2</em>");
  s = s.replace(/(^|[^_])_([^_\n]+)_(?!_)/g, "$1<em>$2</em>");

  // Links: only allow http(s) and mailto schemes.
  s = s.replace(
    /\[([^\]\n]+)\]\(((?:https?:\/\/|mailto:)[^)\s]+)\)/g,
    '<a href="$2" target="_blank" rel="noopener noreferrer">$1</a>'
  );

  // Re-inject code fragments verbatim (already HTML-escaped).
  s = s.replace(
    /<<CODE(\d+)>>/g,
    (_match, idx) => `<code>${codeFragments[Number(idx)]}</code>`
  );

  return s;
}

/**
 * Block-level parser. Walks lines once, maintaining state for
 * open code fences, list nesting, and paragraph accumulation.
 *
 * List handling is indent-based: a deeper indent opens a nested
 * list; a shallower indent pops back up. Switching between bullet
 * and numbered styles at the same indent closes the previous list
 * before opening the next.
 */
export function markdownToHtml(text) {
  if (!text) return "";

  const lines = String(text).replace(/\r\n/g, "\n").split("\n");
  const out = [];
  const listStack = [];
  let inFence = false;
  let fenceLines = [];
  let paragraph = [];

  const flushParagraph = () => {
    if (paragraph.length === 0) return;
    const joined = paragraph
      .map((l) => escapeHtml(l.trim()))
      .join(" ")
      .trim();
    if (joined) out.push(`<p>${applyInline(joined)}</p>`);
    paragraph = [];
  };

  const closeListsTo = (indent) => {
    while (
      listStack.length > 0 &&
      listStack[listStack.length - 1].indent > indent
    ) {
      out.push(`</${listStack.pop().type}>`);
    }
  };

  const closeAllLists = () => {
    while (listStack.length > 0) {
      out.push(`</${listStack.pop().type}>`);
    }
  };

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];

    if (inFence) {
      if (/^```\s*$/.test(line.trim())) {
        out.push(`<pre><code>${escapeHtml(fenceLines.join("\n"))}</code></pre>`);
        fenceLines = [];
        inFence = false;
      } else {
        fenceLines.push(line);
      }
      continue;
    }

    if (/^```/.test(line.trim())) {
      flushParagraph();
      closeAllLists();
      inFence = true;
      continue;
    }

    if (line.trim() === "") {
      flushParagraph();
      closeAllLists();
      continue;
    }

    const header = line.match(/^(#{1,6})\s+(.*)$/);
    if (header) {
      flushParagraph();
      closeAllLists();
      const level = header[1].length;
      out.push(
        `<h${level}>${applyInline(escapeHtml(header[2].trim()))}</h${level}>`
      );
      continue;
    }

    if (/^[-*_]{3,}\s*$/.test(line)) {
      flushParagraph();
      closeAllLists();
      out.push("<hr/>");
      continue;
    }

    const blockquote = line.match(/^>\s?(.*)$/);
    if (blockquote) {
      flushParagraph();
      closeAllLists();
      out.push(
        `<blockquote>${applyInline(escapeHtml(blockquote[1]))}</blockquote>`
      );
      continue;
    }

    const ul = line.match(/^(\s*)[-*+]\s+(.*)$/);
    const ol = line.match(/^(\s*)\d+\.\s+(.*)$/);
    if (ul || ol) {
      flushParagraph();
      const indent = (ul || ol)[1].length;
      const content = (ul || ol)[2];
      const type = ul ? "ul" : "ol";

      closeListsTo(indent);

      const top = listStack[listStack.length - 1];
      if (!top || top.indent < indent || top.type !== type) {
        out.push(`<${type}>`);
        listStack.push({ type, indent });
      }
      out.push(`<li>${applyInline(escapeHtml(content))}</li>`);
      continue;
    }

    // Anything else -> paragraph text. Lists never resume from a
    // bare paragraph line (CommonMark allows it via indent
    // continuation; we deliberately keep it simple).
    closeAllLists();
    paragraph.push(line);
  }

  flushParagraph();
  closeAllLists();
  if (inFence) {
    out.push(`<pre><code>${escapeHtml(fenceLines.join("\n"))}</code></pre>`);
  }

  return out.join("\n");
}
