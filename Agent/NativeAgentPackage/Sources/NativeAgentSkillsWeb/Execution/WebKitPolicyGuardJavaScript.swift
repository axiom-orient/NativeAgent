import Foundation

#if canImport(WebKit)
import WebKit

enum WebKitPolicyGuardJavaScript {
    static let localPureSource = #"""
    (() => {
      const denied = (surface) => { throw new Error(`NativeAgent local run_js blocks ${surface}`); };
      const deniedPromise = (surface) => Promise.reject(new Error(`NativeAgent local run_js blocks ${surface}`));
      const replaceValue = (owner, name, value) => {
        if (!(name in owner)) return;
        Object.defineProperty(owner, name, {
          value,
          configurable: false,
          enumerable: false,
          writable: false
        });
      };
      const replaceGetter = (owner, name, value) => {
        if (!(name in owner)) return;
        Object.defineProperty(owner, name, {
          get: () => value(),
          configurable: false,
          enumerable: false
        });
      };

      replaceValue(window, 'fetch', () => deniedPromise('network access'));
      replaceValue(window, 'XMLHttpRequest', function() { denied('network access'); });
      replaceValue(window, 'WebSocket', function() { denied('network access'); });
      replaceValue(window, 'EventSource', function() { denied('network access'); });
      replaceValue(window, 'WebTransport', function() { denied('network access'); });
      replaceValue(window, 'Worker', function() { denied('worker execution'); });
      replaceValue(window, 'SharedWorker', function() { denied('worker execution'); });
      replaceValue(window, 'RTCPeerConnection', function() { denied('peer network access'); });
      replaceValue(window, 'webkitRTCPeerConnection', function() { denied('peer network access'); });
      replaceValue(window, 'open', () => denied('external navigation'));
      replaceValue(window, 'openDatabase', () => denied('persistent storage'));
      replaceValue(window, 'showOpenFilePicker', () => deniedPromise('file picker'));
      replaceValue(window, 'showSaveFilePicker', () => deniedPromise('file picker'));
      replaceValue(window, 'showDirectoryPicker', () => deniedPromise('file picker'));

      if (navigator.sendBeacon) {
        replaceValue(navigator, 'sendBeacon', () => denied('network access'));
      }
      if (navigator.serviceWorker) {
        replaceGetter(navigator, 'serviceWorker', () => ({
          register: () => deniedPromise('service worker'),
          getRegistration: () => deniedPromise('service worker'),
          getRegistrations: () => deniedPromise('service worker')
        }));
      }

      for (const name of ['localStorage', 'sessionStorage', 'indexedDB', 'caches']) {
        try { replaceGetter(window, name, () => denied(name)); } catch (_) {}
      }
      for (const name of [
        'mediaDevices', 'geolocation', 'bluetooth', 'usb', 'serial', 'hid',
        'credentials', 'clipboard', 'contacts'
      ]) {
        try { replaceGetter(navigator, name, () => denied(`device capability ${name}`)); } catch (_) {}
      }
      try {
        Object.defineProperty(window, '\#(WebKitSkillScriptContract.nativeBridgeName)', {
          get: () => denied('native bridge intents'),
          configurable: false
        });
      } catch (_) {}

      Object.defineProperty(window, '\#(WebKitSkillScriptContract.localPurePolicyFlag)', {
        value: true,
        configurable: false,
        enumerable: false,
        writable: false
      });
    })();
    """#
}
#endif
