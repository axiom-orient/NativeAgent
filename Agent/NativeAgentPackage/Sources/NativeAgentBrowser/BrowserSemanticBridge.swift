import Foundation

#if canImport(WebKit)
import WebKit

struct BrowserBridgeObservation: Decodable {
    let pageRevision: String
    let visibleText: String
    let elements: [BrowserElement]
    let visibleTextWasTruncated: Bool
    let omittedElementCount: Int
}

struct BrowserActionReceipt: Decodable {
    let pageRevision: String
}

enum BrowserSemanticBridge {
    @MainActor
    static var contentWorld: WKContentWorld {
        WKContentWorld.world(name: "NativeAgent.SemanticBrowser")
    }

    static let source = #"""
    (() => {
      "use strict";
      if (globalThis.__nativeAgentBrowserBridge) return;

      const ids = new WeakMap();
      const elements = new Map();
      let nextID = 1;
      let revision = 1;
      const token = globalThis.crypto?.randomUUID?.()
        ?? `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
      const encoder = new TextEncoder();

      const pageRevision = () => `${token}:${revision}`;
      const changed = () => { revision += 1; };
      const elementID = element => {
        let id = ids.get(element);
        if (!id) {
          id = `e${nextID++}`;
          ids.set(element, id);
        }
        elements.set(id, element);
        return id;
      };
      const clean = value => String(value ?? "").slice(0, 2048).replace(/\s+/g, " ").trim();
      const truncateUTF8 = (value, maximumBytes) => {
        const text = String(value ?? "");
        const bounded = text.length > maximumBytes ? text.slice(0, maximumBytes) : text;
        if (encoder.encode(bounded).byteLength <= maximumBytes) {
          return { text: bounded, truncated: bounded.length !== text.length };
        }
        let low = 0;
        let high = bounded.length;
        while (low < high) {
          const middle = Math.ceil((low + high) / 2);
          if (encoder.encode(bounded.slice(0, middle)).byteLength <= maximumBytes) low = middle;
          else high = middle - 1;
        }
        let end = low;
        const code = bounded.charCodeAt(end - 1);
        if (end > 0 && code >= 0xD800 && code <= 0xDBFF) end -= 1;
        return { text: bounded.slice(0, end), truncated: true };
      };
      const isVisible = element => {
        if (!(element instanceof Element) || !element.isConnected) return false;
        if (element.hidden || element.closest('[hidden],[aria-hidden="true"]')) return false;
        const style = getComputedStyle(element);
        if (style.display === "none" || style.visibility === "hidden" || Number(style.opacity) === 0) return false;
        const rect = element.getBoundingClientRect();
        return rect.width > 0 && rect.height > 0;
      };
      const visibleText = maximumBytes => {
        if (!document.body) return { text: "", truncated: false };
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        const fragments = [];
        let remainingBytes = maximumBytes;
        let scannedNodes = 0;
        const maximumScannedNodes = 100000;
        while (walker.nextNode()) {
          scannedNodes += 1;
          if (scannedNodes > maximumScannedNodes) {
            return { text: fragments.join(""), truncated: true };
          }
          const parent = walker.currentNode.parentElement;
          if (!parent || !isVisible(parent)) continue;
          const raw = String(walker.currentNode.nodeValue ?? "");
          const candidateLimit = Math.min(raw.length, Math.max(2048, remainingBytes * 2));
          const candidate = raw.slice(0, candidateLimit).replace(/\s+/g, " ").trim();
          if (!candidate) {
            if (raw.length > candidateLimit) {
              return { text: fragments.join(""), truncated: true };
            }
            continue;
          }
          const segment = (fragments.length ? " " : "") + candidate;
          const bounded = truncateUTF8(segment, remainingBytes);
          fragments.push(bounded.text);
          remainingBytes -= encoder.encode(bounded.text).byteLength;
          if (bounded.truncated || raw.length > candidateLimit || remainingBytes === 0) {
            return { text: fragments.join(""), truncated: true };
          }
        }
        return { text: fragments.join(""), truncated: false };
      };
      const inputType = element => element instanceof HTMLInputElement
        ? String(element.type || "text").toLowerCase()
        : "";
      const isSensitive = element => {
        if (!(element instanceof HTMLInputElement) && !(element instanceof HTMLTextAreaElement)) return false;
        const type = inputType(element);
        if (type === "password" || type === "file" || type === "hidden") return true;
        const autocomplete = clean(element.getAttribute("autocomplete")).toLowerCase();
        if (/password|one-time-code|cc-|webauthn/.test(autocomplete)) return true;
        const identity = [element.name, element.id, element.getAttribute("aria-label")]
          .map(clean).join(" ").toLowerCase();
        return /password|passwd|secret|token|otp|one.?time|cvv|cvc|card.?number/.test(identity);
      };
      const role = element => {
        const explicit = clean(element.getAttribute("role"));
        if (explicit) return explicit;
        if (element instanceof HTMLAnchorElement) return "link";
        if (element instanceof HTMLButtonElement) return "button";
        if (element instanceof HTMLSelectElement) return "combobox";
        if (element instanceof HTMLTextAreaElement) return "textbox";
        if (element instanceof HTMLInputElement) {
          const type = inputType(element);
          if (type === "checkbox") return "checkbox";
          if (type === "radio") return "radio";
          if (["button", "submit", "reset", "image"].includes(type)) return "button";
          return "textbox";
        }
        if (element.isContentEditable) return "textbox";
        return element.tagName.toLowerCase();
      };
      const label = element => {
        const labelledBy = clean(element.getAttribute("aria-labelledby"));
        const labelled = labelledBy
          ? labelledBy.split(/\s+/).map(id => clean(document.getElementById(id)?.innerText)).filter(Boolean).join(" ")
          : "";
        const labels = element.labels ? Array.from(element.labels).map(item => clean(item.innerText)).join(" ") : "";
        const candidate = clean(
          element.getAttribute("aria-label")
          || labelled
          || labels
          || element.innerText
          || (isSensitive(element) ? "" : element.value)
          || element.getAttribute("placeholder")
          || element.getAttribute("title")
          || role(element)
        );
        return truncateUTF8(candidate, 512).text;
      };
      const selected = element => {
        if (element instanceof HTMLInputElement && ["checkbox", "radio"].includes(inputType(element))) {
          return Boolean(element.checked);
        }
        if (element instanceof HTMLSelectElement) return element.selectedIndex >= 0;
        const aria = element.getAttribute("aria-selected") ?? element.getAttribute("aria-checked");
        return aria === null ? null : aria === "true";
      };
      const editable = element => {
        if (element instanceof HTMLTextAreaElement) return !element.readOnly && !element.disabled;
        if (element instanceof HTMLInputElement) {
          return !element.readOnly && !element.disabled
            && !["button", "submit", "reset", "checkbox", "radio", "file", "hidden", "image"].includes(inputType(element));
        }
        return Boolean(element.isContentEditable);
      };
      const requireRevision = expected => {
        const actual = pageRevision();
        if (expected !== actual) throw new Error(`__NATIVE_AGENT_STALE_PAGE__|${expected}|${actual}`);
      };
      const requireElement = id => {
        const element = elements.get(id);
        if (!element || !element.isConnected || !isVisible(element)) {
          elements.delete(id);
          throw new Error(`__NATIVE_AGENT_ELEMENT_NOT_FOUND__|${id}`);
        }
        return element;
      };
      const dispatch = element => {
        element.dispatchEvent(new Event("input", { bubbles: true, composed: true }));
        element.dispatchEvent(new Event("change", { bubbles: true, composed: true }));
      };

      const observer = new MutationObserver(changed);
      const startObserver = () => {
        if (!document.documentElement) return;
        observer.observe(document.documentElement, {
          subtree: true,
          childList: true,
          attributes: true,
          characterData: true
        });
      };
      if (document.documentElement) startObserver();
      else document.addEventListener("DOMContentLoaded", startObserver, { once: true });

      globalThis.__nativeAgentBrowserBridge = Object.freeze({
        observe(options) {
          const maximumVisibleTextBytes = Math.max(1, Number(options.maximumVisibleTextBytes) || 1);
          const maximumElements = Math.max(1, Number(options.maximumElements) || 1);
          const visible = visibleText(maximumVisibleTextBytes);
          const selectors = [
            "a[href]", "button", "input", "textarea", "select", "[role]", "[contenteditable='true']"
          ].join(",");
          const candidates = document.querySelectorAll(selectors);
          const observed = [];
          let omittedElementCount = 0;
          const maximumScanned = Math.min(20_000, maximumElements * 40);
          elements.clear();
          for (let index = 0; index < candidates.length && index < maximumScanned; index += 1) {
            const element = candidates[index];
            if (!isVisible(element)) continue;
            if (observed.length >= maximumElements) {
              omittedElementCount += 1;
              continue;
            }
            const sensitive = isSensitive(element);
            observed.push({
              id: elementID(element),
              role: role(element),
              label: label(element),
              isEnabled: !(element.disabled || element.getAttribute("aria-disabled") === "true"),
              isEditable: editable(element) && !sensitive,
              isSensitive: sensitive,
              isSelected: selected(element)
            });
          }
          if (candidates.length > maximumScanned) omittedElementCount += candidates.length - maximumScanned;
          return {
            pageRevision: pageRevision(),
            visibleText: visible.text,
            elements: observed,
            visibleTextWasTruncated: visible.truncated,
            omittedElementCount
          };
        },

        click(options) {
          requireRevision(options.expectedPageRevision);
          const element = requireElement(options.elementID);
          if (element.disabled || element.getAttribute("aria-disabled") === "true") {
            throw new Error("__NATIVE_AGENT_UNSUPPORTED_ELEMENT__|disabled");
          }
          if (element instanceof HTMLInputElement && inputType(element) === "file") {
            throw new Error("__NATIVE_AGENT_SENSITIVE_INPUT__|file");
          }
          element.focus({ preventScroll: false });
          element.click();
          changed();
          return { pageRevision: pageRevision() };
        },

        typeText(options) {
          requireRevision(options.expectedPageRevision);
          const element = requireElement(options.elementID);
          if (isSensitive(element)) throw new Error("__NATIVE_AGENT_SENSITIVE_INPUT__|input");
          if (!editable(element)) throw new Error("__NATIVE_AGENT_UNSUPPORTED_ELEMENT__|not-editable");
          element.focus({ preventScroll: false });
          if (element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement) {
            element.value = String(options.text ?? "");
          } else if (element.isContentEditable) {
            element.textContent = String(options.text ?? "");
          } else {
            throw new Error("__NATIVE_AGENT_UNSUPPORTED_ELEMENT__|not-editable");
          }
          dispatch(element);
          changed();
          return { pageRevision: pageRevision() };
        },

        selectValue(options) {
          requireRevision(options.expectedPageRevision);
          const element = requireElement(options.elementID);
          if (!(element instanceof HTMLSelectElement) || element.disabled) {
            throw new Error("__NATIVE_AGENT_UNSUPPORTED_ELEMENT__|not-select");
          }
          const value = String(options.value ?? "");
          if (!Array.from(element.options).some(option => option.value === value)) {
            throw new Error("__NATIVE_AGENT_UNSUPPORTED_ELEMENT__|missing-option");
          }
          element.value = value;
          dispatch(element);
          changed();
          return { pageRevision: pageRevision() };
        },

        scroll(options) {
          requireRevision(options.expectedPageRevision);
          const deltaX = Math.max(-100000, Math.min(100000, Number(options.deltaX) || 0));
          const deltaY = Math.max(-100000, Math.min(100000, Number(options.deltaY) || 0));
          window.scrollBy({ left: deltaX, top: deltaY, behavior: "instant" });
          changed();
          return { pageRevision: pageRevision() };
        }
      });
    })();
    """#
}
#endif
